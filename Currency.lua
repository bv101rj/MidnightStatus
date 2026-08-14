-- Currency.lua
-- Currency discovery, selection storage, and the picker menu.
--
-- Design notes:
--  * Everything is keyed by currencyID. Never by localised name (breaks on
--    non-English clients) and never by currency-list index (shifts whenever a
--    header is collapsed). Blizzard also renames the crest family every
--    season, Dawncrest -> Mistcrest, which name matching cannot survive.
--  * Runtime reads use C_CurrencyInfo.GetCurrencyInfo(id), which is O(1) and
--    ignores the list entirely. The list is only walked when the picker opens.
--
-- Selection shape:  opt.currencies = { { id = 3110 }, { id = 3115, pin = true } }

local addonName, MS = ...

local C_CurrencyInfo = C_CurrencyInfo

-- ------------------------------------------------------------------ helpers

local function iconTag(icon, size)
	if not icon then
		return ""
	end
	return string.format("|T%s:%d:%d:0:0|t", icon, size or 14, size or 14)
end
MS.IconTag = iconTag

local function listSize()
	if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
		return C_CurrencyInfo.GetCurrencyListSize() or 0
	end
	return 0
end

local function listInfo(index)
	if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListInfo then
		return C_CurrencyInfo.GetCurrencyListInfo(index)
	end
	return nil
end

-- The only reliable way to get an ID out of the list on every client version.
local function listIndexToID(index)
	if not (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListLink) then
		return nil
	end
	local link = C_CurrencyInfo.GetCurrencyListLink(index)
	if not link then
		return nil
	end
	return tonumber(string.match(link, "currency:(%d+)"))
end

-- ---------------------------------------------------------------- discovery

-- Collapsed headers hide their children from the list, so expand everything,
-- scan, then put it back. Expanding shifts indices, so each pass restarts from
-- the top; the guard stops a runaway loop if a client misbehaves.
local function withHeadersExpanded(fn)
	if not (C_CurrencyInfo and C_CurrencyInfo.ExpandCurrencyList) then
		return fn()
	end

	local collapsedNames, guard = {}, 0

	while guard < 60 do
		guard = guard + 1
		local found = false
		for i = 1, listSize() do
			local info = listInfo(i)
			if info and info.isHeader and not info.isHeaderExpanded then
				if info.name then
					collapsedNames[info.name] = true
				end
				C_CurrencyInfo.ExpandCurrencyList(i, true)
				found = true
				break
			end
		end
		if not found then
			break
		end
	end

	local ok, err = pcall(fn)

	if next(collapsedNames) then
		guard = 0
		while guard < 60 do
			guard = guard + 1
			local found = false
			for i = 1, listSize() do
				local info = listInfo(i)
				if info and info.isHeader and info.isHeaderExpanded and info.name and collapsedNames[info.name] then
					collapsedNames[info.name] = nil
					C_CurrencyInfo.ExpandCurrencyList(i, false)
					found = true
					break
				end
			end
			if not found then
				break
			end
		end
	end

	if not ok then
		error(err, 0)
	end
end

MS.currencyList = MS.currencyList or {}
MS.currencyByID = MS.currencyByID or {}

