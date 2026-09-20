--!nonstrict
-- Palette Creator — editor panel.
--
-- Inspired by WerWolv's "Color Scheme Creator" for v4
-- (github.com/WerWolv/noctalia-plugins/tree/main/color-scheme-creator).
-- Separate, unaffiliated project, not made or endorsed by WerWolv — v4
-- and v5 plugins aren't compatible, so this is a from-scratch v5 port.
-- See README.md's Accreditation section.
--
-- A v5-native port of the v4 "Color Scheme Creator" plugin, simplified to a
-- single (dark) variant: the same colors are written to both the "dark" and
-- "light" slots of the palette file, so the palette looks the same
-- regardless of which mode Noctalia resolves it in.
--
-- Differences from the v4 plugin, because v5 plugins don't get direct engine
-- hooks into the live color service:
--   * "Preview" repeatedly writes to palettes/_live_preview.json and calls
--     `noctalia msg color-scheme-set custom _live_preview` — a real (if
--     heavier-weight) persist+reload each time, restored to your original
--     source/palette when you stop preview or close the panel.
--   * "Reset" reverts unsaved edits back to the last snapshot (taken when
--     you opened the panel, or right after your last Save) — it does not
--     touch your active system palette or fetch anything.
--   * "New" starts a fresh scheme, seeded from your currently active,
--     fully-resolved palette (any source — builtin/wallpaper/community/
--     custom — via the live-snapshot template; see README) or, failing
--     that, a neutral seed palette.
--
-- Note: Noctalia's custom-palette JSON only accepts strict 6-digit
-- #RRGGBB per role — no alpha. An earlier version of this plugin had a
-- per-role opacity slider; it's gone because Noctalia silently drops any
-- 8-digit value and falls back to something else, so it could never
-- actually apply.

local WIP_FILE = "wip.json"
local PREVIEW_NAME = "_live_preview"

-- ── Color roles (same 16 MD3 roles v4 used, same order) ───────────────────
local ROLES = {
  { key = "mPrimary", label = "Primary" },
  { key = "mOnPrimary", label = "On Primary" },
  { key = "mSecondary", label = "Secondary" },
  { key = "mOnSecondary", label = "On Secondary" },
  { key = "mTertiary", label = "Tertiary" },
  { key = "mOnTertiary", label = "On Tertiary" },
  { key = "mError", label = "Error" },
  { key = "mOnError", label = "On Error" },
  { key = "mSurface", label = "Surface" },
  { key = "mOnSurface", label = "On Surface" },
  { key = "mSurfaceVariant", label = "Surface Variant" },
  { key = "mOnSurfaceVariant", label = "On Surface Variant" },
  { key = "mOutline", label = "Outline" },
  { key = "mShadow", label = "Shadow" },
  { key = "mHover", label = "Hover" },
  { key = "mOnHover", label = "On Hover" },
}

-- Neutral fallback seed, used only when we can't read your actual active
-- custom palette from disk (builtin / wallpaper / community sources).
local FALLBACK_SEED = {
  mPrimary = "#a6e22e", mOnPrimary = "#272822",
  mSecondary = "#66d9ef", mOnSecondary = "#272822",
  mTertiary = "#f92672", mOnTertiary = "#272822",
  mError = "#f92672", mOnError = "#272822",
  mSurface = "#272822", mOnSurface = "#f8f8f2",
  mSurfaceVariant = "#3e3d32", mOnSurfaceVariant = "#a6e22e",
  mOutline = "#75715e", mShadow = "#272822",
  mHover = "#3a3a32", mOnHover = "#f8f8f2",
}

-- ── State ──────────────────────────────────────────────────────────────────
local scheme = nil -- flat { mPrimary = "#RRGGBB", ... } — always clean 6-digit
local baseline = nil -- { colors = {...} } snapshot to revert to
local schemeName = ""
local previewActive = false
local origSourceKind = nil
local origSourceValue = nil
local statusText = ""
local pendingPickRole = nil -- role.key waiting on a hyprpicker screen-sample across a close/reopen
local showLoadPicker = false
local loadOptions = {} -- list of saved palette names (without .json), for the Load picker
local confirmDeleteName = nil -- name pending a second confirming click before it's actually deleted

