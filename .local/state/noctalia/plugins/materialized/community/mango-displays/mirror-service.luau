--!nonstrict

local TITLE = "Mango Displays Mirror"

-- How long to wait for the client to map before giving up on moving it.
local PLACE_ATTEMPTS = 40
local PLACE_RETRY_MS = 100

local dataDir = noctalia.pluginDataDir()
local pidFile = dataDir and (dataDir .. "/mirror.pid") or nil
local commandAvailable = noctalia.commandExists("wl-mirror")
local streamActive = false
local stopMessage = nil
local lastError = ""

local mirror = {
  phase = "stopped",
  source = nil,
  destination = nil,
  available = commandAvailable and pidFile ~= nil,
  message = "",
}

local function tr(key, values)
  return noctalia.tr(key, values)
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function publish(phase, message)
  mirror.phase = phase
  mirror.available = commandAvailable and pidFile ~= nil
  mirror.message = message or ""
  noctalia.state.set("mirror_status", mirror)
end

local function connected(name)
  for _, output in ipairs(noctalia.outputs() or {}) do
    if output.name == name then
      return true
    end
  end
  return false
end

local function cleanup()
  if pidFile ~= nil then
    noctalia.removeFile(pidFile)
  end
end

-- runStream owns the shell process group, so unloading the entry also reaches
-- wl-mirror. The PID file is only needed to stop it without unloading.
local function mirrorCommand(source, destination)
  -- fit keeps the aspect ratio and letterboxes; cover would fill the screen by
  -- cropping the long edge, which loses the top of a 16:10 panel on 16:9.
  local launch = "wl-mirror --scaling fit --fullscreen-output "
    .. shellQuote(destination)
    .. " --fullscreen --title "
    .. shellQuote(TITLE)
    .. " "
    .. shellQuote(source)
    .. " 2>&1 &"

  return table.concat({
    "PIDFILE=" .. shellQuote(pidFile),
    launch,
    "PID=$!",
    [[trap 'kill -TERM "$PID" 2>/dev/null || true' HUP INT TERM EXIT]],
    [[if ! printf '%s\n' "$PID" >"$PIDFILE"; then kill -TERM "$PID" 2>/dev/null; wait "$PID"; printf '__mango_mirror__:failed\n'; exit 0; fi]],
    "sleep 0.15",
    [[if ! kill -0 "$PID" 2>/dev/null; then wait "$PID"; printf '__mango_mirror__:failed\n'; exit 0; fi]],
    [[printf '__mango_mirror__:started\n']],
    [[wait "$PID"; CODE=$?]],
    [[trap - HUP INT TERM EXIT]],
    [[printf '__mango_mirror__:exited:%s\n' "$CODE"]],
  }, "\n")
end

-- Mango honours a fullscreen request but ignores the output the client names,
-- so wl-mirror opens on whichever monitor had focus. Left alone it mirrors the
-- laptop onto the laptop, which is a feedback tunnel rather than a mirror.
-- The unique --title is the handle; appid is shared with any other wl-mirror.
local place
place = function(source, destination, attempt)
  noctalia.runAsync("mmsg get all-clients", function(result)
    if mirror.phase ~= "running" or mirror.destination ~= destination then
      return
    end

    local id = nil
    if result.exitCode == 0 then
      local decoded = noctalia.json.decode(result.stdout)
      if type(decoded) == "table" and type(decoded.clients) == "table" then
        for _, client in ipairs(decoded.clients) do
          if client.title == TITLE then
            id = client.id
            break
          end
        end
      end
    end

    if id == nil then
      if attempt < PLACE_ATTEMPTS then
        noctalia.runAsync(string.format("sleep %.2f", PLACE_RETRY_MS / 1000), function()
          place(source, destination, attempt + 1)
        end)
      end
      return
    end

    local move = string.format("mmsg dispatch %s client,%d", shellQuote("tagmon," .. destination), id)
    noctalia.runAsync(move, function()
      -- tagmon follows the window, and the mirror would then eat every keystroke.
      noctalia.runAsync("mmsg dispatch " .. shellQuote("focusmon," .. source))
    end)
  end, 3000)
end

local function finishStopped(message)
  streamActive = false
  stopMessage = nil
  lastError = ""
  cleanup()
  mirror.source = nil
  mirror.destination = nil
  publish("stopped", message or tr("mirror.service.stopped"))
end

