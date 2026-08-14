-- MidnightStatus.lua
-- Stacked HUD: big clock, small sys-stats line, gold line, currency line.
-- KISS: no OnUpdate anywhere. Two 1-second tickers, everything else event driven.

local addonName, MS = ...

MidnightStatusDB = MidnightStatusDB or {}

-- ------------------------------------------------------------------ options

local DEFAULT_POS = { point = "TOP", x = 0, y = -80 }

local LAYOUT_DEFAULTS = {
	point = DEFAULT_POS.point,
	x = DEFAULT_POS.x,
	y = DEFAULT_POS.y,
	autoWindow = false,
	autoCount = 3,
	hideZero = false,
	showWeekly = false,
}

local function applyDefaults(t)
	for k, v in pairs(LAYOUT_DEFAULTS) do
		if t[k] == nil then
			t[k] = v
		end
	end
	t.currencies = t.currencies or {}
	-- v0.8 stored bare numbers here. Normalise on every read so no caller can
	-- ever see a malformed entry, whatever order things initialise in.
	for i = 1, #t.currencies do
		if type(t.currencies[i]) == "number" then
			t.currencies[i] = { id = t.currencies[i] }
		end
	end
	return t
end

local activeLayout = nil

-- Used only in the window between "LibEditMode is managing us" and "LibEditMode
-- has told us which layout is active". Deliberately not written to the DB, so
-- LEM users don't accumulate an orphan __default layout.
local scratchLayout = {}

-- Never returns nil, so a settings callback can't index a missing layout.
local function getLayout(name)
	name = name or activeLayout
	if not name then
		if MS.frame and MS.frame.__lemManaged then
			return applyDefaults(scratchLayout)
		end
		name = "__default"
	end
	MidnightStatusDB.layouts = MidnightStatusDB.layouts or {}
	MidnightStatusDB.layouts[name] = MidnightStatusDB.layouts[name] or {}
	return applyDefaults(MidnightStatusDB.layouts[name])
end

function MS.GetOptions()
	return getLayout(activeLayout)
end

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

local lastMask, lastW, lastH = nil, 0, 0

local function relayout()
	-- Build the whole visibility mask first, so the re-anchor test compares a
	-- complete mask against a complete mask.
	local mask = ""
	for i = 1, #LINES do
		mask = mask .. (LINES[i].msText ~= "" and "1" or "0")
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
			end
			fs:Show()
			prev = fs
			h = h + fs.msSize + GAP
			local sw = fs:GetStringWidth() or 0
			if sw > w then
				w = sw
			end
		else
			fs:Hide()
		end
	end

	w = math.max(w + PAD * 2, 60)
	h = math.max(h + PAD * 2, 20)
	if math.abs(w - lastW) > 1 or math.abs(h - lastH) > 1 then
		lastW, lastH = w, h
		f:SetSize(w, h)
	end
end

-- ------------------------------------------------------------------- colour

local CLASS_COLOR = "FFFFFFFF"

local function refreshClassColor()
	local _, classFile = UnitClass("player")
	if not classFile then
		return
	end
	local c
	if C_ClassColor and C_ClassColor.GetClassColor then
		c = C_ClassColor.GetClassColor(classFile)
	end
	c = c or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile])
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
	if text == "" then
		return ""
	end
	return "|c" .. CLASS_COLOR .. text .. "|r"
end

local function setLine(fs, text)
	if fs.msText ~= text then
		fs.msText = text
		fs:SetText(text)
		relayout()
	end
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

local function getDurabilityPercent()
	local lowest
	for i = 1, #DURABILITY_SLOTS do
		local slot = DURABILITY_SLOTS[i]
		if slot then
			local cur, max = GetInventoryItemDurability(slot)
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
	dura = nil,
	fps = -1,
	ms = -1,
}

-- ------------------------------------------------------------------ updates

function MS.UpdateTimeLine()
	local t
	if MS.Is24Hour() then
		t = date("%H:%M")
	else
		local h = tonumber(date("%I")) or 12
		t = string.format("%d:%s %s", h, date("%M"), date("%p"))
	end
	setLine(timeFS, cc(t))
end