local render -- forward decl
local applyPreview -- forward decl (revertChanges/loadPaletteByName call this before its own
  -- definition further down; without a forward decl those calls would resolve
  -- to a nil global instead of this local function)

-- ── Color math (port of the v4 QML HSV helpers) ───────────────────────────

local function hexToRgb(hex)
  hex = hex:gsub("#", "")
  if #hex == 3 then
    hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
  end
  local r = tonumber(hex:sub(1, 2), 16) or 0
  local g = tonumber(hex:sub(3, 4), 16) or 0
  local b = tonumber(hex:sub(5, 6), 16) or 0
  return r / 255, g / 255, b / 255
end

local function rgbToHex(r, g, b)
  r = math.floor(math.max(0, math.min(1, r)) * 255 + 0.5)
  g = math.floor(math.max(0, math.min(1, g)) * 255 + 0.5)
  b = math.floor(math.max(0, math.min(1, b)) * 255 + 0.5)
  return string.format("#%02X%02X%02X", r, g, b)
end

local function rgbToHsv(r, g, b)
  local maxc = math.max(r, g, b)
  local minc = math.min(r, g, b)
  local v = maxc
  local delta = maxc - minc
  local s = (maxc == 0) and 0 or delta / maxc
  local h = 0
  if delta > 0 then
    if maxc == r then
      h = ((g - b) / delta) % 6
    elseif maxc == g then
      h = (b - r) / delta + 2
    else
      h = (r - g) / delta + 4
    end
    h = h / 6
    if h < 0 then h = h + 1 end
  end
  return h, s, v
end

local function hsvToRgb(h, s, v)
  local i = math.floor(h * 6) % 6
  local f = h * 6 - math.floor(h * 6)
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)
  if i == 0 then return v, t, p
  elseif i == 1 then return q, v, p
  elseif i == 2 then return p, v, t
  elseif i == 3 then return p, q, v
  elseif i == 4 then return t, p, v
  else return v, p, q end
end

local function brighten(hex)
  local r, g, b = hexToRgb(hex)
  local h, s, v = rgbToHsv(r, g, b)
  local ns = math.max(0, s - 0.1)
  local nv = math.min(1.0, v + 0.15)
  return rgbToHex(hsvToRgb(h, ns, nv))
end

-- Strip any alpha suffix from a hex value down to a clean 6-digit color.
-- Noctalia's palette loader only accepts strict #RRGGBB in the role fields
-- of a custom palette file — an 8-digit value is silently dropped and the
-- role falls back to something else, so alpha can never actually survive
-- here. This just guards against seeding from an old hand-written file
-- that has one. Also lowercases: Noctalia's palette loader appears to
-- choke on uppercase hex, and several color sources here (hyprpicker's
-- default output, the native color-picker dialog, hand-edited palette
-- files) can hand us uppercase or mixed-case values.
local function sanitizeHex(hex)
  local clean = hex:gsub("#", ""):lower()
  if #clean == 8 then
    clean = clean:sub(1, 6)
  end
  return "#" .. clean
end

-- Restrict a user-typed palette name down to a safe filesystem basename
-- before it's used in a path or passed to another process.
local function sanitizeName(raw)
  local name = noctalia.string.trim(tostring(raw or ""))
  name = name:gsub("[/\\]", "")
  name = name:gsub("%.%.", "")
  name = name:gsub("[^%w %-_%(%)]", "")
  return noctalia.string.trim(name)
end

