-- MidnightStatus.lua
-- Stacked HUD: big clock, small sys-stats line, gold line, currency line.
-- KISS: no OnUpdate anywhere. One 1-second ticker that idles while the frame is
-- not visible; everything else is event driven and coalesced.

local addonName, MS = ...

-- ------------------------------------------------------------------ storage
--
-- Two scopes, deliberately:
--
--   MidnightStatusDB      account-wide. Personal prefs (clock format, mouse)
--                         plus a "template" that seeds brand-new characters.
--   MidnightStatusCharDB  per character. What's actually on the bar.
--
-- Content is per character because Edit Mode remembers the active layout per
-- specialisation, so anything keyed off the layout name silently changed when
-- you swapped spec. Content is per character and position is a single shared
-- value; neither is keyed by layout, so spec swaps never disturb either.
--
-- New characters inherit the last setup you touched, then diverge the moment
-- they change anything.

MidnightStatusDB = MidnightStatusDB or {}
MidnightStatusCharDB = MidnightStatusCharDB or {}

local DEFAULT_POS = { point = "TOP", x = 0, y = -80 }
local MANUAL_KEY = "__manual" -- legacy position key, only read during migration

local SETTING_DEFAULTS = {
	autoWindow = false,
	autoCount = 3,
	hideZero = false,
	showWeekly = false,
}

local function deepCopy(src)
	local out = {}
	for k, v in pairs(src) do
		out[k] = (type(v) == "table") and deepCopy(v) or v
	end
	return out
end

local activeLayout = nil

-- ---- settings (per character) ----

local function getSettings()
	local s = MidnightStatusCharDB.settings
	if not s then
		s = MidnightStatusDB.template and deepCopy(MidnightStatusDB.template) or {}
		MidnightStatusCharDB.settings = s
	end

	for k, v in pairs(SETTING_DEFAULTS) do
		if s[k] == nil then
			s[k] = v
		end
	end
	s.currencies = s.currencies or {}

	-- v0.8 stored bare numbers. Normalise on every read so no caller can ever
	-- see a malformed entry, whatever order things initialise in.
	for i = 1, #s.currencies do
		if type(s.currencies[i]) == "number" then
			s.currencies[i] = { id = s.currencies[i] }
		end
	end
	return s
end

function MS.GetOptions()
	return getSettings()
end

-- Call after any settings change so the next fresh character inherits it.
local function saveTemplate()
	MidnightStatusDB.template = deepCopy(getSettings())
	MidnightStatusDB.template.__migrated = nil
end
MS.SaveTemplate = saveTemplate

-- ---- position (one shared spot, not per Edit Mode layout) ----
--
-- Edit Mode keeps a separate active layout per specialisation, so anything
-- stored per layout name moves every time you swap spec. The frame gets ONE
-- position, reused for every layout.
--
-- Scope defaults to account-wide ("global"): same spot on every character.
-- Flip it with /ms posscope character if you want alts placed differently.

local function posScope()
	return MidnightStatusDB.posScope or "global"
end

local function posStore()
	if posScope() == "character" then
		MidnightStatusCharDB.position = MidnightStatusCharDB.position
			or (MidnightStatusDB.position and deepCopy(MidnightStatusDB.position))
			or { point = DEFAULT_POS.point, x = DEFAULT_POS.x, y = DEFAULT_POS.y }
		return MidnightStatusCharDB.position
	end
	MidnightStatusDB.position = MidnightStatusDB.position
		or { point = DEFAULT_POS.point, x = DEFAULT_POS.x, y = DEFAULT_POS.y }
	return MidnightStatusDB.position
end

local function getPos()
	local p = posStore()
	if not p.point then
		p.point, p.x, p.y = DEFAULT_POS.point, DEFAULT_POS.x, DEFAULT_POS.y
	end
	return p
end

-- Set while we are placing the frame ourselves, so a position callback that
-- LibEditMode fires in response to our own SetPoint can't overwrite the store
-- with the value it just handed us for a different layout.
local applyingPos = false

local function setPos(_, point, x, y)
	if applyingPos then
		return
	end
	local p = getPos()
	p.point, p.x, p.y = point, x, y
end

local function applyPos()
	local p = getPos()
	applyingPos = true
	MS.frame:ClearAllPoints()
	MS.frame:SetPoint(p.point, UIParent, p.point, p.x, p.y)
	applyingPos = false
end

function MS.SetPosScope(scope)
	if scope ~= "global" and scope ~= "character" then
		return false
	end
	local current = getPos()
	MidnightStatusDB.posScope = scope
	-- carry the spot across so the frame doesn't jump when you switch scope
	local target = posStore()
	target.point, target.x, target.y = current.point, current.x, current.y
	applyPos()
	return true
