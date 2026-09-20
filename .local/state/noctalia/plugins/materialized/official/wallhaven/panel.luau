--!nonstrict
-- Wallhaven wallpaper browser panel.
--
-- Browse search results with category and purity filters and pagination, download the full
-- image into the configured wallpaper directory, then apply it via noctalia.setWallpaper.

local API_BASE = "https://wallhaven.cc/api/v1"
local CACHE_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state")) .. "/noctalia/wallhaven/thumbs"
local PANEL_WIDTH = 920
local PANEL_PADDING = 28 -- Style::panelPadding * 2 on the host surface
local COLUMNS = 4
local COLUMN_GAP = 12
local THUMB_MAX_CONCURRENT = 6 -- host allows 8 async HTTP ops per plugin
local TILE_FRAME_RADIUS = 12
local TILE_BORDER_SFW = 1
local TILE_BORDER_RATED = 3
local TILE_BORDER_SELECTED = 3
local TILE_LABEL_GAP = 4
local TILE_LABEL_FONT = 11

local query = ""
local page = 1
local totalPages = 1
local wallpapers = {}
local loading = false
local errorMessage = ""
local selectedId = ""
local applying = false

local puritySfw = true
local puritySketchy = false
local purityNsfw = false

local categoryGeneral = true
local categoryAnime = true
local categoryPeople = true

local resolutionMode = "atleast" -- "atleast" or "exact"
local resolutionWidth = ""
local resolutionHeight = ""
local aspectRatioIndex = 0
local clearCounter = 0
local pageInputCounter = 0
local pageEditing = false

local thumbPaths = {} -- id -> cache file path
local thumbPending = {} -- id -> true while downloading
local thumbQueue = {} -- wallpapers waiting for a download slot
local thumbActive = 0

local render
local fetchWallpapers
local applyWallpaper

local sortOptions = { "relevance", "random", "date_added", "views", "favorites", "toplist", "hot" }
local sortIndex = 2
local sortOrder = "desc"

local function tr(key)
  return noctalia.tr(key)
end

local function sortLabelList()
  return {
    tr("sort.options.relevance"),
    tr("sort.options.random"),
    tr("sort.options.date_added"),
    tr("sort.options.views"),
    tr("sort.options.favorites"),
    tr("sort.options.toplist"),
    tr("sort.options.hot")
  }
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function apiKey()
  local key = noctalia.getConfig("api_key")
  if type(key) == "string" then
    return key
  end
  return ""
end

local function nsfwAllowed()
  return apiKey() ~= ""
end

local function normalizePurityFilters()
  if not nsfwAllowed() then
    purityNsfw = false
  end
end

local function downloadDir()
  local dir = noctalia.getConfig("download_dir")
  if type(dir) == "string" and dir ~= "" then
    return noctalia.expandPath(dir)
  end
  local wallpaperDir = noctalia.wallpaperDirectory()
  if type(wallpaperDir) == "string" and wallpaperDir ~= "" then
    return noctalia.expandPath(wallpaperDir)
  end
  return noctalia.expandPath("~/Pictures/Wallpapers")
end

local function buildPurity()
  local sfw = puritySfw and "1" or "0"
  local sketchy = puritySketchy and "1" or "0"
  local nsfw = purityNsfw and nsfwAllowed() and "1" or "0"
  local purity = sfw .. sketchy .. nsfw
  if purity == "000" then
    return "100"
  end
  return purity
end

local function buildCategories()
  local general = categoryGeneral and "1" or "0"
  local anime = categoryAnime and "1" or "0"
  local people = categoryPeople and "1" or "0"
  local categories = general .. anime .. people
  if categories == "000" then
    return "100"
  end
  return categories
end

local function sortValue()
  return sortOptions[sortIndex + 1] or "date_added"
end

-- Wallhaven returns an empty first page for relevance when no search query is set.
local function relevanceWithoutQuery()
  return sortValue() == "relevance" and noctalia.string.trim(query) == ""
end

local function apiPage()
  if relevanceWithoutQuery() then
    return page + 1
  end
  return page
end