-- Derive a full terminal ANSI palette from the MD3 roles — same approach the
-- v4 plugin used: green/yellow have no MD3 equivalent so they're synthesized
-- from the primary's saturation/value at standard ANSI hues (135°, 55°).
local function generateTerminalColors(s)
  local pr, pg, pb = hexToRgb(s.mPrimary)
  local _, ps, _ = rgbToHsv(pr, pg, pb)
  local sat = (ps > 0.3) and ps or 0.70
  local val = 0.80

  local function colorAt(hueDeg)
    return rgbToHex(hsvToRgb(hueDeg / 360, sat, val))
  end

  local normGreen = colorAt(135)
  local normYellow = colorAt(55)

  return {
    normal = {
      black = s.mSurface:lower(),
      red = s.mError:lower(),
      green = normGreen,
      yellow = normYellow,
      blue = s.mPrimary:lower(),
      magenta = s.mSecondary:lower(),
      cyan = s.mTertiary:lower(),
      white = s.mOnSurface:lower(),
    },
    bright = {
      black = s.mSurfaceVariant:lower(),
      red = brighten(s.mError),
      green = brighten(normGreen),
      yellow = brighten(normYellow),
      blue = brighten(s.mPrimary),
      magenta = brighten(s.mSecondary),
      cyan = brighten(s.mTertiary),
      white = "#FFFFFF",
    },
    background = s.mSurface:lower(),
    foreground = s.mOnSurface:lower(),
    cursor = s.mPrimary:lower(),
    cursorText = s.mOnPrimary:lower(),
    selectionBg = s.mPrimary:lower(),
    selectionFg = s.mOnPrimary:lower(),
  }
end

-- Build the final palette-variant object written to disk / pushed for
-- preview: the 16 role colors (clean 6-digit hex) plus the terminal block
-- generated from them.
local function composePayload(s)
  local payload = {}
  for _, role in ipairs(ROLES) do
    payload[role.key] = s[role.key]
  end
  payload.terminal = generateTerminalColors(s)
  return payload
end

-- ── Persistence helpers ─────────────────────────────────────────────────────

local function deepCopy(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = (type(v) == "table") and deepCopy(v) or v
  end
  return out
end

local function palettesDir()
  return noctalia.expandPath("~/.config/noctalia/palettes")
end

-- Path a Noctalia user template (see templates/live-snapshot.tpl, shipped
-- with this plugin) should be configured to render to. Unlike
-- color-scheme-get + reading a named file — which only works when
-- source = "custom" — this file holds the actual resolved colors no matter
-- what source is active (builtin/wallpaper/community/custom), because
-- Noctalia's own template engine resolves them regardless of source.
local function snapshotPath()
  return noctalia.expandPath("~/.local/state/noctalia/plugin-data/kyle-palette-creator/live-snapshot.json")
end

-- Where OUR OWN template config entry lives — a file this plugin owns
-- exclusively, never touching any file you might already have. Noctalia
-- merges every *.toml under ~/.config/noctalia/, so this is enough to be
-- picked up without risking clobbering something of yours.
local function ownTemplateConfigPath()
  return noctalia.expandPath("~/.config/noctalia/palette-creator-live-template.toml")
end

-- Find where this plugin's own files actually live on disk. Not the same
-- path in every install: a local path-source install (like `noctalia msg
-- plugins source add ... path ...`) sits at a predictable location, but a
-- git-source install (the normal case once this ships in community-
-- plugins) gets "materialized" into an unpredictable per-install
-- directory. Rather than assume one or the other, check the predictable
-- spot first, then search the materialized-plugins directory for whichever
-- subfolder's plugin.toml actually declares our id.
local function findOwnPluginDir()
  local candidate = noctalia.expandPath("~/.local/share/noctalia/plugins/palette-creator")
  local manifest = noctalia.readFile(candidate .. "/plugin.toml")
  if manifest and manifest:find("decksters-lab/palette-creator", 1, true) then
    return candidate
  end

  local materializedRoot = noctalia.expandPath("~/.local/state/noctalia/plugins/materialized")
  local entries = noctalia.listDir(materializedRoot)
  if entries then
    for _, entry in ipairs(entries) do
      local dir = materializedRoot .. "/" .. entry
      local m = noctalia.readFile(dir .. "/plugin.toml")
      if m and m:find("decksters-lab/palette-creator", 1, true) then
        return dir
      end
      -- Some materialization layouts nest one level deeper by plugin name.
      local nested = dir .. "/palette-creator"
      local m2 = noctalia.readFile(nested .. "/plugin.toml")
      if m2 and m2:find("decksters-lab/palette-creator", 1, true) then
        return nested
      end
    end
  end

  return nil
end

-- Set up wallpaper/builtin/community theme seeding automatically, the
-- first time it's needed. Safe to call every time: it's a no-op once our
-- own config file exists with the right content. Never touches any file
-- you didn't create yourself.
local function ensureLiveTemplateConfigured()
  local configPath = ownTemplateConfigPath()
  local existing = noctalia.readFile(configPath)
  if existing and existing:find("palette_creator_live", 1, true) then
    return -- already set up
  end

  local ownDir = findOwnPluginDir()
  if not ownDir then
    return -- couldn't find our own install location; leave it for manual setup
  end

  local toml = "[theme.templates.user.palette_creator_live]\n"
    .. ('input_path  = "%s/templates/live-snapshot.tpl"\n'):format(ownDir)
    .. ('output_path = "%s"\n'):format(snapshotPath())

  local ok = noctalia.writeFile(configPath, toml)
  if ok then
    noctalia.runAsync("noctalia msg config-reload", function()
      noctalia.runAsync("noctalia msg templates-apply")
    end)
  end
end

local function wipPath()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return nil
  end
  return dir .. "/" .. WIP_FILE
end

-- Written to disk right before we force-close the panel for a hyprpicker
-- pick, deleted the moment onOpen() sees it. Deliberately NOT an in-memory
-- flag: if the host tears down/recreates this panel's Luau state between
-- close() and the next onOpen() (untested assumption either way), a plain
-- local var would silently lose the "this reopen continues an edit" signal
-- and the just-picked color would vanish. A file survives that regardless.
local function resumeMarkerPath()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return nil
  end
  return dir .. "/resume-pending"
end

local function setResumePending()
  local path = resumeMarkerPath()
  if path then
    noctalia.writeFile(path, "1")
  end
end

local function consumeResumePending()
  local path = resumeMarkerPath()
  if not path then
    return false
  end
  local marker = noctalia.readFile(path)
  if marker then
    noctalia.removeFile(path)
    return true
  end
  return false
end

local function saveWip()
  local path = wipPath()
  if not path or not scheme then
    return
  end
  local encoded = noctalia.json.encode({ name = schemeName, colors = scheme })
  if encoded then
    noctalia.writeFile(path, encoded)
  end
end

local function clearWip()
  local path = wipPath()
  if path then
    noctalia.removeFile(path)
  end
end

local function loadWip()
  local path = wipPath()
  if not path then
    return nil
  end
  local raw = noctalia.readFile(path)
  if not raw then
    return nil
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) == "table" and type(decoded.colors) == "table" then
    return decoded
  end
  return nil
