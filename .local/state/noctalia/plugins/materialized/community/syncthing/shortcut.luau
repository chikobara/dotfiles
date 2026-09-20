--!nonstrict
-- Syncthing global pause — the [[shortcut]] control-center tile.
--
-- Active while Syncthing is running normally; click to pause all devices
-- (Syncthing's global pause), click again to resume. Mirrors the state
-- published by the poller service.

local snapshot = nil
local cmdNonce = 0

local function allPaused()
  return snapshot ~= nil
    and snapshot.devices.configured > 0
    and snapshot.devices.paused >= snapshot.devices.configured
end

local function reachable()
  if not snapshot then
    return false
  end
  local s = snapshot.state
  return s ~= "offline" and s ~= "unconfigured" and s ~= "unauthorized"
end

local function render()
  shortcut.setLabel(noctalia.tr("shortcut.label"))
  shortcut.setIcon("cloud-network", "cloud-pause")
  shortcut.setActive(reachable() and not allPaused())
  shortcut.setEnabled(reachable())
end

noctalia.state.watch("st.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

function onClick()
  cmdNonce += 1
  local action = allPaused() and "resume_all" or "pause_all"
  noctalia.state.set("st.cmd", noctalia.json.encode({ n = cmdNonce, action = action }))
end

render()