end

function MS.GetPosScope()
	return posScope()
end

-- ---- account-wide prefs ----

function MS.Is24Hour()
	if MidnightStatusDB.use24HourTime == nil then
		MidnightStatusDB.use24HourTime = true
	end
	return MidnightStatusDB.use24HourTime
end

-- ------------------------------------------------------------------- frame

local f = CreateFrame("Frame", "MidnightStatusFrame", UIParent)
f:SetClampedToScreen(true)
f:SetMovable(true)
f:SetFrameStrata("MEDIUM")
f:SetSize(300, 90)
f:RegisterForDrag("LeftButton")
MS.frame = f

-- STANDARD_TEXT_FONT can be nil early on some clients, and SetFont with a nil
-- path silently leaves the string invisible rather than erroring.
local FONT = STANDARD_TEXT_FONT
if not FONT and GameFontNormal and GameFontNormal.GetFont then
	FONT = (GameFontNormal:GetFont())
end
FONT = FONT or "Fonts\\FRIZQT__.TTF"

local PAD, GAP = 2, 2

local function makeLine(size)
	local fs = f:CreateFontString(nil, "OVERLAY")
	fs:SetJustifyH("CENTER")
	fs:SetFont(FONT, size, "OUTLINE")
	fs.msSize = size
	fs.msText = ""
	return fs
end

local timeFS = makeLine(28)
local statsFS = makeLine(14)
local goldFS = makeLine(14)
local currFS = makeLine(14)

local LINES = { timeFS, statsFS, goldFS, currFS }

-- Icons are sized off the line they sit on, so changing a font size later can't
-- silently desync the artwork from the text.
local CURR_ICON = currFS.msSize

local lastMask, lastW, lastH = -1, 0, 0

-- Runs on every text change (~1/s), so it allocates nothing: the visibility
-- mask is an integer rather than a built string, and widths come from the
-- per-line cache that setLine refreshes for the one line that changed.
local function relayout()
	local mask = 0
	for i = 1, #LINES do
		mask = mask * 2 + (LINES[i].msText ~= "" and 1 or 0)
	end
	local reanchor = (mask ~= lastMask)
	lastMask = mask

	local prev, h, w = nil, 0, 0

	for i = 1, #LINES do
		local fs = LINES[i]
		if fs.msText ~= "" then
			if reanchor then
				fs:ClearAllPoints()
				if prev then
					fs:SetPoint("TOP", prev, "BOTTOM", 0, -GAP)
				else
					fs:SetPoint("TOP", f, "TOP", 0, -PAD)
				end
				fs:Show()
			end
			prev = fs
			h = h + fs.msSize + GAP
			local sw = fs.msW or 0
			if sw > w then
				w = sw
			end
		elseif reanchor then
			fs:Hide()
		end
	end

	w = w + PAD * 2
	h = h + PAD * 2
	if w < 60 then
		w = 60
	end
	if h < 20 then
		h = 20
	end
	-- SetSize is a layout invalidation; skip it unless the box really moved.
	if w > lastW + 1 or w < lastW - 1 or h > lastH + 1 or h < lastH - 1 then
		lastW, lastH = w, h
		f:SetSize(w, h)
	end
end

-- ------------------------------------------------------------------- colour

-- The colour is a property of the font string, not of the text. Wrapping every
-- line in |cAARRGGBB...|r rebuilt two extra strings per line per tick for a
-- colour that changes approximately never; SetTextColor is set once instead.
-- Returns true once the colour has actually been applied. UnitClass can come
-- back empty very early on login, and a silent failure there would leave the
-- bar white for the rest of the session, so the ticker retries until it takes.
local classColorDone = false

local function refreshClassColor()
	local _, classFile = UnitClass("player")
	if not classFile then
		return false
	end
	local c
	if C_ClassColor and C_ClassColor.GetClassColor then
		c = C_ClassColor.GetClassColor(classFile)
	end
	c = c or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile])
	if not c then
		return false
	end
	for i = 1, #LINES do
		LINES[i]:SetTextColor(c.r, c.g, c.b)
	end
	return true
end

local function setLine(fs, text)
	if fs.msText == text then
		return
	end
	fs.msText = text
	fs:SetText(text)
	-- Measure only the line that actually changed; relayout reuses the rest.
	fs.msW = (text ~= "" and fs:GetStringWidth() or 0) or 0
	relayout()
end

-- ------------------------------------------------------------------ helpers

local COIN = 14
local GOLD_ICON = string.format("|TInterface\\MoneyFrame\\UI-GoldIcon:%d:%d:0:0|t", COIN, COIN)
local SILVER_ICON = string.format("|TInterface\\MoneyFrame\\UI-SilverIcon:%d:%d:0:0|t", COIN, COIN)
local COPPER_ICON = string.format("|TInterface\\MoneyFrame\\UI-CopperIcon:%d:%d:0:0|t", COIN, COIN)

