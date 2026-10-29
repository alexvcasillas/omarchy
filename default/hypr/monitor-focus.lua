-- Hyprland clears focus when the sole monitor drops onto the headless FALLBACK,
-- and doesn't put it back when the real one returns, so the session takes no
-- keyboard input until you switch workspace by hand. Upstream considers this
-- intended, see hyprwm/Hyprland discussion #15554.
--
-- Focus dispatches don't take while the session lock is held, and the idle lock
-- is what powers the display down, so a restore attempted on the timer alone
-- is usually lost. The snapshot stays pending until focus is seen to move, and
-- omarchy-system-wake retries it through `hyprctl dispatch
-- 'o.monitor_focus.restore()'` once the session is unlocked.

local fallback_monitor = "FALLBACK"
local restore_delay_ms = 500

local went_headless = false
local restore_generation = 0
-- Ids, not objects. The objects don't survive the migration.
local saved_workspace_id = nil
local saved_window_address = nil
-- What to put back after a FALLBACK round trip, until focus moves.
local pending = nil

-- A newer monitor event makes a pending restore stale.
local function invalidate_pending()
  restore_generation = restore_generation + 1
end

local function forget_saved()
  saved_workspace_id = nil
  saved_window_address = nil
end

local function focused_window()
  for _, window in ipairs(hl.get_windows()) do
    if window.active then
      return window
    end
  end
end

-- Lowest focus_history_id is the most recently focused window.
local function most_recent_window(workspace_id)
  local best = nil
  for _, window in ipairs(hl.get_workspace_windows(workspace_id) or {}) do
    if not best or window.focus_history_id < best.focus_history_id then
      best = window
    end
  end
  return best
end

local function current_workspace_id()
  for _, monitor in ipairs(hl.get_monitors()) do
    if monitor.focused then
      return monitor.active_workspace and monitor.active_workspace.id
    end
  end
end

local function other_workspace(target_id)
  for _, workspace in ipairs(hl.get_workspaces()) do
    if workspace.id ~= target_id and not tostring(workspace.name):match("^special:") then
      return workspace
    end
  end
end

local function restore_focus(workspace_id, window_address)
  local workspace = hl.get_workspace(workspace_id)
  if not workspace then
    return
  end

  -- Refocusing the workspace Hyprland already records as focused is a no-op.
  if current_workspace_id() == workspace_id then
    local via = other_workspace(workspace_id)
    if via then
      hl.dispatch(hl.dsp.focus({ workspace = via }))
    end
  end
  hl.dispatch(hl.dsp.focus({ workspace = workspace }))

  -- The selector needs the address: prefix, a bare address resolves to nil.
  local window = window_address and hl.get_window("address:" .. window_address)
  window = window or most_recent_window(workspace_id)
  if window then
    hl.dispatch(hl.dsp.focus({ window = window }))
  end
end

local function restore_pending()
  if pending then
    restore_focus(pending.workspace_id, pending.window_address)
  end
end

hl.on("monitor.removed", function(monitor)
  if monitor.name == fallback_monitor then
    return
  end

  invalidate_pending()
  pending = nil

  -- Hyprland still reports the pre-lock window as active here.
  local window = focused_window()
  local workspace = window and window.workspace or monitor.active_workspace
  if not workspace then
    forget_saved()
    return
  end

  saved_workspace_id = workspace.id
  saved_window_address = window and window.address or nil
end)

hl.on("monitor.added", function(monitor)
  if monitor.name == fallback_monitor then
    invalidate_pending()
    went_headless = true
    return
  end

  if not went_headless then
    -- An ordinary hotplug, nothing to put back.
    forget_saved()
    return
  end

  went_headless = false
  if saved_workspace_id then
    pending = { workspace_id = saved_workspace_id, window_address = saved_window_address }
  end
  forget_saved()

  if not pending then
    return
  end

  -- The monitor needs a moment to settle before focus will stick.
  invalidate_pending()
  local generation = restore_generation

  hl.timer(function()
    if generation == restore_generation then
      restore_pending()
    end
  end, { timeout = restore_delay_ms, type = "oneshot" })
end)

-- Under the lock the restore emits nothing, so an event here means focus took,
-- whether from the restore or from the user, and there is nothing left to do.
hl.on("workspace.active", function()
  pending = nil
end)

local M = {}

-- Returns a function for hl.dispatch, so omarchy-system-wake can retry the
-- restore after unlock with `hyprctl dispatch 'o.monitor_focus.restore()'`.
-- Does nothing when no round trip is pending.
function M.restore()
  return restore_pending
end

o.monitor_focus = M

return M
