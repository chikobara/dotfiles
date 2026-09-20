--!nonstrict
-- Syncthing launcher provider — type `/st` in the launcher.
--
-- Fuzzy-search the monitored folders; Enter triggers a rescan of the
-- selected folder.

local function decodeSnapshot()
  local encoded = noctalia.state.get("st.snapshot")
  return encoded and noctalia.json.decode(encoded) or nil
end

local STATE_GLYPHS = {
  idle = "cloud-check",
  syncing = "refresh",
  paused = "player-pause",
  error = "alert-triangle",
}

function onQuery(text)
  local snapshot = decodeSnapshot()
  if not snapshot or #snapshot.folders == 0 then
    launcher.setResults(text, {
      { id = "noop", title = noctalia.tr("panel.no-folders"), glyph = "cloud-question" },
    })
    return
  end

  local query = noctalia.string.trim(text)
  local results = {}
  for _, folder in snapshot.folders do
    local score = 0
    if query ~= "" then
      score = noctalia.fuzzyScore(query, `{folder.label} {folder.id}`)
      if not score then
        continue
      end
    end
    -- The state goes in the subtitle, not in `badge`: a badge is drawn in the
    -- icon slot and scaled up to fill it, so a whole phrase like "Up to date"
    -- swallows the row and hides the state glyph.
    local status = noctalia.tr(`state.{folder.state}`)
    local action = noctalia.tr("launcher.rescan-hint", { id = folder.id })
    table.insert(results, {
      id = folder.id,
      title = folder.label,
      subtitle = `{status} · {action}`,
      glyph = STATE_GLYPHS[folder.state] or "cloud-question",
      score = score,
    })
  end
  launcher.setResults(text, results)
end

local cmdNonce = 0

function onActivate(id)
  if id == "noop" then
    return
  end
  cmdNonce += 1
  noctalia.state.set("st.cmd", noctalia.json.encode({ n = cmdNonce, action = "rescan", folder = id }))
  noctalia.notify(noctalia.tr("toast.title"), noctalia.tr("launcher.rescan-started", { id = id }))
end