local function formatCompactGold(copper)
	copper = copper or 0
	local g = math.floor(copper / 10000)
	local s = math.floor((copper % 10000) / 100)
	local c = copper % 100

	local goldText
	if g >= 1000000 then
		local whole = math.floor(g / 1000000)
		local frac = math.floor((g % 1000000) / 10000)
		goldText = string.format("%d.%02dm", whole, frac)
	elseif g >= 1000 then
		local whole = math.floor(g / 1000)
		local frac = math.floor((g % 1000) / 100)
		if frac == 0 then
			goldText = string.format("%dk", whole)
		else
			goldText = string.format("%d.%dk", whole, frac)
		end
	else
		goldText = tostring(g)
	end
	return string.format("%s%s %d%s %d%s", goldText, GOLD_ICON, s, SILVER_ICON, c, COPPER_ICON)
end

local DURABILITY_SLOTS = {
	INVSLOT_HEAD,
	INVSLOT_SHOULDER,
	INVSLOT_CHEST,
	INVSLOT_WRIST,
	INVSLOT_HAND,
	INVSLOT_WAIST,
	INVSLOT_LEGS,
	INVSLOT_FEET,
	INVSLOT_MAINHAND,
	INVSLOT_OFFHAND,
}

local getDurability = (MS.Resolve and MS.Resolve(rawget(_G, "C_Item"), "GetInventoryItemDurability"))
	or rawget(_G, "GetInventoryItemDurability")

local function getDurabilityPercent()
	if not getDurability then
		return nil
	end
	local lowest
	for i = 1, #DURABILITY_SLOTS do
		local slot = DURABILITY_SLOTS[i]
		if slot then
			local cur, max = getDurability(slot)
			if cur and max and max > 0 then
				local p = (cur / max) * 100
				if not lowest or p < lowest then
					lowest = p
				end
			end
		end
	end
	if not lowest then
		return nil
	end
	return math.floor(lowest + 0.5)
end

local function specIconTag(icon, size)
	if not icon then
		return ""
	end
	size = size or 14
	return string.format("|T%s:%d:%d:0:0:64:64:4:60:4:60|t", icon, size, size)
end

-- -------------------------------------------------------------------- state

local cache = {
	loot = "",
	lootIcon = nil,
	specTag = "", -- prebuilt icon escape; only rebuilt when the spec changes
	dura = nil,
	duraText = "--",
	fps = -1,
	ms = -1,
}

local lastMinute = -1

-- Called whenever something invalidates a cached render (clock format change,
-- becoming visible again) so the next tick rebuilds instead of early-outing.
function MS.Invalidate()
	lastMinute = -1
end

-- ------------------------------------------------------------------ updates

-- The clock shows minutes, so there is nothing to do 59 ticks out of 60.
-- time() is a cheap C call that allocates nothing; date() allocates a string,
-- so it only runs once the minute has actually rolled over.
local getEpoch = rawget(_G, "time") or rawget(_G, "GetServerTime")

function MS.UpdateTimeLine()
	if getEpoch then
		local minute = math.floor(getEpoch() / 60)
		if minute == lastMinute then
			return
		end
		lastMinute = minute
	end

	local t
	if MS.Is24Hour() then
		t = date("%H:%M")
	else
		local h = tonumber(date("%I")) or 12
		t = string.format("%d:%s %s", h, date("%M"), date("%p"))
	end
	setLine(timeFS, t)
end

-- Rebuilt once a second, so it is a single string.format over prebuilt pieces
-- rather than a throwaway table plus a concat.
local function updateStatsLine()
	local fps = cache.fps
	local ms = cache.ms
	setLine(
		statsFS,
		string.format("%dfps %dms %s%s", fps < 0 and 0 or fps, ms < 0 and 0 or ms, cache.specTag, cache.duraText)
	)
end

local function updateGoldLine()
	setLine(goldFS, formatCompactGold(GetMoney and GetMoney() or 0))
end

local function updateLoot()
	if MS.GetSpecNameAndIcon then
		cache.loot, cache.lootIcon = MS.GetSpecNameAndIcon()
	end
	local name = cache.loot or ""
	if cache.lootIcon then
		cache.specTag = specIconTag(cache.lootIcon, 14) .. name .. " "
	elseif name ~= "" then
		cache.specTag = name .. " "
	else
		cache.specTag = ""
	end
	updateStatsLine()
end

local function updateDurability()
	local d = getDurabilityPercent()
	cache.dura = d
	cache.duraText = d and (d .. "%") or "--"
	updateStatsLine()
