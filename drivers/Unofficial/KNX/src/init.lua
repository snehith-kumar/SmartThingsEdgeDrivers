-- KNX IoT Controller — SmartThings Edge driver (Approach D, standards-grade).
--
-- Thin LAN client for controllers implementing the KNX IoT 3rd-Party API
-- (KNX Standard V3.0). The controller owns the KNX stack, DPT encoding and
-- the ETS-derived catalog; this driver:
--   1. onboards a controller shell via Add device → Scan (manual IP first:
--      the user enters host/credentials in Settings),
--   2. authenticates (OAuth2 client-credentials, HTTP Basic token exchange),
--   3. reads /functions and creates one EDGE_CHILD per KNX function,
--   4. sends commands as PUT /datapoints/values,
--   5. polls GET /datapoints (timeFilter delta) for status — commands never
--      flip tiles optimistically; the poll cycle is the source of truth.
local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local KnxApi = require "api"
local catalog = require "catalog"
local poller = require "poller"
local mapping = require "mapping"
local logger = require "logger"

local function is_controller(device)
  return device.parent_assigned_child_key == nil
end

------------------------------------------------------------------------------
-- Controller connection
------------------------------------------------------------------------------

local function configured(prefs)
  return prefs and prefs.host and prefs.host ~= ""
    and prefs.clientId and prefs.clientId ~= ""
    and prefs.clientSecret and prefs.clientSecret ~= ""
end

local function build_api(controller)
  local prefs = controller.preferences or {}
  return KnxApi.new({
    host = prefs.host,
    port = tonumber(prefs.port) or 443,
    client_id = prefs.clientId,
    client_secret = prefs.clientSecret,
    label = controller.label,
  })
end

-- Full (re)connect: auth → catalog sync → children → polling. Queued onto
-- the controller's own thread so lifecycle handlers return promptly.
local function connect(driver, controller)
  controller.thread:queue_event(function()
    local prefs = controller.preferences or {}
    if not configured(prefs) then
      logger.info(controller, "connect", "waiting for host/clientId/clientSecret in device Settings")
      return
    end
    local state = poller.state(driver, controller)
    state.api = build_api(controller)

    local ok, err = state.api:authenticate()
    if not ok then
      logger.error(controller, "connect", "authentication failed: %s", tostring(err))
      controller:offline()
      -- Keep polling anyway: each tick retries auth via the 401/token path,
      -- so the driver recovers by itself once the controller is reachable.
      poller.start(driver, controller)
      return
    end
    controller:online()

    local summary, sync_err = catalog.sync(driver, controller, state.api)
    if not summary then
      logger.error(controller, "connect", "catalog sync failed: %s", tostring(sync_err))
    end
    poller.start(driver, controller)
    poller.poll_now(driver, controller) -- seed all tiles with a full read
  end)
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

local function device_init(driver, device)
  logger.info(device, "lifecycle", "init (%s)", is_controller(device) and "controller" or "child")
  if not is_controller(device) then return end

  local state = poller.state(driver, device)
  if configured(device.preferences) then
    state.api = state.api or build_api(device)
    -- Restart path: rebuild the poll index from the persisted mapping and
    -- resume polling without re-fetching the catalog (TC-U5).
    catalog.rebuild_index(driver, device)
    local has_mapping = next(catalog.get_fn_roles(device)) ~= nil
    if has_mapping then
      poller.start(driver, device)
    else
      connect(driver, device) -- configured but never synced (first run)
    end
  end
end

local function device_added(driver, device)
  logger.info(device, "lifecycle", "added")
  -- Children get their state from the next full poll; nothing to seed here
  -- (and never optimistically).
end

local function device_info_changed(driver, device, event, args)
  if not is_controller(device) then return end
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = device.preferences or {}
  logger.info(device, "lifecycle", "infoChanged")
  if old.host ~= new.host or old.port ~= new.port
    or old.clientId ~= new.clientId or old.clientSecret ~= new.clientSecret then
    logger.info(device, "lifecycle", "connection settings changed, reconnecting")
    poller.stop(driver, device)
    connect(driver, device)
  elseif old.pollInterval ~= new.pollInterval then
    logger.info(device, "lifecycle", "poll interval changed to %s", tostring(new.pollInterval))
    if poller.state(driver, device).api then
      poller.start(driver, device)
    end
  end
