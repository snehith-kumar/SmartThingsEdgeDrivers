-- KNX IoT 3rd-Party API client (KNX Standard V3.0, ch. 3/10/4).
--
-- Pure outbound HTTPS client. Payloads are JSON:API ("application/vnd.api+json"):
--   GET  /functions, /functions/{id}/datapoints, /datapoints [?filter[timestamp][gt]=..]
--   PUT  /datapoints/values   { data = { {id=..., type="datapoint", attributes={value=".."}} } }
--   POST /oauth/access        OAuth2 client-credentials, HTTP Basic client auth, form body
--
-- Datapoint values are JSON *strings* on the wire ("on", "63") — coercion to
-- typed Lua values happens in mapping.lua, not here.
--
-- API base path is "/" exactly (OAS servers block); controllers commonly use
-- self-signed certs, so the TLS mode is client-verify-none (lab default).
local cosock = require "cosock"
local https = cosock.asyncify "ssl.https"
local ltn12 = require "ltn12"
local json = require "dkjson"
local base64 = require "st.base64"
local socket_url = require "socket.url"
local logger = require "logger"

local KnxApi = {}
KnxApi.__index = KnxApi

-- The OAS defines lowercase scopes; the PoC server historically used
-- capitalized ones. Try in this order on scope rejection.
local SCOPE_VARIANTS = { "read write manage", "Read Write Manage" }
local TOKEN_EARLY_REFRESH = 30 -- s before expiry to consider a token stale
local REQUEST_TIMEOUT = 10 -- s per HTTP request

function KnxApi.new(config)
  local self = setmetatable({}, KnxApi)
  self.host = config.host
  self.port = config.port or 443
  self.client_id = config.client_id
  self.client_secret = config.client_secret
  self.label = config.label or self.host -- log context
  self.token = nil
  self.token_expires_at = 0
  self.scope_index = 1
  return self
end

function KnxApi:base_url()
  return string.format("https://%s:%d", self.host, self.port)
end