local function normalizeTotalPages(lastPage)
  if relevanceWithoutQuery() then
    return math.max(1, lastPage - 1)
  end
  return lastPage
end

local function aspectRatioOptions()
  return {
    "",
    "wide",
    "portrait",
    "16x9",
    "16x10",
    "21x9",
    "32x9",
    "48x9",
    "9x16",
    "10x16",
    "9x18",
    "1x1",
    "3x2",
    "4x3",
    "5x4",
  }
end

local function aspectRatioLabelList()
  return {
    tr("ratio_any"),
    tr("ratio_wide"),
    tr("ratio_portrait"),
    "16:9",
    "16:10",
    "21:9",
    "32:9",
    "48:9",
    "9:16",
    "10:16",
    "9:18",
    "1:1",
    "3:2",
    "4:3",
    "5:4",
  }
end

local function aspectRatioParamValue()
  local ratios = aspectRatioOptions()
  local ratio = ratios[aspectRatioIndex + 1] or ""
  if ratio == "" then return nil end
  if ratio == "wide" then return "landscape" end
  if ratio == "portrait" then return "portrait" end
  return ratio
end

local function resolutionModeOptions()
  return { "atleast", "exact" }
end

local function resolutionModeLabelList()
  return {
    tr("resolution_mode_atleast"),
    tr("resolution_mode_exact"),
  }
end

local function parsePositiveInt(s)
  local n = tonumber(s)
  if n == nil or n < 1 or math.floor(n) ~= n then
    return nil
  end
  return n
end

local function buildResolutionParam()
  local w = parsePositiveInt(resolutionWidth)
  local h = parsePositiveInt(resolutionHeight)
  if w ~= nil and h ~= nil then
    local resolution = tostring(w) .. "x" .. tostring(h)
    if resolutionMode == "atleast" then
      return "atleast", resolution
    else
      return "resolutions", resolution
    end
  end
  return nil, nil
end

local function filterChip(label, active, onClick, key, enabled)
  return ui.button({
    key = key,
    text = label,
    variant = if active then "primary" else "outline",
    onClick = onClick,
    enabled = if enabled == nil then true else enabled,
  })
end

local function filterGroup(title, content, flexGrow)
  return ui.row({ gap = 6, align = "center", flexGrow = flexGrow }, {
    ui.label({
      text = title,
      fontSize = 12,
      color = "on_surface_variant",
    }),
    content,
  })
end

local function filtersPanel()
  return ui.column({ gap = 12, align = "stretch" }, {
    ui.row({ gap = 16, align = "center" }, {
      filterGroup(tr("filter_categories"), ui.row({ gap = 6, align = "center" }, {
        filterChip(tr("category_general"), categoryGeneral, "onCategoryGeneral", "filter_cat_general"),
        filterChip(tr("category_anime"), categoryAnime, "onCategoryAnime", "filter_cat_anime"),
        filterChip(tr("category_people"), categoryPeople, "onCategoryPeople", "filter_cat_people"),
      })),
      filterGroup(tr("filter_purity"), ui.row({ gap = 6, align = "center" }, {
        filterChip(tr("purity_sfw"), puritySfw, "onPuritySfw", "filter_purity_sfw"),
        filterChip(tr("purity_sketchy"), puritySketchy, "onPuritySketchy", "filter_purity_sketchy"),
        filterChip(tr("purity_nsfw"), purityNsfw, "onPurityNsfw", "filter_purity_nsfw", nsfwAllowed()),
      })),
      filterGroup(tr("filter_sort"), ui.row({ gap = 4, align = "center", flexGrow = 1 }, {
        ui.select({
          key = "sort",
          options = sortLabelList(),
          selectedIndex = sortIndex,
          onChange = "onSort",
          flexGrow = 1,
        }),
        ui.button({
          key = "sort_order",
          glyph = if sortOrder == "desc" then "arrow-down" else "arrow-up",
					tooltip = if sortOrder == "desc" then tr("sort_desc") else tr("sort_asc"),
          variant = "outline",
          onClick = "onToggleSortOrder",
        }),
      }), 1),
    }),
    ui.row({ gap = 12, align = "center" }, {
      filterGroup(tr("filter_aspect_ratio"), ui.row({ flexGrow = 0 }, {
        ui.select({
          key = "aspect_ratio",
          options = aspectRatioLabelList(),
          selectedIndex = aspectRatioIndex,
          onChange = "onAspectRatioChange",
          width = 260,
        })
      })),
      filterGroup(tr("filter_resolution"), ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
        ui.select({
          key = "resolution_mode",
          options = resolutionModeLabelList(),
          selectedIndex = if resolutionMode == "exact" then 1 else 0,
          onChange = "onResolutionModeChange",
          width = 180,
        }),
        ui.input({
          key = `resolution_width_{clearCounter}`,
          placeholder = tr("resolution_width_placeholder"),
          value = resolutionWidth,
          onChange = "onResolutionWidthChange",
          onSubmit = "onResolutionWidthSubmit",
          flexGrow = 1,
        }),
        ui.label({
          text = "×",
          fontSize = 14,
          color = "on_surface_variant",
        }),
        ui.input({
          key = `resolution_height_{clearCounter}`,
          placeholder = tr("resolution_height_placeholder"),
          value = resolutionHeight,
          onChange = "onResolutionHeightChange",
          onSubmit = "onResolutionHeightSubmit",
          flexGrow = 1,
        }),
      }), 1),
      ui.button({
        key = "clear_resolution",
        text = tr("clear_resolution"),
        variant = "destructive",
        onClick = "onClearResolution",
      }),
    }),
  })
