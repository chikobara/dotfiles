--!nonstrict
-- Saves the layout as mango monitorrule lines on its own, so an arrangement made
-- in wdisplays survives a reboot without anyone opening the panel.
--
-- The compositor is the event source: `mmsg watch all-monitors` emits a line
-- whenever anything about a monitor changes. It also fires on focus and tag
-- changes, so a line means "look again", not "the layout moved" - the signature
-- below decides that. Noctalia has no output hook and wlr-randr has no watch
-- mode, so a slow tick stays armed as a backstop, and becomes the only trigger
-- on a compositor without mmsg.

local layout = require("./layout.luau")

local WATCH_CMD = "mmsg watch all-monitors"
local STREAM_IDLE_MS = 30000
local POLL_MS = 2000
local CHECK_MS = 400
-- Long enough to ride out the burst of events a re-apply produces, short enough
-- that a deliberate rearrange is saved before anyone wonders whether it worked.
local SETTLE_MS = 1200

-- mango gets first refusal on a dark session; this is how long it gets.
local DARK_TICKS = 5

local idleMs = POLL_MS
local lastSig = ""
local lastSaved = ""
local stableSince = 0
local darkTicks = 0

-- Whichever monitor was lit most recently is the best guess at where someone is
-- actually looking, and it beats picking by connector name: a desktop has no
-- eDP-1 to fall back to.
local lastLit = ""

local function signature()
  local parts = {}
  for _, output in ipairs(noctalia.outputs() or {}) do
    table.insert(parts, string.format("%s|%d,%d|%dx%d|%.4f",
      output.name, output.x, output.y, output.width, output.height, output.scale))
  end
  table.sort(parts)
  return table.concat(parts, " ")
end

-- Nothing is lit. That happens when the last enabled monitor is unplugged while
-- the others are off and no rule turns the survivor on. Turning one back on
-- beats leaving a session with nowhere to draw.
local function recover()
  layout.query(function(outputs)
    if outputs == nil then
      return
    end
    local pick = nil
    for _, output in ipairs(outputs) do
      if output.enabled then
        return
      end
      if pick == nil or output.name == lastLit then
        pick = output
      end
    end
    if pick == nil then
      return
    end
    noctalia.log("display: no enabled monitor, turning on " .. pick.name)
    layout.setMonitorEnabled(pick, true)
  end)
end

local function check()
  if noctalia.getConfig("auto_save") == false then
    return
  end

  local sig = signature()
  if sig == "" then
    -- No enabled outputs means no monitor events either, so the tick has to
    -- carry this rather than the stream.
    noctalia.setUpdateInterval(CHECK_MS)
    darkTicks += 1
    if darkTicks >= DARK_TICKS then
      darkTicks = 0
      recover()
    end
    return
  end
  darkTicks = 0

  for _, output in ipairs(noctalia.outputs() or {}) do
    lastLit = output.name
    break
  end

  if sig ~= lastSig then
    lastSig = sig
    stableSince = noctalia.nowMs()
    noctalia.setUpdateInterval(CHECK_MS)
    return
  end
  if sig == lastSaved then
    noctalia.setUpdateInterval(idleMs)
    return
  end
  if noctalia.nowMs() - stableSince < SETTLE_MS then
    return
  end

  lastSaved = sig
  noctalia.setUpdateInterval(idleMs)
  layout.query(function(outputs)
    if outputs == nil or #outputs == 0 then
      lastSaved = ""
      return
    end
    local ok, err, changed = layout.save(outputs)
    if not ok then
      lastSaved = ""
      noctalia.log("display: auto-save failed: " .. tostring(err))
    elseif changed then
      noctalia.log("display: saved rules for " .. #outputs .. " monitor(s)")
    end
  end)
end

function update()
  check()
end

-- runStream reports that the process spawned, not that it works, so the
-- compositor is probed once before the tick is allowed to go quiet.
if noctalia.commandExists("mmsg") then
  noctalia.runAsync("mmsg get all-monitors", function(result)
    if result.exitCode == 0 and noctalia.runStream(WATCH_CMD, check) then
      idleMs = STREAM_IDLE_MS
      noctalia.setUpdateInterval(idleMs)
      noctalia.log("display: watching " .. WATCH_CMD)
    end
  end, 3000)
end

noctalia.setUpdateInterval(idleMs)
