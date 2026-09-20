--!nonstrict

local symbols = {
  Up = "↑",
  Down = "↓",
  Left = "←",
  Right = "→",
  Enter = "↵",
  Backspace = "⌫",
  Tab = "⇥",
  Space = "␣",
  Esc = "Esc",
  Super = "⌘",
  Ctrl = "Ctrl",
  Alt = "Alt",
  Shift = "⇧",
}

local function getFontSize()
  local val = noctalia.getConfig("font_size")

  if type(val) == "number" then
    return val
  elseif type(val) == "string" then
    local cleaned = string.gsub(val, "px", "")
    local num = tonumber(cleaned)
    if num then
      return num
    end
    if val == "small" then
      return 13
    elseif val == "large" then
      return 20
    elseif val == "medium" then
      return 16
    end
  end

  return 16
end

local function getStyle()
  local style = noctalia.getConfig("badge_style") or "glass"

  if style == "solid" then
    return { fill = "surface_container_high", border = "outline", borderWidth = 1, textColor = "on_surface", isKeycap = false }
  elseif style == "accent" then
    return { fill = "primary/0.16", border = "primary/0.75", borderWidth = 1, textColor = "primary", isKeycap = false }
  elseif style == "keycap_dark" then
    return { fill = "#1e1e24", border = "#2d2e38", textColor = "#ffffff", isKeycap = true, baseColor = "#0d0e12", shadowColor = "#000000" }
  elseif style == "keycap_light" then
    return { fill = "#f5f5f7", border = "#ffffff", textColor = "#111116", isKeycap = true, baseColor = "#000000", shadowColor = "#000000" }
  end

  return { fill = "surface_container_high/0.92", border = "outline/0.55", borderWidth = 1, textColor = "on_surface", isKeycap = false }
end

local function render()
  local keys = noctalia.state.get("active_keys") or {}

  if #keys == 0 then
    panel.render(ui.row({}))
    return
  end

  local fontSize = getFontSize()
  local st = getStyle()
  local gap = noctalia.getConfig("margin") or 6
  local padding = noctalia.getConfig("padding") or 6
  local items = {}

  for _, combo in ipairs(keys) do
    local children = {}
    local parts = string.split(combo, " + ")

    for i, part in ipairs(parts) do
      table.insert(children, ui.label({
        text = symbols[part] or part,
        fontSize = fontSize,
        fontWeight = "bold",
        color = st.textColor,
      }))

      if i < #parts then
        table.insert(children, ui.label({
          text = "+",
          fontSize = math.max(9, fontSize - 3),
          fontWeight = "bold",
          color = if st.isKeycap then st.textColor else "on_surface_variant",
        }))
      end
    end

    local isSingleKey = #parts == 1 and #combo <= 3
    local padH = isSingleKey and math.max(8, math.floor(fontSize * 0.6)) or math.max(11, math.floor(fontSize * 0.85))
    local itemHeight = math.max(26, math.floor(fontSize * 1.6))

    if st.isKeycap then
      local basePadBottom = math.max(3, math.floor(fontSize * 0.2))
      -- Extruded keycap base layer
      table.insert(items, ui.row({
        paddingH = 1,
        paddingBottom = basePadBottom,
        fill = st.baseColor,
        border = st.shadowColor,
        borderWidth = 1,
        radius = math.max(7, math.floor(fontSize * 0.45)),
        align = "center",
        justify = "center",
      }, {
        -- Keycap top face
        ui.row({
          height = itemHeight,
          paddingH = padH,
          gap = 6,
          fill = st.fill,
          border = st.border,
          borderWidth = 1,
          radius = math.max(5, math.floor(fontSize * 0.35)),
          align = "center",
          justify = "center",
        }, children),
      }))
    else
      table.insert(items, ui.row({
        height = itemHeight,
        paddingH = padH,
        gap = 6,
        fill = st.fill,
        border = st.border,
        borderWidth = st.borderWidth or 1,
        radius = math.max(6, math.floor(fontSize * 0.4)),
        align = "center",
        justify = "center",
      }, children))
    end
  end

  panel.render(ui.row({
    flexGrow = 1,
    align = "center",
    justify = "center",
  }, {
    ui.row({
      gap = gap,
      padding = padding,
      align = "center",
      justify = "center",
    }, items),
  }))
end

noctalia.state.watch("active_keys", render)

function onConfigChanged()
  render()
end

function onOpen()
  render()
end

render()