end

-- The client only recomputes latency every ~30s, so polling it every second
-- was 29 wasted calls out of 30. fps is read every tick; latency every fifth.
local netTick = 0

local function updatePerf()
	local fps = cache.fps
	if GetFramerate then
		fps = math.floor((GetFramerate() or 0) + 0.5)
	end

	local ms = cache.ms
	netTick = netTick - 1
	if netTick <= 0 then
		netTick = 5
		if GetNetStats then
			local _, _, homeMS, worldMS = GetNetStats()
			ms = (worldMS and worldMS > 0) and worldMS or (homeMS or 0)
		else
			ms = 0
		end
	end

	if fps ~= cache.fps or ms ~= cache.ms then
		cache.fps, cache.ms = fps, ms
		updateStatsLine()
	end
end
MS.UpdatePerf = updatePerf

-- The bottom row. Two modes:
--   manual - show every selected currency, in the game's own tier order
--   auto   - slide a window of N over the unpinned ones, ending at the highest
--            you actually have any of. Pinned entries always show, so things
--            like Radiant Spark Dust don't get chomped by the window.
-- Scratch tables, reused across calls. C_CurrencyInfo.GetCurrencyInfo returns a
-- fresh table per call, so each entry is read exactly once per refresh and the
-- results are held here rather than being queried twice in auto mode.
local showScratch, windowScratch, partsScratch = {}, {}, {}
local qtyScratch, iconScratch, earnedScratch, capScratch = {}, {}, {}, {}

local function wipeArray(t, n)
	for i = 1, n do
		t[i] = nil
	end
end

function MS.UpdateCurrencyLine()
	local opt = MS.GetOptions()
	local sel = opt.currencies
	local count = #sel

	if count == 0 then
		setLine(currFS, "")
		return
	end

	-- single pass: everything the render needs, one API call per entry
	for i = 1, count do
		local qty, _, icon, earned, cap = MS.GetCurrency(sel[i].id)
		qtyScratch[i], iconScratch[i], earnedScratch[i], capScratch[i] = qty, icon, earned, cap
	end

	local show = showScratch
	wipeArray(show, count)

	if opt.autoWindow then
		local windowed = windowScratch
		local wn = 0
		for i = 1, count do
			if sel[i].pin then
				show[i] = true
			else
				wn = wn + 1
				windowed[wn] = i
			end
		end

		if wn > 0 then
			local highest
			for j = 1, wn do
				local qty = qtyScratch[windowed[j]]
				if qty and qty > 0 then
					highest = j
				end
			end
			highest = highest or wn

			local n = opt.autoCount or 3
			if n < 1 then
				n = 1
			elseif n > wn then
				n = wn
			end
			local last = highest
			local first = last - n + 1
			if first < 1 then
				first = 1
				last = n < wn and n or wn
			end
			for j = first, last do
				show[windowed[j]] = true
			end
		end
	else
		for i = 1, count do
			show[i] = true
		end
	end

	local parts = partsScratch
	local pn = 0
	local hideZero, showWeekly = opt.hideZero, opt.showWeekly

	for i = 1, count do
		if show[i] then
			local qty = qtyScratch[i]
			if qty and not (hideZero and qty == 0) then
				local cap, earned = capScratch[i], earnedScratch[i]
				pn = pn + 1
				if showWeekly and cap and earned then
					parts[pn] = string.format(
						"%s%d |cff9d9d9d(%d/%d)|r",
						MS.IconTag(iconScratch[i], CURR_ICON),
						qty,
						earned,
						cap
					)
				else
					parts[pn] = string.format("%s%d", MS.IconTag(iconScratch[i], CURR_ICON), qty)
				end
			end
		end
	end

	if pn == 0 then
		setLine(currFS, "")
	else
		-- concat is bounded to 1..pn, so any stale tail from a longer previous
		-- render is simply not read.
		setLine(currFS, table.concat(parts, "  ", 1, pn))
	end
	wipeArray(qtyScratch, count)
end

-- -------------------------------------------------------------------- mouse

function MS.ApplyMouse()
	if MidnightStatusDB.mouse == nil then
		MidnightStatusDB.mouse = false
	end
	f:EnableMouse(MidnightStatusDB.mouse and true or false)
end

f:SetScript("OnDragStart", function(self)
	if not self.__lemManaged then
		self:StartMoving()
	end
end)

f:SetScript("OnDragStop", function(self)
	if not self.__lemManaged then
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint(1)
		setPos(nil, point, x, y)
	end
end)

f:SetScript("OnMouseUp", function(self, button)
	if button == "RightButton" then
		MS.OpenPicker(self)
	elseif button == "LeftButton" and IsShiftKeyDown and IsShiftKeyDown() then
		if ToggleCharacter then
			ToggleCharacter("TokenFrame")
		end
	end
end)