end

local function device_removed(driver, device)
  logger.info(device, "lifecycle", "removed")
  if is_controller(device) then
    poller.stop(driver, device)
    if driver.knx_state then driver.knx_state[device.id] = nil end
  end
end

local function driver_switched(driver, device)
  logger.info(device, "lifecycle", "driverSwitched")
  device_init(driver, device)
end

------------------------------------------------------------------------------
-- Command plumbing
------------------------------------------------------------------------------

-- Resolve a child's mapping entry {kind, roles} and its controller state.
local function resolve(driver, device)
  local controller = device:get_parent_device()
  if not controller then return nil, nil, nil, "no parent controller" end
  local entry = catalog.get_fn_roles(controller)[device.parent_assigned_child_key]
  if not entry then return nil, nil, nil, "no mapping for this device (run Refresh on the controller)" end
  local state = poller.state(driver, controller)
  if not state.api then return nil, nil, nil, "controller not connected" end
  return entry, controller, state, nil
end

-- Write one datapoint and schedule a quick delta poll so the tile reflects
-- the controller's actual state fast — without an optimistic flip.
local function put(driver, device, controller, state, dp, wire, what)
  logger.info(device, "command", "%s → PUT dp %s = %q", what, dp.id, wire)
  local ok, err = state.api:put_value(dp.id, wire)
  if not ok then
    logger.error(device, "command", "%s failed: %s", what, tostring(err))
    return false
  end
  controller.thread:call_with_delay(1, function()
    poller.tick(driver, controller)
  end, "knx-post-command-poll")
  return true
end

local function handle_switch(driver, device, on)
  local entry, controller, state, err = resolve(driver, device)
  if not entry then
    logger.warn(device, "command", "switch %s dropped: %s", on and "on" or "off", tostring(err))
    return
  end
  local roles = entry.roles
  if entry.kind == "scene" then
    if on and put(driver, device, controller, state, roles.scene, mapping.scene_wire(roles.scene), "scene recall") then
      -- Scenes are momentary triggers with no readable state: blip the tile.
      device:emit_event(capabilities.switch.switch.on())
    end
    device:emit_event(capabilities.switch.switch.off())
    return
  end
  if roles.switch then
    put(driver, device, controller, state, roles.switch, mapping.switch_wire(roles.switch, on), on and "switch on" or "switch off")
  elseif roles.level then
    -- Dimmer functions without a discrete switch datapoint: drive the level.
    local level = on and (device:get_latest_state("main", capabilities.switchLevel.ID, "level", 100)) or 0
    if on and level == 0 then level = 100 end
    put(driver, device, controller, state, roles.level, mapping.level_wire(roles.level, level), on and "switch on (via level)" or "switch off (via level)")
  else
    logger.warn(device, "command", "no switch datapoint mapped")
  end
end

local function handle_set_level(driver, device, command)
  local entry, controller, state, err = resolve(driver, device)
  if not entry or not entry.roles.level then
    logger.warn(device, "command", "setLevel dropped: %s", tostring(err or "no level datapoint mapped"))
    return
  end
  put(driver, device, controller, state, entry.roles.level,
    mapping.level_wire(entry.roles.level, command.args.level), "setLevel " .. tostring(command.args.level))
end

local function handle_shade(driver, device, open)
  local entry, controller, state, err = resolve(driver, device)
  if not entry then
    logger.warn(device, "command", "shade command dropped: %s", tostring(err))
    return
  end
  local roles = entry.roles
  if roles.move then
    put(driver, device, controller, state, roles.move, mapping.move_wire(roles.move, open), open and "shade open" or "shade close")
  elseif roles.position then
    put(driver, device, controller, state, roles.position,
      mapping.shade_position_wire(roles.position, open and 100 or 0), open and "shade open (via position)" or "shade close (via position)")
  else
    logger.warn(device, "command", "no shade datapoint mapped")
  end
end

