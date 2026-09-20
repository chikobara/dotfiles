--!nonstrict

local SNAPSHOT = "asus_fan.status"
local COMMAND = "asus_fan.command"

local snap = noctalia.state.get(SNAPSHOT) or {
  cpu_rpm = 0,
  gpu_rpm = 0,
  profile = "Balanced",
  display_mode = "rpm",
  available = false,
}

local function setProfile(name)
  noctalia.state.set(COMMAND, { action = "set_profile", profile = name })
end

local function setDisplayMode(mode)
  noctalia.state.set(COMMAND, { action = "set_display_mode", mode = mode })
end

local function profileButton(name, label)
  local isSelected = string.lower(snap.profile or "") == string.lower(name)
  return ui.button({
    text = label,
    variant = isSelected and "primary" or "ghost",
    flexGrow = 1,
    onClick = function()
      setProfile(name)
    end,
  })
end

local function modeButton(mode, label)
  local currentMode = snap.display_mode or "rpm"
  local isSelected = currentMode == mode
  return ui.button({
    text = label,
    variant = isSelected and "primary" or "ghost",
    flexGrow = 1,
    onClick = function()
      setDisplayMode(mode)
    end,
  })
end

local function render()
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    -- Header
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ align = "center", gap = 6 }, {
        ui.glyph({ name = "car-fan", color = "primary", size = 18 }),
        ui.label({ text = "ASUS Fan & Profiles", fontSize = 15, fontWeight = "bold", color = "on_surface" }),
      }),
      ui.button({ glyph = "close", variant = "ghost", onClick = function() panel.close() end }),
    }),

    -- Display Mode Section
    ui.column({ gap = 6 }, {
      ui.label({ text = "BAR DISPLAY TEXT", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      ui.row({ gap = 6 }, {
        modeButton("rpm", "RPM"),
        modeButton("profile", "Profile"),
        modeButton("both", "Both"),
      }),
    }),

    -- Profile Switcher Section
    ui.column({ gap = 6 }, {
      ui.label({ text = "PLATFORM PROFILE", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      ui.row({ gap = 6 }, {
        profileButton("Quiet", "Quiet"),
        profileButton("Balanced", "Balanced"),
        profileButton("Performance", "Performance"),
      }),
    }),

    -- Live Telemetry Cards
    ui.column({ gap = 6 }, {
      ui.label({ text = "HARDWARE TELEMETRY", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      ui.row({ gap = 8, align = "center", justify = "space_between" }, {
        ui.row({ fill = "secondary/0.15", radius = 6, paddingH = 8, paddingV = 4, gap = 4, flexGrow = 1, justify = "center" }, {
          ui.label({ text = "CPU Fan: ", fontSize = 12, color = "on_surface_variant" }),
          ui.label({ text = string.format("%d RPM", snap.cpu_rpm or 0), fontSize = 12, fontWeight = "bold", color = "primary" }),
        }),
        ui.row({ fill = "secondary/0.15", radius = 6, paddingH = 8, paddingV = 4, gap = 4, flexGrow = 1, justify = "center" }, {
          ui.label({ text = "GPU Fan: ", fontSize = 12, color = "on_surface_variant" }),
          ui.label({ text = string.format("%d RPM", snap.gpu_rpm or 0), fontSize = 12, fontWeight = "bold", color = "primary" }),
        }),
      }),
    }),
  }))
end

function onOpen(_context)
  snap = noctalia.state.get(SNAPSHOT) or snap
  render()
end

noctalia.state.watch(SNAPSHOT, function(val)
  if type(val) == "table" then
    snap = val
    render()
  end
end)

function update()
  render()
end

render()
