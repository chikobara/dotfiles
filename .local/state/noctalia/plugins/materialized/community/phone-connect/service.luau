-- entries/service.luau
-- Phone Connect - KDE Connect backend service (the single owner of DBus logic).
--
-- Architecture: Noctalia plugin scripts run in an isolated sandbox with NO
-- `require`/`dofile`/`loadfile`. So all KDE Connect interaction lives here and
-- is published to UI entries (widget/tile/panel) as plain data via
-- `noctalia.state`. A future Valent backend would replace this file's internals
-- only; the state contract below stays unchanged so UI entries need no edits.
--

-- Local translation: reads from pc.trTable (published by service) so users
-- can switch language at runtime, unlike noctalia.tr() which follows system locale.
local function t(key)
	local table = noctalia.state.get("pc.trTable") or {}
	return table[key] or key
end

-- ── State contract (read by UI entries) ──────────────────────────────────────
--   noctalia.state "pc.backend"   : { available=bool, name="KDE Connect"|"None",
--                                     announcedName="", selfId="" }
--   noctalia.state "pc.devices"   : { [id] = { id, name, type, isReachable,
--                                     isPaired, pairState, verificationKey,
--                                     supportedPlugins={}, batteryCharge,
--                                     batteryCharging, networkType,
--                                     networkStrength } }
--   noctalia.state "pc.order"     : { id, ... }  device id display order
--   noctalia.state "pc.selected"  : string  currently selected device id
--   noctalia.state "pc.cmd"       : { op=string, device=string, [args...] }
--                                   written by UI entries; service executes
--                                   and clears. ops: ring|ping|clipboard|
--                                   share_text|share_url|share_file|pair|
--                                   accept|reject|unpair|browse|select|refresh
--   noctalia.state "pc.event"     : { type=string, ... } transient UI events
--                                   (pairing request, file received) the panel
--                                   may surface; service sets, panel consumes.
--
-- ── KDE Connect DBus surface (verified via gdbus introspect) ─────────────────
--   service   : org.kde.kdeconnect
--   daemon    : /modules/kdeconnect  iface org.kde.kdeconnect.daemon
--               methods: devices(b,b)->as, selfId()->s, announcedName()->s
--               signals: deviceAdded(s), deviceRemoved(s),
--                        deviceVisibilityChanged(s,b), deviceListChanged(),
--                        pairingRequestsChanged()
--   device    : /modules/kdeconnect/devices/<id>  iface org.kde.kdeconnect.device
--               props: type,name,isReachable,isPaired,pairState,verificationKey,
--                      supportedPlugins,statusIconName
--               methods: requestPairing,acceptPairing,cancelPairing,unpair
--               signals: reachableChanged(b), pairStateChanged(i),
--                        nameChanged(s), typeChanged(s), statusIconNameChanged
--   battery   : <dev>/battery  props: charge(i),isCharging(b); sig: refreshed(b,i)
--   conn      : <dev>/connectivity_report props: cellularNetworkType(s),
--               cellularNetworkStrength(i); sig: refreshed(s,i)
--   share     : <dev>/share  methods: shareUrl(s),shareText(s); sig: shareReceived(s)
--   ping      : <dev>/ping  methods: sendPing(), sendPing(s)
--   sftp      : <dev>/sftp  methods: startBrowsing()->b, mount(), mountAndWait()->b,
--               mountPoint()->s, isMounted()->b

-- ── Shell helpers (duplicated per the sandbox constraint; keep tiny) ─────────
local function shellQuote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local SVC = "org.kde.kdeconnect"
local DAEMON_PATH = "/modules/kdeconnect"
local DAEMON_IFACE = "org.kde.kdeconnect.daemon"
local DEV_IFACE = "org.kde.kdeconnect.device"
local PROPS_IFACE = "org.freedesktop.DBus.Properties"
local BATTERY_IFACE = "org.kde.kdeconnect.device.battery"
local CONN_IFACE = "org.kde.kdeconnect.device.connectivity_report"
local MPRIS_IFACE = "org.kde.kdeconnect.device.mprisremote"

-- Build a gdbus call that returns every property of an interface at once
-- (a{sv} dict). One subprocess per interface instead of one per property.
local function gdbusGetAll(devPath, iface)
	return table.concat({
		"gdbus call --session",
		"--dest", shellQuote(SVC),
		"--object-path", shellQuote(devPath),
		"--method", shellQuote(PROPS_IFACE .. ".GetAll"),
		shellQuote(iface),
	}, " ")
end