local function handle_shade_pause(driver, device)
  local entry, controller, state, err = resolve(driver, device)
  if not entry or not entry.roles.stop then
    logger.warn(device, "command", "pause dropped: %s", tostring(err or "no stop datapoint mapped"))
    return
  end
  put(driver, device, controller, state, entry.roles.stop, mapping.stop_wire(entry.roles.stop), "shade pause")
end

local function handle_set_shade_level(driver, device, command)
  local entry, controller, state, err = resolve(driver, device)
  if not entry or not entry.roles.position then
    logger.warn(device, "command", "setShadeLevel dropped: %s", tostring(err or "no position datapoint mapped"))
    return
  end
  put(driver, device, controller, state, entry.roles.position,
    mapping.shade_position_wire(entry.roles.position, command.args.shadeLevel), "setShadeLevel " .. tostring(command.args.shadeLevel))
end

local function handle_set_heating_setpoint(driver, device, command)
  local entry, controller, state, err = resolve(driver, device)
  if not entry or not entry.roles.setpoint then
    logger.warn(device, "command", "setHeatingSetpoint dropped: %s", tostring(err or "no setpoint datapoint mapped"))
    return
  end
  put(driver, device, controller, state, entry.roles.setpoint,
    mapping.setpoint_wire(entry.roles.setpoint, command.args.setpoint), "setHeatingSetpoint " .. tostring(command.args.setpoint))
end

-- Refresh: on the controller re-sync the catalog and re-read everything;
-- on a child just force a full poll on its controller.
local function handle_refresh(driver, device)
  logger.info(device, "command", "refresh")
  local controller = is_controller(device) and device or device:get_parent_device()
  if not controller then return end
  local state = poller.state(driver, controller)
  if not state.api then
    connect(driver, controller)
    return
  end
  if is_controller(device) then
    controller.thread:queue_event(function()
      local summary, err = catalog.sync(driver, controller, state.api)
      if not summary then
        logger.error(controller, "refresh", "catalog sync failed: %s", tostring(err))
      end
      poller.poll_now(driver, controller)
    end)
  else
    poller.poll_now(driver, controller)
  end
end

------------------------------------------------------------------------------
-- Discovery — manual IP first (guide §7 phase 1)
------------------------------------------------------------------------------

-- Creates a single controller shell; the user enters host/credentials in
-- its Settings. Another shell is only created once the previous one is
-- configured (so repeated scans don't pile up empty controllers).
-- mDNS/SSDP discovery is phase 2: the KNX IoT service type is not defined
-- in the OAS and must be confirmed against a real advertising controller.
local function handle_discovery(driver, _opts, _should_continue)
  for _, device in ipairs(driver:get_devices()) do
    if is_controller(device) and not configured(device.preferences) then
      logger.info(device, "discovery", "unconfigured controller already exists, not creating another")
      return
    end
  end
  logger.info("driver", "discovery", "creating controller shell (enter IP + OAuth2 credentials in Settings)")
  driver:try_create_device({
    type = "LAN",
    device_network_id = "knx-iot-controller-" .. tostring(os.time()),
    label = "KNX Controller",
    profile = "knx-controller",
    manufacturer = "KNX",
    model = "KNX IoT 3rd-Party API",
    vendor_provided_label = "KNX IoT Controller",
  })
end

------------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------------

local knx_driver = Driver("knx-iot-controller", {
  discovery = handle_discovery,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = device_info_changed,
    removed = device_removed,
    driverSwitched = driver_switched,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = function(d, dev) handle_switch(d, dev, true) end,
      [capabilities.switch.commands.off.NAME] = function(d, dev) handle_switch(d, dev, false) end,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handle_set_level,
    },
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME] = function(d, dev) handle_shade(d, dev, true) end,
      [capabilities.windowShade.commands.close.NAME] = function(d, dev) handle_shade(d, dev, false) end,
      [capabilities.windowShade.commands.pause.NAME] = function(d, dev) handle_shade_pause(d, dev) end,
    },
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = handle_set_shade_level,
    },
    [capabilities.thermostatHeatingSetpoint.ID] = {
      [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = handle_set_heating_setpoint,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
})

logger.info("driver", "startup", "KNX IoT Controller driver starting")
knx_driver:run()
