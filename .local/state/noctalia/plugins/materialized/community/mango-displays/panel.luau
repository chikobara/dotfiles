--!nonstrict
-- Resolution, refresh rate and scale for one output at a time.
--
-- Each control writes mango monitorrule lines and reloads the compositor config,
-- which is both how the change lands and how it survives a reboot. wlr-randr is read
-- once for the mode lists and the make/model/serial the rules match on; mango
-- reports neither. Arrangement stays with wdisplays, and service.luau saves it
-- without anyone opening this panel.

local layout = require("./layout.luau")
local controls = require("./controls.luau")

-- wlroots takes any positive scale, but fractional factors off this ladder
-- produce blurry integer-scaled clients more often than they help.
local SCALE_STEPS = { 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 3.0 }
local resolutionOf, roundHz = layout.resolutionOf, layout.roundHz

local opened = false
local outputs = {}
local selectedName = ""
local pendingRes = ""
local pendingRefresh = 0
local pendingScale = 1.0
local status = ""
local statusIsError = false
local mirrorErrorShown = false
local busy = false
local overwriteNeeded = false
local mirrorRequestSerial = 0
local mirrorFrom = ""
local mirrorTo = ""
local mirrorStatus = noctalia.state.get("mirror_status") or {
  phase = "stopped",
  available = noctalia.commandExists("wl-mirror"),
  source = nil,
  destination = nil,
  message = "",
}

local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function clearStatus()
  status = ""
  statusIsError = false
  overwriteNeeded = false
end

-- ── Model ──────────────────────────────────────────────────────────────────

local function selectedOutput()
  for _, output in ipairs(outputs) do
    if output.name == selectedName then
      return output
    end
  end
  return nil
end

local function enabledOutputs()
  local list = {}
  for _, entry in ipairs(outputs) do
    if entry.enabled then
      table.insert(list, entry)
    end
  end
  return list
end

local function resolutions(output)
  local seen, list = {}, {}
  for _, mode in ipairs(output.modes) do
    local res = resolutionOf(mode)
    if not seen[res] then
      seen[res] = true
      table.insert(list, { res = res, pixels = mode.width * mode.height })
    end
  end
  table.sort(list, function(a, b) return a.pixels > b.pixels end)
  return list
end

local function refreshRates(output, res)
  local seen, list = {}, {}
  for _, mode in ipairs(output.modes) do
    if resolutionOf(mode) == res then
      local hz = roundHz(mode.refresh)
      if not seen[hz] then
        seen[hz] = true
        table.insert(list, hz)
      end
    end
  end
  table.sort(list, function(a, b) return a > b end)
  return list
end

local function scaleSteps(output)
  local list = {}
  for _, step in ipairs(SCALE_STEPS) do
    table.insert(list, step)
  end
  local current = math.floor(output.scale * 100 + 0.5) / 100
  for _, step in ipairs(list) do
    if math.abs(step - current) < 0.001 then
      return list
    end
  end
  table.insert(list, current)
  table.sort(list)
  return list
end

local function adoptCurrent(output)
  pendingScale = output.scale
  if output.currentMode ~= nil then
    pendingRes = resolutionOf(output.currentMode)
    pendingRefresh = roundHz(output.currentMode.refresh)
    return
  end
  local available = resolutions(output)
  pendingRes = available[1] and available[1].res or ""
  pendingRefresh = refreshRates(output, pendingRes)[1] or 0
end

local function selectOutput(name)
  selectedName = name
  local output = selectedOutput()
  if output ~= nil then
    adoptCurrent(output)
  end
end

local function hasOutput(list, name)
  for _, entry in ipairs(list) do
    if entry.name == name then
      return true
    end
  end
  return false
end

-- A running mirror owns the pair. Otherwise keep whatever the user picked as
-- long as it is still lit, and fill the gaps with the built-in panel and the
-- first output that is not it.
local function syncMirrorPair()
  if mirrorStatus.phase == "running" or mirrorStatus.phase == "starting" then
    mirrorFrom = mirrorStatus.source or mirrorFrom
    mirrorTo = mirrorStatus.destination or mirrorTo
    return
  end

  local lit = enabledOutputs()
  if not hasOutput(lit, mirrorFrom) then
    mirrorFrom = layout.mirrorSource(outputs) or ""
  end
  if mirrorTo == mirrorFrom or not hasOutput(lit, mirrorTo) then
    mirrorTo = ""
    for _, entry in ipairs(lit) do
      if entry.name ~= mirrorFrom then
        mirrorTo = entry.name
        break
      end
    end
  end