-- The bar is icons and bare numbers by design. The tooltip is where the names,
-- weekly progress and totals live.
f:SetScript("OnEnter", function(self)
	local sel = MS.GetOptions().currencies
	if not GameTooltip then
		return
	end

	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	GameTooltip:AddLine("MidnightStatus")

	if #sel == 0 then
		GameTooltip:AddLine("No currencies selected.", 0.7, 0.7, 0.7)
	else
		for i = 1, #sel do
			local qty, name, icon, earned, weeklyMax = MS.GetCurrency(sel[i].id)
			if qty then
				local left = MS.IconTag(icon, 14) .. " " .. (name or MS.CurrencyName(sel[i].id))
				if sel[i].pin then
					left = left .. " |cff9d9d9d(pinned)|r"
				end
				local right = tostring(qty)
				if weeklyMax and earned then
					right = string.format("%d  |cff9d9d9d%d/%d this week|r", qty, earned, weeklyMax)
				end
				GameTooltip:AddDoubleLine(left, right, 1, 1, 1, 1, 1, 1)
			end
		end
	end

	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Right-click to configure", 0.6, 0.6, 0.6)
	GameTooltip:AddLine("Shift+left-click for the currency tab", 0.6, 0.6, 0.6)
	GameTooltip:Show()
end)

f:SetScript("OnLeave", function()
	if GameTooltip then
		GameTooltip:Hide()
	end
end)

-- ---------------------------------------------------------------- migration
--
-- v0.7  MidnightStatusDB.layouts[name].showadv/showvet/... booleans, matched
--       against localised currency names.
-- v0.8  MidnightStatusDB.layouts[name].currencies = flat array of numeric IDs.
-- v0.9  same, but array of { id = } tables.
-- v1.0  settings move to MidnightStatusCharDB.settings, positions move to
--       MidnightStatusCharDB.positions keyed by layout name.
--
-- Each character migrates independently from the shared old data, so every alt
-- inherits your old setup exactly once and then goes its own way.

local MIGRATE_NAMES = {
	showadv = { "Adventurer Dawncrest", "Adventurer Mistcrest" },
	showvet = { "Veteran Dawncrest", "Veteran Mistcrest" },
	showchamp = { "Champion Dawncrest", "Champion Mistcrest" },
	showhero = { "Hero Dawncrest", "Hero Mistcrest" },
	showmyth = { "Myth Dawncrest", "Myth Mistcrest" },
}

-- Which old layout table should this character's settings come from? Prefer the
-- active Edit Mode layout, otherwise whichever one actually had a selection.
local function pickSourceLayout()
	local layouts = MidnightStatusDB.layouts
	if not layouts then
		return nil
	end
	if activeLayout and layouts[activeLayout] then
		return layouts[activeLayout]
	end
	local best, bestCount
	for _, L in pairs(layouts) do
		local n = (type(L.currencies) == "table") and #L.currencies or 0
		if not bestCount or n > bestCount then
			best, bestCount = L, n
		end
	end
	return best
end

-- Collapse every older per-layout position into the one shared slot.
--
-- Guarded by explicit flags rather than by probing for the new key, because
-- applyPos() creates that key with defaults the first time the frame is placed,
-- which happens before this runs.
--
-- The two flags are separate on purpose: the character flag governs this
-- character's own old data (kept, in case the position scope is later switched
-- to per-character), and the account flag governs the shared global slot, which
-- the first character to log in seeds.
local function migratePositions()
	local charPositions = MidnightStatusCharDB.positions

	local function pickChar()
		if charPositions then
			if activeLayout and charPositions[activeLayout] then
				return charPositions[activeLayout]
			end
			if charPositions[MANUAL_KEY] then
				return charPositions[MANUAL_KEY]
			end
		end
		if MidnightStatusCharDB.lastPos then
			return MidnightStatusCharDB.lastPos
		end
		if charPositions then
			for _, v in pairs(charPositions) do
				if v.point then
					return v
				end
			end
		end
		return nil
	end

	local function pickAccount()
		-- v0.7 top-level manual drag position
		if MidnightStatusDB.point then
			return { point = MidnightStatusDB.point, x = MidnightStatusDB.x or 0, y = MidnightStatusDB.y or 0 }
		end
		local layouts = MidnightStatusDB.layouts
		if layouts then
			if activeLayout and layouts[activeLayout] and layouts[activeLayout].point then
				return layouts[activeLayout]
			end
			for _, L in pairs(layouts) do
				if L.point then
					return L
				end
			end
		end
		local tpl = MidnightStatusDB.templatePos
		if tpl then
			for _, v in pairs(tpl) do
				if v.point then
					return v
				end
			end
		end
		return nil
	end

	if not MidnightStatusCharDB.__posMigrated then
		MidnightStatusCharDB.__posMigrated = true
		local src = pickChar()
		if src and src.point and not MidnightStatusCharDB.position then
			MidnightStatusCharDB.position = { point = src.point, x = src.x or 0, y = src.y or 0 }
		end
		MidnightStatusCharDB.positions = nil
		MidnightStatusCharDB.lastPos = nil
	end

	if not MidnightStatusDB.__posMigrated then
		MidnightStatusDB.__posMigrated = true
		local src = MidnightStatusCharDB.position or pickAccount()
		if src and src.point then
			MidnightStatusDB.position = { point = src.point, x = src.x or 0, y = src.y or 0 }
		end
		MidnightStatusDB.templatePos = nil
	end
