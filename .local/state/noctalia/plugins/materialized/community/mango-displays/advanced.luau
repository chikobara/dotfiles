--!nonstrict

local layout = require("./layout.luau")
local controls = require("./controls.luau")

local TRANSFORMS = { "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" }
local HDR_INPUTS = { "hdr_min_lum", "hdr_max_lum", "hdr_max_avg_lum" }
local MODE_INPUTS = { "width", "height", "refresh" }
local DRAFT_FIELDS = { "width", "height", "refresh", "hdr_min_lum", "hdr_max_lum", "hdr_max_avg_lum", "icc" }

local outputs = {}
local selectedName = ""
local status = ""
local statusIsError = false
local busy = false
local overwriteNeeded = false
local drafts = {}
local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function clearStatus()
  status = ""
  statusIsError = false
  overwriteNeeded = false
end

local function selectedOutput()
  for _, output in ipairs(outputs) do
    if output.name == selectedName then
      return output
    end
  end
  return nil
end

local function draftKey(output, key)
  return output.name .. ":" .. key
end

local function advancedValue(output, key)
  local extra = type(output.ruleFields) == "table" and output.ruleFields or {}
  return extra[key] or ""
end

local function modeValue(output, key)
  local mode = output.currentMode
  if mode == nil then
    return ""
  end
  if key == "refresh" then
    return tostring(layout.roundHz(mode.refresh))
  end
  return tostring(mode[key] or "")
end

local function draftValue(output, key)
  if key == "width" or key == "height" or key == "refresh" then
    return modeValue(output, key)
  end
  return advancedValue(output, key)
end

local function syncDraft(output, key)
  drafts[draftKey(output, key)] = draftValue(output, key)
end

local function loadOutputs()
  layout.query(function(found)
    if found == nil then
      outputs = {}
      status = tr("status.query_failed")
      statusIsError = true
      render()
      return
    end

    outputs = found
    layout.attachRuleFields(outputs)
    for _, output in ipairs(outputs) do
      for _, key in ipairs(DRAFT_FIELDS) do
        syncDraft(output, key)
      end
    end
    if selectedOutput() == nil then
      selectedName = outputs[1] and outputs[1].name or ""
    end
    render()
  end)
end

local function save(overwrite)
  if layout.rulesPath() == nil then
    busy = false
    status = tr("status.no_profile_path")
    statusIsError = true
    render()
    return
  end

  local ok, err = layout.save(outputs, function()
    busy = false
    overwriteNeeded = false
    status = tr("status.saved")
    statusIsError = false
    loadOutputs()
  end, overwrite)
  if not ok then
    busy = false
    overwriteNeeded = err == layout.NON_MONITOR_RULES
    status = overwriteNeeded and tr("status.overwrite_required") or tr("status.save_failed", { error = tostring(err) })
    statusIsError = true
    render()
  end
end

local function commit(output, changes)
  if busy then
    return
  end
  output.ruleFields = type(output.ruleFields) == "table" and output.ruleFields or {}
  for key, value in pairs(changes) do
    if key == "transform" then
      output.transform = value
    else
      output.ruleFields[key] = value ~= "" and value or nil
    end
  end

  busy = true
  overwriteNeeded = false
  status = ""
  render()
  save()
end

local function validCustomMode(width, height, refresh)
  return width ~= nil and height ~= nil and refresh ~= nil
    and width >= 1 and width <= 9999 and width % 1 == 0
    and height >= 1 and height <= 9999 and height % 1 == 0
    and refresh >= 0.001 and refresh <= 9999
end

local function commitCustomMode(output)
  local width = tonumber(noctalia.string.trim(drafts[draftKey(output, "width")] or ""))
  local height = tonumber(noctalia.string.trim(drafts[draftKey(output, "height")] or ""))
  local refresh = tonumber(noctalia.string.trim(drafts[draftKey(output, "refresh")] or ""))
  if not validCustomMode(width, height, refresh) then
    status = tr("status.invalid_mode")
    statusIsError = true
    render()
    return
  end
  output.currentMode = { width = width, height = height, refresh = refresh, current = true }
  commit(output, { custom = "1" })