end

-- Try to read the currently active custom palette straight off disk (its
-- "dark" section), so Reset seeds from what you're actually using right now.
local function seedFromActivePalette(onDone)
  noctalia.runAsync("noctalia msg color-scheme-get", function(result)
    if result.exitCode == 0 then
      local out = noctalia.string.trim(result.stdout)
      local kind, value = out:match("^(%S+)%s+(.+)$")
      origSourceKind = kind
      origSourceValue = value
    else
      origSourceKind = nil
      origSourceValue = nil
    end

    -- Prefer the live-resolved snapshot (works for any source: builtin,
    -- wallpaper, community, custom) over the old custom-only file read.
    local raw = noctalia.readFile(snapshotPath())
    if raw then
      local decoded = noctalia.json.decode(raw)
      if type(decoded) == "table" and type(decoded.dark) == "table" then
        onDone(decoded.dark)
        return
      end
    end

    -- Fall back to the old path: only works when source = "custom", and
    -- only until the snapshot template above is set up (see README).
    -- origSourceValue must be sanitized before use, same as the Save name.
    if origSourceKind == "custom" and origSourceValue
        and not origSourceValue:find("[/\\]")
        and not origSourceValue:find("%.%.") then
      local raw2 = noctalia.readFile(palettesDir() .. "/" .. origSourceValue .. ".json")
      if raw2 then
        local decoded2 = noctalia.json.decode(raw2)
        if type(decoded2) == "table" and type(decoded2.dark) == "table" then
          onDone(decoded2.dark)
          return
        end
      end
    end
    onDone(nil)
  end, 2000)
end

-- Sanitize every role in a raw dark/light variant table down to clean
-- 6-digit hex (see sanitizeHex).
local function sanitizeScheme(raw)
  local out = {}
  for _, role in ipairs(ROLES) do
    local v = raw[role.key]
    if v then
      out[role.key] = sanitizeHex(v)
    end
  end
  return out