end

-- Returns true when settings are settled. Returns false if it needs the
-- currency list and the client hasn't populated it yet, so the caller retries.
local function migrateSettings()
	local s = getSettings()
	if s.__migrated then
		return true
	end

	if #s.currencies > 0 then
		s.__migrated = true
		saveTemplate()
		return true
	end

	local src = pickSourceLayout()
	if not src then
		s.__migrated = true
		return true
	end

	for k in pairs(SETTING_DEFAULTS) do
		if src[k] ~= nil then
			s[k] = src[k]
		end
	end

	-- v0.8 / v0.9 selection
	if type(src.currencies) == "table" and #src.currencies > 0 then
		for i = 1, #src.currencies do
			local e = src.currencies[i]
			local id = (type(e) == "table") and e.id or e
			if id then
				local added = MS.AddCurrency(s, id)
				if added and type(e) == "table" and e.pin then
					added.pin = true
				end
			end
		end
		s.__migrated = true
		saveTemplate()
		return true
	end

	-- v0.7 booleans need a real scan to resolve names to IDs
	local hasOldFlags = false
	for k in pairs(MIGRATE_NAMES) do
		if src[k] ~= nil then
			hasOldFlags = true
			break
		end
	end
	if not hasOldFlags then
		s.__migrated = true
		return true
	end

	local list = MS.ScanCurrencies()
	if #list == 0 then
		return false -- currency data not ready; retry
	end

	local order = { "showadv", "showvet", "showchamp", "showhero", "showmyth" }
	for i = 1, #order do
		local key = order[i]
		if src[key] ~= false then -- nil or true both meant "show"
			for _, wanted in ipairs(MIGRATE_NAMES[key]) do
				for j = 1, #list do
					if list[j].name == wanted then
						MS.AddCurrency(s, list[j].id)
						break
					end
				end
			end
		end
	end

	s.__migrated = true
	saveTemplate()
	return true
end

-- ----------------------------------------------------------- LibEditMode glue

local function setupLibEditMode()
	if not LibStub then
		return
	end
	local ok, LEM = pcall(LibStub, "LibEditMode", true)
	if not ok or not LEM then
		return
	end

	LEM:RegisterCallback("layout", function(layoutName)
		activeLayout = layoutName
		applyPos()
		MS.UpdateCurrencyLine()
	end)

	pcall(LEM.RegisterCallback, LEM, "enter", function()
		f:EnableMouse(true)
	end)
	pcall(LEM.RegisterCallback, LEM, "exit", function()
		MS.ApplyMouse()
	end)

	LEM:AddFrame(f, function(_, layoutName, point, x, y)
		setPos(layoutName, point, x, y)
	end, DEFAULT_POS)

	if not (LEM.AddFrameSettings and LEM.SettingType) then
		f.__lemManaged = true
		return
	end

	local Checkbox = LEM.SettingType.Checkbox or LEM.SettingType.Toggle
	local Button = LEM.SettingType.Button
	local settings = {}

	local function boolSetting(name, get, set)
		settings[#settings + 1] = {
			name = name,
			kind = Checkbox,
			default = false,
			get = get,
			set = set,
		}
	end

	if Checkbox then
		boolSetting("24-hour time", function()
			return MS.Is24Hour()
		end, function(_, v)
			MidnightStatusDB.use24HourTime = not not v
			MS.Invalidate()
			MS.UpdateTimeLine()
		end)

		boolSetting("Auto: follow highest tier", function()
			return getSettings().autoWindow
		end, function(_, v)
			getSettings().autoWindow = not not v
			saveTemplate()
			MS.UpdateCurrencyLine()
		end)

		boolSetting("Hide currencies at zero", function()
			return getSettings().hideZero
		end, function(_, v)
			getSettings().hideZero = not not v
			saveTemplate()
			MS.UpdateCurrencyLine()
		end)

		boolSetting("Show weekly earned / cap", function()
			return getSettings().showWeekly
		end, function(_, v)
			getSettings().showWeekly = not not v
			saveTemplate()
			MS.UpdateCurrencyLine()
		end)

		boolSetting("Same position on every character", function()
			return MS.GetPosScope() == "global"
		end, function(_, v)
			MS.SetPosScope(v and "global" or "character")
		end)

		boolSetting("Frame accepts mouse", function()
			return MidnightStatusDB.mouse and true or false
		end, function(_, v)
			MidnightStatusDB.mouse = not not v
			MS.ApplyMouse()
		end)
	end

	if LEM.SettingType.Slider then
		settings[#settings + 1] = {
			name = "Window size",
			kind = LEM.SettingType.Slider,
			default = 3,
			minValue = 1,
			maxValue = 7,
			valueStep = 1,
			get = function()
				return getSettings().autoCount or 3
			end,
			set = function(_, v)
				getSettings().autoCount = math.floor(tonumber(v) or 3)
				saveTemplate()
				MS.UpdateCurrencyLine()
			end,
		}
	end

	if Button then
		settings[#settings + 1] = {
			name = "Choose currencies...",
			kind = Button,
			click = function()
				MS.OpenPicker(f)
			end,
		}
	end

	if #settings > 0 then
		pcall(LEM.AddFrameSettings, LEM, f, settings)
	end

	f.__lemManaged = true
