-- Offline tests for poller.lua + catalog.rebuild_index (test plan TC-U4:
-- polling loop detects and emits changes; TC-P6/P7/P9 logic: offline after
-- consecutive failures, full re-read after recovery, no duplicate events).
-- Run from the driver root:  lua5.3 src/test/offline_poller_test.lua
package.path = "../../../lua_libs/?.lua;../../../lua_libs/?/init.lua;src/?.lua;" .. package.path

local poller = require "poller"
local catalog = require "catalog"

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("PASS " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" — " .. tostring(detail)) or ""))
  end
end

-- Mocks ----------------------------------------------------------------------

local emitted = {}
local child = {
  id = "child-1",
  label = "Bathroom Light",
  parent_assigned_child_key = "fn-1",
  emit_event = function(_, event) table.insert(emitted, event) end,
  online = function() end,
  offline = function() end,
}

local health = {}
local fields = {
  fn_roles = {
    ["fn-1"] = {
      kind = "switch",
      profile = "knx-switch",
      title = "Bathroom Light",
      roles = {
        switch = { id = "dp-1", enum = { "on", "off" }, types = "urn:knx:dpt.switch", readable = true, writable = true },
        switch_status = { id = "dp-1", enum = { "on", "off" }, types = "urn:knx:dpt.switch", readable = true, writable = true },
      },
    },
  },
}
local controller = {
  id = "ctrl-1",
  label = "KNX Controller",
  parent_assigned_child_key = nil,
  preferences = { pollInterval = 3 },
  get_child_list = function() return { child } end,
  get_field = function(_, k) return fields[k] end,
  set_field = function(_, k, v) fields[k] = v end,
  online = function() table.insert(health, "online") end,
  offline = function() table.insert(health, "offline") end,
}

local api = { responses = {}, calls = {} }
function api:get_datapoints(since)
  table.insert(self.calls, since or "FULL")
  local r = table.remove(self.responses, 1)
  if r.err then return nil, r.err end
  return r.items
end

local driver = {}
local state = poller.state(driver, controller)
state.api = api

-- Index built from the persisted mapping (restart path) -----------------------

catalog.rebuild_index(driver, controller)
check("index watches dp-1", state.index["dp-1"] ~= nil and state.index["dp-1"][1].child_key == "fn-1")

local function dp_item(value, ts)
  return { id = "dp-1", type = "datapoint", attributes = { value = value, timestamp = ts } }
end

-- Tick 1: initial full read seeds state ---------------------------------------

api.responses = { { items = { dp_item("on", "2026-07-31T10:00:00Z") } } }
poller.tick(driver, controller)
check("first tick is a full read", api.calls[1] == "FULL", api.calls[1])
check("'on' emitted", #emitted == 1 and emitted[1].value.value == "on")
check("hwm tracked from server timestamp", state.hwm == "2026-07-31T10:00:00Z", state.hwm)
check("controller marked online on first tick", health[#health] == "online")

-- Tick 2: delta poll with no changes ------------------------------------------

api.responses = { { items = {} } }
poller.tick(driver, controller)
check("second tick uses timeFilter delta", api.calls[2] == "2026-07-31T10:00:00Z", api.calls[2])
check("no change → no event", #emitted == 1)

-- Tick 3: a second client flipped the switch (TC-P4) ---------------------------

api.responses = { { items = { dp_item("off", "2026-07-31T10:00:05Z") } } }
poller.tick(driver, controller)
check("'off' emitted after external change", #emitted == 2 and emitted[2].value.value == "off")
check("hwm advanced", state.hwm == "2026-07-31T10:00:05Z")

-- Failures: offline after 2 consecutive, full read on recovery (TC-P6/P9) -----

health = {}
api.responses = { { err = "connection refused" }, { err = "connection refused" } }
poller.tick(driver, controller)
check("first failure does not mark offline", #health == 0)
poller.tick(driver, controller)
check("second consecutive failure marks offline", health[#health] == "offline")

api.responses = { { items = { dp_item("off", "2026-07-31T10:01:00Z") } } }
poller.tick(driver, controller)
check("recovery tick is a full read (TC-P7)", api.calls[#api.calls] == "FULL", api.calls[#api.calls])
check("recovery marks online again", health[#health] == "online")
check("same value on full read → no duplicate event", #emitted == 2)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