end

local function seedEditor(afterSeed)
  schemeName = ""
  ensureLiveTemplateConfigured()
  seedFromActivePalette(function(fromDisk)
    if fromDisk then
      scheme = sanitizeScheme(fromDisk)
    else
      scheme = deepCopy(FALLBACK_SEED)
    end
    baseline = { colors = deepCopy(scheme) }
    clearWip()
    if afterSeed then afterSeed() end
    render()
  end)
end

-- Revert any unsaved edits back to the last snapshot (taken on load, or
-- after your last Save) — undoes changes made this session, doesn't touch
-- your active system palette or fetch anything.
local function revertChanges()
  if not baseline then
    return
  end
  scheme = deepCopy(baseline.colors)
  statusText = "Reverted unsaved changes."
  if previewActive then
    applyPreview()
  end
  saveWip()
  render()
end

-- ── Load an existing saved palette ──────────────────────────────────────
-- Only seedFromActivePalette() existed before — it only ever pulls whatever
-- palette is *currently active*. This lets you browse and re-open any
-- previously-saved file in ~/.config/noctalia/palettes, active or not.

local function refreshLoadOptions()
  local entries, err = noctalia.listDir(palettesDir())
  loadOptions = {}
  if not entries then
    return
  end
  for _, entry in ipairs(entries) do
    local name = entry:match("^(.+)%.json$")
    if name and name ~= PREVIEW_NAME then
      table.insert(loadOptions, name)
    end
  end
  table.sort(loadOptions)
end

local function loadPaletteByName(name)
  local raw = noctalia.readFile(palettesDir() .. "/" .. name .. ".json")
  if not raw then
    statusText = "Couldn't read \"" .. name .. "\"."
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" or type(decoded.dark) ~= "table" then
    statusText = "\"" .. name .. "\" isn't a valid palette file."
    return
  end
  scheme = sanitizeScheme(decoded.dark)
  schemeName = name
  baseline = { colors = deepCopy(scheme) }
  clearWip()
  saveWip()
  statusText = "Loaded \"" .. name .. "\"."
  if previewActive then
    applyPreview()
  end
end

-- ── Preview ─────────────────────────────────────────────────────────────────

applyPreview = function()
  if not previewActive or not scheme then
    return
  end
  local payload = composePayload(scheme)
  -- Same colors for dark and light so the palette looks the same regardless
  -- of which mode Noctalia resolves it in.
  local encoded = noctalia.json.encode({ dark = payload, light = payload })
  if encoded then
    noctalia.writeFile(palettesDir() .. "/" .. PREVIEW_NAME .. ".json", encoded)
    noctalia.runAsync(("noctalia msg color-scheme-set custom %s"):format(PREVIEW_NAME))
  end
end

local function startPreview()
  if previewActive then
    return
  end
  previewActive = true
  origSourceKind = nil
  origSourceValue = nil
  noctalia.runAsync("noctalia msg color-scheme-get", function(result)
    if result.exitCode == 0 then
      local out = noctalia.string.trim(result.stdout)
      local kind, value = out:match("^(%S+)%s+(.+)$")
      origSourceKind = kind
      origSourceValue = value
    end
    applyPreview()
  end, 2000)
end

local function stopPreview()
  if not previewActive then
    return
  end
  previewActive = false
  if origSourceKind and origSourceValue then
    -- Argv form, not a formatted shell string — origSourceValue is
    -- untrusted, same as the Save name.
    noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", origSourceKind, origSourceValue })
  end
  render()
end

-- ── Screen color picking (hyprpicker) ──────────────────────────────────────
-- Same close/reopen pattern as the community "Color Picker" plugin: the
-- panel has to get out of the way before hyprpicker can freeze and sample
-- the screen underneath it, so the pick actually happens from onClose(),
-- once the close animation is done, then the panel reopens with the result.