local function finishFailed(fallback)
  local message = lastError ~= "" and lastError or fallback
  streamActive = false
  stopMessage = nil
  lastError = ""
  cleanup()
  mirror.source = nil
  mirror.destination = nil
  publish("error", message)
  noctalia.notifyError(tr("title"), message)
end

local function handleLine(line)
  line = noctalia.string.trim(line or "")
  if line == "__mango_mirror__:started" then
    if mirror.phase ~= "stopping" then
      publish("running", tr("mirror.service.active"))
      place(mirror.source, mirror.destination, 1)
    end
  elseif line == "__mango_mirror__:failed" then
    finishFailed(tr("mirror.service.start_failed"))
  elseif line:match("^__mango_mirror__:exited:") then
    if mirror.phase == "stopping" then
      finishStopped(stopMessage)
    else
      finishFailed(tr("mirror.service.exited"))
    end
  elseif line ~= "" then
    lastError = line
  end
end

local function stop(message)
  if mirror.phase == "stopping" then
    return
  end
  if not streamActive then
    finishStopped(message)
    return
  end

  local pid = pidFile and noctalia.string.trim(noctalia.readFile(pidFile) or ""):match("^%d+$") or nil
  if pid == nil then
    finishFailed(tr("mirror.service.data_unavailable"))
    return
  end

  stopMessage = message
  publish("stopping", tr("mirror.service.stopping"))
  local started = noctalia.runAsync("kill -TERM " .. pid, function(result)
    if mirror.phase == "stopping" and result.exitCode ~= 0 then
      finishFailed(tr("mirror.service.stop_failed"))
    end
  end)
  if not started then
    finishFailed(tr("mirror.service.stop_failed"))
  end
end

local function start(source, destination)
  if not commandAvailable then
    finishFailed(tr("mirror.service.missing_tool"))
    return
  end
  if pidFile == nil then
    finishFailed(tr("mirror.service.data_unavailable"))
    return
  end
  if source == nil or destination == nil or source == destination then
    finishFailed(tr("mirror.service.invalid_pair"))
    return
  end
  if not connected(source) or not connected(destination) then
    finishFailed(tr("mirror.service.disconnected"))
    return
  end
  if streamActive then
    return
  end

  stopMessage = nil
  lastError = ""
  mirror.source = source
  mirror.destination = destination
  publish("starting", tr("mirror.service.starting"))
  streamActive = true
  if not noctalia.runStream(mirrorCommand(source, destination), handleLine) then
    finishFailed(tr("mirror.service.launch_failed"))
  end
end

noctalia.state.watch("mirror_request", function(request)
  if type(request) ~= "table" then
    return
  end
  if request.action == "start" then
    start(request.source, request.destination)
  elseif request.action == "stop" then
    stop(tr("mirror.service.stopped"))
  end
end)

-- A keybind has no panel to pick a pair from, so it gets the obvious one: copy
-- the built-in panel, or the first output on a desktop that has none.
local function defaultPair()
  local names = {}
  for _, output in ipairs(noctalia.outputs() or {}) do
    table.insert(names, output.name)
  end
  if #names < 2 then
    return nil, nil
  end

  local source = names[1]
  for _, name in ipairs(names) do
    if name:match("^eDP") or name:match("^LVDS") or name:match("^DSI") then
      source = name
      break
    end
  end
  for _, name in ipairs(names) do
    if name ~= source then
      return source, name
    end
  end
  return nil, nil
end

--   noctalia msg plugin prponkshe/mango-displays:mirror service toggle ["eDP-1 DP-1"]
function onIpc(event, payload)
  if event == "stop" then
    stop(tr("mirror.service.stopped"))
    return
  end
  if event ~= "start" and event ~= "toggle" then
    return
  end
  if streamActive then
    if event == "toggle" then
      stop(tr("mirror.service.stopped"))
    end
    return
  end

  local source, destination = tostring(payload or ""):match("^%s*(%S+)%s+(%S+)%s*$")
  if source == nil then
    source, destination = defaultPair()
  end
  if source == nil then
    finishFailed(tr("mirror.service.invalid_pair"))
    return
  end
  start(source, destination)
end

function onOutputsChanged()
  if streamActive and (not connected(mirror.source) or not connected(mirror.destination)) then
    stop(tr("mirror.service.disconnected"))
  end
end

function onExit(_signal)
  cleanup()
end

cleanup()
if not commandAvailable then
  publish("error", tr("mirror.service.missing_tool"))
elseif pidFile == nil then
  publish("error", tr("mirror.service.data_unavailable"))
else
  publish("stopped", tr("mirror.service.ready"))
end