end

-- ------------------------------------------------------------------- events

-- CURRENCY_DISPLAY_UPDATE arrives in bursts; coalesce into one refresh.
local currencyPending = false
local function queueCurrencyUpdate()
	if currencyPending then
		return
	end
	currencyPending = true
	C_Timer.After(0.2, function()
		currencyPending = false
		MS.UpdateCurrencyLine()
	end)
end

-- PLAYER_EQUIPMENT_CHANGED fires once per slot, so a full gear swap or a
-- weapon swap mid-combat can burst a dozen times. Each one would otherwise walk
-- ten inventory slots and rebuild the stats line.
local duraPending = false
local function queueDurabilityUpdate()
	if duraPending then
		return
	end
	duraPending = true
	C_Timer.After(0.5, function()
		duraPending = false
		updateDurability()
	end)
end

local DURABILITY_EVENTS = {
	UPDATE_INVENTORY_DURABILITY = true,
	PLAYER_EQUIPMENT_CHANGED = true,
	UPDATE_INVENTORY_ALERTS = true,
}

-- Wait for LibEditMode to hand us a layout name before touching the DB, so we
-- don't leave an orphan "__default" layout behind for LEM users. Retries a few
-- times, then gives up and uses the fallback layout.
local function deferredInit(attempt)
	attempt = attempt or 1

	-- Wait for LibEditMode to name the active layout before deciding which old
	-- layout to migrate settings from.
	if f.__lemManaged and not activeLayout and attempt < 6 then
		C_Timer.After(1, function()
			deferredInit(attempt + 1)
		end)
		return
	end

	-- Always scan, even when there is nothing to migrate. Without this, a fresh
	-- install has no list order to sort against and /ms add lands out of order.
	MS.ScanCurrencies()

	local done = migrateSettings()
	MS.SortSelection(MS.GetOptions())
	if not done and attempt < 6 then
		C_Timer.After(1, function()
			deferredInit(attempt + 1)
		end)
	end

	MS.UpdateCurrencyLine()

	if done and #MS.GetOptions().currencies == 0 and not MidnightStatusCharDB.hinted then
		MidnightStatusCharDB.hinted = true
		print("|cff8080ffMidnightStatus|r: no currencies picked yet. Type /ms to choose some.")
	end
end

local booted = false

f:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
		if not booted then
			booted = true
			classColorDone = refreshClassColor()
			MS.ApplyMouse()
			-- before anything reads or creates a position
			migratePositions()
			setupLibEditMode()

			if not f.__lemManaged then
				applyPos()
			end

			C_Timer.After(1, function()
				deferredInit(1)
			end)
		end

		MS.UpdateTimeLine()
		updateLoot()
		updateDurability()
		updateGoldLine()
		updatePerf()
		MS.UpdateCurrencyLine()
	elseif event == "PLAYER_MONEY" then
		updateGoldLine()
	elseif MS.IsSpecEvent and MS.IsSpecEvent(event) then
		updateLoot()
	elseif DURABILITY_EVENTS[event] then
		queueDurabilityUpdate()
	elseif event == "CURRENCY_DISPLAY_UPDATE" then
		queueCurrencyUpdate()
	end
end)