-- Parse a single gdbus return value. gdbus prints results as a tuple:
--   variant string : (<'24122RKC7C'>,)
--   variant bool   : (<true>,)
--   variant int    : (<-1>,)
--   bare bool      : (true,)            (non-variant, e.g. NameHasOwner)
-- Validated against real kdeconnect gdbus output.
local function parseGdbusValue(raw)
	if raw == nil then return nil end
	raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
	-- variant form: (<value>,)
	local inner = raw:match("^%(<(.+)>%,?%)?$")
		if inner then
			if inner == "true" then return true end
			if inner == "false" then return false end
			local n = tonumber(inner)
			if n then return n end
			local s = inner:match("^'(.*)'$") or inner:match('^"(.*)"$')
			if s then return s end
			return inner
		end
		-- bare form: (true,) (false,) (-1,)  -> strip tuple parens and trailing comma
		local bare = raw:match("^%((.-)%,?%)$")
		if bare == nil then bare = raw end
		bare = bare:gsub("%s+$", ""):gsub(",%s*$", "")
		if bare == "true" then return true end
		if bare == "false" then return false end
		local n = tonumber(bare)
		if n then return n end
		local s = bare:match("^'(.*)'$") or bare:match('^"(.*)"$')
		if s then return s end
		return bare
end

-- Parse gdbus array-of-strings tuple like: (['id1', 'id2'],)
local function parseGdbusStringArray(raw)
	if raw == nil then return {} end
	local arr = raw:match("%[(.-)%]")
	if arr == nil then return {} end
	local out = {}
	for item in arr:gmatch("'([^']*)'") do
		table.insert(out, item)
	end
	return out
end

-- Parse one value from inside a `<>` variant of a GetAll dict:
--   true/false | number | 'string' | "string" | ['a','b'] array
local function parseVariantInner(v)
	if v == "true" then return true end
	if v == "false" then return false end
	local n = tonumber(v)
	if n then return n end
	local s = v:match("^'(.*)'$") or v:match('^"(.*)"$')
	if s ~= nil then return s end
	if v:sub(1, 1) == "[" then
		local arr = {}
		for item in v:gmatch("'([^']*)'") do table.insert(arr, item) end
		for item in v:gmatch('"([^"]*)"') do table.insert(arr, item) end
		return arr
	end
	return v
end

-- Parse a gdbus Properties.GetAll result like:
--   ({'charge': <91>, 'isCharging': <true>},)
-- into a table keyed by property name. %b<> keeps multi-token values
-- (arrays) intact; keys are always single-quoted.
local function parseGdbusVariantDict(raw)
	local out = {}
	if raw == nil then return out end
	for key, vraw in raw:gmatch("'([^']+)'%s*:%s*(%b<>)") do
		out[key] = parseVariantInner(vraw:sub(2, -2))
	end
	return out
end

-- ── Device data model ────────────────────────────────────────────────────────
-- In-memory device table keyed by id (mirrors original PhoneConnectService.devices).
local devices= {}
local deviceOrder= {}
-- forward-declared: fetchMpris re-evaluates the poll interval; the definition
-- lives in the Lifecycle section below.
local intervalMs

local function snapshotDevices()
	local snap = {}
	for _, id in ipairs(deviceOrder) do
		local d = devices[id]
		if d then snap[id] = d end
	end
	return snap
end

local function publishDevices()
	noctalia.state.set("pc.devices", snapshotDevices())
	noctalia.state.set("pc.order", deviceOrder)
end

-- ── Persistent state (selected device) ──────────────────────────────────────
-- noctalia.state is in-memory only and cleared when the plugin stops, so the
-- last selected device is persisted to pluginDataDir()/state.json. Per-device
-- image/type/recent-images maps will live here too once their UI lands.
local DATA_FILE -- resolved lazily; pluginDataDir() may be nil very early

local function dataPath()
	if DATA_FILE then return DATA_FILE end
	local dir = noctalia.pluginDataDir()
	if not dir then return nil end
	DATA_FILE = dir .. "/state.json"
	return DATA_FILE
end

local function loadData()
	local p = dataPath()
	if not p then return {} end
	local raw = noctalia.readFile(p)
	if not raw then return {} end
	local ok, data = pcall(noctalia.json.decode, raw)
	if ok and type(data) == "table" then return data end
	return {}
end

local function saveData(data)
	local p = dataPath()
	if not p then return end
	local ok, encoded = pcall(noctalia.json.encode, data)
	if ok and encoded then noctalia.writeFile(p, encoded) end
