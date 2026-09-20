-- panel.luau
-- Phone Connect - details panel (520x640).
--
-- Layout: header row (connection status + refresh + close) with a device
-- switcher button row below; a full-width device card (avatar, name/status,
-- draggable volume, network, battery); then a two-column row: left (flex,
-- scrollable) holds now-playing + SMS composer, right (fixed width) holds
-- action buttons. All per-device UI state (SMS drafts, slider drags) is keyed
-- by device id so switching devices never mixes data between them.
-- Reads state from the service entry; sends commands via "pc.cmd".


-- Local translation: reads from pc.trTable (published by service) so users
-- can switch language at runtime, unlike noctalia.tr() which follows system locale.
local function t(key)
	local table = noctalia.state.get("pc.trTable") or {}
	return table[key] or key
end

-- ── Command channel ─────────────────────────────────────────────────────────
-- seq must strictly increase across clicks or the service drops the command
-- (its guard is `seq <= lastCmdSeq`). os.clock() is CPU time, which barely
-- advances in an event-driven VM, so rapid clicks produced identical seqs and
-- the second click was silently discarded. Wall-clock seconds + a per-second
-- counter keeps seq unique and monotonic; wall time also stays >= any seq the
-- service saw before a hot-reload.
local cmdSeq = 0
local function sendCmd(cmd)
	cmdSeq = cmdSeq + 1
	cmd.seq = os.time() * 1000000 + cmdSeq
	noctalia.state.set("pc.cmd", cmd)
end

-- ── Per-device UI state (keyed by device id; never shared across devices) ────
-- SMS composer drafts. ui.input is uncontrolled, so drafts live here and are
-- re-seeded via value + a device-suffixed key when the selected device changes.
local smsDrafts = {}   -- [deviceId] = { dest = string, msg = string }
local function draftFor(id)
	local d = smsDrafts[id]
	if not d then
		d = { dest = "", msg = "" }
		smsDrafts[id] = d
	end
	return d
end

-- Slider drag state: while the user drags we freeze the displayed value so a
-- service refresh (position ticks ~1s, volume sync) doesn't yank the thumb
-- back. Keyed by device id. Progress and volume keep separate states because
-- both are sliders on the same device.
local mediaDragState = {}    -- [deviceId] = { dragging = true, position = <ms> }
local volumeDragState = {}   -- [deviceId] = { dragging = true, position = <0-100> }
local mutedPrevVolume = {}   -- [deviceId] = volume before mute, for unmute

-- Inline name editing: deviceNameEdits[deviceId] = true while the input is
-- shown (instead of the label). Per-device, so editing one device's name never
-- affects another's.
local deviceNameEdits = {}

-- ── Helpers ─────────────────────────────────────────────────────────────────
local function glyphForType(t)
	if t == "tablet" then return "device-tablet" end
	if t == "laptop" then return "device-laptop" end
	if t == "desktop" or t == "computer" then return "device-desktop" end
	if t == "tv" then return "device-tv" end
	return "device-mobile"
end

local function batteryGlyph(charge, charging)
	if charging then return "battery-charging" end
	if type(charge) ~= "number" then return "battery" end
	if charge >= 90 then return "battery" end
	if charge >= 60 then return "battery-3" end
	if charge >= 30 then return "battery-2" end
	if charge > 0 then return "battery-1" end
	return "battery-off"
end

local function fmtTime(ms)
	if type(ms) ~= "number" or ms <= 0 then return "0:00" end
	local s = math.floor(ms / 1000)
	local m = math.floor(s / 60)
	s = s % 60
	return string.format("%d:%02d", m, s)
end

-- ── Header: connection count + device switcher + refresh/close ──────────────
-- Device switcher buttons share this row when more than one device is present.
local function headerRow(order, devices, sel)
	local connected = 0
	for _, id in ipairs(order) do
		local d = devices[id]
		-- connected = paired AND reachable; reachable alone includes unpaired
		-- devices that are merely visible on the network
		if d and d.isPaired and d.isReachable then connected = connected + 1 end
	end
	local connText = t("panel.devices_connected"):gsub("{connected}", tostring(connected))
	local aliasMap = noctalia.state.get("pc.aliasMap") or {}
	local multi = #order > 1
	local kids = {
		ui.glyph({ name = "device-mobile", size = 18, color = "primary" }),
		ui.label({ text = connText, fontSize = 13, fontWeight = "medium",
			color = "on_surface", flexGrow = multi and 0 or 1 }),
	}
	if multi then
		for idx, id in ipairs(order) do
			local d = devices[id]
			if d then
				local isSel = id == sel
				local devName = aliasMap[id] or d.name or "Your-Phone"
				table.insert(kids, ui.button({
					key = "sw-" .. id,
					text = tostring(idx),
					glyph = glyphForType(d.type),
					variant = isSel and "primary" or "outline",
					controlSize = "sm",
					selected = isSel,
					flexGrow = 1,
					tooltip = devName,
					onClick = function() sendCmd({ op = "select", device = id }) end,
				}))
			end
		end
	end
	table.insert(kids, ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm",
		tooltip = t("action.refresh"),
		onClick = function() sendCmd({ op = "refresh" }) end }))
	table.insert(kids, ui.button({ glyph = "close", variant = "ghost", controlSize = "sm",
		tooltip = t("panel.close"),
		onClick = function() panel.close() end }))
	return ui.row({ gap = 8, align = "center" }, kids)
