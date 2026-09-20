--!nonstrict
-- Bar widget that opens the Wallhaven browser panel.

local glyph = noctalia.getConfig("glyph")

local function render()
  barWidget.setGlyph(glyph)
  barWidget.setTooltip(noctalia.tr("title"))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("noctalia/wallhaven:browser")
end

render()