end

local function loadOutputs(onLoaded)
  layout.query(function(found)
    if found == nil then
      outputs = {}
      status = tr("status.query_failed")
      statusIsError = true
      render()
      return
    end

    outputs = found
    if selectedOutput() == nil then
      selectOutput(outputs[1] and outputs[1].name or "")
    else
      adoptCurrent(selectedOutput())
    end
    syncMirrorPair()
    if onLoaded ~= nil then
      onLoaded()
    end
    render()
  end)
end

local function persistCurrent(overwrite)
  if layout.rulesPath() == nil then
    status = tr("status.no_profile_path")
    statusIsError = true
    busy = false
    render()
    return
  end
  local ok, err = layout.save(outputs, function()
    busy = false
    overwriteNeeded = false
    loadOutputs()
  end, overwrite)
  if not ok then
    busy = false
    overwriteNeeded = err == layout.NON_MONITOR_RULES
    status = overwriteNeeded and tr("status.overwrite_required") or tr("status.save_failed", { error = tostring(err) })
    statusIsError = true
    render()
    return
  end
  overwriteNeeded = false
  status = tr("status.saved")
  statusIsError = false
  render()
end

-- Every control applies as it is picked, so this is the tail of each of them.
local function setPendingMode(output)
  local width, height = pendingRes:match("^(%d+)x(%d+)$")
  if width == nil then
    return
  end
  output.currentMode = {
    width = tonumber(width),
    height = tonumber(height),
    refresh = pendingRefresh,
    current = true,
  }
  output.scale = pendingScale
end

local function applyPending()
  local output = selectedOutput()
  if output == nil or busy then
    return
  end

  if output.enabled then
    setPendingMode(output)
  end

  busy = true
  overwriteNeeded = false
  status = ""
  render()
  persistCurrent()
end

local function setEnabled(name, on)
  if busy then
    return
  end
  local output = nil
  for _, entry in ipairs(outputs) do
    if entry.name == name then
      output = entry
      break
    end
  end
  if output == nil then
    return
  end

  busy = true
  overwriteNeeded = false
  status = ""
  render()

  layout.setMonitorEnabled(output, on, function(result)
    if result.exitCode ~= 0 then
      busy = false
      status = noctalia.string.trim(result.stderr)
      if status == "" then
        status = tr("status.toggle_failed")
      end
      statusIsError = true
      render()
      return
    end
    output.enabled = on
    if on and output.currentMode == nil then
      setPendingMode(output)
    end
    persistCurrent()
  end)
end

local function adoptMirrorStatus(value)
  if type(value) ~= "table" then
    return
  end

  mirrorStatus = value
  syncMirrorPair()
  if value.phase == "error" then
    local message = type(value.message) == "string" and noctalia.string.trim(value.message) or ""
    status = message ~= "" and message or tr("status.mirror_failed")
    statusIsError = true
    mirrorErrorShown = true
  elseif mirrorErrorShown then
    status = ""
    statusIsError = false
    mirrorErrorShown = false
  end
end

local function setMirrored(on)
  if on and (mirrorFrom == "" or mirrorTo == "" or mirrorFrom == mirrorTo) then
    return
  end

  mirrorRequestSerial += 1
  noctalia.state.set("mirror_request", {
    action = on and "start" or "stop",
    source = on and mirrorFrom or nil,
    destination = on and mirrorTo or nil,
    serial = mirrorRequestSerial,
  })
end

-- ── Rendering ──────────────────────────────────────────────────────────────

local function currentSummary(output)
  local mode = output.currentMode
  if mode == nil then
    return tr("state.off")
  end
  return tr("state.current", {
    resolution = resolutionOf(mode),
    refresh = string.format("%.4g", roundHz(mode.refresh)),
    scale = string.format("%.4g", output.scale),
  })
