--!nonstrict
-- Translator launcher provider.
--
-- Usage from the launcher: `/tr <lang> <text>` - e.g. `/tr es hello world`.
-- If the first word is not a language, the whole query is translated to the
-- configured default target. Press Enter on a result to copy it to the clipboard.
-- Translation uses Google Translate's public `translate_a/single` endpoint or DeepL's `v2/translate` endpoint.

-- Common language aliases → ISO code. Any other 2–3 letter token is passed
-- through to the provider as-is, so uncommon languages still work.
local LANGUAGES = {
  ar = { "arabic", "arabe" },
  bg = { "bulgarian", "bulgare" },
  cs = { "czech", "tcheque" },
  da = { "danish", "danois" },
  de = { "german", "allemand", "deutsch" },
  el = { "greek", "grec" },
  en = { "english", "anglais" },
  es = { "spanish", "espagnol", "espanol" },
  et = { "estonian", "estonien" },
  fa = { "persian", "farsi", "persan" },
  fi = { "finnish", "finnois" },
  fr = { "french", "francais" },
  he = { "hebrew", "hebreu" },
  hi = { "hindi" },
  hu = { "hungarian", "hongrois" },
  id = { "indonesian", "indonesien" },
  it = { "italian", "italien" },
  ja = { "japanese", "japonais" },
  ko = { "korean", "coreen" },
  lt = { "lithuanian", "lituanien" },
  lv = { "latvian", "letton" },
  nl = { "dutch", "neerlandais" },
  no = { "norwegian", "norvegien" },
  pl = { "polish", "polonais" },
  pt = { "portuguese", "portugais" },
  ro = { "romanian", "roumain" },
  ru = { "russian", "russe" },
  sk = { "slovak", "slovaque" },
  sl = { "slovenian", "slovène", "slovene" },
  sv = { "swedish", "suedois" },
  th = { "thai", "thailandais" },
  tr = { "turkish", "turc" },
  uk = { "ukrainian", "ukrainien" },
  vi = { "vietnamese", "vietnamien" },
  zh = { "chinese", "chinois", "mandarin" },
}

-- provider|target|text -> { text, target, recoveredFrom }; pending guards against
-- duplicate in-flight fetches.
local cache = {}
local pending = {}

-- Resolve a token to a language code: a known alias, or a bare 2–3 letter code.
local function resolveLang(token)
  local lower = token:lower()
  for code, aliases in LANGUAGES do
    if code == lower or table.find(aliases, lower) then
      return code
    end
  end
  if lower:match("^%a%a%a?$") then
    return lower
  end
  return nil
end

-- Google returns [[[ "segment", "orig", ... ], ...], ...]; the translation is the
-- concatenation of segment[1] across the first array.
local function parseGoogle(body)
  local decoded = noctalia.json.decode(body)
  if type(decoded) ~= "table" or type(decoded[1]) ~= "table" then
    return nil
  end
  local parts = {}
  for _, segment in decoded[1] do
    if type(segment) ~= "table" or type(segment[1]) ~= "string" then
      continue
    end
    table.insert(parts, segment[1])
  end
  if #parts == 0 then
    return nil
  end

  -- auto detected source language
  local source = nil
  if type(decoded[3]) == "string" then
    source = decoded[3]:lower()
  end

  return table.concat(parts), source
end

-- Returned when a provider rejects the target language; drives the retry in onQuery.
local INVALID_TARGET = "Invalid target language code"

-- Maps a failed response to a user-facing message. `extra` holds provider-specific codes.
local function httpError(res, extra)
  if not res.ok or res.status == 0 then
    return "Connection error - is the network up?"
  end
  if extra and extra[res.status] then
    return extra[res.status]
  end
  if res.status == 400 then
    return INVALID_TARGET
  elseif res.status == 429 then
    return "Rate limit exceeded: Please slow down"
  elseif res.status >= 500 then
    return "Internal Server Error / Service Unavailable: Try again later"
  end
  return "Translation error"
end

local function fetchGoogle(text, target, onDone)
  local url = `https://translate.googleapis.com/translate_a/single?client=dict-chrome-ex&sl=auto&tl={noctalia.string.urlEncode(target)}&dt=t&q={noctalia.string.urlEncode(text)}`
  noctalia.http({ url = url }, function(res)
    if not res.ok or res.status >= 400 then
      onDone(nil, httpError(res))
      return
    end
    local translated, source = parseGoogle(res.body)
    if translated then
      onDone(translated, nil, source)
    else
      onDone(nil, "Translation error")
    end
  end)
end

local DEEPL_ERRORS = {
  [403] = "Authorization failed: Invalid DeepL API key",
  [456] = "Quota exceeded: DeepL limit reached",
}

