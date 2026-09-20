--!nonstrict

local SNAPSHOT = "asus_fan.status"
local COMMAND = "asus_fan.command"

local snap = noctalia.state.get(SNAPSHOT) or {
  cpu_rpm = 0,
  gpu_rpm = 0,
  profile = "Balanced",
  display_mode = "rpm",
  available = false,
}

local function getDisplayText()
  local mode = snap.display_mode or noctalia.getConfig("display_mode") or "rpm"
  local showLabel = noctalia.getConfig("show_label")
  if showLabel == false then
    return ""
  end

  local maxRpm = math.max(snap.cpu_rpm or 0, snap.gpu_rpm or 0)
  if mode == "profile" then
    return snap.profile or "Auto"
  elseif mode == "both" then
    return string.format("%s %d", snap.profile or "", maxRpm)
  end
  return string.format("%d RPM", maxRpm)
end

local function tooltipRows()
  return {
    { key = noctalia.tr("tooltip.cpu_fan"), value = string.format("%d RPM", snap.cpu_rpm or 0) },
    { key = noctalia.tr("tooltip.gpu_fan"), value = string.format("%d RPM", snap.gpu_rpm or 0) },
    { key = noctalia.tr("tooltip.profile"), value = snap.profile or "Unknown" },
  }
end

local function render()
  local text = getDisplayText()
  barWidget.setGlyph("car-fan")
  barWidget.setText(text)
  barWidget.setTooltip(tooltipRows())
end

noctalia.state.watch(SNAPSHOT, function(val)
  if type(val) == "table" then
    snap = val
    render()
  end
end)

function update()
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  noctalia.state.set(COMMAND, { action = "cycle" })
end

function onRightClick()
  noctalia.togglePanel("kv7499/asus-fan:panel")
end

noctalia.setUpdateInterval(2500)
render()
