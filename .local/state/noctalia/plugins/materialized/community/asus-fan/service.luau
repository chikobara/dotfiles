--!nonstrict

local SNAPSHOT = "asus_fan.status"
local COMMAND = "asus_fan.command"

local status = {
  cpu_rpm = 0,
  gpu_rpm = 0,
  profile = "Balanced",
  display_mode = "rpm",
  available = false,
}

local reading = false

local function publish()
  noctalia.state.set(SNAPSHOT, {
    cpu_rpm = status.cpu_rpm,
    gpu_rpm = status.gpu_rpm,
    profile = status.profile,
    display_mode = status.display_mode,
    available = status.available,
  })
end

local function parseOutput(stdout)
  if not stdout or stdout == "" then
    return
  end
  status.available = true

  local cpu, gpu = stdout:match("FANS:(%d+):(%d+)")
  if cpu and gpu then
    status.cpu_rpm = tonumber(cpu) or 0
    status.gpu_rpm = tonumber(gpu) or 0
  end

  local prof = stdout:match("Active profile:%s*([%a%d_-]+)")
  if prof and prof ~= "" then
    status.profile = prof
  end
end

local function refresh()
  if reading then
    return
  end
  reading = true

  local cmd = "sh -c 'for h in /sys/class/hwmon/hwmon*; do if [ \"$(cat $h/name 2>/dev/null)\" = \"asus\" ]; then echo \"FANS:$(cat $h/fan1_input 2>/dev/null || echo 0):$(cat $h/fan2_input 2>/dev/null || echo 0)\"; break; fi; done; asusctl profile get 2>/dev/null | grep \"Active profile:\" || true'"

  local ok = noctalia.runAsync(cmd, function(result)
    reading = false
    if result.exitCode == 0 then
      parseOutput(result.stdout or "")
    else
      status.available = false
    end
    publish()
  end, 3000)

  if not ok then
    reading = false
  end
end

local function cycleProfile()
  noctalia.runAsync("asusctl profile next", function()
    refresh()
  end, 2000)
end

local function setProfile(name)
  noctalia.runAsync("asusctl profile set " .. name, function()
    refresh()
  end, 2000)
end

noctalia.state.watch(COMMAND, function(cmd)
  if type(cmd) == "table" then
    if cmd.action == "cycle" then
      cycleProfile()
    elseif cmd.action == "set_profile" and type(cmd.profile) == "string" then
      setProfile(cmd.profile)
    elseif cmd.action == "set_display_mode" and type(cmd.mode) == "string" then
      status.display_mode = cmd.mode
      publish()
    elseif cmd.action == "refresh" then
      refresh()
    end
  elseif cmd == "cycle" then
    cycleProfile()
  elseif cmd == "refresh" then
    refresh()
  end
end)

function update()
  refresh()
end

function onConfigChanged()
  local poll = tonumber(noctalia.getConfig("poll_interval_ms")) or 2500
  noctalia.setUpdateInterval(poll)
  refresh()
end

local pollInterval = tonumber(noctalia.getConfig("poll_interval_ms")) or 2500
noctalia.setUpdateInterval(pollInterval)

publish()
refresh()