local function updateStatsLine()
	local parts = {
		string.format("%dfps", cache.fps < 0 and 0 or cache.fps),
		string.format("%dms", cache.ms < 0 and 0 or cache.ms),
	}
	if cache.lootIcon then
		parts[#parts + 1] = specIconTag(cache.lootIcon, 14) .. (cache.loot or "")
	elseif cache.loot and cache.loot ~= "" then
		parts[#parts + 1] = cache.loot
	end
	parts[#parts + 1] = cache.dura and (cache.dura .. "%") or "--"

	setLine(statsFS, cc(table.concat(parts, " ")))
end

local function updateGoldLine()
	setLine(goldFS, cc(formatCompactGold(GetMoney and GetMoney() or 0)))
end

local function updateLoot()
	if MS.GetSpecNameAndIcon then
		cache.loot, cache.lootIcon = MS.GetSpecNameAndIcon()
	end
	updateStatsLine()
end

local function updateDurability()
	cache.dura = getDurabilityPercent()
	updateStatsLine()
end

local function updatePerf()
	local fps = math.floor((GetFramerate() or 0) + 0.5)
	local _, _, homeMS, worldMS = GetNetStats()
	local ms = (worldMS and worldMS > 0) and worldMS or (homeMS or 0)
	if fps ~= cache.fps or ms ~= cache.ms then
		cache.fps, cache.ms = fps, ms
		updateStatsLine()
	end
end

-- The bottom row. Two modes:
--   manual - show every selected currency, in the game's own tier order
--   auto   - slide a window of N over the unpinned ones, ending at the highest
--            you actually have any of. Pinned entries always show, so things
--            like Radiant Spark Dust don't get chomped by the window.
function MS.UpdateCurrencyLine()
	local opt = MS.GetOptions()
	local sel = opt.currencies

	if #sel == 0 then
		setLine(currFS, "")
		return
	end

	local show = {}

	if opt.autoWindow then
		local windowed = {}
		for i = 1, #sel do
			if sel[i].pin then
				show[i] = true
			else
				windowed[#windowed + 1] = i
			end
		end

		if #windowed > 0 then
			local highest
			for j = 1, #windowed do
				local qty = MS.GetCurrency(sel[windowed[j]].id)
				if qty and qty > 0 then
					highest = j
				end
			end
			highest = highest or #windowed

			local n = math.max(1, math.min(opt.autoCount or 3, #windowed))
			local last = highest
			local first = last - n + 1
			if first < 1 then
				first = 1
				last = math.min(#windowed, n)
			end
			for j = first, last do
				show[windowed[j]] = true
			end
		end
	else
		for i = 1, #sel do
			show[i] = true
		end
	end

	local parts = {}
	for i = 1, #sel do
		if show[i] then
			local qty, _, icon, earned, weeklyMax = MS.GetCurrency(sel[i].id)
			if qty and not (opt.hideZero and qty == 0) then
				if opt.showWeekly and weeklyMax and earned then
					parts[#parts + 1] =
						string.format("%s%d |cff9d9d9d(%d/%d)|r", MS.IconTag(icon, 14), qty, earned, weeklyMax)
				else
					parts[#parts + 1] = string.format("%s%d", MS.IconTag(icon, 14), qty)
				end
			end
		end
	end

	setLine(currFS, #parts > 0 and cc(table.concat(parts, "  ")) or "")
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
		MidnightStatusDB.point, MidnightStatusDB.x, MidnightStatusDB.y = point, x, y
	end
end)

f:SetScript("OnMouseUp", function(self, button)
	if button == "RightButton" then
		MS.OpenPicker(self)
	end
end)

-- ---------------------------------------------------------------- migration

-- v0.7 stored showadv/showvet/... booleans matched against localised names.
-- v0.8 stored opt.currencies as a flat array of numeric IDs.
-- v0.9 stores opt.currencies as an array of { id = , pin = } tables.
local MIGRATE_NAMES = {
	showadv = { "Adventurer Dawncrest", "Adventurer Mistcrest" },
	showvet = { "Veteran Dawncrest", "Veteran Mistcrest" },
	showchamp = { "Champion Dawncrest", "Champion Mistcrest" },
	showhero = { "Hero Dawncrest", "Hero Mistcrest" },
	showmyth = { "Myth Dawncrest", "Myth Mistcrest" },
}

local function migrateLayout(opt)
	if opt.__migrated then
		return
	end

	-- Nothing to do if a selection already exists. (The v0.8 flat-number shape
	-- is normalised in applyDefaults before anyone gets here.)
	if #opt.currencies > 0 then
		opt.__migrated = true
		return
	end

	-- v0.7 -> v0.9: needs a real scan to resolve names to IDs
	local list = MS.ScanCurrencies()
	if #list == 0 then
		return -- currency data not ready yet; the caller retries
	end

	local order = { "showadv", "showvet", "showchamp", "showhero", "showmyth" }
	for i = 1, #order do
		local key = order[i]
		if opt[key] ~= nil and opt[key] ~= false then
			for _, wanted in ipairs(MIGRATE_NAMES[key]) do
				for j = 1, #list do
					if list[j].name == wanted then
						MS.AddCurrency(opt, list[j].id)
						break
					end
				end
			end
		end
	end

	opt.__migrated = true
end

MS.MigrateLayout = migrateLayout

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
		local p = getLayout(layoutName)
		f:ClearAllPoints()
		f:SetPoint(p.point, UIParent, p.point, p.x, p.y)
		migrateLayout(p)
		MS.UpdateCurrencyLine()
	end)

	pcall(LEM.RegisterCallback, LEM, "enter", function()
		f:EnableMouse(true)
	end)
	pcall(LEM.RegisterCallback, LEM, "exit", function()
		MS.ApplyMouse()
	end)

	LEM:AddFrame(f, function(_, layoutName, point, x, y)
		local p = getLayout(layoutName)
		p.point, p.x, p.y = point, x, y
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
			MS.UpdateTimeLine()
		end)

		boolSetting("Auto: follow highest tier", function(n)
			return getLayout(n).autoWindow
		end, function(n, v)
			getLayout(n).autoWindow = not not v
			MS.UpdateCurrencyLine()
		end)

		boolSetting("Hide currencies at zero", function(n)
			return getLayout(n).hideZero
		end, function(n, v)
			getLayout(n).hideZero = not not v
			MS.UpdateCurrencyLine()
		end)

		boolSetting("Show weekly earned / cap", function(n)
			return getLayout(n).showWeekly
		end, function(n, v)
			getLayout(n).showWeekly = not not v
			MS.UpdateCurrencyLine()
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
			get = function(n)
				return getLayout(n).autoCount or 3
			end,
			set = function(n, v)
				getLayout(n).autoCount = math.floor(tonumber(v) or 3)
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

local SPEC_EVENTS = {
	PLAYER_SPECIALIZATION_CHANGED = true,
	PLAYER_LOOT_SPEC_UPDATED = true,
	PLAYER_TALENT_UPDATE = true,
	CHARACTER_POINTS_CHANGED = true,
	ACTIVE_TALENT_GROUP_CHANGED = true,
	PLAYER_LEVEL_UP = true,
}

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
	if f.__lemManaged and not activeLayout and attempt < 6 then
		C_Timer.After(1, function()
			deferredInit(attempt + 1)
		end)
		return
	end
	local opt = MS.GetOptions()
	migrateLayout(opt)
	if not opt.__migrated and attempt < 6 then
		C_Timer.After(1, function()
			deferredInit(attempt + 1)
		end)
	end
	MS.UpdateCurrencyLine()

	-- One-time nudge on a fresh install, so the empty bottom row isn't a mystery.
	if #opt.currencies == 0 and not MidnightStatusDB.hinted then
		MidnightStatusDB.hinted = true
		print("|cff8080ffMidnightStatus|r: no currencies picked yet. Type /ms to choose some.")
	end
end

local booted = false

f:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
		if not booted then
			booted = true
			refreshClassColor()
			MS.ApplyMouse()
			setupLibEditMode()

			if not f.__lemManaged then
				local point = MidnightStatusDB.point or DEFAULT_POS.point
				local x = MidnightStatusDB.x or DEFAULT_POS.x
				local y = MidnightStatusDB.y or DEFAULT_POS.y
				f:ClearAllPoints()
				f:SetPoint(point, UIParent, point, x, y)
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
	elseif SPEC_EVENTS[event] or (MS.IsSpecEvent and MS.IsSpecEvent(event)) then
		updateLoot()
	elseif DURABILITY_EVENTS[event] then
		updateDurability()
	elseif event == "CURRENCY_DISPLAY_UPDATE" then
		queueCurrencyUpdate()
	end
end)

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_MONEY")
f:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
for event in pairs(DURABILITY_EVENTS) do
	f:RegisterEvent(event)
end
if MS.RegisterSpecEvents then
	MS.RegisterSpecEvents(f)
else
	for event in pairs(SPEC_EVENTS) do
		f:RegisterEvent(event)
	end
end

-- Two tickers, both cheap. updatePerf early-outs when nothing changed.
C_Timer.NewTicker(1, MS.UpdateTimeLine)
C_Timer.NewTicker(1, updatePerf)

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
		MS.UpdateCurrencyLine()
	elseif cmd == "mouse" then
		MidnightStatusDB.mouse = not MidnightStatusDB.mouse
		MS.ApplyMouse()
		msg("mouse " .. (MidnightStatusDB.mouse and "on" or "off"))
	elseif cmd == "12" or cmd == "24" then
		MidnightStatusDB.use24HourTime = (cmd == "24")
		MS.UpdateTimeLine()
	elseif cmd == "reset" then
		MidnightStatusDB.point, MidnightStatusDB.x, MidnightStatusDB.y = nil, nil, nil
		f:ClearAllPoints()
		f:SetPoint(DEFAULT_POS.point, UIParent, DEFAULT_POS.point, DEFAULT_POS.x, DEFAULT_POS.y)
		msg("position reset")
	elseif cmd == "scan" then
		local list = MS.ScanCurrencies()
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
		msg("/ms | add <id> | remove <id> | list | scan | mouse | 12 | 24 | reset")
	end
end