end

	local function persistSelected(dev)
		local data = loadData()
		data.selected = dev
		saveData(data)
	end

	local function persistImageMap(map)
		local data = loadData()
		data.imageMap = map
		saveData(data)
	end

	local function persistAliasMap(map)
		local data = loadData()
		data.aliasMap = map
		saveData(data)
	end

	-- restore last selection and image map at load
	do
		local saved = loadData()
		if saved.selected and type(saved.selected) == "string" and saved.selected ~= "" then
			noctalia.state.set("pc.selected", saved.selected)
		end
		noctalia.state.set("pc.imageMap", saved.imageMap or {})
		noctalia.state.set("pc.aliasMap", saved.aliasMap or {})
	end

	-- ── Translation loader ──────────────────────────────────────────────────
	-- noctalia.tr() follows system locale and can't be switched at runtime,
	-- so we load both translations ourselves and publish the active one
	-- to state. Each UI entry reads pc.trTable for a local t(key) wrapper.
	local function flattenTable(t, prefix)
		local out = {}
		for k, v in pairs(t) do
			local full = prefix and (prefix .. "." .. k) or k
			if type(v) == "table" then
				local sub = flattenTable(v, full)
				for sk, sv in pairs(sub) do out[sk] = sv end
			else
				out[full] = v
			end
		end
		return out
	end

	local function loadTranslations(lang)
		local dir = noctalia.pluginDir()
		if not dir then return {} end
		local raw = noctalia.readFile(dir .. "/translations/" .. lang .. ".json")
		if not raw then return {} end
		local ok, data = pcall(noctalia.json.decode, raw)
		if ok and type(data) == "table" then return flattenTable(data) end
		return {}
	end

	local function publishTranslations(lang)
		local table = loadTranslations(lang or "en")
		noctalia.state.set("pc.trTable", table)
		noctalia.state.set("pc.lang", lang)
	end

	-- initial load
	publishTranslations(noctalia.getConfig("language") or "en")

-- ── Backend availability ─────────────────────────────────────────────────────
local function detectBackend()
	local hasGdbus = noctalia.commandExists("gdbus")
	local hasCli = noctalia.commandExists("kdeconnect-cli")
	local available = noctalia.commandExists("kdeconnectd") or hasGdbus or hasCli
	-- A more precise check: is the DBus name actually owned? Use gdbus if present.
	if hasGdbus then
		noctalia.runAsync(
			"gdbus call --session --dest org.freedesktop.DBus "
				.. "--object-path /org/freedesktop/DBus "
				.. "--method org.freedesktop.DBus.NameHasOwner "
				.. shellQuote(SVC),
			function(res)
				local owned = false
				if res and not res.error then
					owned = parseGdbusValue(res.stdout or "") == true
				end
				noctalia.state.set("pc.backend", {
					available = owned,
					name = owned and "KDE Connect" or "None",
					announcedName = "",
					selfId = "",
					hasGdbus = hasGdbus,
					hasCli = hasCli,
				})
			end
		)
	else
		noctalia.state.set("pc.backend", {
			available = available,
			name = available and "KDE Connect" or "None",
			announcedName = "",
			selfId = "",
			hasGdbus = false,
			hasCli = hasCli,
		})
	end
end

-- ── Fetch device properties via gdbus ────────────────────────────────────────
-- Fetches the device interface properties in one GetAll call and merges them
-- into the in-memory record: one subprocess instead of one per field.
local function fetchDeviceProps(id, cb)
	local devPath = DAEMON_PATH .. "/devices/" .. id
	noctalia.runAsync(gdbusGetAll(devPath, DEV_IFACE), function(res)
		local d = devices[id] or { id = id }
		if res and not res.error then
			local p = parseGdbusVariantDict(res.stdout or "")
			d.name = p.name
			d.type = p.type
			d.isReachable = p.isReachable
			d.isPaired = p.isPaired
			d.pairState = p.pairState
			d.verificationKey = p.verificationKey
			d.supportedPlugins = p.supportedPlugins
			-- split addresses into IPv4 / IPv6 for the info footer
			local v4, v6
			if type(p.reachableAddresses) == "table" then
				for _, a in ipairs(p.reachableAddresses) do
					if type(a) == "string" then
						if not v4 and a:find(".", 1, true) then v4 = a end
						if not v6 and a:find(":", 1, true) then v6 = a end
					end
				end
			end
			d.ipv4 = v4
			d.ipv6 = v6
		else
			-- The property fetch failed: the device is offline or its DBus
			-- object is gone. Fall back to unreachable so the UI shows
			-- "Offline" instead of a stale "Connected" from the last
			-- successful fetch (the old code kept the previous value).
			d.isReachable = false
		end
		devices[id] = d
		publishDevices()
		if cb then cb() end
	end)
