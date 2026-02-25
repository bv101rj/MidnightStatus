-- MidnightStatus.lua
-- Stacked HUD: Big Time, small sys stats line, gold line
-- Tried to make this straight forward enough to now implode anyones games.
-- Made with love, will def be adding more stuff as time goes on

local addonName, MS = ...
MS = MS or {}
MidnightStatusDB = MidnightStatusDB or {}

local f = CreateFrame("Frame", "MidnightStatusFrame", UIParent)
f:SetClampedToScreen(true)
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", function(self)
	if not self.__lemManaged then
		self:StartMoving()
	end
end)
f:SetScript("OnDragStop", function(self)
	if not self.__lemManaged then
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint(1)
		MidnightStatusDB.point, MidnightStatusDB.x, MidnightStatusDB.y = point, x, y
	end
end)

-- Click area (no backdrop)
f:SetSize(300, 90)

-- Fonts (no background, just text)
local FONT = STANDARD_TEXT_FONT

local timeFS = f:CreateFontString(nil, "OVERLAY")
timeFS:SetPoint("TOP", f, "TOP", 0, -2)
timeFS:SetJustifyH("CENTER")
timeFS:SetFont(FONT, 28, "OUTLINE")

local statsFS = f:CreateFontString(nil, "OVERLAY")
statsFS:SetPoint("TOP", timeFS, "BOTTOM", 0, -2)
statsFS:SetJustifyH("CENTER")
statsFS:SetFont(FONT, 14, "OUTLINE")

local goldFS = f:CreateFontString(nil, "OVERLAY")
goldFS:SetPoint("TOP", statsFS, "BOTTOM", 0, -2)
goldFS:SetJustifyH("CENTER")
goldFS:SetFont(FONT, 14, "OUTLINE")

local crestFS = f:CreateFontString(nil, "OVERLAY")
crestFS:SetPoint("TOP", goldFS, "BOTTOM", 0, -2)
crestFS:SetJustifyH("CENTER")
crestFS:SetFont(FONT, 14, "OUTLINE")

-- -------- helpers

local function specIconTag(icon, size)
	if not icon then
		return ""
	end
	size = size or 14
	-- Tight crop so it looks crisp in a HUD line
	return string.format("|T%s:%d:%d:0:0:64:64:4:60:4:60|t", icon, size, size)
end

local function getLootSpecNameAndIcon()
	if MS and type(MS.GetSpecNameAndIcon) == "function" then
		return MS.GetSpecNameAndIcon()
	end
	-- fallback: show nothing rather than erroring
	return "None", nil
end

local function format24hTime()
	return date("%H:%M")
end

local function format12hTime()
	local h = tonumber(date("%I")) or 12
	return string.format("%d:%s %s", h, date("%M"), date("%p"))
end

local function is24HourEnabled()
	if MidnightStatusDB.use24HourTime == nil then
		MidnightStatusDB.use24HourTime = true -- preserve existing behavior
	end
	return MidnightStatusDB.use24HourTime
end

-- Call deez icons so we can use them later
local COIN_SIZE = 14
local GOLD_ICON = string.format("|TInterface\\MoneyFrame\\UI-GoldIcon:%d:%d:0:0|t", COIN_SIZE, COIN_SIZE)
local SILVER_ICON = string.format("|TInterface\\MoneyFrame\\UI-SilverIcon:%d:%d:0:0|t", COIN_SIZE, COIN_SIZE)
local COPPER_ICON = string.format("|TInterface\\MoneyFrame\\UI-CopperIcon:%d:%d:0:0|t", COIN_SIZE, COIN_SIZE)

