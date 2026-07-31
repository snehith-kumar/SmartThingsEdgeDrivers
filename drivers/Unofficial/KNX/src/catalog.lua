-- ETS-derived catalog → SmartThings devices (implementation guide §8).
--
-- One ST child device per KNX *function* (never per datapoint): the driver
-- reads /functions, classifies each with its /functions/{id}/datapoints,
-- and creates an EDGE_CHILD under the controller with
-- parent_assigned_child_key = the function id (the stable identity).
--
-- The function-id → {kind, roles} map is persisted on the controller device
-- so restarts rebuild the poller index without re-fetching the catalog
-- (test plan TC-U5: mapping survives restart, no duplicates).
local mapping = require "mapping"
local logger = require "logger"

local catalog = {}

-- Leave headroom under the 300-devices-per-location platform cap.
local DEVICE_CAP = 290

local FN_ROLES_FIELD = "fn_roles"

function catalog.get_fn_roles(controller)
  return controller:get_field(FN_ROLES_FIELD) or {}
end

-- Build the poller's reverse index: datapoint id → list of watchers
-- {child_key, role, dp}. Reads only the persisted map, so it works on a
-- fresh restart before any network traffic.
function catalog.rebuild_index(driver, controller)
  local poller = require "poller"
  local state = poller.state(driver, controller)
  local index = {}
  for fn_id, entry in pairs(catalog.get_fn_roles(controller)) do
    for _, role in ipairs(mapping.STATUS_ROLES[entry.kind] or {}) do
      local dp = entry.roles[role]
      if dp then
        index[dp.id] = index[dp.id] or {}
        table.insert(index[dp.id], { child_key = fn_id, role = role, dp = dp })
      end
    end
  end
  state.index = index
  local n = 0
  for _ in pairs(index) do n = n + 1 end
  logger.info(controller, "catalog", "status index rebuilt: %d watched datapoints", n)
end

-- Fetch the catalog and reconcile: classify every function, persist the
-- role map, create missing children. Returns a summary table or (nil, err).
function catalog.sync(driver, controller, api)
  local fns, err = api:get_functions()
  if not fns then
    return nil, "functions fetch failed: " .. tostring(err)
  end
  logger.info(controller, "catalog", "/functions returned %d functions", #fns)

  local existing = {}
  local child_count = 0
  for _, child in ipairs(controller:get_child_list() or {}) do
    if child.parent_assigned_child_key then
      existing[child.parent_assigned_child_key] = true
      child_count = child_count + 1
    end
  end

  local fn_roles = {}
  local mapped, created, skipped = 0, 0, 0

  for _, fn in ipairs(fns) do
    local dps, dp_err = api:get_function_datapoints(fn.id)
    if not dps then
      logger.warn(controller, "catalog", "datapoints fetch failed for function %s: %s", fn.id, tostring(dp_err))
      skipped = skipped + 1
    else
      local profile, roles_or_reason, kind = mapping.classify(fn, dps)
      local title = (fn.attributes and fn.attributes.title) or ("KNX " .. tostring(kind or "function"))
      if not profile then
        logger.info(controller, "catalog", "skipping function %s (%q): %s", fn.id, title, tostring(roles_or_reason))
        skipped = skipped + 1
      else
        mapped = mapped + 1
        fn_roles[fn.id] = { kind = kind, roles = roles_or_reason, profile = profile, title = title }
        if not existing[fn.id] then
          if child_count + created >= DEVICE_CAP then
            logger.warn(controller, "catalog", "cap-guard hit (%d devices): not creating %q", DEVICE_CAP, title)
          else
            logger.info(controller, "catalog", "creating device %q profile=%s key=%s", title, profile, fn.id)
            local ok, create_err = pcall(driver.try_create_device, driver, {
              type = "EDGE_CHILD",
              label = title,
              profile = profile,
              parent_device_id = controller.id,
              parent_assigned_child_key = fn.id,
              vendor_provided_label = title,
            })
            if ok then
              created = created + 1
            else
              logger.error(controller, "catalog", "try_create_device failed for %q: %s", title, tostring(create_err))
            end
          end
        end
      end
    end
  end

  controller:set_field(FN_ROLES_FIELD, fn_roles, { persist = true })
  catalog.rebuild_index(driver, controller)

  local summary = { total = #fns, mapped = mapped, created = created, skipped = skipped }
  logger.info(controller, "catalog", "sync done: %d functions, %d mapped, %d created, %d skipped",
    summary.total, summary.mapped, summary.created, summary.skipped)
  return summary
end

return catalog