end

-- Fetch MPRIS media fields for one device in one GetAll call. Resolves
-- localAlbumArtUrl -> mediaArtPath and publishes once. Shared by the poll
-- path and the real-time monitor.
local function fetchMpris(id, cb)
	local d = devices[id]
	if not d then
		if cb then cb() end
		return
	end
	local devPath = DAEMON_PATH .. "/devices/" .. id
	noctalia.runAsync(gdbusGetAll(devPath .. "/mprisremote", MPRIS_IFACE), function(res)
		local d2 = devices[id]
		if d2 and res and not res.error then
			local p = parseGdbusVariantDict(res.stdout or "")
			d2.mediaisPlaying = p.isPlaying
			d2.mediatitle = p.title
			d2.mediaartist = p.artist
			d2.mediaalbum = p.album
			d2.mediavolume = p.volume
			d2.medialocalAlbumArtUrl = p.localAlbumArtUrl
			d2.medialength = p.length
			d2.mediaposition = p.position
			d2.mediacanSeek = p.canSeek
			local art = d2.medialocalAlbumArtUrl
			if art and art ~= "" then
				if art:sub(1, 7) == "file://" then art = art:sub(8) end
				d2.mediaArtPath = art
			end
			devices[id] = d2
		end
		publishDevices()
		-- Re-evaluate the poll interval now that media state is fresh:
		-- without this, playback start/stop only switches the 1s fast poll
		-- on the next update() (up to 30s later), because intervalMs() runs
		-- before refreshDevices() in update().
		noctalia.setUpdateInterval(intervalMs())
		if cb then cb() end
	end)
end

-- Fetch battery + connectivity sub-interface properties (only if paired+reachable).
local function fetchDeviceExtras(id)
	local d = devices[id]
	if not d then return end
	if not (d.isPaired and d.isReachable) then return end
	local devPath = DAEMON_PATH .. "/devices/" .. id
	-- battery.charge / battery.isCharging in one GetAll
	noctalia.runAsync(gdbusGetAll(devPath .. "/battery", BATTERY_IFACE), function(res)
		if res and not res.error then
			local d2 = devices[id]
			if d2 then
				local p = parseGdbusVariantDict(res.stdout or "")
				d2.batteryCharge = p.charge
				d2.batteryCharging = p.isCharging
				devices[id] = d2
				publishDevices()
			end
		end
	end)
	-- connectivity in one GetAll
	noctalia.runAsync(gdbusGetAll(devPath .. "/connectivity_report", CONN_IFACE),
		function(res)
			if res and not res.error then
				local d2 = devices[id]
				if d2 then
					local p = parseGdbusVariantDict(res.stdout or "")
					d2.networkType = p.cellularNetworkType
					d2.networkStrength = p.cellularNetworkStrength
					devices[id] = d2
					publishDevices()
					-- if network still default, nudge the phone to report
					-- (but not more than once per 120s)
					if (type(d2.networkType) ~= "string" or d2.networkType == "")
						and d2.networkStrength == -1 then
						local now = os.time()
						local last = d2._netRefreshAt or 0
						if now - last > 120 then
							d2._netRefreshAt = now
							devices[id] = d2
							runCli("--refresh -d " .. shellQuote(id))
						end
					end
				end
			end
		end)
	-- mprisremote: media fields fetched in one GetAll via fetchMpris; it
		-- resolves album art and publishes once.
		fetchMpris(id)
end