end

local function httpHeaders()
  local headers = { "Accept: application/json" }
  local key = apiKey()
  if key ~= "" then
    table.insert(headers, "X-API-Key: " .. key)
  end
  return headers
end

local function ensureCacheDir(done)
  noctalia.runAsync(`mkdir -p {shellQuote(CACHE_DIR)}`, done)
end

local function thumbCachePath(id)
  return `{CACHE_DIR}/{id}.jpg`
end

local function columnWidth()
  local gridWidth = PANEL_WIDTH - PANEL_PADDING
  return math.floor((gridWidth - COLUMN_GAP * (COLUMNS - 1)) / COLUMNS)
end

local function tileThumbSize()
  local width = columnWidth()
  local height = math.floor(width * 9 / 16)
  return width, height
end

local function pumpThumbQueue()
  while thumbActive < THUMB_MAX_CONCURRENT and #thumbQueue > 0 do
    local wallpaper = table.remove(thumbQueue, 1)
    local id = wallpaper.id
    if thumbPaths[id] == nil and not thumbPending[id] then
      local thumbUrl = wallpaper.thumbs and wallpaper.thumbs.large
      if type(thumbUrl) == "string" and thumbUrl ~= "" then
        thumbPending[id] = true
        thumbActive += 1
        local dest = thumbCachePath(id)
        local started = noctalia.download(thumbUrl, dest, function(ok)
          thumbActive -= 1
          thumbPending[id] = nil
          if ok then
            thumbPaths[id] = dest
            render()
          end
          pumpThumbQueue()
        end)
        if not started then
          thumbActive -= 1
          thumbPending[id] = nil
          table.insert(thumbQueue, 1, wallpaper)
          break
        end
      end
    end
  end
end

local function queueThumbDownload(wallpaper)
  local id = wallpaper.id
  if thumbPaths[id] ~= nil or thumbPending[id] then
    return
  end
  local thumbUrl = wallpaper.thumbs and wallpaper.thumbs.large
  if type(thumbUrl) ~= "string" or thumbUrl == "" then
    return
  end
  table.insert(thumbQueue, wallpaper)
  pumpThumbQueue()
end

local function pickWallpaper(id)
  selectedId = id
  applyWallpaper(id)
end

local function fileExtension(wallpaper)
  if wallpaper.file_type == "image/png" then
    return ".png"
  end
  return ".jpg"
end

local function findWallpaper(id)
  for _, wallpaper in wallpapers do
    if wallpaper.id == id then
      return wallpaper
    end
  end
  return nil
end

