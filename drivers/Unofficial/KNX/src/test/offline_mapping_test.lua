-- Offline unit tests for mapping.lua (test plan TC-U1 value conversion,
-- TC-U2 catalogue classification). Run from the driver root:
--   lua5.3 src/test/offline_mapping_test.lua
package.path = "../../../lua_libs/?.lua;../../../lua_libs/?/init.lua;src/?.lua;" .. package.path

local mapping = require "mapping"

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("PASS " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" — " .. tostring(detail)) or ""))
  end
end

-- Canned items in the exact OAS example shape ------------------------------

local switch_dp = {
  id = "dp-switch-1",
  attributes = {
    title = "On and off switching",
    readable = true, writable = true,
    value = "on", valueType = "string",
    enum = { "on", "off" },
    datapointType = { "urn:knx:dpt.switch", "knx:switch" },
  },
}

local level_dp = {
  id = "dp-level-1",
  attributes = {
    title = "Brightness",
    readable = true, writable = true,
    value = "63", valueType = "string",
    unit = "unit:PERCENT", minimum = 0, maximum = 100,
    datapointType = { "knx:scaling" },
  },
}

local updown_dp = {
  id = "dp-move-1",
  attributes = {
    title = "Move", writable = true, valueType = "string",
    enum = { "up", "down" },
    datapointType = { "urn:knx:dpt.upDown" },
  },
}

local temp_dp = {
  id = "dp-temp-1",
  attributes = {
    title = "Room temperature", readable = true, writable = false,
    value = "21.5", valueType = "string",
    unit = "unit:DEG_C", datapointType = { "urn:knx:dpt.temperature" },
  },
}

local setpoint_dp = {
  id = "dp-setpoint-1",
  attributes = {
    title = "Setpoint", readable = true, writable = true,
    value = "22", valueType = "string",
    unit = "unit:DEG_C", minimum = 5, maximum = 30,
    datapointType = { "urn:knx:dpt.temperature" },
  },
}

local function fn(types)
  return { id = "fn-1", type = "function", attributes = { title = "T" }, meta = { ["@type"] = types } }
end

-- TC-U2: classification -----------------------------------------------------

local profile, roles = mapping.classify(fn({ "knx:switching", "urn:knx:fct.switching" }), { switch_dp })
check("switching fn → knx-switch", profile == "knx-switch", profile)
check("switch role picked", roles and roles.switch and roles.switch.id == "dp-switch-1")

local profile2, roles2 = mapping.classify(fn({ "knx:dimming", "urn:knx:fct.dimming" }), { switch_dp, level_dp })
check("dimming fn → knx-dimmer", profile2 == "knx-dimmer", profile2)
check("dimmer level role", roles2 and roles2.level and roles2.level.id == "dp-level-1")
check("dimmer switch role", roles2 and roles2.switch and roles2.switch.id == "dp-switch-1")

local profile3, roles3 = mapping.classify(fn({ "urn:knx:fct.sunProtection" }), { updown_dp, level_dp })
check("sunProtection fn → knx-shade", profile3 == "knx-shade", profile3)
check("shade move role", roles3 and roles3.move and roles3.move.id == "dp-move-1")

local profile4, roles4 = mapping.classify(fn({}), { temp_dp, setpoint_dp })
check("untyped fn w/ writable temp → knx-thermostat", profile4 == "knx-thermostat", profile4)
check("thermostat temperature role is the readable dp", roles4 and roles4.temperature and roles4.temperature.id == "dp-temp-1")
check("thermostat setpoint role is the writable dp", roles4 and roles4.setpoint and roles4.setpoint.id == "dp-setpoint-1")

local profile5 = mapping.classify(fn({}), { temp_dp })
check("untyped fn w/ readonly temp → knx-temperature", profile5 == "knx-temperature", profile5)

local profile6, reason6 = mapping.classify(fn({ "urn:knx:fct.somethingExotic" }), {})
check("unmappable fn skipped with reason", profile6 == nil and reason6 ~= nil, reason6)

-- TC-U1: value conversion ----------------------------------------------------

local d_switch = mapping.describe_datapoint(switch_dp)
local d_level = mapping.describe_datapoint(level_dp)
local d_move = mapping.describe_datapoint(updown_dp)
local d_temp = mapping.describe_datapoint(temp_dp)
local d_setp = mapping.describe_datapoint(setpoint_dp)

check("60% stays '60' (never 153)", mapping.level_wire(d_level, 60) == "60", mapping.level_wire(d_level, 60))
check("level clamped to max", mapping.level_wire(d_level, 150) == "100")
check("level rounds", mapping.level_wire(d_level, 59.6) == "60")
check("switch on honors dp enum", mapping.switch_wire(d_switch, true) == "on")
check("switch off honors dp enum", mapping.switch_wire(d_switch, false) == "off")
check("move open → up", mapping.move_wire(d_move, true) == "up")
check("move close → down", mapping.move_wire(d_move, false) == "down")
check("ST 100% open → KNX position 0", mapping.shade_position_wire(d_level, 100) == "0")
check("ST 0% open → KNX position 100", mapping.shade_position_wire(d_level, 0) == "100")
check("setpoint float preserved", mapping.setpoint_wire(d_setp, 21.5) == "21.5", mapping.setpoint_wire(d_setp, 21.5))
check("setpoint clamped to min", mapping.setpoint_wire(d_setp, 1) == "5")

-- Status events ---------------------------------------------------------------

local ev = mapping.events_for("switch_status", d_switch, "on")
check("'on' → switch.on event", ev and ev[1] and ev[1].value.value == "on", ev and ev[1] and tostring(ev[1].value.value))
ev = mapping.events_for("switch_status", d_switch, "0")
check("'0' → switch.off event", ev and ev[1] and ev[1].value.value == "off")
ev = mapping.events_for("level_status", d_level, "63")
check("'63' → level 63", ev and ev[1] and ev[1].value.value == 63)
ev = mapping.events_for("position_status", d_level, "25")
check("KNX pos 25 → shadeLevel 75", ev and ev[1] and ev[1].value.value == 75)
check("KNX pos 25 → partially open", ev and ev[2] and ev[2].value.value == "partially open", ev and ev[2] and tostring(ev[2].value.value))
ev = mapping.events_for("position_status", d_level, "100")
check("KNX pos 100 → closed", ev and ev[2] and ev[2].value.value == "closed")
ev = mapping.events_for("temperature", d_temp, "21.5")
check("'21.5' → temperature 21.5 C", ev and ev[1] and ev[1].value.value == 21.5 and ev[1].value.unit == "C")
ev = mapping.events_for("setpoint", d_setp, "22")
check("'22' → heatingSetpoint 22", ev and ev[1] and ev[1].value.value == 22)
ev = mapping.events_for("switch_status", d_switch, "garbage###")
check("uninterpretable value → nil (logged, not crash)", ev == nil)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