end

-- What clients actually get a surface for, which is the number people care
-- about when they reach for fractional scaling.
local function logicalSize()
  local w, h = pendingRes:match("^(%d+)x(%d+)$")
  if w == nil or pendingScale <= 0 then
    return nil
  end
  return math.floor(tonumber(w) / pendingScale + 0.5), math.floor(tonumber(h) / pendingScale + 0.5)
end

local function card(titleKey, children)
  local nodes = { ui.label({ text = tr(titleKey), fontSize = 15, fontWeight = "bold", color = "on_surface" }) }
  for _, child in ipairs(children) do
    table.insert(nodes, child)
  end
  return ui.column({
    gap = 10,
    fill = "surface_variant",
    border = "outline",
    borderWidth = 1,
    radius = 12,
    padding = 16,
    align = "stretch",
  }, nodes)
end

-- grow is for a caption sharing a row; a column child must not stretch.
local function caption(text, color, grow)
  return ui.label({
    text = text,
    fontSize = 11,
    color = color or "on_surface_variant",
    maxLines = 1,
    flexGrow = grow and 1 or nil,
  })
end

local function enabledCount()
  return #enabledOutputs()
end

local function fieldRow(labelKey, control, align)
  return ui.row({ gap = 10, align = align or "center" }, {
    ui.label({
      text = tr(labelKey),
      fontSize = 12,
      color = "on_surface_variant",
      width = 88,
      height = align == "start" and 34 or nil,
    }),
    control,
  })
end

-- Equal-width buttons filling the row, the segmented look the built-in panels use.
local function segment(value, index, labelOf, glyphOf, isActive, onPick, live)
  return ui.button({
    key = tostring(index),
    text = labelOf(value),
    glyph = glyphOf ~= nil and glyphOf(value) or nil,
    variant = isActive(value) and "primary" or "outline",
    controlSize = "sm",
    enabled = not busy and live,
    flexGrow = 1,
    onClick = function()
      onPick(value)
      render()
    end,
  })
end

local function segmented(values, labelOf, glyphOf, isActive, onPick, live)
  local row = {}
  for index, value in ipairs(values) do
    table.insert(row, segment(value, index, labelOf, glyphOf, isActive, onPick, live))
  end
  return ui.row({ gap = 6, align = "center" }, row)
end

local function segmentedGrid(values, labelOf, isActive, onPick, perRow, live)
  local rows, current = {}, {}
  for index, value in ipairs(values) do
    table.insert(current, segment(value, index, labelOf, nil, isActive, onPick, live))
    if #current == perRow or index == #values then
      -- Pad the short last row so its buttons keep the width of the row above.
      for _ = #current + 1, perRow do
        table.insert(current, ui.spacer({ flexGrow = 1 }))
      end
      table.insert(rows, ui.row({ gap = 6, align = "center" }, current))
      current = {}
    end
  end
  return ui.column({ gap = 6, align = "stretch", flexGrow = 1 }, rows)
end

local function dropdown(key, options, selectedIndex, onPick, live)
  return ui.select({
    key = key,
    options = options,
    selectedIndex = selectedIndex,
    controlSize = "sm",
    enabled = not busy and live,
    flexGrow = 1,
    onChange = function(index)
      onPick((tonumber(index) or 0) + 1)
    end,
  })
end

local function outputPicker(key, choices, current, onPick, live)
  -- Beyond three connectors the segmented row stops being readable.
  if #choices <= 3 then
    return segmented(choices, function(entry)
      return entry.name
    end, nil, function(entry)
      return entry.name == current
    end, function(entry)
      onPick(entry.name)
    end, live)
  end

  local options, selectedIndex = {}, 0
  for index, entry in ipairs(choices) do
    table.insert(options, entry.name)
    if entry.name == current then
      selectedIndex = index - 1
    end
  end
  return dropdown(key, options, selectedIndex, function(index)
    local picked = choices[index]
    if picked ~= nil then
      onPick(picked.name)
      render()
    end
  end, live)
end

