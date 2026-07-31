-- Offline tests for api.lua with a scripted HTTPS stub (test plan TC-P1/P8
-- logic: OAuth2 client-credentials exchange, scope-variant fallback,
-- Bearer header, 401 → re-auth → retry, JSON:API pagination, PUT body shape).
-- Run from the driver root:  lua5.3 src/test/offline_api_test.lua
package.path = "../../../lua_libs/?.lua;../../../lua_libs/?/init.lua;src/?.lua;" .. package.path

-- The hub-native socket layer doesn't exist offline; stub the modules
-- api.lua pulls in through it.
local fake_https = { script = {}, sent = {} }
package.preload["cosock"] = function()
  return { asyncify = function() return fake_https end }
end
package.preload["socket"] = function() return {} end -- socket.url only needs the table to exist

local json = require "dkjson"

function fake_https.request(t)
  local body = nil
  if t.source then
    local chunks = {}
    while true do
      local chunk = t.source()
      if not chunk then break end
      chunks[#chunks + 1] = chunk
    end
    body = table.concat(chunks)
  end
  table.insert(fake_https.sent, { url = t.url, method = t.method, headers = t.headers, body = body })
  local step = table.remove(fake_https.script, 1)
  if not step then error("fake_https: script exhausted for " .. t.url) end
  if step.fail then return nil, step.fail end
  if step.body then t.sink(step.body) end
  return 1, step.status, {}, "HTTP/1.1 " .. step.status
end

local KnxApi = require "api"

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("PASS " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" — " .. tostring(detail)) or ""))
  end
end

local api = KnxApi.new({ host = "192.168.1.50", port = 8443, client_id = "ThirdPartyTestClient", client_secret = "TestClientSecret" })

-- Auth: scope fallback (lowercase rejected with 400 → capitalized accepted) --

fake_https.script = {
  { status = 400, body = json.encode({ error = "invalid_scope" }) },
  { status = 200, body = json.encode({ access_token = "tok-1", token_type = "Bearer", expires_in = 1440 }) },
}
local ok = api:authenticate()
check("auth succeeds via scope fallback", ok == true)
check("token endpoint + port", fake_https.sent[1].url == "https://192.168.1.50:8443/oauth/access", fake_https.sent[1].url)
check("client-credentials form body", fake_https.sent[1].body:find("grant_type=client_credentials", 1, true) ~= nil, fake_https.sent[1].body)
check("first attempt lowercase scope", fake_https.sent[1].body:find("read%%20write%%20manage") ~= nil, fake_https.sent[1].body)
check("second attempt capitalized scope", fake_https.sent[2].body:find("Read%%20Write%%20Manage") ~= nil, fake_https.sent[2].body)
check("HTTP Basic client auth", fake_https.sent[1].headers["Authorization"]:find("^Basic ") ~= nil)

-- Authorized GET + pagination -------------------------------------------------

local function page(items, total)
  return json.encode({ meta = { collection = { number = 0, size = #items, total = total } }, data = items })
end

fake_https.script = {
  { status = 200, body = page({ { id = "f1", type = "function" }, { id = "f2", type = "function" } }, 3) },
  { status = 200, body = page({ { id = "f3", type = "function" } }, 3) },
}
local fns = api:get_functions()
check("pagination collects all pages", fns and #fns == 3, fns and #fns)
check("Bearer token on requests", fake_https.sent[3].headers["Authorization"] == "Bearer tok-1")
check("page[number] advances", fake_https.sent[4].url:lower():find("page%%5bnumber%%5d=1") ~= nil, fake_https.sent[4].url)

-- 401 → re-auth → retry once (TC-P8) ------------------------------------------

fake_https.script = {
  { status = 401 },
  { status = 200, body = json.encode({ access_token = "tok-2", token_type = "Bearer", expires_in = 1440 }) },
  { status = 200, body = page({ { id = "n1", type = "node" } }, 1) },
}
local ok2, data2 = api:request("GET", "/node")
check("401 triggers refresh + retry", ok2 == true and data2.data[1].id == "n1")
check("retry carries the new token", fake_https.sent[#fake_https.sent].headers["Authorization"] == "Bearer tok-2")

-- Delta poll query ------------------------------------------------------------

fake_https.script = { { status = 200, body = page({}, 0) } }
api:get_datapoints("2026-07-31T10:00:00Z")
-- socket.url.escape percent-encodes conservatively (lowercase hex, and even
-- unreserved chars like "-"); that is RFC 3986-legal, servers decode it.
local delta_url = fake_https.sent[#fake_https.sent].url:lower()
check("timeFilter delta on GET /datapoints",
  delta_url:find("filter%%5btimestamp%%5d%%5bgt%%5d=") ~= nil
    and delta_url:find("t10%%3a00%%3a00z") ~= nil, delta_url)

-- PUT /datapoints/values body shape --------------------------------------------

fake_https.script = { { status = 204 } }
local ok3 = api:put_value("dp-9", "on")
local put = fake_https.sent[#fake_https.sent]
local decoded = json.decode(put.body)
check("PUT to /datapoints/values", put.url:find("/datapoints/values", 1, true) ~= nil and put.method == "PUT")
check("JSON:API write body", decoded.data[1].id == "dp-9" and decoded.data[1].type == "datapoint" and decoded.data[1].attributes.value == "on", put.body)
check("vnd.api+json content type", put.headers["Content-Type"] == "application/vnd.api+json")
check("204 accepted as success", ok3 == true)

-- Transport failure surfaces as error ------------------------------------------

fake_https.script = { { fail = "connection refused" } }
local ok4, err4 = api:request("GET", "/node")
check("transport error propagates", ok4 == false and tostring(err4):find("connection refused") ~= nil, err4)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
