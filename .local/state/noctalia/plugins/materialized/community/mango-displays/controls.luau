--!nonstrict

local M = {}

M.PADDING = 16
M.RADIUS = 14

function M.card(children)
  return ui.column({ gap = 14, padding = M.PADDING, radius = M.RADIUS, fill = "surface_variant" }, children)
end

function M.heading(text)
  return ui.label({ text = text, fontSize = 15, fontWeight = "bold", flexGrow = 1 })
end

function M.control(caption, node, reading)
  local head = { ui.label({ text = caption, fontSize = 13, fontWeight = "bold", flexGrow = 1 }) }
  if reading ~= nil then
    table.insert(head, ui.label({ text = reading, fontSize = 13, fontWeight = "bold", color = "primary" }))
  end
  return ui.column({ gap = 6 }, {
    ui.row({ align = "center", gap = 8 }, head),
    node,
  })
end

function M.chips(labels, current, onPick)
  local widest = 0
  for _, label in ipairs(labels) do
    widest = math.max(widest, #label)
  end
  local perRow = widest > 6 and 3 or 4

  local rows, row = {}, {}
  for _, label in ipairs(labels) do
    if #row == perRow then
      table.insert(rows, ui.row({ gap = 8 }, row))
      row = {}
    end
    local picked = label == current
    table.insert(row, ui.button({
      key = "chip-" .. label,
      text = label,
      controlSize = "sm",
      flexGrow = 1,
      variant = picked and "primary" or "outline",
      selected = picked,
      onClick = function()
        onPick(label)
      end,
    }))
  end
  if #row > 0 then
    for _ = #row + 1, perRow do
      table.insert(row, ui.spacer({ flexGrow = 1 }))
    end
    table.insert(rows, ui.row({ gap = 8 }, row))
  end
  return ui.column({ gap = 8 }, rows)
end

function M.toggleRow(caption, checked, onSet, key, enabled)
  return ui.row({ align = "center", gap = 10 }, {
    ui.label({ text = caption, fontSize = 13, fontWeight = "bold", flexGrow = 1 }),
    ui.toggle({
      key = key,
      checked = checked,
      enabled = enabled ~= false,
      onChange = function(value)
        onSet(value == "true")
      end,
    }),
  })
end

function M.tiles(outputs, selectedName, onPick)
  local tiles = {}
  for _, entry in ipairs(outputs) do
    local active = entry.name == selectedName
    local name = entry.name
    table.insert(tiles, ui.row({
      key = "pick-" .. name,
      gap = 6,
      align = "center",
      justify = "center",
      paddingV = 9,
      radius = M.RADIUS,
      flexGrow = 1,
      fill = active and "primary" or "surface_variant",
      onClick = function()
        onPick(name)
      end,
    }, {
      ui.glyph({
        name = entry.enabled and "device-desktop" or "device-desktop-off",
        size = 15,
        color = active and "on_primary" or "on_surface_variant",
      }),
      ui.label({
        text = name,
        fontSize = 12,
        fontWeight = "medium",
        color = active and "on_primary" or "on_surface",
      }),
    }))
  end
  return ui.row({ gap = 8 }, tiles)
end

function M.status(text, isError, overwriteNeeded)
  if text == "" then
    return nil
  end
  local row = {
    ui.glyph({
      name = isError and "alert-triangle" or "circle-check",
      size = 14,
      color = isError and "error" or "primary",
    }),
    ui.label({
      text = text,
      fontSize = 11,
      color = isError and "error" or "on_surface_variant",
      maxLines = 2,
      flexGrow = 1,
    }),
  }
  if overwriteNeeded then
    table.insert(row, ui.button({ text = noctalia.tr("action.cancel"), variant = "outline", controlSize = "sm", onClick = "onCancelOverwrite" }))
    table.insert(row, ui.button({ text = noctalia.tr("action.overwrite"), variant = "primary", controlSize = "sm", onClick = "onOverwrite" }))
  end
  return ui.row({ gap = 6, align = "center" }, row)
end

function M.message(text)
  return ui.column({ flexGrow = 1, gap = 10, align = "center", justify = "center" }, {
    ui.glyph({ name = "device-desktop-off", size = 26, color = "on_surface_variant" }),
    ui.label({ text = text, fontSize = 13, color = "on_surface_variant", textAlign = "center" }),
  })
end

function M.header(title, buttons)
  local children = { ui.label({ text = title, fontSize = 15, fontWeight = "semibold", color = "primary", flexGrow = 1 }) }
  for _, button in ipairs(buttons) do
    table.insert(children, button)
  end
  return ui.row({ align = "center", gap = 6 }, children)
end

return M