local function monitorCard(output)

  local picker
  -- Beyond three connectors the segmented row stops being readable.
  if #outputs <= 3 then
    picker = segmented(outputs, function(entry)
      return entry.name
    end, function(entry)
      return entry.enabled and "device-desktop" or "device-desktop-off"
    end, function(entry)
      return entry.name == selectedName
    end, function(entry)
      selectOutput(entry.name)
    end, true)
  else
    local options, selectedIndex = {}, 0
    for index, entry in ipairs(outputs) do
      table.insert(options, entry.model ~= "" and (entry.name .. "  ·  " .. entry.model) or entry.name)
      if entry.name == selectedName then
        selectedIndex = index - 1
      end
    end
    picker = dropdown("output", options, selectedIndex, function(index)
      local picked = outputs[index]
      if picked ~= nil then
        selectOutput(picked.name)
        render()
      end
    end, true)
  end

  local last = output.enabled and enabledCount() <= 1
  local summary = output.model ~= "" and (output.model .. "  ·  " .. currentSummary(output)) or currentSummary(output)

  return card("card.monitor", {
    picker,
    ui.row({ gap = 8, align = "center" }, {
      caption(summary, nil, true),
      ui.label({
        text = tr(last and "field.last_output" or "field.enabled"),
        fontSize = 12,
        color = last and "on_surface_variant" or "on_surface",
      }),
      ui.toggle({
        checked = output.enabled,
        enabled = not busy and not last,
        onChange = function(value)
          setEnabled(output.name, value == "true")
        end,
      }),
    }),
  })
end

-- Mango has no output cloning, so this is a wl-mirror client shown fullscreen
-- on the destination. Either output can be the source - a desktop has no eDP-1
-- - so the pair is picked here rather than inferred from the selected monitor.
local function mirrorCard()
  local lit = enabledOutputs()
  if #lit < 2 then
    return nil
  end

  local on = mirrorStatus.phase == "running" or mirrorStatus.phase == "starting"
  local mirrorBusy = mirrorStatus.phase == "starting" or mirrorStatus.phase == "stopping"
  local available = mirrorStatus.available ~= false
  -- The pair is what wl-mirror was launched with, so it is fixed until it stops.
  local live = available and not on and not mirrorBusy

  local targets = {}
  for _, entry in ipairs(lit) do
    if entry.name ~= mirrorFrom then
      table.insert(targets, entry)
    end
  end

  return card("card.mirror", {
    fieldRow("mirror.from", outputPicker("mirror_from", lit, mirrorFrom, function(name)
      mirrorFrom = name
      syncMirrorPair()
    end, live)),
    fieldRow("mirror.to", outputPicker("mirror_to", targets, mirrorTo, function(name)
      mirrorTo = name
    end, live)),
    ui.row({ gap = 8, align = "center" }, {
      caption(tr("mirror.explain", { source = mirrorFrom, destination = mirrorTo }), nil, true),
      ui.label({ text = tr(on and "mirror.on" or "mirror.off"), fontSize = 12, color = "on_surface" }),
      ui.toggle({
        checked = on,
        enabled = not busy and not mirrorBusy and available and mirrorTo ~= "",
        onChange = function(value)
          setMirrored(value == "true")
        end,
      }),
    }),
  })
end

local function modeCard(output)
  local available = resolutions(output)
  local options, selectedIndex = {}, 0
  for index, item in ipairs(available) do
    table.insert(options, item.res)
    if item.res == pendingRes then
      selectedIndex = index - 1
    end
  end

  local resolutionControl = dropdown("resolution", options, selectedIndex, function(index)
    local picked = available[index]
    if picked == nil then
      return
    end
    pendingRes = picked.res
    -- The old rate rarely exists at the new resolution; take the fastest one.
    pendingRefresh = refreshRates(output, pendingRes)[1] or 0
    applyPending()
  end, output.enabled)

  local rates = refreshRates(output, pendingRes)
  local function rateLabel(hz)
    return string.format("%.4g Hz", hz)
  end
  local function rateActive(hz)
    return math.abs(hz - pendingRefresh) < 0.001
  end
  local function pickRate(hz)
    pendingRefresh = hz
    applyPending()
  end

  local refreshControl
  local refreshAlign = "center"
  if #rates <= 3 then
    refreshControl = segmented(rates, rateLabel, nil, rateActive, pickRate, output.enabled)
  elseif #rates <= 8 then
    refreshControl = segmentedGrid(rates, rateLabel, rateActive, pickRate, 4, output.enabled)
    refreshAlign = "start"
  else
    local rateOptions, rateIndex = {}, 0
    for index, hz in ipairs(rates) do
      table.insert(rateOptions, rateLabel(hz))
      if rateActive(hz) then
        rateIndex = index - 1
      end
    end
    refreshControl = dropdown("refresh", rateOptions, rateIndex, function(index)
      local hz = rates[index]
      if hz ~= nil then
        pickRate(hz)
        render()
      end
    end, output.enabled)
  end

  return card("card.mode", {
    fieldRow("field.resolution", resolutionControl),
    fieldRow("field.refresh", refreshControl, refreshAlign),
  })