applyWallpaper = function(id)
  if applying then
    return
  end
  local wallpaper = findWallpaper(id)
  if wallpaper == nil then
    return
  end
  local imageUrl = wallpaper.path
  if type(imageUrl) ~= "string" or imageUrl == "" then
    noctalia.notifyError(tr("title"), tr("download_failed"))
    return
  end

  applying = true
  render()

  local destDir = downloadDir()
  local dest = `{destDir}/wallhaven-{id}{fileExtension(wallpaper)}`
  noctalia.runAsync(`mkdir -p {shellQuote(destDir)}`, function(mkdirRes)
    if mkdirRes == nil or mkdirRes.exitCode ~= 0 then
      applying = false
      noctalia.notifyError(tr("title"), tr("download_failed"))
      render()
      return
    end

    noctalia.download(imageUrl, dest, function(downloadOk)
      if not downloadOk then
        applying = false
        noctalia.notifyError(tr("title"), tr("download_failed"))
        render()
        return
      end

      noctalia.setWallpaper(dest)
      applying = false
      noctalia.notify(tr("title"), tr("applied"))
      render()
    end)
  end)
end

local function parseSearchResponse(body)
  local decoded = noctalia.json.decode(body)
  if type(decoded) ~= "table" then
    return nil, tr("error")
  end
  if type(decoded.data) ~= "table" then
    local err = decoded.error or tr("error")
    return nil, tostring(err)
  end
  local meta = decoded.meta
  local lastPage = 1
  if type(meta) == "table" and type(meta.last_page) == "number" then
    lastPage = math.max(1, math.floor(meta.last_page))
  end
  return decoded.data, nil, lastPage
end

fetchWallpapers = function()
  if loading then
    return
  end
  loading = true
  errorMessage = ""
  render()

  local params = {
    `categories={buildCategories()}`,
    `purity={buildPurity()}`,
    `page={apiPage()}`,
    `sorting={sortValue()}`,
    `order={sortOrder}`,
  }

  local trimmed = noctalia.string.trim(query)
  if trimmed ~= "" then
    table.insert(params, `q={noctalia.string.urlEncode(trimmed)}`)
  end

  local resolutionParamName, resolutionValue = buildResolutionParam()
  if resolutionParamName ~= nil and resolutionValue ~= nil then
    table.insert(params, `{resolutionParamName}={resolutionValue}`)
  end

  local aspectRatio = aspectRatioParamValue()
  if aspectRatio ~= nil then
    table.insert(params, `ratios={aspectRatio}`)
  end

  local url = API_BASE .. "/search?" .. table.concat(params, "&")

  noctalia.http({ url = url, headers = httpHeaders() }, function(res)
    loading = false
    if not res.ok then
      errorMessage = tr("error")
      wallpapers = {}
      render()
      return
    end

    local data, err, lastPage = parseSearchResponse(res.body)
    if data == nil then
      errorMessage = err or tr("error")
      wallpapers = {}
      render()
      return
    end

    local filteredWallpapers = {}
    local options = aspectRatioOptions()
    local selectedRatio = options[aspectRatioIndex + 1] or ""

    for _, wallpaper in ipairs(data) do
      local include = true

      -- Client-side aspect ratio check since API's ratio filter is often inaccurate
      if selectedRatio ~= "" then
        local res = wallpaper.resolution
        if type(res) == "string" then
          local w, h = res:match("(%d+)x(%d+)")
          if w and h then
            w, h = tonumber(w), tonumber(h)
            local ratio = w / h
            local isWide = ratio > 1
            local isPortrait = ratio < 1

            if selectedRatio == "wide" and not isWide then
              include = false
            elseif selectedRatio == "portrait" and not isPortrait then
              include = false
            elseif selectedRatio:find("x") then
              local rw, rh = selectedRatio:match("(%d+)x(%d+)")
              if rw and rh then
                local targetRatio = tonumber(rw) / tonumber(rh)
                if math.abs(ratio - targetRatio) > 0.05 then
                  include = false
                end
              end
            end
          end
        end
      end

      if include then
        table.insert(filteredWallpapers, wallpaper)
      end
    end

    wallpapers = filteredWallpapers
    totalPages = normalizeTotalPages(lastPage)
    if page > totalPages then
      page = totalPages
    end
    render()
    ensureCacheDir(function()
      thumbQueue = {}
      for _, wallpaper in ipairs(wallpapers) do
        queueThumbDownload(wallpaper)
      end
    end)
  end)
