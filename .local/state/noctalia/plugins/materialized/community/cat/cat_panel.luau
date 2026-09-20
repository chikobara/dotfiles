--!nonstrict
-- Cat panel: the popup opened by clicking the bar widget. Shows the same cat
-- glyph as the bar, just bigger, plus the CPU percentage.
--
-- The panel runs in its own Luau runtime, so it can't share locals with
-- cat.luau. Instead the bar widget publishes { glyph, cpu, color, pace } to
-- the plugin's shared state store under "cat" whenever any of them change,
-- and this script re-renders on every update — which is also what keeps the
-- big cat's run cycle in step with the bar cat, frame for frame. No ticks of
-- its own: with no widget publishing (state.get returns nil) it just shows
-- the sleeping cat with no reading.

local catFont = noctalia.loadFont("fonts/catwalk2.otf")

local PANEL_CAT_SIZE = 120

local snapshot = nil

local function render()
  local glyph = snapshot and snapshot.glyph or "a"
  local color = snapshot and snapshot.color or "secondary"
  local cpuText = snapshot and `CPU {snapshot.cpu}%` or "CPU —"

  panel.render(ui.column({ gap = 12, align = "center", padding = 24 }, {
    ui.label({
      text = glyph,
      fontFamily = catFont,
      baseline = "inkCentered",
      fontSize = PANEL_CAT_SIZE,
      color = color,
    }),
    ui.label({ text = cpuText, fontSize = 20, color = color }),
  }))
end

noctalia.state.watch("cat", function(value)
  snapshot = value
  render()
end)

function onOpen()
  snapshot = noctalia.state.get("cat")
  render()
end