local function runHyprpicker()
  local role = pendingPickRole
  pendingPickRole = nil
  if not role then
    return
  end
  local roleLabel = role
  for _, r in ipairs(ROLES) do
    if r.key == role then roleLabel = r.label end
  end
  if not noctalia.commandExists("hyprpicker") then
    noctalia.notifyError("Palette Creator", "hyprpicker isn't installed — can't pick from screen.")
    setResumePending()
    noctalia.togglePanel("decksters-lab/palette-creator:creator")
    return
  end
  -- -a: hyprpicker copies to clipboard itself, independent of whether our
  -- own stdout parsing below succeeds. -b/-q: plain, quiet output so
  -- stdout is just the color. Search for a hex token anywhere in the
  -- (trimmed) output rather than requiring the whole string to be exactly
  -- one, in case any stray log line slips through despite -q.
  noctalia.runAsync("hyprpicker -f hex -b -q -a -l", function(result)
    if result.exitCode == 0 then
      local out = noctalia.string.trim(result.stdout)
      local hex = out:match("#(%x%x%x%x%x%x)") or out:match("(%x%x%x%x%x%x)")
      if hex then
        hex = hex:lower()
        scheme[role] = "#" .. hex
        saveWip()
        if previewActive then
          applyPreview()
        end
        noctalia.notify("Palette Creator", "Picked #" .. hex .. " → " .. roleLabel .. " (also copied to clipboard)")
      else
        statusText = "Couldn't read a color from hyprpicker's output."
        noctalia.notifyError("Palette Creator", "Pick didn't return a readable color — check the clipboard, hyprpicker's -a should have copied it anyway.")
      end
    else
      statusText = "Screen pick cancelled."
    end
    setResumePending()
    noctalia.togglePanel("decksters-lab/palette-creator:creator")
  end, 30000)
end

-- ── Save ─────────────────────────────────────────────────────────────────

local function saveScheme()
  local name = sanitizeName(schemeName)
  if name == "" or not scheme then
    statusText = "Enter a name before saving."
    render()
    return
  end
  schemeName = name

  local payload = composePayload(scheme)

  local encoded, err = noctalia.json.encode({ dark = payload, light = payload }, true)
  if not encoded then
    noctalia.notifyError("Palette Creator", err or "Failed to encode palette JSON")
    return
  end

  local dir = palettesDir()
  local okDir = noctalia.mkdirAll(dir)
  if not okDir then
    noctalia.notifyError("Palette Creator", "Could not create " .. dir)
    return
  end

  local path = dir .. "/" .. name .. ".json"
  local ok, werr = noctalia.writeFile(path, encoded)
  if not ok then
    noctalia.notifyError("Palette Creator", werr or ("Failed to write " .. path))
    return
  end

  -- One-click apply, same as v4: saving switches the active palette to it.
  -- Argv form so the name can't be reinterpreted by a shell.
  noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "custom", name })
  noctalia.notify("Palette Creator", "Saved and applied \"" .. name .. "\"")

  previewActive = false
  baseline = { colors = deepCopy(scheme) }
  statusText = "Saved \"" .. name .. "\". Reset now reverts to this."
  saveWip()
  render()
end