end

local function persistAndRefetch()
  page = 1
  fetchWallpapers()
end

local function tileBorder(wallpaper, selected)
  if selected then
    return "primary", TILE_BORDER_SELECTED
  end
  local purity = wallpaper.purity
  if purity == "nsfw" then
    return "error", TILE_BORDER_RATED
  end
  if purity == "sketchy" then
    return "tertiary", TILE_BORDER_RATED
  end
  return "outline", TILE_BORDER_SFW
end

local function wallpaperPreview(wallpaper, frameWidth, frameHeight, borderColor, borderWidth)
  local id = wallpaper.id
  local thumb = thumbPaths[id]
  local onClick = function()
    pickWallpaper(id)
  end
  if thumb ~= nil then
    return ui.image({
      width = frameWidth,
      height = frameHeight,
      path = thumb,
      fit = "cover",
      radius = TILE_FRAME_RADIUS,
      border = borderColor,
      borderWidth = borderWidth,
      onClick = onClick,
    })
  end
  return ui.box({
    width = frameWidth,
    height = frameHeight,
    fill = "surface_variant",
    radius = TILE_FRAME_RADIUS,
    border = borderColor,
    borderWidth = borderWidth,
    onClick = onClick,
  })
end

local function wallpaperTile(wallpaper)
  local id = wallpaper.id
  local resolution = wallpaper.resolution or id
  local selected = selectedId == id
  local borderColor, borderWidth = tileBorder(wallpaper, selected)
  local frameWidth, frameHeight = tileThumbSize()
  return ui.column({
    gap = TILE_LABEL_GAP,
    key = id,
    flexGrow = 1,
    align = "center",
  }, {
    wallpaperPreview(wallpaper, frameWidth, frameHeight, borderColor, borderWidth),
    ui.label({
      text = resolution,
      fontSize = TILE_LABEL_FONT,
      color = "on_surface_variant",
      maxLines = 1,
      maxWidth = frameWidth,
      textAlign = "center",
    }),
  })
end

local function wallpaperGrid()
  if loading then
    return ui.label({ text = tr("loading"), color = "on_surface_variant" })
  end
  if errorMessage ~= "" then
    return ui.label({ text = errorMessage, color = "error" })
  end
  if #wallpapers == 0 then
    return ui.label({ text = tr("empty"), color = "on_surface_variant" })
  end

  local rows = {}
  local row = {}
  for index, wallpaper in ipairs(wallpapers) do
    table.insert(row, wallpaperTile(wallpaper))
    if #row == COLUMNS or index == #wallpapers then
      table.insert(rows, ui.row({ gap = COLUMN_GAP, align = "stretch" }, row))
      row = {}
    end
  end
  return ui.column({ gap = 12, align = "stretch" }, rows)
end

render = function()
  normalizePurityFilters()
  local pageLabel = if applying then tr("applying") else `Page {page}`
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),

    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "search",
        placeholder = tr("search_placeholder"),
        value = query,
        flexGrow = 1,
        onChange = "onSearchChange",
        onSubmit = "onSearchSubmit",
      }),
      ui.button({ text = tr("search"), variant = "primary", onClick = "onSearchClicked", enabled = not loading }),
    }),

    filtersPanel(),

    ui.scroll({ flexGrow = 1, gap = 12 }, {
      wallpaperGrid(),
    }),

    ui.row({ align = "center", justify = "center" }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.button({
          key = "prev_page",
          glyph = "chevron-left",
          variant = "ghost",
          onClick = "onPrevPage",
          enabled = not loading and page > 1,
        }),
        (if pageEditing then
          ui.input({
            key = `page_jump_{pageInputCounter}`,
            placeholder = tostring(page),
            width = 72,
            focus = true,
            onSubmit = "onPageEditSubmit",
          })
        else
          ui.button({
            key = "page_label",
            text = pageLabel,
            variant = "ghost",
            tooltip = tr("page_jump_tooltip"),
            onClick = "onPageLabelClicked",
            enabled = not loading and not applying,
          })),
        ui.label({ text = if applying then "" else `/ {totalPages}`, color = "on_surface_variant" }),
        ui.button({
          key = "next_page",
          glyph = "chevron-right",
          variant = "ghost",
          onClick = "onNextPage",
          enabled = not loading and page < totalPages,
        }),
      }),
    }),
  }))