local function urlencode_form(params)
  local parts = {}
  for k, v in pairs(params) do
    parts[#parts + 1] = socket_url.escape(k) .. "=" .. socket_url.escape(v)
  end
  return table.concat(parts, "&")
end

local function build_query(query)
  if not query or next(query) == nil then return "" end
  local parts = {}
  for k, v in pairs(query) do
    parts[#parts + 1] = socket_url.escape(k) .. "=" .. socket_url.escape(tostring(v))
  end
  return "?" .. table.concat(parts, "&")
end

-- Low-level HTTPS exchange. Returns (status, decoded-body-or-nil, err).
function KnxApi:_raw_request(method, path, query, headers, body)
  local chunks = {}
  local url = self:base_url() .. path .. build_query(query)
  https.TIMEOUT = REQUEST_TIMEOUT
  local ok, status_or_err = https.request({
    url = url,
    method = method,
    headers = headers,
    source = body and ltn12.source.string(body) or nil,
    sink = ltn12.sink.table(chunks),
    protocol = "any",
    verify = "none",
  })
  if not ok then
    return nil, nil, tostring(status_or_err)
  end
  local raw = table.concat(chunks)
  local decoded = nil
  if #raw > 0 then
    local parsed, _, jerr = json.decode(raw)
    if parsed ~= nil then
      decoded = parsed
    elseif jerr then
      logger.warn(self.label, "http", "non-JSON body on %s %s (%s)", method, path, tostring(jerr))
    end
  end
  return status_or_err, decoded, nil
end

-- OAuth2 client-credentials token exchange (POST /oauth/access).
-- Client authenticates with HTTP Basic; body is x-www-form-urlencoded.
function KnxApi:authenticate()
  if not (self.host and self.client_id and self.client_secret) then
    return false, "controller host/credentials not configured"
  end
  local basic = base64.encode(self.client_id .. ":" .. self.client_secret)
  for i = self.scope_index, #SCOPE_VARIANTS do
    local scope = SCOPE_VARIANTS[i]
    local body = urlencode_form({ grant_type = "client_credentials", scope = scope })
    logger.info(self.label, "auth", "requesting token (scope variant %d)", i)
    local status, data, err = self:_raw_request("POST", "/oauth/access", nil, {
      ["Authorization"] = "Basic " .. basic,
      ["Content-Type"] = "application/x-www-form-urlencoded",
      ["Content-Length"] = tostring(#body),
      ["Accept"] = "application/json",
    }, body)
    if not status then
      return false, "token request failed: " .. tostring(err)
    end
    if status == 200 and data and data.access_token then
      self.token = data.access_token
      self.token_expires_at = os.time() + (tonumber(data.expires_in) or 300) - TOKEN_EARLY_REFRESH
      self.scope_index = i -- remember the variant that worked
      logger.info(self.label, "auth", "token acquired, expires_in=%s", tostring(data.expires_in))
      return true
    end
    logger.warn(self.label, "auth", "token request rejected (HTTP %s), scope variant %d", tostring(status), i)
    -- 400 is the OAuth2 invalid_scope/invalid_request class → try next variant.
    if status ~= 400 then
      return false, "auth failed with HTTP " .. tostring(status)
    end
  end
  self.scope_index = 1
  return false, "all scope variants rejected"
end

function KnxApi:_ensure_token()
  if self.token and os.time() < self.token_expires_at then return true end
  return self:authenticate()
end

-- Authorized JSON:API request; re-authenticates once on 401.
-- Returns (ok, decoded-body-or-err-string, http-status).
function KnxApi:request(method, path, query, body_table)
  local ok, err = self:_ensure_token()
  if not ok then return false, err, nil end

  local body = body_table and json.encode(body_table) or nil
  local headers = {
    ["Authorization"] = "Bearer " .. self.token,
    ["Accept"] = "application/vnd.api+json, application/json",
  }
  if body then
    headers["Content-Type"] = "application/vnd.api+json"
    headers["Content-Length"] = tostring(#body)
  end

  local status, data, req_err = self:_raw_request(method, path, query, headers, body)
  if not status then
    return false, "request failed: " .. tostring(req_err), nil
  end

  if status == 401 then
    logger.warn(self.label, "auth", "401 on %s %s, refreshing token", method, path)
    self.token = nil
    ok, err = self:authenticate()
    if not ok then return false, err, 401 end
    headers["Authorization"] = "Bearer " .. self.token
    status, data, req_err = self:_raw_request(method, path, query, headers, body)
    if not status then
      return false, "request failed after re-auth: " .. tostring(req_err), nil
    end
  end

  if status >= 200 and status < 300 then
    return true, data, status
  end
  return false, "HTTP " .. tostring(status), status
end

-- Fetch every page of a JSON:API collection endpoint into one items array.
-- meta.collection.total drives termination; a defensive page cap avoids
-- looping on a misbehaving server.
function KnxApi:get_collection(path, query)
  local items = {}
  local page = 0
  local MAX_PAGES = 64
  while page < MAX_PAGES do
    local q = { ["page[number]"] = page }
    for k, v in pairs(query or {}) do q[k] = v end
    local ok, data, status = self:request("GET", path, q)
    if not ok then return nil, data, status end
    local batch = (data and data.data) or {}
    for _, item in ipairs(batch) do items[#items + 1] = item end
    local total = data and data.meta and data.meta.collection and data.meta.collection.total
    if #batch == 0 or not total or #items >= total then
      return items
    end
    page = page + 1
  end
  return items
end

function KnxApi:get_node()
  return self:request("GET", "/node")
end

function KnxApi:get_functions()
  return self:get_collection("/functions")
end

function KnxApi:get_function_datapoints(function_id)
  return self:get_collection("/functions/" .. function_id .. "/datapoints")
end

-- since_ts (RFC3339 string) requests only datapoints whose value changed
-- after that instant — the delta-polling path. nil = full read.
function KnxApi:get_datapoints(since_ts)
  local query = nil
  if since_ts then
    query = { ["filter[timestamp][gt]"] = since_ts }
  end
  return self:get_collection("/datapoints", query)
end

-- Write one datapoint value. The wire format is always a string.
function KnxApi:put_value(datapoint_id, value)
  return self:request("PUT", "/datapoints/values", nil, {
    data = {
      {
        id = datapoint_id,
        type = "datapoint",
        attributes = { value = tostring(value) },
      },
    },
  })
end

return KnxApi