end

local function boolControl(output, key, checked)
  return controls.toggleRow(tr("field." .. key), checked, function(on)
    commit(output, { [key] = on and "1" or "0" })
  end, key, not busy)
end

local function validateInput(key, value)
  if value == "" or key == "icc" then
    return true
  end
  local number = tonumber(value)
  return number ~= nil and number >= 0 and number <= 10000
end

local function draftInput(output, key)
  local id = draftKey(output, key)
  return ui.input({
    key = id,
    value = drafts[id] or "",
    placeholder = tr("advanced.unset"),
    controlSize = "sm",
    flexGrow = 1,
    onChange = function(value)
      drafts[id] = value or ""
    end,
  })
end

local function modeInput(output, key)
  return controls.control(tr("field." .. key), draftInput(output, key))
end

local function inputControl(output, key)
  return controls.control(tr("field." .. key), ui.row({ gap = 8, align = "center" }, {
    draftInput(output, key),
    ui.button({
      text = tr("action.apply"),
      controlSize = "sm",
      enabled = not busy,
      onClick = function()
        local value = noctalia.string.trim(drafts[draftKey(output, key)] or "")
        if not validateInput(key, value) then
          status = tr("status.invalid_value", { field = tr("field." .. key) })
          statusIsError = true
          render()
          return
        end
        commit(output, { [key] = value })
      end,
    }),
  }))
end

local function transformControl(output)
  return controls.control(tr("field.rr"), controls.chips(TRANSFORMS, output.transform or "normal", function(label)
    commit(output, { transform = label })
  end))
end

render = function()
  local output = selectedOutput()
  local nodes = {
    controls.header(tr("advanced.title"), {
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = tr("rescan"), enabled = not busy, onClick = "onRefresh" }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClick" }),
    }),
  }

  if output == nil then
    table.insert(nodes, controls.message(status ~= "" and status or tr("status.no_outputs")))
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, nodes))
    return
  end

  local picture = { controls.heading(tr("advanced.picture")), transformControl(output) }
  table.insert(picture, boolControl(output, "vrr", advancedValue(output, "vrr") == "1"))
  table.insert(picture, boolControl(output, "custom", advancedValue(output, "custom") == "1"))
  for _, key in ipairs(MODE_INPUTS) do
    table.insert(picture, modeInput(output, key))
  end
  table.insert(picture, ui.button({
    text = tr("action.apply_custom_mode"),
    controlSize = "sm",
    enabled = not busy,
    onClick = function()
      commitCustomMode(output)
    end,
  }))

  local hdr = {
    controls.heading(tr("advanced.hdr")),
    boolControl(output, "hdr", advancedValue(output, "hdr") == "1"),
    boolControl(output, "hdr_force", advancedValue(output, "hdr_force") == "1"),
  }
  for _, key in ipairs(HDR_INPUTS) do
    table.insert(hdr, inputControl(output, key))
  end

  local body = {
    controls.tiles(outputs, selectedName, function(name)
      selectedName = name
      status = ""
      render()
    end),
    controls.card(picture),
    controls.card(hdr),
    controls.card({ controls.heading(tr("advanced.color")), inputControl(output, "icc") }),
  }
  local note = controls.status(status, statusIsError, overwriteNeeded)
  if note ~= nil then
    table.insert(body, note)
  end
  table.insert(nodes, ui.scroll({ flexGrow = 1, gap = 10 }, body))
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, nodes))
end

function onOpen(_context)
  clearStatus()
  busy = false
  render()
  loadOutputs()
end

function onRefresh()
  clearStatus()
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
  save(true)
end

function onKey(chord, pressed)
  if pressed and chord == "escape" then
    panel.close()
    noctalia.togglePanel("prponkshe/mango-displays:panel")
  end
end