-- ── Full device list refresh ─────────────────────────────────────────────────
local refreshing = false
local refreshLockedAt = 0  -- os.clock() when the lock was taken
-- forward-declared: refreshDevices calls ensureMonitors, defined below
local ensureMonitors
local function refreshDevices()
	if refreshing then
		-- Watchdog: if a refresh callback never fires (e.g. the gdbus child
		-- was reaped without a result), the lock would wedge and every later
		-- refresh would be swallowed. Release it after 3s so polling recovers.
		if os.clock() - refreshLockedAt > 3.0 then
			refreshing = false
			noctalia.log("[phone-connect] refresh lock stale; reset")
		else
			return
		end
	end
	refreshing = true
	refreshLockedAt = os.clock()
	noctalia.runAsync(
		"gdbus call --session --dest " .. SVC
			.. " --object-path " .. DAEMON_PATH
			.. " --method " .. DAEMON_IFACE .. ".devices false false",
		function(res)
			refreshing = false
			if not res or res.error then
				noctalia.log("[phone-connect] devices() failed: "
					.. (res and res.error or "nil"))
				return
			end
			local ids = parseGdbusStringArray(res.stdout or "")
			-- remove gone devices
			local seen = {}
			for _, id in ipairs(ids) do seen[id] = true end
			for i = #deviceOrder, 1, -1 do
				if not seen[deviceOrder[i]] then
					devices[deviceOrder[i]] = nil
					table.remove(deviceOrder, i)
				end
			end
			-- add new
			for _, id in ipairs(ids) do
				if not devices[id] then
					table.insert(deviceOrder, id)
					devices[id] = { id = id }
				end
			end
			-- fetch props for each (sequential via a chain)
			local idx = 1
			local function fetchNext()
				if idx > #deviceOrder then
					publishDevices()
					-- then extras for reachable paired devices
					for _, id2 in ipairs(deviceOrder) do
						fetchDeviceExtras(id2)
					end
					-- keep real-time daemon/media monitors in sync with the
					-- current device set
					ensureMonitors()
					return
				end
				local id = deviceOrder[idx]
				idx = idx + 1
				fetchDeviceProps(id, fetchNext)
			end
			fetchNext()
		end)
end

-- ── Real-time media sync via gdbus monitor ──────────────────────────────────
-- Polling (update()) covers state at a 1-30s cadence, but media title/position/
-- volume changes should reach the UI as soon as the phone reports them. Each
-- reachable paired device gets a `gdbus monitor` stream on its mprisremote
-- path; a PropertiesChanged line triggers a targeted fetchMpris(). A daemon-level
-- stream watches device add/remove/visibility and triggers refreshDevices().
-- The runtime terminates active streams when the script reloads or the plugin
-- stops, so we only track which devices already have a stream. If a stream
-- fails to start, ensureMonitors() simply retries on the next refresh — the
-- poll path keeps working either way, so this layer is best-effort.
local monitors = {}          -- [deviceId] = true when a stream is active
local daemonMonitorActive = false
local lastDaemonEventAt = 0  -- os.clock() of the last handled daemon signal
local lastMediaEventAt = {}  -- [deviceId] = os.clock() of last handled signal

ensureMonitors = function()
	-- daemon-level stream: device added/removed/visibility/list changes.
	if not daemonMonitorActive then
		local ok = noctalia.runStream(
			"gdbus monitor --session --dest " .. SVC
				.. " --object-path " .. shellQuote(DAEMON_PATH),
			function(line)
				if line == nil or line == "" then return end
				-- deviceListChanged is usually preceded by several per-device
				-- lines; debounce so one burst becomes one refresh.
				local now = os.clock()
				if now - lastDaemonEventAt > 0.5 then
					lastDaemonEventAt = now
					refreshDevices()
				end
			end)
		if ok then daemonMonitorActive = true end
	end
	-- per-device media streams. Only paired+reachable devices emit signals.
	for _, id in ipairs(deviceOrder) do
		local d = devices[id]
		if not monitors[id] and d and d.isPaired and d.isReachable then
			local ok = noctalia.runStream(
				"gdbus monitor --session --dest " .. SVC
					.. " --object-path " .. shellQuote(DAEMON_PATH .. "/devices/" .. id .. "/mprisremote"),
				function(line)
					if line == nil or line == "" then return end
					-- kdeconnectd emits lowercase "propertiesChanged"; match
					-- case-insensitively so both spellings are caught.
					if not line:lower():find("propertieschanged") then return end
					-- position ticks arrive frequently while playing; debounce
					-- so we don't spam fetchMpris (9 serialized gdbus calls).
					local now = os.clock()
					local last = lastMediaEventAt[id] or 0
					if now - last > 0.25 then
						lastMediaEventAt[id] = now
						fetchMpris(id)
					end
				end)
			if ok then monitors[id] = true end
		end
	end
	-- drop bookkeeping for devices that are gone
	for id in pairs(monitors) do
		if not devices[id] then monitors[id] = nil end
	end
end

-- ── Command execution (from UI entries via pc.cmd) ──────────────────────────
-- State refresh is poll-driven (update()) for reliability, plus a best-effort
-- `gdbus monitor` layer (ensureMonitors above) for real-time media updates.
-- Historically dbus-monitor captured zero kdeconnect-path signals, so the poll
-- path stays the source of truth and monitors are only an accelerator: state-
-- mutating commands below still trigger an immediate refreshDevices() on
-- completion for responsive UI without waiting for the next poll.