local function formatCompactGold(copper)
	local g = math.floor(copper / 10000)
	local s = math.floor((copper % 10000) / 100)
	local c = copper % 100

	local goldText

	if g >= 1000000 then
		-- Truncate (don't round up) to 2 decimals, e.g. 3,299,999g -> 3.29m
		local whole = math.floor(g / 1000000)
		local frac = math.floor((g % 1000000) / 10000) -- 2 decimals
		goldText = string.format("%d.%02dm", whole, frac)
	elseif g >= 1000 then
		-- Truncate (don't round up) to 1 decimal, e.g. 3,999g -> 3.9k
		local whole = math.floor(g / 1000)
		local frac = math.floor((g % 1000) / 100) -- 1 decimal
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

local function getDurabilityPercent()
	local lowest

	for i = 1, #DURABILITY_SLOTS do
		local slot = DURABILITY_SLOTS[i]
		local cur, max = GetInventoryItemDurability(slot) -- 1-arg only on your client

		if cur and max and max > 0 then
			local p = (cur / max) * 100
			if not lowest or p < lowest then
				lowest = p
			end
		end
	end

	if not lowest then
		return nil
	end
	return math.floor(lowest + 0.5)
end

local function inlineicon(icon, size)
	if not icon then
		return ""
	end
	size = size or 14
	return string.format("|T%s:%d:%d:0:0|t", icon, size, size)
end

local CREST_NAMES = {
	adventurer = "Adventurer Dawncrest",
	veteran = "Veteran Dawncrest",
	champion = "Champion Dawncrest",
	hero = "Hero Dawncrest",
	myth = "Myth Dawncrest",
}

-- wait let me cook
local crestsize = 14

-- brazy style cache?
local crestIndex = {
	adventurer = nil,
	veteran = nil,
	champion = nil,
	hero = nil,
	myth = nil,
}

local function getCurrencyListSize()
	return (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize and C_CurrencyInfo.GetCurrencyListSize())
		or (GetCurrencyListSize and GetCurrencyListSize())
		or 0
end

local function getCurrencyListInfo(i)
	-- Prefer modern table API, fall back to legacy tuple API if present
	if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListInfo then
		local info = C_CurrencyInfo.GetCurrencyListInfo(i)
		if info then
			local name = info.name
			local isHeader = info.isHeader
			-- quantity field names vary by client; handle a few common ones
			local qty = info.quantity or info.count or info.quantityEarned or info.amountr or 0
			local icon = info.iconfileid or info.icon
			return name, isHeader, qty, icon
		end
	end

	if GetCurrencyListInfo then
		-- legacy: name, isHeader, isExpanded, isUnused, isWatched, count, ..., icon, itemID
		local name, isHeader, _, _, _, count, _, _, _, _, icon = GetCurrencyListInfo(i)
		return name, isHeader, count
	end

	return nil, nil, nil, nil
end

local crestIconTag = {
	adventurer = "",
	veteran = "",
	champion = "",
	hero = "",
	myth = "",
}

local function resolveCrestIndices()
	local size = getCurrencyListSize()
	if size <= 0 then
		return
	end

	-- Only scan for missing ones
	for key, targetName in pairs(CREST_NAMES) do
		if not crestIndex[key] then
			for i = 1, size do
				local name, isHeader, _, icon = getCurrencyListInfo(i)
				if name == targetName and not isHeader then
					crestIndex[key] = i
					crestIconTag[key] = inlineicon(icon, 14)
					break
				end
			end
		end
	end
end

local function getCrestCount(key)
	local idx = crestIndex[key]
	if not idx then
		return nil
	end
	local name, isHeader, qty = getCurrencyListInfo(idx)
	if isHeader then
		return nil
	end
	if name ~= CREST_NAMES[key] then
		-- currency list shifted; force re-resolve
		crestIndex[key] = nil
		return nil
	end
	return qty
end

-- -------- targeted updates (avoid rebuilding everything)

local CLASS_COLOR = "FFFFFFFF" -- fallback white ARGB
do
	local _, classFile = UnitClass("player")
	local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
	if c then
		CLASS_COLOR = string.format(
			"FF%02X%02X%02X",
			math.floor(c.r * 255 + 0.5),
			math.floor(c.g * 255 + 0.5),
			math.floor(c.b * 255 + 0.5)
		)
	end
end

local function cc(text)
	return "|c" .. CLASS_COLOR .. text .. "|r"
end

local cache = {
	time = "",
	stats = "",
	gold = "",
	loot = "None",
	crest = "",
	dura = nil,
	fps = 0,
	ms = 0,
}

local function setIfChanged(fs, newText, key)
	if cache[key] ~= newText then
		cache[key] = newText
		fs:SetText(newText)
	end
end

local function updateCrestLine()
	resolveCrestIndices()
	local a = getCrestCount("adventurer") or 0
	local v = getCrestCount("veteran") or 0
	local champ = getCrestCount("champion") or 0
	local h = getCrestCount("hero") or 0
	local m = getCrestCount("myth") or 0

	local text = string.format(
		"%s%d %s%d %s%d %s%d %s%d",
		crestIconTag.adventurer or "A:",
		a,
		crestIconTag.veteran or "V:",
		v,
		crestIconTag.champion or "C:",
		champ,
		crestIconTag.hero or "H:",
		h,
		crestIconTag.myth or "M:",
		m
	)
	setIfChanged(crestFS, cc(text), "crest")
end

local function updateTimeLine()
	local t = is24HourEnabled() and format24hTime() or format12hTime()
	setIfChanged(timeFS, cc(t), "time")
end

local function updateStatsLine()
	local duraText = cache.dura and (cache.dura .. "%") or "--"

	local parts = {
		format("%dfps", cache.fps or 0),
		format("%dms", cache.ms or 0),
	}

	-- Compat.lua returns "" on Classic (user requested no talents/spec there).
	if cache.lootIcon then
		table.insert(parts, specIconTag(cache.lootIcon, 14) .. (cache.loot or ""))
	elseif cache.loot and cache.loot ~= "" then
		table.insert(parts, cache.loot)
	end

	table.insert(parts, duraText)

	local text = table.concat(parts, " ")
	setIfChanged(statsFS, cc(text), "stats")
end

local function updateGoldLine()
	local money = GetMoney() or 0
	setIfChanged(goldFS, cc(formatCompactGold(money)), "gold")
end

local function updateLoot()
	cache.loot, cache.lootIcon = getLootSpecNameAndIcon()
	updateStatsLine()
end

local function updateDurability()
	cache.dura = getDurabilityPercent()
	updateStatsLine()
end

local function getFpsAndMs()
	local fps = GetFramerate() or 0
	local _, _, homeMS, worldMS = GetNetStats()
	local ms = worldMS or homeMS or 0
	return math.floor(fps + 0.5), ms
end

local function updatePerf()
	cache.fps, cache.ms = getFpsAndMs()
	updateStatsLine()
end

-- -------- LibEditMode (installed dependency)

local function setupLibEditMode()
	if not LibStub then
		return
	end
	local ok, LEM = pcall(LibStub, "LibEditMode")
	if not ok or not LEM then
		return
	end

	local defaultPos = { point = "TOP", x = 0, y = -80 }

	LEM:RegisterCallback("layout", function(layoutName)
		MidnightStatusDB.layouts = MidnightStatusDB.layouts or {}
		MidnightStatusDB.layouts[layoutName] = MidnightStatusDB.layouts[layoutName]
			or {
				point = defaultPos.point,
				x = defaultPos.x,
				y = defaultPos.y,
			}

		local p = MidnightStatusDB.layouts[layoutName]
		f:ClearAllPoints()
		f:SetPoint(p.point, UIParent, p.point, p.x, p.y)
	end)

	local function onPositionChanged(_, layoutName, point, x, y)
		MidnightStatusDB.layouts = MidnightStatusDB.layouts or {}
		MidnightStatusDB.layouts[layoutName] = MidnightStatusDB.layouts[layoutName] or {}
		local p = MidnightStatusDB.layouts[layoutName]
		p.point, p.x, p.y = point, x, y
	end

	LEM:AddFrame(f, onPositionChanged, defaultPos)

	-- Optional extra Edit Mode settings (works on some backports too)
	if LEM.AddFrameSettings and LEM.SettingType then
		local checkboxKind = LEM.SettingType.Checkbox or LEM.SettingType.Toggle
		if checkboxKind then
			LEM:AddFrameSettings(f, {
				{
					name = "24-hour time",
					kind = checkboxKind,
					default = true,
					get = function(_layoutName)
						return is24HourEnabled()
					end,
					set = function(_layoutName, value)
						MidnightStatusDB.use24HourTime = not not value
						updateTimeLine()
					end,
				},
			})
		end
	end

	f.__lemManaged = true
end

-- -------- events

f:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_ENTERING_WORLD" then
		setupLibEditMode()

		updateTimeLine()
		updateLoot()
		updateDurability()
		updateGoldLine()
		updatePerf()

		-- fallback position if LEM isn't managing it
		if not f.__lemManaged then
			local point = MidnightStatusDB.point or "TOP"
			local x = MidnightStatusDB.x or 0
			local y = MidnightStatusDB.y or -80
			f:ClearAllPoints()
			f:SetPoint(point, UIParent, point, x, y)
		end
	elseif event == "PLAYER_MONEY" then
		updateGoldLine()
	elseif
		(MS and type(MS.IsSpecEvent) == "function" and MS.IsSpecEvent(event))
		or event == "PLAYER_SPECIALIZATION_CHANGED"
		or event == "PLAYER_LOOT_SPEC_UPDATED"
		or event == "PLAYER_TALENT_UPDATE"
		or event == "CHARACTER_POINTS_CHANGED"
		or event == "ACTIVE_TALENT_GROUP_CHANGED"
		or event == "PLAYER_LEVEL_UP"
	then
		updateLoot()
	elseif
		event == "UPDATE_INVENTORY_DURABILITY"
		or event == "PLAYER_EQUIPMENT_CHANGED"
		or event == "UPDATE_INVENTORY_ALERTS"
	then
		updateDurability()
	elseif event == "CURRENCY_DISPLAY_UPDATE" then
		updateCrestLine()
	end
end)

f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_MONEY")
if MS and type(MS.RegisterSpecEvents) == "function" then
	MS.RegisterSpecEvents(f)
else
	f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	f:RegisterEvent("PLAYER_LOOT_SPEC_UPDATED")
	f:RegisterEvent("PLAYER_TALENT_UPDATE")
	f:RegisterEvent("CHARACTER_POINTS_CHANGED")
	f:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
	f:RegisterEvent("PLAYER_LEVEL_UP")
end
f:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
f:RegisterEvent("UPDATE_INVENTORY_ALERTS")
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
f:RegisterEvent("CURRENCY_DISPLAY_UPDATE")

-- Tick only what must tick:
-- time (1s) and fps/ms (0.5s). These update ONLY their own lines.
C_Timer.NewTicker(1, updateTimeLine)
C_Timer.NewTicker(0.5, updatePerf)
