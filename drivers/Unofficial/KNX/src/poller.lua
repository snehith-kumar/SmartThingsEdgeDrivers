-- Status transport: polling only (implementation guide §5 — Edge cosock has
-- no server-side TLS, so callbacks/WebSocket subscriptions are off the table).
--
-- Each controller device gets a scheduled tick on its own device thread:
--   GET /datapoints [?filter[timestamp][gt]=<high-water-mark>]
--   → diff against the value cache → emit capability events on the mapped
--     children. Tiles are never flipped optimistically by command handlers;
--     this loop is the single source of tile truth.
--
-- Recovery rules (test plan TC-P6/P7/P9): after any failed tick the next
-- successful one does a FULL read (changes that happened while unreachable
-- carry timestamps the delta filter could skip past). A full read also runs
-- every FULL_EVERY ticks as a safety net against timestamp-resolution races.
local mapping = require "mapping"
local logger = require "logger"

local poller = {}

local FULL_EVERY = 20
local OFFLINE_AFTER_FAILURES = 2

-- Driver-scoped state bag for one controller device.
function poller.state(driver, controller)
  driver.knx_state = driver.knx_state or {}
  local s = driver.knx_state[controller.id]
  if not s then
    s = { values = {}, hwm = nil, tick_count = 0, fail_count = 0, force_full = true }
    driver.knx_state[controller.id] = s
  end
  return s
end

local function emit_safely(device, event)
  local ok, err = pcall(device.emit_event, device, event)
  if not ok then
    logger.warn(device, "status", "emit failed: %s", tostring(err))
  end
end

local function set_health(controller, online)
  local devices = { controller }
  for _, child in ipairs(controller:get_child_list() or {}) do
    devices[#devices + 1] = child
  end
  for _, d in ipairs(devices) do
    local ok = pcall(function()
      if online then d:online() else d:offline() end
    end)
    if not ok then
      logger.warn(controller, "health", "failed to mark device %s", online and "online" or "offline")
    end
  end
end

-- One poll cycle. `state.index` (built by catalog.rebuild_index) maps
-- datapoint id → list of {child_key, role, dp}.
function poller.tick(driver, controller)
  local state = poller.state(driver, controller)
  local api = state.api
  if not api then return end

  state.tick_count = state.tick_count + 1
  local full = state.force_full or state.hwm == nil or (state.tick_count % FULL_EVERY == 0)
  local since = (not full) and state.hwm or nil

  local items, err = api:get_datapoints(since)
  if not items then
    state.fail_count = state.fail_count + 1
    state.force_full = true
    logger.warn(controller, "poll", "tick failed (%d consecutive): %s", state.fail_count, tostring(err))
    if state.fail_count == OFFLINE_AFTER_FAILURES then
      set_health(controller, false)
    end
    return
  end

  if state.fail_count > 0 or state.tick_count == 1 then
    set_health(controller, true)
  end
  state.fail_count = 0
  state.force_full = false

  -- Child lookup by parent_assigned_child_key, refreshed per tick (cheap).
  local children = {}
  for _, child in ipairs(controller:get_child_list() or {}) do
    if child.parent_assigned_child_key then
      children[child.parent_assigned_child_key] = child
    end
  end

  local applied = 0
  for _, item in ipairs(items) do
    local attrs = item.attributes or {}
    local value = attrs.value
    if value ~= nil then
      -- Track the newest server-side timestamp as the next delta anchor.
      local ts = attrs.timestamp
      if ts and (state.hwm == nil or ts > state.hwm) then state.hwm = ts end

      local watchers = state.index and state.index[item.id]
      local changed = state.values[item.id] ~= tostring(value)
      state.values[item.id] = tostring(value)
      if watchers and changed then
        for _, w in ipairs(watchers) do
          local child = children[w.child_key]
          if child then
            local events = mapping.events_for(w.role, w.dp, value)
            if events then
              for _, event in ipairs(events) do emit_safely(child, event) end
              applied = applied + 1
              logger.debug(controller, "status", "dp %s → %s.%s = %s", item.id, w.child_key, w.role, tostring(value))
            else
              logger.warn(controller, "status", "dp %s value %q not interpretable as %s", item.id, tostring(value), w.role)
            end
          end
        end
      end
    end
  end
  logger.debug(controller, "poll", "tick ok: %d items (%s), %d events", #items, full and "full" or "delta", applied)
end

-- (Re)start the scheduled poll for a controller, using the pollInterval
-- preference. Safe to call repeatedly (infoChanged, reconnects).
function poller.start(driver, controller)
  local state = poller.state(driver, controller)
  poller.stop(driver, controller)
  local interval = tonumber(controller.preferences and controller.preferences.pollInterval) or 3
  if interval < 1 then interval = 1 end
  state.force_full = true
  state.timer = controller.thread:call_on_schedule(interval, function()
    poller.tick(driver, controller)
  end, "knx-poll-" .. controller.id)
  logger.info(controller, "poll", "polling started, every %ds", interval)
end

function poller.stop(driver, controller)
  local state = poller.state(driver, controller)
  if state.timer then
    controller.thread:cancel_timer(state.timer)
    state.timer = nil
    logger.info(controller, "poll", "polling stopped")
  end
end

-- Manual "read everything now" (refresh capability / right after catalog sync).
function poller.poll_now(driver, controller)
  local state = poller.state(driver, controller)
  state.force_full = true
  controller.thread:queue_event(function()
    poller.tick(driver, controller)
  end)
end

return poller