end

function onOpen(_context)
  normalizePurityFilters()
  fetchWallpapers()
end

function onSearchChange(value)
  query = value
end

function onSearchSubmit(value)
  query = value
  page = 1
  fetchWallpapers()
end

function onSearchClicked()
  page = 1
  fetchWallpapers()
end

function onPuritySfw()
  if puritySfw and not puritySketchy and not purityNsfw then
    return
  end
  puritySfw = not puritySfw
  persistAndRefetch()
end

function onCategoryGeneral()
  if categoryGeneral and not categoryAnime and not categoryPeople then
    return
  end
  categoryGeneral = not categoryGeneral
  persistAndRefetch()
end

function onCategoryAnime()
  if categoryAnime and not categoryGeneral and not categoryPeople then
    return
  end
  categoryAnime = not categoryAnime
  persistAndRefetch()
end

function onCategoryPeople()
  if categoryPeople and not categoryGeneral and not categoryAnime then
    return
  end
  categoryPeople = not categoryPeople
  persistAndRefetch()
end

function onPuritySketchy()
  if puritySketchy and not puritySfw and not purityNsfw then
    return
  end
  puritySketchy = not puritySketchy
  persistAndRefetch()
end

function onPurityNsfw()
  if not nsfwAllowed() then
    return
  end
  if purityNsfw and not puritySfw and not puritySketchy then
    return
  end
  purityNsfw = not purityNsfw
  persistAndRefetch()
end

function onSort(index, _text)
  sortIndex = tonumber(index) or 0
  persistAndRefetch()
end

function onToggleSortOrder()
  sortOrder = if sortOrder == "desc" then "asc" else "desc"
  persistAndRefetch()
end

function onResolutionModeChange(index, _text)
  local modes = resolutionModeOptions()
  resolutionMode = modes[(tonumber(index) or 0) + 1] or "atleast"
  persistAndRefetch()
end

function onResolutionWidthChange(value)
  resolutionWidth = noctalia.string.trim(value)
end

function onResolutionHeightChange(value)
  resolutionHeight = noctalia.string.trim(value)
end

function handleResolutionSubmit(value, isWidth)
  local trimmedValue = noctalia.string.trim(value)
  if isWidth then
    resolutionWidth = trimmedValue
  else
    resolutionHeight = trimmedValue
  end
  page = 1
  fetchWallpapers()
end

function onResolutionWidthSubmit(value)
  handleResolutionSubmit(value, true)
end

function onResolutionHeightSubmit(value)
  handleResolutionSubmit(value, false)
end

function onAspectRatioChange(index, _text)
  aspectRatioIndex = tonumber(index) or 0
  persistAndRefetch()
end

function onClearResolution()
  if resolutionMode == "atleast" and resolutionWidth == "" and resolutionHeight == "" then
    return
  end
  resolutionMode = "atleast"
  resolutionWidth = ""
  resolutionHeight = ""
  clearCounter += 1
  persistAndRefetch()
end

function onPrevPage()
  if page > 1 then
    page -= 1
    fetchWallpapers()
  end
end

function onNextPage()
  if page < totalPages then
    page += 1
    fetchWallpapers()
  end
end

function onPageLabelClicked()
  pageEditing = true
  pageInputCounter += 1
  render()
end

function onPageEditSubmit(value)
  pageEditing = false
  pageInputCounter += 1
  if not loading then
    local target = parsePositiveInt(noctalia.string.trim(value))
    if target ~= nil then
      if target > totalPages then
        target = totalPages
      end
      if target ~= page then
        page = target
        fetchWallpapers()
        return
      end
    end
  end
  render()
end

function onCloseClicked()
  panel.close()
end