-- ── UI ───────────────────────────────────────────────────────────────────
-- Click pattern matches the official example plugin exactly: a plain preview
-- box (no onClick — boxes aren't interactive) next to a real button that
-- opens the color picker.

local function roleRow(role)
  local displayColor = scheme and scheme[role.key] or "#000000"
  return ui.row({ gap = 12, align = "center" }, {
    ui.box({ width = 26, height = 26, radius = 6, fill = displayColor, border = "outline", borderWidth = 1 }),
    ui.label({ text = role.label, color = "on_surface", flexGrow = 1 }),
    ui.label({ text = displayColor, color = "on_surface_variant", fontSize = 12 }),
    ui.button({
      key = "edit-" .. role.key,
      text = "Edit",
      onClick = function()
        local initial = scheme[role.key]
        local accepted = noctalia.openColorPicker(initial, function(newColor)
          if newColor ~= nil then
            scheme[role.key] = newColor:lower()
            saveWip()
            if previewActive then
              applyPreview()
            end
          end
          render()
        end)
        if not accepted then
          statusText = "A color picker is already open."
          render()
        end
      end,
    }),
    ui.button({
      key = "pick-" .. role.key,
      glyph = "color-picker",
      tooltip = "Pick from screen (hyprpicker)",
      onClick = function()
        pendingPickRole = role.key
        panel.close()
      end,
    }),
  })
end


render = function()
  local roleRows = {}
  for _, role in ipairs(ROLES) do
    table.insert(roleRows, roleRow(role))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
    -- Header
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = "Palette Creator", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = function() panel.close() end }),
    }),

    -- Name + actions
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "name", placeholder = "Palette name (e.g. MyScheme)", value = schemeName,
        flexGrow = 1,
        onChange = function(value)
          schemeName = value
          saveWip()
        end,
      }),
      ui.button({
        text = previewActive and "Stop preview" or "Preview",
        glyph = previewActive and "eye-off" or "eye",
        onClick = function()
          if previewActive then stopPreview() else startPreview() end
          render()
        end,
      }),
      ui.button({ text = "Reset", onClick = function() revertChanges() end }),
      ui.button({
        text = "Load",
        glyph = "folder-open",
        onClick = function()
          refreshLoadOptions()
          showLoadPicker = true
          render()
        end,
      }),
      ui.button({ text = "New", onClick = function() seedEditor() end }),
      ui.button({ text = "Save", glyph = "device-floppy", onClick = function() saveScheme() end }),
    }),

    -- Role list, or the Load picker when it's open
    (showLoadPicker and ui.column({ flexGrow = 1, gap = 12 }, {
      ui.row({ align = "center", justify = "space_between" }, {
        ui.label({ text = "Saved Palettes", fontWeight = "bold", color = "on_surface" }),
        ui.button({
          text = "Close",
          onClick = function()
            showLoadPicker = false
            render()
          end,
        }),
      }),
      (#loadOptions > 0 and ui.scroll({ height = 260, flexGrow = 1, gap = 6 }, (function()
        local rows = {}
        for _, name in ipairs(loadOptions) do
          if confirmDeleteName == name then
            -- Second step of a two-click delete: the row swaps to an
            -- explicit Confirm/Cancel pair so an accidental misclick on the
            -- original trash icon can never destroy a saved palette outright.
            table.insert(rows, ui.row({ align = "center", justify = "space_between", gap = 8 }, {
              ui.label({ text = "Delete \"" .. name .. "\"?", fontSize = 13, color = "on_surface", flexGrow = 1 }),
              ui.button({
                text = "Confirm",
                glyph = "trash-2",
                onClick = function()
                  local file = palettesDir() .. "/" .. name .. ".json"
                  noctalia.removeFile(file)
                  confirmDeleteName = nil
                  refreshLoadOptions()
                  render()
                end,
              }),
              ui.button({
                text = "Cancel",
                onClick = function()
                  confirmDeleteName = nil
                  render()
                end,
              }),
            }))
          else
            table.insert(rows, ui.row({ align = "center", justify = "space_between", gap = 8 }, {
              ui.label({ text = name, fontSize = 13, color = "on_surface", flexGrow = 1 }),
              ui.button({
                text = "Load",
                glyph = "folder-open",
                onClick = function()
                  loadPaletteByName(name)
                  showLoadPicker = false
                  render()
                end,
              }),
              ui.button({
                glyph = "trash-2",
                onClick = function()
                  confirmDeleteName = name
                  render()
                end,
              }),
            }))
          end
        end
        return rows
      end)()) or ui.label({
        text = "No saved palettes found in ~/.config/noctalia/palettes.",
        color = "on_surface_variant", fontSize = 12,
      })),
    }) or ui.scroll({ flexGrow = 1, gap = 8 }, roleRows)),

    -- Status line
    ui.label({ text = statusText, color = "on_surface_variant", fontSize = 12 }),
  }))
end

function onOpen(_context)
  if consumeResumePending() then
    local wip = loadWip()
    if wip then
      scheme = wip.colors
      baseline = { colors = deepCopy(wip.colors) }
      schemeName = wip.name or ""
    end
    render()
    return
  end
  -- Every other open — including reopening the panel after closing it
  -- normally — always reflects whatever theme is actually active right
  -- now (wallpaper-derived or otherwise), not a leftover draft from a
  -- past session. If you want to keep unsaved edits across a close, hit
  -- Save before closing; otherwise every open starts from current.
  seedEditor()
end

function onClose()
  if pendingPickRole then
    runHyprpicker()
    return
  end
  if previewActive then
    stopPreview()
  end
  saveWip()
end
