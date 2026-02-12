-- MidnightStatus.lua
-- Stacked HUD: Big Time, small sys stats line, gold line
-- Tried to make this straight forward enough to now implode anyones games.
-- Made with love, will def be adding more stuff as time goes on

local ADDON = ...
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
f:SetSize(300, 70)

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
	local lootSpecID = GetLootSpecialization()
	if lootSpecID and lootSpecID ~= 0 then
		local _, name, _, icon = GetSpecializationInfoForSpecID(lootSpecID)
		return name or ("SpecID " .. lootSpecID), icon
	end

	local curIndex = GetSpecialization()
	if curIndex then
		local _, name, _, icon = GetSpecializationInfo(curIndex)
		return name or "Current", icon
	end

	return "None", nil
end

local function format24hTime()
	return date("%H:%M")
end

local function formatCompactGold(copper)
	local g = math.floor(copper / 10000)
	local s = math.floor((copper % 10000) / 100)
	local c = copper % 100

	local goldText

	if g >= 1000000 then
		goldText = string.format("%.2fm", g / 1000000)
	elseif g >= 1000 then
		goldText = string.format("%.0fk", g / 1000)
	else
		goldText = tostring(g)
	end

	return string.format("%sg %ds %dc", goldText, s, c)
end

local function getLootSpecName()
	local lootSpecID = GetLootSpecialization()
	if lootSpecID and lootSpecID ~= 0 then
		local _, name = GetSpecializationInfoForSpecID(lootSpecID)
		return name or ("SpecID " .. lootSpecID)
	end
	local curIndex = GetSpecialization()
	if curIndex then
		local _, name = GetSpecializationInfo(curIndex)
		return name or "Current"
	end
	return "None"
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

-- -------- targeted updates (avoid rebuilding everything)

local CLASS_COLOR = "FFFFFFFF" -- fallback white ARGB
do
	local _, classFile = UnitClass("player")
	local c = classFile and RAID_CLASS_COLORS[classFile]
	if c then
		CLASS_COLOR = string.format("FF%02X%02X%02X", c.r * 255, c.g * 255, c.b * 255)
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
	lootIcon = nil,
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

local function updateTimeLine()
	setIfChanged(timeFS, cc(format24hTime()), "time")
end

local function updateStatsLine()
	local duraText = cache.dura and (cache.dura .. "%") or "--"
	-- Layout: "###fps  ##ms  loot  dura" (tight like your screenshot)
	local text = string.format("%dfps %dms %s %s", cache.fps, cache.ms, icon, cache.loot, duraText)
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
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_LOOT_SPEC_UPDATED" then
		updateLoot()
	elseif
		event == "UPDATE_INVENTORY_DURABILITY"
		or event == "PLAYER_EQUIPMENT_CHANGED"
		or event == "UPDATE_INVENTORY_ALERTS"
	then
		updateDurability()
	end
end)

f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_MONEY")
f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
f:RegisterEvent("PLAYER_LOOT_SPEC_UPDATED")
f:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
f:RegisterEvent("UPDATE_INVENTORY_ALERTS")
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

-- Tick only what must tick:
-- time (1s) and fps/ms (0.5s). These update ONLY their own lines.
C_Timer.NewTicker(1, updateTimeLine)
C_Timer.NewTicker(0.5, updatePerf)