-- File-picker result polling. GUI pickers (zenity/kdialog) outlive the
-- runAsync call that spawns them (a detached `cmd &` shell), so the panel asks
-- us to watch a tmp file for the chosen path; we pick it up on update().
-- pendingPick.purpose decides what happens with the chosen path:
--   "image" -> set the device's avatar (pc.imageMap)
--   "share" -> send the file to the device via kdeconnect-cli --share
local pendingPick = nil   -- { device, path, started, purpose }
local function pollPendingPick()
	if not pendingPick then return end
	local raw = noctalia.readFile(pendingPick.path)
	if raw and raw ~= "" then
		local p = raw:gsub("[\r\n%s]+$", "")
		if p ~= "" then
			if pendingPick.purpose == "share" then
				noctalia.runAsync(
					"kdeconnect-cli --share " .. shellQuote(p)
						.. " -d " .. shellQuote(pendingPick.device),
					function(res)
						if res and res.error then
							noctalia.notifyError(t("error.share_failed"), res.error)
						end
					end)
				noctalia.notify(t("notify.file_shared"), p)
			else
				local map = noctalia.state.get("pc.imageMap") or {}
				map[pendingPick.device] = p
				noctalia.state.set("pc.imageMap", map)
				persistImageMap(map)
				noctalia.log("[phone-connect] picked image for " .. pendingPick.device .. ": " .. p)
			end
		end
		noctalia.removeFile(pendingPick.path)
		pendingPick = nil
	elseif os.time() - pendingPick.started > 120 then
		-- give up: user cancelled or the picker never wrote anything
		noctalia.removeFile(pendingPick.path)
		pendingPick = nil
	end
end

local function runCli(args, cb)
	noctalia.runAsync("kdeconnect-cli " .. args, function(res)
		if res and res.error then
			noctalia.notifyError(t("error.cli_failed"), res.error)
		end
		if cb then cb(res) end
	end)
end

local function gdbusDeviceMethod(id, method, cb)
	local path = DAEMON_PATH .. "/devices/" .. id
	noctalia.runAsync(
		"gdbus call --session --dest " .. SVC
			.. " --object-path " .. path
			.. " --method " .. DEV_IFACE .. "." .. method,
		function(res)
			if res and res.error then
				noctalia.log("[phone-connect] " .. method .. " failed: " .. res.error)
			end
			if cb then cb(res) end
		end)
end

-- Call a method on a device sub-interface (e.g. sftp, mprisremote, sms).
-- sub is the path suffix + interface suffix, e.g. "sftp" -> path /devices/<id>/sftp,
-- iface org.kde.kdeconnect.device.sftp. extraArgs is a shell-quoted arg string.
local function gdbusSubMethod(id, sub, method, extraArgs, cb)
	local path = DAEMON_PATH .. "/devices/" .. id .. "/" .. sub
	local iface = "org.kde.kdeconnect.device." .. sub
	local cmd = "gdbus call --session --dest " .. SVC
		.. " --object-path " .. shellQuote(path)
		.. " --method " .. shellQuote(iface .. "." .. method)
	if extraArgs and extraArgs ~= "" then cmd = cmd .. " " .. extraArgs end
	noctalia.runAsync(cmd, function(res)
		if res and res.error then
			noctalia.log("[phone-connect] " .. sub .. "." .. method .. " failed: " .. res.error)
		end
		if cb then cb(res) end
	end)
end

-- Call a sub-interface method that returns a single value; parse the result.
local function gdbusSubMethodValue(id, sub, method, cb)
	gdbusSubMethod(id, sub, method, "", function(res)
		if not res or res.error then cb(nil) return end
		cb(parseGdbusValue(res.stdout or ""))
	end)
end