end

local function scaleCard(output)
  local w, h = logicalSize()
  return card("card.scale", {
    segmentedGrid(scaleSteps(output), function(step)
      return string.format("%.4gx", step)
    end, function(step)
      return math.abs(step - pendingScale) < 0.001
    end, function(step)
      pendingScale = step
      applyPending()
    end, 4, output.enabled),
    caption(w ~= nil and tr("preview.logical", { width = w, height = h }) or "", "primary"),
  })
end

local function header()
  return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", color = "primary", flexGrow = 1 }),
    ui.button({ glyph = "settings", variant = "outline", controlSize = "sm", tooltip = tr("advanced.title"), enabled = not busy, onClick = "onAdvanced" }),
    ui.button({ glyph = "refresh", variant = "outline", controlSize = "sm", tooltip = tr("rescan"), enabled = not busy, onClick = "onRescan" }),
    ui.button({ glyph = "x", variant = "outline", controlSize = "sm", onClick = "onCloseClick" }),
  })
end

local function message(glyph, text, color)
  return ui.column({ flexGrow = 1, gap = 12, align = "center", justify = "center" }, {
    ui.glyph({ name = glyph, size = 48, color = "on_surface_variant" }),
    ui.label({ text = text, color = color, textAlign = "center" }),
  })
end

local function cards(output)
  local stack = { monitorCard(output), modeCard(output), scaleCard(output) }
  local mirror = mirrorCard()
  if mirror ~= nil then
    table.insert(stack, mirror)
  end
  return stack
end

render = function()
  if not noctalia.commandExists("wlr-randr") then
    panel.render(message("device-desktop-off", tr("status.missing_tool"), "error"))
    return
  end

  local output = selectedOutput()
  if output == nil then
    panel.render(message("device-desktop-off", status ~= "" and status or tr("status.no_outputs"), "on_surface_variant"))
    return
  end

  -- The header and the status line stay pinned and the cards scroll, so the
  -- last thing that happened is readable whatever the content does.
  local nodes = { header(), ui.scroll({ flexGrow = 1, gap = 12 }, cards(output)) }
  local note = controls.status(status, statusIsError, overwriteNeeded)
  if note ~= nil then
    table.insert(nodes, note)
  end
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, nodes))
end

-- ── Callbacks ──────────────────────────────────────────────────────────────

noctalia.state.watch("mirror_status", function(value)
  adoptMirrorStatus(value)
  if opened then
    render()
  end
end)

function onOpen(_context)
  opened = true
  clearStatus()
  mirrorErrorShown = false
  busy = false
  adoptMirrorStatus(noctalia.state.get("mirror_status"))
  render()
  loadOutputs()
end

function onClose()
  opened = false
end

function onRescan()
  clearStatus()
  selectedName = ""
  loadOutputs()
end

function onCloseClick()
  panel.close()
end

function onCancelOverwrite()
  overwriteNeeded = false
  status = ""
  busy = false
  loadOutputs()
end

function onOverwrite()
  if busy then
    return
  end
  busy = true
  status = ""
  render()
  persistCurrent(true)
end

function onAdvanced()
  panel.close()
  noctalia.togglePanel("prponkshe/mango-displays:advanced")
end
