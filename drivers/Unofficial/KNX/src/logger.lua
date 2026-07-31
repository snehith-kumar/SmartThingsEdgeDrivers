-- Structured logging for the KNX IoT driver (implementation guide §9).
-- Every line: "[KNX] <ctx>: <op>: message". Secrets are never logged; use
-- redact() on anything that may embed a token/secret before passing it here.
local log = require "log"

local logger = {}

local LEVELS = { "trace", "debug", "info", "warn", "error" }

-- Replace token/secret-looking values in free-form text (defense in depth;
-- callers should avoid logging credentials in the first place).
function logger.redact(s)
  if type(s) ~= "string" then return s end
  s = s:gsub("(access_token[\"']?%s*[:=]%s*[\"']?)[%w%-%._~%+/]+", "%1<redacted>")
  s = s:gsub("(client_secret[\"']?%s*[:=]%s*[\"']?)[%w%-%._~%+/]+", "%1<redacted>")
  s = s:gsub("(Bearer%s+)[%w%-%._~%+/=]+", "%1<redacted>")
  return s
end

-- ctx: a string, or a device (uses its label) — identifies controller/device.
local function fmt(ctx, op, msg, ...)
  if type(ctx) == "table" then ctx = ctx.label or (ctx.id and tostring(ctx.id)) or "?" end
  local text = select("#", ...) > 0 and string.format(msg, ...) or msg
  return string.format("[KNX] %s: %s: %s", tostring(ctx), tostring(op), logger.redact(text))
end

for _, level in ipairs(LEVELS) do
  -- logger.info(ctx, op, msg, ...) etc.; hub_logs=true so `logcat` shows them.
  logger[level] = function(ctx, op, msg, ...)
    log[level .. "_with"]({ hub_logs = true }, fmt(ctx, op, msg, ...))
  end
end

return logger
