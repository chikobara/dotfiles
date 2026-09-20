--!nonstrict
-- Syncthing desktop widget — a compact status card pinned to the desktop.
--
-- Logo + state, device/folder/pending counters, transfer rates, and a
-- progress bar while syncing. Pure display; open the panel for actions.

local snapshot = nil

local STATE_COLORS = {
  idle = "primary",
  syncing = "secondary",
  paused = "outline",
  disconnected = "secondary",
  offline = "error",
  unauthorized = "error",
  error = "error",
  unconfigured = "outline",
}

local function formatRate(bytesPerSec)
  local units = { "B", "KB", "MB", "GB" }
  local value = bytesPerSec
  local index = 1
  while value >= 1024 and index < #units do
    value /= 1024
    index += 1
  end
  local rounded = (value >= 10 or index == 1) and tostring(math.round(value)) or string.format("%.1f", value)
  return `{rounded} {units[index]}/s`
end

local function stat(value, label)
  return ui.column({ gap = 1, align = "center", flexGrow = 1 }, {
    ui.label({ text = value, fontSize = 15, fontWeight = "bold" }),
    ui.label({ text = label, fontSize = 10, color = "on_surface/0.6" }),
  })
end

local function render()
  local state = snapshot and snapshot.state or "unconfigured"
  local color = STATE_COLORS[state] or "outline"
  local devices = snapshot and `{snapshot.devices.connected}/{snapshot.devices.configured}` or "-"
  local folders = snapshot and tostring(snapshot.totals.monitoredFolders) or "-"
  local pending = snapshot and tostring(snapshot.totals.needItems) or "-"

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.image({
        path = noctalia.isDarkMode() and "icon.svg" or "icon-light.svg",
        width = 18,
        height = 18,
        fit = "contain",
      }),
      ui.label({ text = "Syncthing", fontSize = 14, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = noctalia.tr(`state.{state}`), fontSize = 11, color = color }),
    }),
    ui.row({ gap = 6 }, {
      stat(devices, noctalia.tr("panel.devices")),
      stat(folders, noctalia.tr("panel.folders")),
      stat(pending, noctalia.tr("panel.pending")),
    }),
  }

  if snapshot and state == "syncing" and (snapshot.syncPercent or -1) >= 0 then
    table.insert(children, ui.progress({ progress = snapshot.syncPercent / 100, height = 4, fill = "secondary" }))
  end
  if snapshot and ((snapshot.rateIn or 0) >= 1024 or (snapshot.rateOut or 0) >= 1024) then
    table.insert(children, ui.label({
      text = `↓ {formatRate(snapshot.rateIn or 0)} · ↑ {formatRate(snapshot.rateOut or 0)}`,
      fontSize = 10,
      color = "secondary",
      textAlign = "center",
    }))
  end

  desktopWidget.render(ui.column({ gap = 8, padding = 10, fill = "surface_variant/0.4", radius = 12 }, children))
end

noctalia.state.watch("st.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

function update()
  noctalia.setUpdateInterval(5000)
  -- See bar.luau: watch only fires on the next publish, so pick up the current
  -- snapshot when this widget starts.
  if not snapshot then
    local encoded = noctalia.state.get("st.snapshot")
    snapshot = encoded and noctalia.json.decode(encoded) or nil
  end
  render()
end
