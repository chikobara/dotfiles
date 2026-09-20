--!nonstrict
-- Control-center quick tile: same toggle as the bar widget.

shortcut.setLabel("Palette Creator")
shortcut.setIcon("palette")

function onClick()
  noctalia.togglePanel("decksters-lab/palette-creator:creator")
end
