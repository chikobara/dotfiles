--!nonstrict

local active = noctalia.getConfig("enabled_by_default") ~= false
local keys = {}
local lastPress = 0
local lastWasModifier = false
local listenerRunning = false
local listenerPid: number? = nil
local panelOpen = false

noctalia.state.set("is_active", active)
noctalia.state.set("active_keys", {})

local script = `{noctalia.pluginDir()}/scripts/listener.py`

local function openPanel()
  if not panelOpen then
    if type(noctalia.togglePanel) == "function" then
      noctalia.togglePanel("h-jangra/keyviz:overlay")
    end
    panelOpen = true
  end
end

local function closePanel()
  if panelOpen then
    if type(noctalia.togglePanel) == "function" then
      noctalia.togglePanel("h-jangra/keyviz:overlay")
    end
    panelOpen = false
  end
end

local function clear()
  keys = {}
  lastWasModifier = false
  lastPress = 0
  noctalia.state.set("active_keys", {})
  closePanel()
end

local function decodeJson(str: string)
  if type(json) == "table" and type(json.decode) == "function" then
    return pcall(json.decode, str)
  elseif type(noctalia.json) == "table" and type(noctalia.json.decode) == "function" then
    return pcall(noctalia.json.decode, str)
  end
  return false, nil
end

local function stopListener()
  if listenerPid and type(noctalia.runAsync) == "function" then
    noctalia.runAsync(`kill -TERM {listenerPid}`, function() end)
    listenerPid = nil
  end

  if type(noctalia.runAsync) == "function" then
    noctalia.runAsync(`pkill -TERM -f "{script}"`, function() end)
  end

  listenerRunning = false
  clear()
end

local function startListener()
  if listenerRunning then
    return
  end

  listenerRunning = true

  noctalia.runStream(`python3 -u "{script}"`, function(line)
    local ok, event = decodeJson(line)

    if not ok or type(event) ~= "table" then
      return
    end

    if type(event.pid) == "number" then
      listenerPid = event.pid
    end

    if event.type == "release" then
      if not event.modifiers or #event.modifiers == 0 then
        lastWasModifier = false
      end
      return
    end

    if event.type ~= "press" or not active then
      return
    end

    local mods = event.modifiers or {}

    if noctalia.getConfig("show_modifiers_only") == true and #mods == 0 then
      return
    end

    local combo = event.combo or event.key
    local isMod = event.is_modifier == true

    if isMod then
      if lastWasModifier and #keys > 0 then
        keys[#keys] = combo
      else
        table.insert(keys, combo)
      end
      lastWasModifier = true
    else
      if lastWasModifier and #keys > 0 then
        keys[#keys] = combo
      else
        table.insert(keys, combo)
      end
      lastWasModifier = false
    end

    local maxKeys = noctalia.getConfig("max_keys") or 4

    while #keys > maxKeys do
      table.remove(keys, 1)
    end

    lastPress = noctalia.nowMs()

    local copy = {}

    for _, key in ipairs(keys) do
      table.insert(copy, key)
    end

    noctalia.state.set("active_keys", copy)
    openPanel()
  end)
end

noctalia.state.watch("is_active", function(value)
  active = value == true

  if active then
    startListener()
  else
    stopListener()
  end
end)

function onIpc(event: string, _payload: any)
  if event == "toggle" then
    noctalia.state.set("is_active", not active)
  elseif event == "enable" then
    noctalia.state.set("is_active", true)
  elseif event == "disable" then
    noctalia.state.set("is_active", false)
  elseif event == "clear" then
    clear()
  end
end

function onExit()
  stopListener()
end

noctalia.setUpdateInterval(50)

function update()
  if #keys > 0 and noctalia.nowMs() - lastPress >= (noctalia.getConfig("timeout_ms") or 500) then
    clear()
  end
end

if active then
  startListener()
end
