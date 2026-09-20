--!nonstrict
-- Syncthing bar widget — the [[widget]] entry.
--
-- Shows a state-colored cloud glyph, plus the pending item count while
-- syncing (widget setting "show_pending"). The tooltip carries the full
-- summary. Left click opens the detail panel, right click forces a refresh.

-- Real Syncthing logo, shipped with the plugin: light fill for dark themes,
-- dark fill for light themes. State is conveyed by a small glyph overlay and
-- the pending count, since the image itself cannot be tinted.
local function logo(state)
  return ui.image({
    path = noctalia.isDarkMode() and "icon.svg" or "icon-light.svg",
    width = 16,
    height = 16,
    fit = "contain",
    opacity = (state == "paused" or state == "unconfigured") and 0.45 or 1,
  })
end

local BADGES = {
  syncing = { glyph = "refresh", color = "secondary" },
  paused = { glyph = "player-pause", color = "outline" },
  disconnected = { glyph = "plug-connected-x", color = "secondary" },
  offline = { glyph = "x", color = "error" },
  unauthorized = { glyph = "lock-exclamation", color = "error" },
  error = { glyph = "alert-triangle", color = "error" },
  unconfigured = { glyph = "question-mark", color = "outline" },
}

local COLORS = {
  idle = "on_surface",
  syncing = "secondary",
  paused = "outline",
  disconnected = "secondary",
  offline = "error",
  unauthorized = "error",
  error = "error",
  unconfigured = "outline",
}

local snapshot = nil
local cmdNonce = 0

local function sendCmd(action)
  cmdNonce += 1
  noctalia.state.set("st.cmd", noctalia.json.encode({ n = cmdNonce, action = action }))
end

local function stateOf()
  return snapshot and snapshot.state or "unconfigured"
end

local function pendingText()
  if not snapshot then
    return ""
  end
  -- Prefer the overall completion percentage; fall back to pending counts.
  local pct = snapshot.syncPercent or -1
  if pct >= 0 and pct < 100 then
    return `{pct}%`
  end
  local items = snapshot.totals.needItems
  if items > 99 then
    return "99+"
  end
  if items > 0 then
    return tostring(items)
  end
  if snapshot.totals.syncingFolders > 0 then
    return tostring(snapshot.totals.syncingFolders)
  end
  return ""
end

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

local function tooltipRows()
  local state = stateOf()
  local rows = {
    { key = noctalia.tr("tooltip.state"), value = noctalia.tr(`state.{state}`) },
  }
  if snapshot then
    table.insert(rows, {
      key = noctalia.tr("tooltip.devices"),
      value = `{snapshot.devices.connected}/{snapshot.devices.configured}`,
    })
    table.insert(rows, {
      key = noctalia.tr("tooltip.folders"),
      value = tostring(snapshot.totals.monitoredFolders),
    })
    if snapshot.totals.needItems > 0 then
      table.insert(rows, {
        key = noctalia.tr("tooltip.pending"),
        value = tostring(snapshot.totals.needItems),
      })
    end
    if (snapshot.rateIn or 0) >= 1024 or (snapshot.rateOut or 0) >= 1024 then
      table.insert(rows, {
        key = noctalia.tr("tooltip.rates"),
        value = `↓ {formatRate(snapshot.rateIn or 0)} · ↑ {formatRate(snapshot.rateOut or 0)}`,
      })
    end
    table.insert(rows, { key = noctalia.tr("tooltip.checked"), value = snapshot.checkedAt })
  end
  return rows
end

local function render()
  local state = stateOf()
  local color = COLORS[state] or "outline"
  local showPending = noctalia.getConfig("show_pending") ~= false
  local pending = state == "syncing" and showPending and pendingText() or ""
  local container = barWidget.isVertical() and ui.column or ui.row

  local children = { logo(state) }
  local badge = BADGES[state]
  if badge then
    table.insert(children, ui.glyph({ name = badge.glyph, size = 11, color = badge.color }))
  end
  if pending ~= "" then
    table.insert(children, ui.label({ text = pending, fontWeight = "bold", color = color }))
  end

  barWidget.render(container({ gap = 5, align = "center" }, children))
  barWidget.setTooltip(tooltipRows())
end

noctalia.state.watch("st.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

function update()
  noctalia.setUpdateInterval(2000)
  -- state.watch only fires on the next publish, so a widget created after the
  -- service's last poll would sit at "unconfigured" until then; read whatever
  -- snapshot is already there.
  if not snapshot then
    local encoded = noctalia.state.get("st.snapshot")
    snapshot = encoded and noctalia.json.decode(encoded) or nil
  end
  render()
end

function onClick()
  noctalia.togglePanel("rylos/syncthing:panel")
end

function onRightClick()
  sendCmd("refresh")
end

function onIpc(event)
  if event == "refresh" then
    sendCmd("refresh")
  end
end
