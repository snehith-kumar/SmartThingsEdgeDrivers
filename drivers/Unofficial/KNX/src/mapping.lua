-- Function-level device modeling (implementation guide §8):
--   * classify a KNX IoT function (+ its datapoints) into one ST profile
--   * pick which datapoint plays which role (switch / level / position / ...)
--   * coerce values both directions — the API carries every value as a JSON
--     string ("on", "63", "21.5"); the controller already did DPT encoding,
--     so 60% stays "60" (never rescaled to 0..255).
--
-- KNX blind convention: position 0 = open/up, 100 = closed/down. SmartThings
-- windowShadeLevel is % open. The two are mirrored: st_level = 100 - knx_pos.
local capabilities = require "st.capabilities"
local logger = require "logger"

local mapping = {}

-- Profile names must match profiles/*.yml.
mapping.PROFILES = {
  switch = "knx-switch",
  dimmer = "knx-dimmer",
  shade = "knx-shade",
  thermostat = "knx-thermostat",
  temperature = "knx-temperature",
  scene = "knx-scene",
}

------------------------------------------------------------------------------
-- Datapoint descriptors
------------------------------------------------------------------------------

-- Reduce a JSON:API datapoint item to the fields classification and
-- coercion need. Stored per-role in the device datastore, so keep it plain.
function mapping.describe_datapoint(item)
  local attrs = item.attributes or {}
  local types = {}
  for _, t in ipairs(attrs.datapointType or {}) do
    types[#types + 1] = tostring(t):lower()
  end
  local meta_types = (item.meta or {})["@type"] or {}
  for _, t in ipairs(meta_types) do
    types[#types + 1] = tostring(t):lower()
  end
  local enum = nil
  if type(attrs.enum) == "table" then
    enum = {}
    for i, e in ipairs(attrs.enum) do enum[i] = tostring(e) end
  end
  return {
    id = item.id,
    title = attrs.title,
    types = table.concat(types, " "),
    enum = enum,
    unit = attrs.unit and tostring(attrs.unit):lower() or nil,
    minimum = tonumber(attrs.minimum),
    maximum = tonumber(attrs.maximum),
    readable = attrs.readable ~= false, -- schema default true
    writable = attrs.writable == true,  -- schema default false
    value_type = attrs.valueType,
  }
end

local function enum_has(dp, word)
  if not dp.enum then return false end
  for _, e in ipairs(dp.enum) do
    if e:lower() == word then return true end
  end
  return false
end

local function is_switch_dp(dp)
  return dp.types:find("dpt%.switch") ~= nil
    or dp.types:find("knx:switch") ~= nil
    or (enum_has(dp, "on") and enum_has(dp, "off"))
end

local function is_percent_dp(dp)
  return dp.types:find("scaling") ~= nil
    or dp.types:find("percent") ~= nil
    or (dp.unit ~= nil and dp.unit:find("percent") ~= nil)
end

local function is_updown_dp(dp)
  return dp.types:find("updown") ~= nil
    or (enum_has(dp, "up") and enum_has(dp, "down"))
end

local function is_stop_dp(dp)
  return dp.types:find("dpt%.step") ~= nil or enum_has(dp, "stop")
end

local function is_temperature_dp(dp)
  return (dp.unit ~= nil and (dp.unit:find("deg_c") or dp.unit:find("deg_f") or dp.unit:find("cel")) ~= nil)
    or dp.types:find("temperature") ~= nil
end

local function is_scene_dp(dp)
  return dp.types:find("scene") ~= nil
end

-- Prefer a datapoint matching `pred`; among matches prefer the requested
-- access (writable for command roles, readable-only for status roles).
local function pick(dps, pred, want)
  local best = nil
  for _, dp in ipairs(dps) do
    if pred(dp) then
      if want == "writable" and dp.writable then return dp end
      if want == "readonly" and dp.readable and not dp.writable then return dp end
      best = best or dp
    end
  end
  return best
end

------------------------------------------------------------------------------
-- Classification: function + datapoints → (profile kind, roles)
------------------------------------------------------------------------------

-- Concatenated lowercase meta["@type"] of the function, e.g.
-- "knx:dimming urn:knx:fct.dimming".
function mapping.function_type_string(fn)
  local out = {}
  for _, t in ipairs((fn.meta or {})["@type"] or {}) do
    out[#out + 1] = tostring(t):lower()
  end
  return table.concat(out, " ")
end

local function classify_by_type(ftype)
  if ftype:find("scene") then return "scene" end
  if ftype:find("dim") then return "dimmer" end
  if ftype:find("sunprotect") or ftype:find("shutter") or ftype:find("blind")
    or ftype:find("venetian") or ftype:find("awning") or ftype:find("shade") then
    return "shade"
  end
  if ftype:find("thermostat") or ftype:find("temperaturecontrol")
    or ftype:find("heating") or ftype:find("cooling") or ftype:find("hvac") then
    return "thermostat"
  end
  if ftype:find("switch") then return "switch" end
  if ftype:find("temperature") then return "temperature" end
  return nil
end

local function classify_by_datapoints(dps)
  local has = { switch_w = false, percent_w = false, updown = false, temp_r = false, temp_w = false, scene = false }
  for _, dp in ipairs(dps) do
    if is_scene_dp(dp) then has.scene = true end
    if is_switch_dp(dp) and dp.writable then has.switch_w = true end
    if is_percent_dp(dp) and dp.writable then has.percent_w = true end
    if is_updown_dp(dp) then has.updown = true end
    if is_temperature_dp(dp) then
      if dp.writable then has.temp_w = true end
      if dp.readable then has.temp_r = true end
    end
  end
  if has.scene then return "scene" end
  if has.updown then return "shade" end
  if has.switch_w and has.percent_w then return "dimmer" end
  if has.temp_w then return "thermostat" end
  if has.switch_w then return "switch" end
  if has.percent_w then return "dimmer" end
  if has.temp_r then return "temperature" end
  return nil
end

-- roles: map role-name → datapoint descriptor. Every role a profile's
-- handlers/poller touch must be present, or the function is skipped.
local function extract_roles(kind, dps)
  local roles = {}
  if kind == "switch" then
    roles.switch = pick(dps, is_switch_dp, "writable")
    roles.switch_status = pick(dps, is_switch_dp, "readonly") or roles.switch
    if not roles.switch then return nil end
  elseif kind == "dimmer" then
    roles.switch = pick(dps, is_switch_dp, "writable")
    roles.switch_status = pick(dps, is_switch_dp, "readonly") or roles.switch
    roles.level = pick(dps, is_percent_dp, "writable")
    roles.level_status = pick(dps, is_percent_dp, "readonly") or roles.level
    if not roles.level then return nil end
    -- A dimmer without a discrete switch GA still works: on/off via level.
  elseif kind == "shade" then
    roles.position = pick(dps, is_percent_dp, "writable")
    roles.position_status = pick(dps, is_percent_dp, "readonly") or roles.position
    roles.move = pick(dps, is_updown_dp, "writable")
    roles.stop = pick(dps, is_stop_dp, "writable")
    if not (roles.position or roles.move) then return nil end
  elseif kind == "thermostat" then
    roles.setpoint = pick(dps, is_temperature_dp, "writable")
    for _, dp in ipairs(dps) do
      if is_temperature_dp(dp) and dp.readable and (not roles.setpoint or dp.id ~= roles.setpoint.id) then
        roles.temperature = dp
        break
      end
    end
    roles.temperature = roles.temperature or roles.setpoint
    if not roles.setpoint then return nil end
  elseif kind == "temperature" then
    roles.temperature = pick(dps, is_temperature_dp, "readonly") or pick(dps, is_temperature_dp)
    if not roles.temperature then return nil end
  elseif kind == "scene" then
    for _, dp in ipairs(dps) do
      if dp.writable then roles.scene = dp break end
    end
    if not roles.scene then return nil end
  else
    return nil
  end
  return roles
end

-- Main entry: returns (profile_name, roles) or (nil, reason).
function mapping.classify(fn, dp_items)
  local dps = {}
  for _, item in ipairs(dp_items) do
    local dp = mapping.describe_datapoint(item)
    -- Array-valued datapoints (valueType "object") are out of v1 scope.
    if dp.value_type ~= "object" then dps[#dps + 1] = dp end
  end
  local ftype = mapping.function_type_string(fn)
  local kind = classify_by_type(ftype) or classify_by_datapoints(dps)
  if not kind then
    return nil, "unrecognized function type '" .. ftype .. "' with " .. tostring(#dps) .. " datapoints"
  end
  local roles = extract_roles(kind, dps)
  if not roles then
    return nil, "function classified as '" .. kind .. "' but required datapoints are missing"
  end
  return mapping.PROFILES[kind], roles, kind
end

------------------------------------------------------------------------------
-- Value coercion — commands (ST → wire string)
------------------------------------------------------------------------------

local function clamp(n, lo, hi)
  if lo and n < lo then return lo end
  if hi and n > hi then return hi end
  return n
end

local function round(n)
  return math.floor(n + 0.5)
end

-- Choose the wire word for an intent, honoring the datapoint's own enum
-- list (KNX 1.xxx variants: on/off, true/false, enable/disable, up/down...).
function mapping.enum_pick(dp, candidates)
  if dp.enum then
    for _, want in ipairs(candidates) do
      for _, e in ipairs(dp.enum) do
        if e:lower() == want then return e end
      end
    end
  end
  return candidates[1]
end

local ON_WORDS = { "on", "true", "enable", "start", "1" }
local OFF_WORDS = { "off", "false", "disable", "stop", "0" }
local UP_WORDS = { "up", "open", "0" }
local DOWN_WORDS = { "down", "close", "closed", "1" }
local STOP_WORDS = { "stop", "true", "1" }

function mapping.switch_wire(dp, on)
  return mapping.enum_pick(dp, on and ON_WORDS or OFF_WORDS)
end

function mapping.move_wire(dp, open)
  return mapping.enum_pick(dp, open and UP_WORDS or DOWN_WORDS)
end

function mapping.stop_wire(dp)
  return mapping.enum_pick(dp, STOP_WORDS)
end

-- ST 0-100 level → wire string, clamped to the datapoint's applicative
-- range. The API value is already in engineering units (percent).
function mapping.level_wire(dp, st_level)
  local n = clamp(round(tonumber(st_level) or 0), dp.minimum or 0, dp.maximum or 100)
  return tostring(n)
end

-- ST windowShadeLevel (% open) → KNX position (% closed).
function mapping.shade_position_wire(dp, st_level)
  local pos = 100 - clamp(round(tonumber(st_level) or 0), 0, 100)
  return tostring(clamp(pos, dp.minimum, dp.maximum))
end

function mapping.setpoint_wire(dp, value)
  local n = clamp(tonumber(value) or 0, dp.minimum, dp.maximum)
  return tostring(n)
end

function mapping.scene_wire(dp)
  if dp.enum and dp.enum[1] then return dp.enum[1] end
  return "1"
end

------------------------------------------------------------------------------
-- Value coercion — status (wire string → capability events)
------------------------------------------------------------------------------

local function truthy(v)
  local s = tostring(v):lower()
  if s == "on" or s == "true" or s == "enable" or s == "start" then return true end
  if s == "off" or s == "false" or s == "disable" or s == "stop" then return false end
  local n = tonumber(s)
  if n ~= nil then return n ~= 0 end
  return nil
end

local function temp_unit(dp)
  if dp.unit and dp.unit:find("deg_f") then return "F" end
  return "C"
end

-- Map (role, wire value) → list of capability events for the device.
-- Returns nil when the value can't be interpreted (caller logs it).
function mapping.events_for(role, dp, value)
  if role == "switch_status" or role == "switch" then
    local on = truthy(value)
    if on == nil then return nil end
    return { on and capabilities.switch.switch.on() or capabilities.switch.switch.off() }
  elseif role == "level_status" or role == "level" then
    local n = tonumber(value)
    if n == nil then return nil end
    n = clamp(round(n), 0, 100)
    local events = { capabilities.switchLevel.level(n) }
    return events
  elseif role == "position_status" or role == "position" then
    local n = tonumber(value)
    if n == nil then return nil end
    local st_level = clamp(100 - round(n), 0, 100)
    local state
    if st_level >= 99 then
      state = capabilities.windowShade.windowShade.open()
    elseif st_level <= 1 then
      state = capabilities.windowShade.windowShade.closed()
    else
      state = capabilities.windowShade.windowShade.partially_open()
    end
    return { capabilities.windowShadeLevel.shadeLevel(st_level), state }
  elseif role == "temperature" then
    local n = tonumber(value)
    if n == nil then return nil end
    return { capabilities.temperatureMeasurement.temperature({ value = n, unit = temp_unit(dp) }) }
  elseif role == "setpoint" then
    local n = tonumber(value)
    if n == nil then return nil end
    return { capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = n, unit = temp_unit(dp) }) }
  end
  return nil
end

-- Roles whose datapoints the poller should watch, per profile kind. Command
-- roles double as status roles when no separate status datapoint exists —
-- the *_status aliases already collapse to the command dp in extract_roles.
mapping.STATUS_ROLES = {
  switch = { "switch_status" },
  dimmer = { "switch_status", "level_status" },
  shade = { "position_status" },
  thermostat = { "temperature", "setpoint" },
  temperature = { "temperature" },
  scene = {},
}

return mapping
