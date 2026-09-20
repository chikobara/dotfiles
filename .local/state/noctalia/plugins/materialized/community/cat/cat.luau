--!nonstrict
-- Cat: an animated running cat bar widget. Pace reflects CPU usage, sampled
-- from /proc/stat, with separately configurable walk/run thresholds. Color
-- follows the theme's secondary role by default, or a pinned custom color.
--
-- The cat shape is a custom pictographic font (fonts/catwalk2.otf, traced
-- from the MIT-licensed CatWalk plasmoid by Driglu4it) so it can be colored
-- like any other bar text: "a" = idle/asleep, "b".."f" = the 5-frame run
-- cycle. Each glyph's advance width is trimmed to the shared ink extent
-- (non-negative left bearing, no dead trailing space) so bar layout doesn't
-- overlap the previous widget or leave a large gap before the next one.
--
-- Font registration is process-global and keyed by file path/family, so this
-- filename must change (not just its contents) whenever the glyph set changes
-- during development, or the shell keeps rendering whatever it cached the
-- first time it saw this path.

local catFont = noctalia.loadFont("fonts/catwalk2.otf")

local GLYPH_IDLE = "a"
local RUN_GLYPHS = { "b", "c", "d", "e", "f" }

local TICK_MS = 80
local WALK_MAX_MS = 380
local WALK_MIN_MS = 180
local RUN_MAX_MS = 160
local RUN_MIN_MS = 55

local catSize = noctalia.getConfig("cat_size")
local showCpuPercent = noctalia.getConfig("show_cpu_percent")
local walkThreshold = noctalia.getConfig("walk_threshold")
local runThreshold = noctalia.getConfig("run_threshold")
local pollIntervalMs = noctalia.getConfig("poll_interval") * 1000
local colorMode = noctalia.getConfig("cat_color_mode")
local customColor = noctalia.getConfig("cat_color")

local frameIndex = 1
local frameElapsed = 0
local frameDurationMs = WALK_MAX_MS

local sampleElapsed = pollIntervalMs -- sample immediately on first tick
local cpuPercent = 0
local prevTotal, prevIdle = nil, nil

local function sampleCpu()
  local stat = noctalia.readFile("/proc/stat")
  if not stat then
    return
  end

  local line = stat:match("^cpu%s+(.-)\n") or stat:match("^cpu%s+(.-)$")
  if not line then
    return
  end

  local fields = {}
  for n in line:gmatch("%d+") do
    table.insert(fields, tonumber(n))
  end

  local idle = (fields[4] or 0) + (fields[5] or 0)
  local total = 0
  for _, v in fields do
    total += v
  end

  if prevTotal then
    local totalDelta = total - prevTotal
    local idleDelta = idle - prevIdle
    if totalDelta > 0 then
      cpuPercent = math.clamp((totalDelta - idleDelta) / totalDelta * 100, 0, 100)
    end
  end

  prevTotal = total
  prevIdle = idle
end

-- Returns ("idle" | "walk" | "run", frame-duration-ms-for-that-pace).
local function paceFor(cpu)
  local runFloor = math.max(runThreshold, walkThreshold + 1)

  if cpu < walkThreshold then
    return "idle", WALK_MAX_MS
  elseif cpu < runFloor then
    local range = math.max(runFloor - walkThreshold, 1)
    local t = math.clamp((cpu - walkThreshold) / range, 0, 1)
    return "walk", WALK_MAX_MS - t * (WALK_MAX_MS - WALK_MIN_MS)
  else
    local range = math.max(100 - runFloor, 1)
    local t = math.clamp((cpu - runFloor) / range, 0, 1)
    return "run", RUN_MAX_MS - t * (RUN_MAX_MS - RUN_MIN_MS)
  end
end

local function resolveColor()
  if colorMode == "custom" and customColor and customColor ~= "" then
    return customColor
  end
  return "secondary"
end

-- The click panel (cat_panel.luau) runs in a separate runtime; it mirrors the
-- bar cat from this shared-state snapshot, republished whenever the visible
-- glyph, whole CPU percent, or color changes (so at most once per animation
-- frame, and only on sample/theme changes while idle).
local lastPublished = nil
local function publishState(pace, glyph, color)
  local cpu = math.floor(cpuPercent)
  local key = `{glyph}|{cpu}|{color}|{pace}`
  if key == lastPublished then
    return
  end
  lastPublished = key
  noctalia.state.set("cat", { glyph = glyph, cpu = cpu, color = color, pace = pace })
end

local function render(pace)
  local glyph = pace == "idle" and GLYPH_IDLE or RUN_GLYPHS[frameIndex]
  local color = resolveColor()

  publishState(pace, glyph, color)

  local children = {
    ui.label({ text = glyph, fontFamily = catFont, baseline = "inkCentered", fontSize = catSize, color = color }),
  }

  if showCpuPercent then
    table.insert(children, ui.label({ text = `{math.floor(cpuPercent)}%`, fontSize = 11, color = color }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))
  barWidget.setTooltip(`Cat — CPU {math.floor(cpuPercent)}% ({pace})`)
end

noctalia.setUpdateInterval(TICK_MS)

function update()
  sampleElapsed += TICK_MS
  if sampleElapsed >= pollIntervalMs then
    sampleElapsed = 0
    sampleCpu()
  end

  local pace, duration = paceFor(cpuPercent)
  frameDurationMs = duration

  if pace == "idle" then
    frameElapsed = 0
    frameIndex = 1
  else
    frameElapsed += TICK_MS
    if frameElapsed >= frameDurationMs then
      frameElapsed = 0
      frameIndex = frameIndex % #RUN_GLYPHS + 1
    end
  end

  render(pace)
end

function onClick()
  noctalia.togglePanel("dotnetrob/cat:panel")
end

function onConfigChanged()
  catSize = noctalia.getConfig("cat_size")
  showCpuPercent = noctalia.getConfig("show_cpu_percent")
  walkThreshold = noctalia.getConfig("walk_threshold")
  runThreshold = noctalia.getConfig("run_threshold")
  pollIntervalMs = noctalia.getConfig("poll_interval") * 1000
  colorMode = noctalia.getConfig("cat_color_mode")
  customColor = noctalia.getConfig("cat_color")
  render((paceFor(cpuPercent)))
end
