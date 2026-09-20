--!nonstrict

-- Type returned by `pass-cli vault list --output=json`
type Vault = { name: string, vault_id: string, share_id: string }
type Vaults = { [number]: Vault }

-- Type returned by `pass-cli item list <vault_name> --output=json`
type Item = { id: string, share_id: string, vault_id: string, state: string, title: string, item_type: string }
type Items = { [number]: Item }

-- Caches to avoid repeated CLI calls while the launcher session is active
local cachedVaults: Vaults = {}
local cachedItems: { [string]: Items } = {}

-- Utility functions -----------------------------------------------------------

-- Search cached items by item id across all cached vaults
local function searchCachedItems(item_id: string): Item?
	for _, vault in cachedItems do
		for _, item in vault do
			if item.id == item_id then
				return item
			end
		end
	end
	return nil
end

-- Map + filter: transform each element, include only non-nil results
local function filterMap<T, U>(sequence: { T }, fn: (T) -> U?)
	local out = {}
	for _, v in sequence do
		local res = fn(v)
		if res ~= nil then
			table.insert(out, res)
		end
	end
	return out
end

local function glyphTable(item_type: string)
	local lookupTable: { [string]: string } = {
		alias = "at",
		credit_card = "credit-card",
		custom = "note",
		identity = "user-circle",
		login = "lock",
		ssh_key = "key",
		wifi = "router",
	}

	return lookupTable[item_type] or "question-mark"
end

-- Proton Pass CLI functions ---------------------------------------------------

local function getVaultsAsync(callback)
	if #cachedVaults ~= 0 then
		callback(cachedVaults)
		return
	end

	noctalia.runAsync(`pass-cli vault list --output=json`, function(result)
		if result.exitCode ~= 0 then
			noctalia.log("proton-pass: failed to list vaults")
			noctalia.notifyError("Proton Pass", noctalia.tr("failed-list-vaults"))
			return callback({})
		end

		local decoded = noctalia.json.decode(result.stdout)
		local vaults: Vaults = decoded["vaults"] or {}
		cachedVaults = vaults
		return callback(vaults)
	end)
end

local function getItemsAsync(vaultName: string, callback)
	if cachedItems[vaultName] ~= nil then
		callback(cachedItems[vaultName])
		return
	end

	noctalia.runAsync(`pass-cli item list "{vaultName}" --output=json`, function(result)
		if result.exitCode ~= 0 then
			-- noctalia.log(`proton-pass: failed to list items in vault: {vaultName}`)
			return callback({})
		end

		local decoded = noctalia.json.decode(result.stdout)
		local items: Items = decoded["items"] or {}
		cachedItems[vaultName] = items
		return callback(items)
	end)
end

local function getPasswordAsync(item: Item, callback)
	noctalia.runAsync(`pass-cli item view "pass://{item.share_id}/{item.id}/password"`, function(result)
		if result.exitCode ~= 0 then
			noctalia.log(`proton-pass: no password found for item: {item.title}`)
			return
		end

		local password: string = result.stdout
		callback(password)
	end)
end

local function getItemTotpAsync(item: Item, callback)
	noctalia.runAsync(`pass-cli item totp "pass://{item.share_id}/{item.id}" --output=json`, function(result)
		if result.exitCode ~= 0 then
			-- It's not an error if a TOTP is absent; just log for debugging
			-- noctalia.log(`proton-pass: no TOTP code for item: {item.title}`)
			return
		end

		local decoded = noctalia.json.decode(result.stdout)
		local totp: string = decoded["totp"]
		callback(totp)
	end)
end

-- Row constructors ------------------------------------------------------------

local function vaultRows(pattern: string, callback)
	getVaultsAsync(function(vaults)
		callback(filterMap(vaults, function(vault)
			local score = noctalia.fuzzyScore(pattern, vault.name)
			if score == nil then
				return nil
			end

			return {
				id = noctalia.json.encode({ type = "vault", id = vault.name }),
				title = vault.name,
				glyph = "folder",
				score = score,
				query = `{vault.name} `,
			}
		end))
	end)
end

local function itemRows(vault: string, pattern: string, callback)
	getItemsAsync(vault, function(items)
		callback(filterMap(items, function(item)
			-- Exclude Trashed items before scoring
			if item.state ~= "Active" then
				return nil
			end

			local score = noctalia.fuzzyScore(pattern, item.title)
			if score == nil then
				return nil
			end

			return {
				id = noctalia.json.encode({ type = "item", id = item.id }),
				title = item.title,
				glyph = glyphTable(item.item_type),
				score = score,
			}
		end))
	end)
end

-- Entry points ----------------------------------------------------------------

function onQuery(query: string)
	local vault, rest = query:match("^(%S+)%s+(.*)$")

	-- Reset cache when query is empty
	if query == "" then
		cachedVaults = {}
		cachedItems = {}
	end

	if not vault then
		launcher.setResults(query, { { id = "loading", title = noctalia.tr("loading-vaults"), glyph = "loader" } })
		vaultRows(query, function(rows)
			launcher.setResults(query, rows)
		end)
	else
		launcher.setResults(query, { { id = "loading", title = noctalia.tr("loading-items"), glyph = "loader" } })
		itemRows(vault, rest, function(rows)
			launcher.setResults(query, rows)
		end)
	end
end

function onActivate(_id: string)
	local id: { type: string, id: string } = noctalia.json.decode(_id)

	if id.type == "item" then
		local item = searchCachedItems(id.id)

		if item == nil then
			noctalia.notifyError("Proton Pass", noctalia.tr("item-not-found"))
			return
		end

		getPasswordAsync(item, function(password)
			noctalia.copyToClipboard(password, "text/plain")
			noctalia.notify(`{item.title}`, noctalia.tr("copied-password"))

			-- Try to fetch TOTP and notify
			getItemTotpAsync(item, function(totp)
				noctalia.notify(`{item.title} TOTP`, totp)
			end)
		end)
	end
end
