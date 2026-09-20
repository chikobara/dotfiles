--!nonstrict
-- Bar [[widget]] entry for Key Visualizer (Keyviz)
-- Provides a clean status icon on the Noctalia bar with left-click toggle support.

local isActive = noctalia.state.get("is_active") ~= false
local function render()
  local isVert = (type(barWidget.isVertical) == "function" and barWidget.isVertical()) or false
  local container = isVert and ui.column or ui.row

  local iconColor = if isActive then "primary" else "on_surface_variant"
  local tooltipText = if isActive then (noctalia.tr("tooltip_active") or "Key Visualizer: Active") else (noctalia.tr("tooltip_paused") or "Key Visualizer: Paused")

  local children = {
    ui.glyph({
      name = "keyboard",
      size = 14,
      color = iconColor,
    }),
  }

  barWidget.render(container({
    align = "center",
    justify = "center",
    gap = 6,
  }, children))

  if type(barWidget.setTooltip) == "function" then
    barWidget.setTooltip(tooltipText)
  end
  if type(barWidget.setActive) == "function" then
    barWidget.setActive(isActive)
  end
end

noctalia.state.watch("is_active", function(val)
  if val ~= nil then
    isActive = val == true
    render()
  end
end)

function onClick()
  isActive = not isActive
  noctalia.state.set("is_active", isActive)

  if not isActive then
    noctalia.state.set("active_keys", {})
  end

  render()
end

function onRightClick()
  onClick()
end

function onConfigChanged()
  render()
end

render()
