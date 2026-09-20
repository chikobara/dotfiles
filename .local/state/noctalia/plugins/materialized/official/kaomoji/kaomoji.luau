--!nonstrict
-- Kaomoji launcher provider.
--
-- Type `/kao` in the launcher to list every kaomoji; the launcher's category
-- filter bar (declared as [[launcher_provider.category]] in plugin.toml) narrows
-- them by category - each result row carries a `category` matching one of those
-- labels. Type after the prefix to search by tag. Press Enter on a kaomoji to
-- copy it to the clipboard.
--
-- The bundled database.json is a curated, compact subset (categories + entries)
-- so it parses well within the script load budget - the full upstream catalogue
-- is far too large to decode inside the launcher.

-- Safety bound, kept above the curated database size so the unfiltered list
-- never truncates a category (the launcher's filter bar narrows the full set).
local RESULT_LIMIT = 2000

local NOTIFY = noctalia.getConfig("notify_on_copy")
NOTIFY = if type(NOTIFY) == "boolean" then NOTIFY else true

-- Lazily loaded + indexed database. nil until the first query.
local db = nil

local function loadDatabase()
  if db ~= nil then
    return db
  end
  local raw = noctalia.readFile("database.json")
  if not raw then
    return nil
  end
  local parsed = noctalia.json.decode(raw)
  if type(parsed) ~= "table" or type(parsed.entries) ~= "table" then
    return nil
  end

  -- Map a category id to its display label/glyph (the label is what the
  -- launcher's category filter matches against on each result row).
  local label, glyph = {}, {}
  for _, c in parsed.categories or {} do
    label[c.id] = c.name
    glyph[c.id] = c.glyph
  end

  db = { label = label, glyph = glyph, entries = parsed.entries }
  return db
end

local function row(d, entry)
  return {
    id = "k:" .. entry.k,
    title = entry.k,
    subtitle = table.concat(entry.t, ", "),
    glyph = d.glyph[entry.c] or "mood-smile",
    category = d.label[entry.c] or "",
  }
end

-- `query` is the launcher text after the `/kao` prefix, leading space trimmed.
-- Category browsing is handled by the launcher's filter bar, so onQuery only
-- distinguishes "show everything" from "free-text tag search".
function onQuery(query)
  local d = loadDatabase()
  if not d then
    launcher.setResults(query, {
      { id = "", title = "Database unavailable", subtitle = "Could not load database.json", glyph = "alert-triangle" },
    })
    return
  end

  local text = noctalia.string.trim(query):lower()
  local words = {}
  for w in text:gmatch("%S+") do
    table.insert(words, w)
  end

  local rows = {}
  for _, entry in d.entries do
    if #rows >= RESULT_LIMIT then
      break
    end
    local matched = true
    if #words > 0 then
      local hay = table.concat(entry.t, " ")
      for _, w in words do
        if not hay:find(w, 1, true) then
          matched = false
          break
        end
      end
    end
    if matched then
      table.insert(rows, row(d, entry))
    end
  end

  if #rows == 0 then
    rows[1] = { id = "", title = "No matches", subtitle = "Try a different word", glyph = "mood-empty" }
  end
  launcher.setResults(query, rows)
end

function onActivate(id)
  -- Use sub() rather than patterns: kaomoji payloads can contain characters Lua
  -- patterns treat specially (and `.` would not match a newline).
  if id:sub(1, 2) ~= "k:" then
    return
  end
  local kaomoji = id:sub(3)
  if kaomoji == "" then
    return
  end
  noctalia.copyToClipboard(kaomoji, "text/plain")
  if NOTIFY then
    noctalia.notify("Kaomoji", kaomoji .. " copied to clipboard")
  end
end