local function fetchDeepL(text, target, onDone)
  -- Trim: a pasted key often carries trailing whitespace, which would break both the
  -- free-tier suffix test below and the Authorization header.
  local configured = noctalia.getConfig("deepl_api_key")
  local apiKey = if type(configured) == "string" then noctalia.string.trim(configured) else ""
  if apiKey == "" then
    onDone(nil, "DeepL API Key is not present")
    return
  end

  -- Free-tier keys end in ":fx" and are only valid against the free endpoint.
  local url = if apiKey:match(":fx$")
    then "https://api-free.deepl.com/v2/translate"
    else "https://api.deepl.com/v2/translate"

  local headers = {
    `Authorization: DeepL-Auth-Key {apiKey}`,
    "Content-Type: application/json",
  }

  -- DeepL uses NB for Norwegian Bokmål and does not accept NO.
  local targetLang = target:upper()
  if targetLang == "NO" then
    targetLang = "NB"
  end

  local body = noctalia.json.encode({
    text = { text },
    target_lang = targetLang,
  })

  noctalia.http({ method = "POST", url = url, headers = headers, body = body }, function(res)
    if not res.ok or res.status >= 400 then
      onDone(nil, httpError(res, DEEPL_ERRORS))
      return
    end

    local decoded = noctalia.json.decode(res.body)
    if
      type(decoded) == "table"
      and type(decoded.translations) == "table"
      and type(decoded.translations[1]) == "table"
    then
      local source = decoded.translations[1].detected_source_language
      if type(source) == "string" then
        source = source:lower()
      end
      onDone(decoded.translations[1].text, nil, source)
    else
      onDone(nil, "Translation error")
    end
  end)
end

local function hintRow(title, subtitle, glyph)
  return { id = title, title = title, subtitle = subtitle, glyph = glyph }
end

-- `entry.recoveredFrom` is set when the leading token was rejected as a language and
-- retranslated as part of the text, so the row never passes that off as a plain hit.
local function resultRow(entry)
  local langPair = if entry.source then `{entry.source} → {entry.target}` else entry.target

  local subtitle = if entry.recoveredFrom
    then `Translation ({langPair}), "{entry.recoveredFrom}" treated as text - press Enter to copy`
    else `Translation ({langPair}) - press Enter to copy`
  return {
    id = entry.text,
    title = entry.text,
    subtitle = subtitle,
    glyph = "language",
    presentation = "detail",
  }
end

function onQuery(query)
  local defaultTarget = noctalia.getConfig("target_lang")
  defaultTarget = if type(defaultTarget) == "string" and defaultTarget ~= "" then defaultTarget:lower() else "en"

  local text = noctalia.string.trim(query)
  if text == "" then
    launcher.setResults(query, { hintRow("Translate text", "Type: <lang> <text> - e.g. es hello", "language") })
    return
  end

  local first, rest = text:match("^(%S+)%s+([%s%S]*)$")
  local target, content
  if first then
    local code = resolveLang(first)
    if code then
      target = code
      content = rest
    else
      target = defaultTarget
      content = text
    end
  else
    if resolveLang(text) then
      launcher.setResults(query, { hintRow("Type text to translate", `Target language: {text}`, "language") })
      return
    end
    target = defaultTarget
    content = text
  end

  if noctalia.string.trim(content) == "" then
    launcher.setResults(query, { hintRow("Type text to translate", `Target language: {target}`, "language") })
    return
  end

  local provider = noctalia.getConfig("provider") or "google"
  local fetchProvider = fetchGoogle
  if provider == "deepl" then
    fetchProvider = fetchDeepL
  end

  -- recoveredFrom: the rejected leading token when this call is the retry.
  -- aliasKey: cache slot of the rejected request, so an identical query skips it next time.
  local function requestTranslation(reqTarget, reqContent, recoveredFrom, aliasKey)
    local reqKey = `{provider}|{reqTarget}|{reqContent}`

    local cached = cache[reqKey]
    if cached then
      launcher.setResults(query, { resultRow(cached) })
      return
    end

    launcher.setResults(query, { hintRow("Translating…", reqContent, "loader") })

    if pending[reqKey] then
      return
    end

    pending[reqKey] = true

    fetchProvider(reqContent, reqTarget, function(translated, err, source)
      pending[reqKey] = nil

      if not translated then
        -- The target came from the leading token, and the provider rejected it: retry once
        -- with the whole input against the default target. Skipped when the retry would
        -- repeat the same request, and never chained.
        local retryable = err == INVALID_TARGET
          and recoveredFrom == nil
          and (reqTarget ~= defaultTarget or reqContent ~= text)
        if retryable then
          requestTranslation(defaultTarget, text, first, reqKey)
          return
        end
        launcher.setResults(query, { hintRow(err or "Translation error", reqContent, "alert-triangle") })
        return
      end

      local entry = { text = translated, target = reqTarget, source = source, recoveredFrom = recoveredFrom }
      cache[reqKey] = entry
      if aliasKey then
        cache[aliasKey] = entry
      end
      launcher.setResults(query, { resultRow(entry) })
    end)
  end

  requestTranslation(target, content)
end

function onActivate(id)
  if id ~= "" then
    noctalia.copyToClipboard(id, "text/plain")
    noctalia.notify("Translator", "Copied to clipboard")
  end
end
