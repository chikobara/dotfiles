--!nonstrict
-- Bar widget: a palette glyph that toggles the editor panel.

local function render()
  barWidget.setGlyph("palette")
  barWidget.setTooltip("Palette Creator")
end

function onClick()
  noctalia.togglePanel("decksters-lab/palette-creator:creator")
end

render()