local function handleCommand(cmd)
	if type(cmd) ~= "table" then return end
	local op = cmd.op
	local dev = cmd.device or ""
	-- helper: run a mutating op, then refresh so the UI updates immediately
	local function mutating(fn)
		fn(function() refreshDevices() end)
	end
	if op == "refresh" then
		refreshDevices()
	elseif op == "select" then
		noctalia.state.set("pc.selected", dev)
		persistSelected(dev)
	elseif op == "ring" then
		runCli("--ring -d " .. shellQuote(dev))
	elseif op == "ping" then
		local msg = cmd.message or ""
		if msg ~= "" then
			runCli("--ping-msg " .. shellQuote(msg) .. " -d " .. shellQuote(dev))
		else
			runCli("--ping -d " .. shellQuote(dev))
		end
	elseif op == "clipboard" then
		runCli("--send-clipboard -d " .. shellQuote(dev))
	elseif op == "share_text" then
		runCli("--share-text " .. shellQuote(cmd.text or "") .. " -d " .. shellQuote(dev))
	elseif op == "share_url" then
		runCli("--share " .. shellQuote(cmd.url or "") .. " -d " .. shellQuote(dev))
	elseif op == "share_file" then
		runCli("--share " .. shellQuote(cmd.path or "") .. " -d " .. shellQuote(dev))
	elseif op == "set_image" then
		local map = noctalia.state.get("pc.imageMap") or {}
		local path = cmd.path or ""
		if path == "" then map[dev] = nil else map[dev] = path end
		noctalia.state.set("pc.imageMap", map)
		persistImageMap(map)
	elseif op == "set_alias" then
		-- per-device alias; empty clears back to the device's real name
		local map = noctalia.state.get("pc.aliasMap") or {}
		local alias = cmd.alias or ""
		if alias == "" then map[dev] = nil else map[dev] = alias end
		noctalia.state.set("pc.aliasMap", map)
		persistAliasMap(map)
	elseif op == "pick_image" or op == "pick_share" then
		-- Open the GUI file picker detached (a `cmd &` shell returns instantly,
		-- so the picker survives runAsync's subprocess timeout) and write the
		-- chosen path to a tmp file that pollPendingPick() consumes on update().
		-- purpose: pick_image -> device avatar, pick_share -> send file to device.
		if pendingPick then
			noctalia.notifyError(t("error.pick_in_progress"))
		else
			local picker
			if noctalia.commandExists("kdialog") then
				picker = "kdialog --getopenfilename ~ ''"
			elseif noctalia.commandExists("zenity") then
				picker = "zenity --file-selection"
			else
				noctalia.notifyError(t("error.pick_failed"), "kdialog/zenity not found")
				return
			end
			local tmp = noctalia.pluginDataDir() .. "/pick-" .. tostring(dev) .. ".tmp"
			pendingPick = {
				device = dev,
				path = tmp,
				started = os.time(),
				purpose = (op == "pick_share") and "share" or "image",
			}
			-- write nothing yet; pollPendingPick keys off a non-empty file
			noctalia.removeFile(tmp)
			noctalia.runAsync(picker .. " > " .. shellQuote(tmp) .. " 2>/dev/null &")
		end
	elseif op == "pair" then
		mutating(function(cb) gdbusDeviceMethod(dev, "requestPairing", cb) end)
	elseif op == "accept" then
		mutating(function(cb) gdbusDeviceMethod(dev, "acceptPairing", cb) end)
	elseif op == "reject" then
		mutating(function(cb) gdbusDeviceMethod(dev, "cancelPairing", cb) end)
	elseif op == "unpair" then
		mutating(function(cb) gdbusDeviceMethod(dev, "unpair", cb) end)
	elseif op == "browse" then
		-- SFTP: ensure mounted, then open the phone's storage directory.
		local function tryOpen()
			gdbusSubMethodValue(dev, "sftp", "mountPoint", function(mp)
				if not mp or mp == "" then
					noctalia.notifyError(t("error.browse_failed"), "no mount point")
					return
				end
				-- getDirectories returns a{sv}, we need to parse it differently.
				-- Use a raw gdbus call and extract the first directory path.
				local path = DAEMON_PATH .. "/devices/" .. dev .. "/sftp"
				local cmd = "gdbus call --session --dest " .. SVC
					.. " --object-path " .. shellQuote(path)
					.. " --method org.kde.kdeconnect.device.sftp.getDirectories"
				noctalia.runAsync(cmd, function(res)
					local dirPath = mp
					if res and not res.error then
						-- output like: ({'/run/.../storage/emulated/0': <'Internal'>,},)
						-- extract the first path in single quotes
						local first = (res.stdout or ""):match("'([^']+)'")
						if first then dirPath = first end
					end
					noctalia.runAsync("xdg-open " .. shellQuote(dirPath))
					noctalia.notify(t("notify.opening_browser"), dirPath)
				end)
			end)
		end
		gdbusSubMethodValue(dev, "sftp", "isMounted", function(mounted)
			if mounted then
				tryOpen()
			else
				gdbusSubMethodValue(dev, "sftp", "mountAndWait", function(ok)
					if ok then
						tryOpen()
					else
						gdbusSubMethodValue(dev, "sftp", "getMountError", function(errMsg)
							noctalia.notifyError(t("error.browse_failed"),
								errMsg or "mount failed (sshfs installed?)")
						end)
					end
				end)
			end
		end)
	elseif op == "sms_send" then
		-- Send an SMS via kdeconnect-cli (handles address/message/attachment).
		local args = "--send-sms " .. shellQuote(cmd.text or "")
			.. " --destination " .. shellQuote(cmd.destination or "")
			.. " -d " .. shellQuote(dev)
		if cmd.attachment and cmd.attachment ~= "" then
			args = args .. " --attachment " .. shellQuote(cmd.attachment)
		end
		runCli(args, function(res)
			if res and not res.error then
				noctalia.notify(t("notify.sms_sent"), cmd.destination or "")
			end
		end)
	elseif op == "launch_sms_app" then
		gdbusSubMethod(dev, "sms", "launchApp", "", nil)
	elseif op == "media" then
		-- MPRIS control. action: Play|Pause|PlayPause|Next|Previous|Stop
		local action = cmd.action or "PlayPause"
		gdbusSubMethod(dev, "mprisremote", "sendAction",
			shellQuote(action), function()
				-- delay 600ms for phone to update MPRIS state
				noctalia.runAsync("sleep 0.6", function()
					refreshDevices()
				end)
			end)
	elseif op == "media_seek" then
		-- set position property directly (seek method is unreliable)
		local offset = tonumber(cmd.offset) or 0
		local path = DAEMON_PATH .. "/devices/" .. dev .. "/mprisremote"
		noctalia.runAsync(
			"gdbus call --session --dest " .. SVC
				.. " --object-path " .. shellQuote(path)
				.. " --method " .. shellQuote(PROPS_IFACE .. ".Set")
				.. " " .. MPRIS_IFACE .. " position "
				.. shellQuote("<int32 " .. tostring(offset) .. ">"),
			function()
				noctalia.runAsync("sleep 0.3", function() refreshDevices() end)
			end)
	elseif op == "media_set_volume" then
		-- volume is a readwrite property; use gdbus Set.
		local vol = tonumber(cmd.volume) or 0
		local path = DAEMON_PATH .. "/devices/" .. dev .. "/mprisremote"
		noctalia.runAsync(
			"gdbus call --session --dest " .. SVC
				.. " --object-path " .. shellQuote(path)
				.. " --method " .. shellQuote(PROPS_IFACE .. ".Set")
				.. " " .. shellQuote(MPRIS_IFACE) .. " volume "
				.. shellQuote("<int32 " .. tostring(vol) .. ">"),
			function() refreshDevices() end)
	else
		noctalia.log("[phone-connect] unknown cmd op: " .. tostring(op))
	end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────
intervalMs = function()
	if pendingPick then return 1000 end  -- poll the picker result promptly
	local secs = tonumber(noctalia.getConfig("state_update_interval")) or 30
	if secs <= 0 then return 3600000 end   -- disabled: large interval to minimize wakeups
	-- if media is playing, poll faster for live position updates
	for _, d in pairs(devices) do
		if d.mediaisPlaying == true then return 1000 end
	end
	return secs * 1000
end

function update()
	local secs = tonumber(noctalia.getConfig("state_update_interval")) or 30
	noctalia.setUpdateInterval(intervalMs())
	pollPendingPick()
	if secs <= 0 then return end            -- disabled: skip auto-refresh
	detectBackend()
	refreshDevices()
end

function onConfigChanged()
	noctalia.setUpdateInterval(intervalMs())
	-- reload translations when language changes
	local lang = noctalia.getConfig("language") or "en"
	if lang ~= noctalia.state.get("pc.lang") then
		publishTranslations(lang)
	end
end

-- IPC hook for external driving / testing: `noctalia msg plugin <entry> <target> <event> [payload]`
--   event "refresh"            -> full device refresh
--   event "cmd"  payload=json  -> execute a command table ({"op":"ring","device":"id"})
function onIpc(event, payload)
	if event == "refresh" then
		refreshDevices()
	elseif event == "cmd" and payload then
		local ok, cmd = pcall(noctalia.json.decode, payload)
		if ok and type(cmd) == "table" then
			handleCommand(cmd)
		else
			noctalia.log("[phone-connect] onIpc cmd: invalid json payload")
		end
	end
end

-- Top-level init runs once at load.
detectBackend()
refreshDevices()
-- Command channel: UI entries write { op, device, seq, ... } to "pc.cmd".
-- seq is a high-resolution timestamp so it never resets on hot-reload (unlike
-- a counter which would cause commands to be silently dropped after UI reload).
local lastCmdSeq = 0
noctalia.state.watch("pc.cmd", function(cmd)
	if type(cmd) ~= "table" then return end
	local seq = tonumber(cmd.seq) or 0
	if seq <= lastCmdSeq then return end
	lastCmdSeq = seq
	cmd.seq = nil
	handleCommand(cmd)
end)