-- RegisterEvent throws on an event name the client doesn't know, which on a new
-- flavor would abort the rest of this block and silently half-start the addon.
-- Each one is registered on its own so a missing event costs only itself.
local function tryRegister(event)
	return pcall(f.RegisterEvent, f, event)
end

tryRegister("PLAYER_LOGIN")
tryRegister("PLAYER_ENTERING_WORLD")
tryRegister("PLAYER_MONEY")
tryRegister("CURRENCY_DISPLAY_UPDATE")
for event in pairs(DURABILITY_EVENTS) do
	tryRegister(event)
end
if MS.RegisterSpecEvents then
	MS.RegisterSpecEvents(f)
end

-- One ticker, not two. While the frame is not visible — UI hidden with Alt+Z,
-- a cinematic, a loading screen, a pet battle — there is nothing on screen to
-- update, so the tick costs a single IsVisible call and returns.
local wasVisible = true

C_Timer.NewTicker(1, function()
	if not f:IsVisible() then
		wasVisible = false
		return
	end
	if not wasVisible then
		-- Coming back from hidden: caches may be stale, so force a full rebuild.
		wasVisible = true
		MS.Invalidate()
		updateGoldLine()
		MS.UpdateCurrencyLine()
	end
	if not classColorDone then
		classColorDone = refreshClassColor()
	end
	MS.UpdateTimeLine()
	updatePerf()
end)

-- -------------------------------------------------------------------- slash

local function msg(text)
	print("|cff8080ffMidnightStatus|r: " .. text)
end

SLASH_MIDNIGHTSTATUS1 = "/ms"
SLASH_MIDNIGHTSTATUS2 = "/midnightstatus"
SlashCmdList.MIDNIGHTSTATUS = function(input)
	input = string.gsub(input or "", "^%s*(.-)%s*$", "%1")
	local cmd, rest = string.match(input, "^(%S*)%s*(.*)$")
	cmd = string.lower(cmd or "")

	if cmd == "" or cmd == "config" then
		MS.OpenPicker(f)
	elseif cmd == "add" or cmd == "remove" then
		local id = MS.ParseCurrencyID(rest)
		if not id then
			msg("usage: /ms " .. cmd .. " <currency id or shift-clicked currency link>")
			return
		end
		local opt = MS.GetOptions()
		if cmd == "add" then
			if MS.AddCurrency(opt, id) then
				msg("added " .. MS.CurrencyName(id))
			else
				msg(MS.CurrencyName(id) .. " is already shown")
			end
		else
			msg(MS.RemoveCurrency(opt, id) and ("removed " .. MS.CurrencyName(id)) or "not currently shown")
		end
		MS.SaveTemplate()
		MS.UpdateCurrencyLine()
	elseif cmd == "mouse" then
		MidnightStatusDB.mouse = not MidnightStatusDB.mouse
		MS.ApplyMouse()
		msg("mouse " .. (MidnightStatusDB.mouse and "on" or "off"))
	elseif cmd == "12" or cmd == "24" then
		MidnightStatusDB.use24HourTime = (cmd == "24")
		MS.Invalidate()
		MS.UpdateTimeLine()
	elseif cmd == "reset" then
		setPos(nil, DEFAULT_POS.point, DEFAULT_POS.x, DEFAULT_POS.y)
		applyPos()
		msg("position reset (" .. MS.GetPosScope() .. ")")
	elseif cmd == "scope" then
		local p = getPos()
		msg("currency selection and display options: per character")
		print(string.format("  position: %s  (%s %d,%d)", MS.GetPosScope(), p.point, p.x or 0, p.y or 0))
		print("  shared across every Edit Mode layout, so swapping spec never moves it")
		print("  change with /ms posscope global|character")
	elseif cmd == "posscope" then
		local want = string.lower(rest or "")
		if MS.SetPosScope(want) then
			msg("position is now " .. want .. (want == "global" and " (same on every character)" or " (this character only)"))
		else
			msg("usage: /ms posscope global|character   (currently " .. MS.GetPosScope() .. ")")
		end
	elseif cmd == "scan" then
		local list = MS.ScanCurrencies()
		MS.SortSelection(MS.GetOptions())
		msg("found " .. #list .. " currencies")
		for i = 1, #list do
			print(string.format("  [%d] %s (%s)", list[i].id, list[i].name or "?", list[i].header or "-"))
		end
	elseif cmd == "list" then
		local sel = MS.GetOptions().currencies
		msg("showing " .. #sel .. " currencies")
		for i = 1, #sel do
			print(string.format("  %d. [%d] %s%s", i, sel[i].id, MS.CurrencyName(sel[i].id), sel[i].pin and "  (pinned)" or ""))
		end
	else
		msg("/ms | add <id> | remove <id> | list | scan | scope | posscope | mouse | 12 | 24 | reset")
	end
end