function MS.ScanCurrencies()
	local out, byID = {}, {}

	withHeadersExpanded(function()
		local header
		for i = 1, listSize() do
			local info = listInfo(i)
			if info then
				if info.isHeader then
					header = info.name
				else
					local id = listIndexToID(i)
					if id and not byID[id] then
						local e = {
							id = id,
							name = info.name,
							icon = info.iconFileID or info.icon,
							header = header,
							order = #out + 1,
						}
						out[#out + 1] = e
						byID[id] = e
					end
				end
			end
		end
	end)

	-- Keep the previous cache if the currency UI wasn't ready yet.
	if #out > 0 then
		MS.currencyList = out
		MS.currencyByID = byID
	end
	return MS.currencyList
end

local function currencyOrder(id)
	local e = MS.currencyByID[id]
	return e and e.order or 9999
end
MS.CurrencyOrder = currencyOrder

-- ------------------------------------------------------------------ reading

-- Returns quantity, name, icon, earnedThisWeek, weeklyMax
function MS.GetCurrency(id)
	if not (id and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo) then
		return nil
	end
	local info = C_CurrencyInfo.GetCurrencyInfo(id)
	if not info then
		return nil
	end
	local weeklyMax
	if info.canEarnPerWeek and info.maxQuantity and info.maxQuantity > 0 then
		weeklyMax = info.maxQuantity
	end
	return info.quantity or 0, info.name, info.iconFileID or info.icon, info.quantityEarnedThisWeek, weeklyMax
end

function MS.CurrencyName(id)
	local cached = MS.currencyByID[id]
	if cached and cached.name then
		return cached.name
	end
	local _, name = MS.GetCurrency(id)
	return name or ("currency:" .. tostring(id))
end

-- ---------------------------------------------------------------- selection

function MS.FindCurrency(opt, id)
	for i = 1, #opt.currencies do
		if opt.currencies[i].id == id then
			return opt.currencies[i], i
		end
	end
	return nil
end

-- Insert in the game's own list order, so crest tiers stay in tier order no
-- matter what order you tick them.
function MS.AddCurrency(opt, id)
	if MS.FindCurrency(opt, id) then
		return nil
	end
	local pos, mine = #opt.currencies + 1, currencyOrder(id)
	for i = 1, #opt.currencies do
		if currencyOrder(opt.currencies[i].id) > mine then
			pos = i
			break
		end
	end
	local entry = { id = id }
	table.insert(opt.currencies, pos, entry)
	return entry
end

function MS.RemoveCurrency(opt, id)
	local _, at = MS.FindCurrency(opt, id)
	if at then
		table.remove(opt.currencies, at)
		return true
	end
	return false
end

function MS.ToggleCurrency(opt, id)
	if not MS.RemoveCurrency(opt, id) then
		MS.AddCurrency(opt, id)
	end
end

-- Accepts "|Hcurrency:3110:...|h", "currency:3110" or a bare "3110".
function MS.ParseCurrencyID(str)
	if not str or str == "" then
		return nil
	end
	local id = string.match(str, "currency:(%d+)")
	if id then
		return tonumber(id)
	end
	return tonumber(string.match(str, "^%s*(%d+)%s*$") or "")
end

-- ------------------------------------------------------------------- picker

local REFRESH
local function refresh()
	if REFRESH == nil then
		REFRESH = (MenuResponse and MenuResponse.Refresh) or false
	end
	return REFRESH or nil
end

function MS.OpenPicker(anchor)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then
		print("|cff8080ffMidnightStatus|r: no MenuUtil on this client. Use /ms add <id> instead.")
		return
	end

	MS.ScanCurrencies()
	local opt = MS.GetOptions()

	MenuUtil.CreateContextMenu(anchor or UIParent, function(_, root)
		root:CreateTitle("MidnightStatus")

		root:CreateCheckbox("Auto: follow highest tier", function()
			return opt.autoWindow
		end, function()
			opt.autoWindow = not opt.autoWindow
			MS.UpdateCurrencyLine()
			return refresh()
		end)

		if opt.autoWindow then
			local win = root:CreateButton("Window size: " .. tostring(opt.autoCount))
			for n = 1, 7 do
				win:CreateRadio(tostring(n), function()
					return opt.autoCount == n
				end, function()
					opt.autoCount = n
					MS.UpdateCurrencyLine()
					return refresh()
				end)
			end
		end

		root:CreateCheckbox("Hide currencies at zero", function()
			return opt.hideZero
		end, function()
			opt.hideZero = not opt.hideZero
			MS.UpdateCurrencyLine()
			return refresh()
		end)

		root:CreateCheckbox("Show weekly earned / cap", function()
			return opt.showWeekly
		end, function()
			opt.showWeekly = not opt.showWeekly
			MS.UpdateCurrencyLine()
			return refresh()
		end)

		root:CreateDivider()

		-- ---- everything the character can see, grouped by the game's headers
		local list = MS.currencyList
		if #list == 0 then
			root:CreateButton("(no currencies found yet)")
		else
			local headers, byHeader = {}, {}
			for i = 1, #list do
				local e = list[i]
				local h = e.header or "Other"
				if not byHeader[h] then
					byHeader[h] = {}
					headers[#headers + 1] = h
				end
				table.insert(byHeader[h], e)
			end

			for i = 1, #headers do
				local h = headers[i]
				local sub = root:CreateButton(h)
				local group = byHeader[h]
				for j = 1, #group do
					local e = group[j]
					sub:CreateCheckbox(iconTag(e.icon, 14) .. " " .. (e.name or ("#" .. e.id)), function()
						return MS.FindCurrency(opt, e.id) ~= nil
					end, function()
						MS.ToggleCurrency(opt, e.id)
						MS.UpdateCurrencyLine()
						return refresh()
					end)
				end
			end
		end

		-- ---- anything selected but no longer in the list (last season's
		-- crests, say) so you can still untick it
		local orphans = {}
		for i = 1, #opt.currencies do
			local id = opt.currencies[i].id
			if not MS.currencyByID[id] then
				orphans[#orphans + 1] = id
			end
		end
		if #orphans > 0 then
			local sub = root:CreateButton("Selected but not listed")
			for i = 1, #orphans do
				local id = orphans[i]
				sub:CreateCheckbox(MS.CurrencyName(id), function()
					return true
				end, function()
					MS.RemoveCurrency(opt, id)
					MS.UpdateCurrencyLine()
					return refresh()
				end)
			end
		end

		-- ---- pinning only matters while the sliding window is on
		if opt.autoWindow and #opt.currencies > 0 then
			local pin = root:CreateButton("Always show (ignore window)")
			for i = 1, #opt.currencies do
				local entry = opt.currencies[i]
				local _, _, icon = MS.GetCurrency(entry.id)
				pin:CreateCheckbox(iconTag(icon, 14) .. " " .. MS.CurrencyName(entry.id), function()
					return entry.pin == true
				end, function()
					entry.pin = not entry.pin
					MS.UpdateCurrencyLine()
					return refresh()
				end)
			end
		end

		root:CreateDivider()
		root:CreateButton("Clear all", function()
			wipe(opt.currencies)
			MS.UpdateCurrencyLine()
			return refresh()
		end)

		root:CreateDivider()
		root:CreateCheckbox("24-hour clock", function()
			return MS.Is24Hour()
		end, function()
			MidnightStatusDB.use24HourTime = not MS.Is24Hour()
			MS.UpdateTimeLine()
			return refresh()
		end)
		root:CreateCheckbox("Frame accepts mouse", function()
			return MidnightStatusDB.mouse and true or false
		end, function()
			MidnightStatusDB.mouse = not MidnightStatusDB.mouse
			MS.ApplyMouse()
			return refresh()
		end)
	end)
end