end

-- ── Device card: avatar | name+status+volume | network | battery ─────────────
local function deviceCard(d)
	-- "Connected" requires a paired AND reachable device: isReachable alone
	-- means "visible on the network" (an unpaired device is also reachable).
	local reachable = d.isPaired == true and d.isReachable == true
	local aliasMap = noctalia.state.get("pc.aliasMap") or {}
	local name = aliasMap[d.id] or d.name or "Your-Phone"
	local glyph = glyphForType(d.type)
	local imgMap = noctalia.state.get("pc.imageMap") or {}
	local imgPath = imgMap[d.id]
	-- Show the chosen image even when fileExists can't confirm it: the path
	-- came from a file picker and exists; fileExists can reject valid paths
	-- (e.g. non-ASCII ones). A stale path just renders as an empty image.
	if imgPath and imgPath ~= "" and not noctalia.fileExists(imgPath) then
		noctalia.log("[phone-connect] image not found: " .. imgPath)
	end

	local statusText, statusColor
	if not reachable then
		statusText = t("status.offline")
		statusColor = "on_surface_variant"
	else
		statusText = t("status.connected")
		statusColor = "primary"
	end

	-- battery
	local charge = d.batteryCharge
	local hasCharge = type(charge) == "number" and charge >= 0
	local chargeText = hasCharge and (tostring(charge) .. "%") or "--"
	local chargeColor = "on_surface"
	if hasCharge and charge <= 20 then chargeColor = "error" end
	local charging = d.batteryCharging == true

	-- network
	local netText = (d.networkType and d.networkType ~= "")
		and (d.networkType .. (type(d.networkStrength) == "number"
			and d.networkStrength >= 0 and (" " .. tostring(d.networkStrength) .. "/4") or ""))
		or "--"

	-- volume (draggable; only meaningful when the device reports media volume)
	local vol = tonumber(d.mediavolume)
	local hasVol = type(vol) == "number" and vol >= 0
	local muted = hasVol and vol <= 0
	local vDrag = volumeDragState[d.id]
	local vFrozen = vDrag and vDrag.dragging and (os.clock() - (vDrag.at or 0)) < 2.0
	if vDrag and vDrag.dragging and not vFrozen then volumeDragState[d.id] = nil end
	local volValue = vFrozen and vDrag.position or (hasVol and vol or 0)
	local volLabel = hasVol and (tostring(math.floor(volValue)) .. "%") or "--"

	local function toggleMute()
		if not hasVol then return end
		if muted then
			-- unmute: restore the volume we remembered before muting
			local restore = mutedPrevVolume[d.id] or 50
			sendCmd({ op = "media_set_volume", device = d.id, volume = tostring(restore) })
		else
			mutedPrevVolume[d.id] = vol
			sendCmd({ op = "media_set_volume", device = d.id, volume = "0" })
		end
	end

	local volumeGroup
	if hasVol then
		volumeGroup = ui.row({ gap = 4, align = "center", width = 132 }, {
			ui.button({
				glyph = muted and "volume-off" or "volume",
				variant = "ghost",
				controlSize = "sm",
				glyphSize = 13,
				tooltip = t(muted and "media.unmute" or "media.mute"),
				onClick = toggleMute,
			}),
			ui.label({ text = volLabel, fontSize = 10, color = "on_surface_variant", width = 34 }),
			ui.slider({
				key = "vol-" .. d.id,
				min = 0, max = 100, step = 1, value = volValue,
				controlSize = "sm", enabled = reachable, flexGrow = 1,
				onChange = function(v)
					volumeDragState[d.id] = { dragging = true, position = tonumber(v) or 0, at = os.clock() }
				end,
				onDragEnd = function()
					local st = volumeDragState[d.id]
					local target = (st and st.position) or (hasVol and vol or 0)
					volumeDragState[d.id] = nil
					sendCmd({ op = "media_set_volume", device = d.id, volume = tostring(target) })
				end,
			}),
		})
	end

	local function pickImage()
		-- Delegate to the service: it spawns the picker detached (so the GUI
		-- dialog outlives runAsync's subprocess timeout) and applies the chosen
		-- path to this device via the pick_image command.
		sendCmd({ op = "pick_image", device = d.id })
	end

	local function commitName(v)
		local newName = (v or ""):gsub("^%s+", ""):gsub("%s+$", "")
		deviceNameEdits[d.id] = nil
		sendCmd({ op = "set_alias", device = d.id, alias = newName })
		render()
	end

	return ui.row({ gap = 10, padding = 12, radius = 10, fill = "surface/0.7",
		border = "primary/0.2", borderWidth = 1, align = "center" }, {
		-- Standalone ui.image (like gamer-mode's circular logo): a ui.image
		-- nested inside ui.box did not render. Clicking swaps the image.
		imgPath and ui.image({ path = imgPath, width = 44, height = 44,
			radius = 22, fit = "cover", onClick = pickImage })
			or ui.box({ width = 44, height = 44, radius = 22, fill = "primary/0.15",
				onClick = pickImage }, {
				ui.glyph({ name = glyph, size = 24, color = "primary" }),
				ui.glyph({ name = "pencil", size = 10, color = "on_surface_variant" }),
			}),
		ui.column({ gap = 3, flexGrow = 1, minWidth = 0 }, {
			deviceNameEdits[d.id] and ui.input({
				key = "name-edit-" .. d.id,
				value = name,
				placeholder = name,
				controlSize = "sm",
				onSubmit = commitName,
			})
			or ui.row({ gap = 4, align = "center", onClick = function()
					deviceNameEdits[d.id] = true
					render()
				end }, {
				ui.label({ text = name, fontSize = 14, fontWeight = "bold",
					color = "on_surface", maxLines = 1 }),
				ui.glyph({ name = "pencil", size = 10, color = "on_surface_variant" }),
			}),
			ui.row({ gap = 6, align = "center" }, {
				ui.row({ radius = 8, fill = statusColor .. "/0.15", paddingH = 6, paddingV = 2 }, {
					ui.label({ text = statusText, fontSize = 10, color = statusColor }),
				}),
			}),
		}),
		volumeGroup,
		ui.column({ gap = 2, align = "center", width = 52 }, {
			ui.glyph({ name = "antenna", size = 16,
				color = (reachable and d.networkType and d.networkType ~= "") and "primary" or "on_surface_variant" }),
			ui.label({ text = netText, fontSize = 9, color = "on_surface_variant" }),
		}),
		ui.column({ gap = 2, align = "center", width = 52 }, {
			ui.glyph({ name = batteryGlyph(charge, charging), size = 16, color = chargeColor }),
			ui.label({ text = chargeText, fontSize = 10, fontWeight = "medium", color = chargeColor }),
		}),
	})
end

-- ── Right column: action buttons stacked vertically ─────────────────────────
local function vActionBtn(text, glyph, onClick, variant, tooltip)
	return ui.button({ text = text, glyph = glyph, variant = variant or "outline",
		controlSize = "md", tooltip = tooltip, onClick = onClick })
end

local function rightColumn(d)
	local reachable = d.isReachable == true
	local paired = d.isPaired == true
	local btns = {}
	if reachable and paired then
		table.insert(btns, vActionBtn(t("action.ring"), "bell-ringing",
			function() sendCmd({ op = "ring", device = d.id }) end, "primary"))
		table.insert(btns, vActionBtn(t("action.ping"), "message",
			function() sendCmd({ op = "ping", device = d.id }) end))
		table.insert(btns, vActionBtn(t("action.browse"), "folder",
			function() sendCmd({ op = "browse", device = d.id }) end))
		if noctalia.getConfig("enable_clipboard_action") then
			table.insert(btns, vActionBtn(t("action.clipboard"), "clipboard",
				function() sendCmd({ op = "clipboard", device = d.id }) end))
		end
		table.insert(btns, vActionBtn(t("action.share"), "share",
			function() sendCmd({ op = "pick_share", device = d.id }) end))
		table.insert(btns, vActionBtn(t("action.unpair"), "link-off",
			function() sendCmd({ op = "unpair", device = d.id }) end, "ghost"))
	elseif not paired then
		table.insert(btns, vActionBtn(t("action.pair"), "link",
			function() sendCmd({ op = "pair", device = d.id }) end, "primary"))
	else
		table.insert(btns, vActionBtn(t("action.unpair"), "link-off",
			function() sendCmd({ op = "unpair", device = d.id }) end, "ghost"))
	end
	-- Wrap buttons in a scroll so a tall action stack cannot force the middle
	-- row past the panel height and push the switcher out of view (#294).
	return ui.column({ width = 110 }, {
		ui.scroll({ flexGrow = 1, gap = 8, padding = 8, align = "stretch" }, btns),
	})
end

-- ── Left column: now-playing + SMS composer (scrollable) ────────────────────
local function mediaSection(d)
	local title = d.mediatitle
	if not title or title == "" then
		-- Left-aligned like the playing state (an earlier version centered
		-- this placeholder, which made the section flip between two layouts
		-- whenever media started/stopped or devices were switched).
		return ui.column({ gap = 6, padding = 10, radius = 8, fill = "surface/0.5" }, {
			ui.row({ gap = 6, align = "center" }, {
				ui.glyph({ name = "music", size = 13, color = "primary" }),
				ui.label({ text = t("panel.now_playing"), fontSize = 10,
					color = "primary", fontWeight = "bold", flexGrow = 1 }),
			}),
			ui.row({ gap = 8, align = "center" }, {
				ui.glyph({ name = "music-off", size = 20, color = "on_surface_variant" }),
				ui.label({ text = t("panel.no_media"), fontSize = 11,
					color = "on_surface_variant" }),
			}),
		})
	end
	local artist = d.mediaartist or ""
	local album = d.mediaalbum or ""
	local playing = d.mediaisPlaying == true
	local length = tonumber(d.medialength) or 0
	local position = tonumber(d.mediaposition) or 0
	local canSeek = d.mediacanSeek == true
	local artUrl = d.mediaArtPath

	-- only use art if the file exists (phone path via SFTP mount)
	if artUrl and artUrl ~= "" and not noctalia.fileExists(artUrl) then
		artUrl = nil
	end

	local header = ui.row({ gap = 6, align = "center" }, {
		ui.glyph({ name = "music", size = 13, color = "primary" }),
		ui.label({ text = t("panel.now_playing"), fontSize = 10,
			color = "primary", fontWeight = "bold", flexGrow = 1 }),
	})

	local titleBlock
	if artUrl then
		titleBlock = ui.row({ gap = 8, align = "center" }, {
			ui.image({ path = artUrl, width = 36, height = 36, radius = 4, fit = "cover" }),
			ui.column({ gap = 1, flexGrow = 1 }, {
				ui.label({ text = title, fontSize = 12, fontWeight = "medium",
					color = "on_surface", maxLines = 1 }),
				ui.label({ text = artist, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
				ui.label({ text = album, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
			}),
		})
	else
		titleBlock = ui.column({ gap = 1 }, {
			ui.label({ text = title, fontSize = 12, fontWeight = "medium",
				color = "on_surface", maxLines = 1 }),
			ui.label({ text = artist, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
			ui.label({ text = album, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
		})
	end

	local transport = ui.row({ gap = 4, align = "center" }, {
		ui.button({ glyph = "player-skip-back", variant = "ghost", controlSize = "sm",
			tooltip = t("media.previous"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "Previous" }) end }),
		ui.button({ glyph = playing and "player-pause" or "player-play",
			variant = "primary", controlSize = "sm",
			tooltip = t(playing and "media.pause" or "media.play"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "PlayPause" }) end }),
		ui.button({ glyph = "player-skip-forward", variant = "ghost", controlSize = "sm",
			tooltip = t("media.next"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "Next" }) end }),
		ui.button({ glyph = "player-stop", variant = "ghost", controlSize = "sm",
			tooltip = t("media.stop"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "Stop" }) end }),
	})

	local progress
	if canSeek and length > 0 then
		local st = mediaDragState[d.id]
		-- Freeze the thumb only while the user is actually dragging; a stale
		-- drag state (e.g. onDragEnd never fired) expires after 2s and the bar
		-- resumes tracking the live position.
		local frozen = st and st.dragging and (os.clock() - (st.at or 0)) < 2.0
		if st and st.dragging and not frozen then mediaDragState[d.id] = nil end
		local sliderValue = frozen and st.position or position
		progress = ui.column({ gap = 2 }, {
			ui.slider({ min = 0, max = length, step = 1000, value = sliderValue,
				controlSize = "sm",
				onChange = function(v)
					mediaDragState[d.id] = { dragging = true, position = tonumber(v) or position, at = os.clock() }
				end,
				onDragEnd = function()
					local st2 = mediaDragState[d.id]
					local target = (st2 and st2.position) or position
					mediaDragState[d.id] = nil
					sendCmd({ op = "media_seek", device = d.id, offset = tostring(target) })
				end }),
			ui.row({ justify = "space_between" }, {
				ui.label({ text = fmtTime(sliderValue), fontSize = 9, color = "on_surface_variant" }),
				ui.label({ text = fmtTime(length), fontSize = 9, color = "on_surface_variant" }),
			}),
		})
	end

	local children = { header, titleBlock, transport }
	if progress then table.insert(children, progress) end
	return ui.column({ gap = 6, padding = 10, radius = 8, fill = "primary/0.08" }, children)
end

local function smsComposer(d)
	local draft = draftFor(d.id)
	return ui.column({ gap = 8, padding = 12, radius = 8, fill = "surface/0.5",
		border = "on_surface/0.1", borderWidth = 1 }, {
		ui.label({ text = t("panel.sms"), fontSize = 12, fontWeight = "bold",
			color = "on_surface" }),
		ui.input({ key = "sms-dest-" .. d.id, placeholder = t("panel.sms_dest"),
			value = draft.dest, controlSize = "sm",
			onChange = function(v) draftFor(d.id).dest = v end }),
		ui.input({ key = "sms-msg-" .. d.id, placeholder = t("panel.sms_msg"),
			value = draft.msg, controlSize = "sm",
			onChange = function(v) draftFor(d.id).msg = v end }),
		ui.button({ text = t("panel.sms_send"), glyph = "send",
			variant = "primary", controlSize = "sm",
			onClick = function()
				local df = draftFor(d.id)
				if df.dest ~= "" and df.msg ~= "" then
					sendCmd({ op = "sms_send", device = d.id,
						destination = df.dest, text = df.msg })
					df.msg = ""
					render()
				end
			end }),
	})
end

local function leftColumn(d)
	local items = {}
	table.insert(items, mediaSection(d))
	if d.isReachable and d.isPaired then
		table.insert(items, smsComposer(d))
	end
	return ui.column({ flexGrow = 1 }, {
		ui.scroll({ flexGrow = 1, gap = 12, padding = 0 }, items),
	})
end

-- ── Footer: device addresses (display only) ─────────────────────────────────
local function infoFooter(d)
	local function ipCell(label, ip)
		return ui.column({ gap = 2, padding = 6, radius = 6, fill = "surface/0.5",
			flexGrow = 1 }, {
			ui.label({ text = label, fontSize = 9, color = "on_surface_variant" }),
			ui.label({ text = ip or "--", fontSize = 10, maxLines = 1,
				color = ip and "on_surface" or "on_surface_variant" }),
		})
	end
	return ui.row({ gap = 8 }, {
		ipCell("IPv4", d.ipv4),
		ipCell("IPv6", d.ipv6),
	})
end

-- ── Main render ─────────────────────────────────────────────────────────────
function render()
	local backend = noctalia.state.get("pc.backend") or { available = false }
	local devices = noctalia.state.get("pc.devices") or {}
	local order = noctalia.state.get("pc.order") or {}
	local sel = noctalia.state.get("pc.selected")
	if not sel or not devices[sel] then sel = order[1] end

	local body = {}
	table.insert(body, headerRow(order, devices, sel))

	if not backend.available then
		table.insert(body, ui.column({ gap = 8, padding = 40, align = "center", flexGrow = 1 }, {
			ui.glyph({ name = "phone-off", size = 40, color = "on_surface_variant" }),
			ui.label({ text = t("status.no_backend"), color = "on_surface_variant" }),
		}))
	elseif not sel or not devices[sel] then
		table.insert(body, ui.column({ gap = 8, padding = 40, align = "center", flexGrow = 1 }, {
			ui.glyph({ name = "phone-off", size = 40, color = "on_surface_variant" }),
			ui.label({ text = t("panel.empty"), color = "on_surface_variant" }),
		}))
	else
		local d = devices[sel]
		table.insert(body, deviceCard(d))
		-- middle: two-column row (left content flex, right actions fixed)
		table.insert(body, ui.row({ gap = 14, flexGrow = 1, align = "stretch", justify = "center" }, {
			leftColumn(d),
			rightColumn(d),
		}))
		-- bottom: device info footer (addresses, type, OS)
		table.insert(body, infoFooter(d))
	end

	panel.render(ui.column({ gap = 10, padding = 12 }, body))
end

function onOpen(_context) render() end
function onClose() end

noctalia.state.watch("pc.devices", render)
noctalia.state.watch("pc.order", render)
noctalia.state.watch("pc.selected", render)
noctalia.state.watch("pc.backend", render)
noctalia.state.watch("pc.imageMap", render)
noctalia.state.watch("pc.trTable", render)
noctalia.state.watch("pc.aliasMap", render)
