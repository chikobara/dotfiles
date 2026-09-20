--!nonstrict
-- Bar tile: left opens the display panel, right hands off to wdisplays.
-- The right binding lives here rather than in [widget.actions] because
-- Noctalia 5.0.0-beta.8 does not apply manifest-declared gesture defaults.

barWidget.setGlyph(noctalia.getConfig("glyph"))
barWidget.setTooltip(noctalia.tr("widget.tooltip"))

function onClick()
  noctalia.togglePanel("prponkshe/mango-displays:panel")
end

function onRightClick()
  noctalia.runAsync("wdisplays")
end
