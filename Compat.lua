-- Compat.lua
-- Normalise API differences between clients so MidnightStatus.lua can stay
-- "what the addon does" rather than "which client am I on".
--
-- Deliberately does NOT branch on WOW_PROJECT_ID. Forever is a new client in
-- the mainline family and there is no documented project constant for it, so
-- any `== WOW_PROJECT_MAINLINE` test is a guess that silently picks the wrong
-- code path when it loses. Instead we ask the client what it can actually do.
-- That also survives the next flavor Blizzard ships without a code change.

local addonName, MS = ...

-- ----------------------------------------------------------------- resolving

-- Blizzard keeps relocating globals into C_ namespaces. Prefer the namespaced
-- version, fall back to the global, return nil if neither exists.
local function resolve(namespace, name)
	if type(namespace) == "table" and type(rawget(namespace, name)) == "function" then
		return namespace[name]
	end
	local g = rawget(_G, name)
	if type(g) == "function" then
		return g
	end
	return nil
end
MS.Resolve = resolve

local SpecNS = rawget(_G, "C_SpecializationInfo")

local GetSpec = resolve(SpecNS, "GetSpecialization")
local GetSpecInfo = resolve(SpecNS, "GetSpecializationInfo")
local GetLootSpec = resolve(SpecNS, "GetLootSpecialization")
local GetSpecInfoForID = resolve(SpecNS, "GetSpecializationInfoForSpecID")

local GetNumTalentTabs = resolve(nil, "GetNumTalentTabs")
local GetNumTalents = resolve(nil, "GetNumTalents")
local GetTalentInfo = resolve(nil, "GetTalentInfo")

-- ------------------------------------------------------------- capabilities

-- What this client supports, by inspection rather than by name.
MS.hasSpecs = (GetSpec ~= nil and GetSpecInfo ~= nil)
MS.hasLootSpec = (GetLootSpec ~= nil and GetSpecInfoForID ~= nil)
MS.hasTalentTabs = (GetNumTalentTabs ~= nil and GetNumTalents ~= nil and GetTalentInfo ~= nil)

-- Informational only. Nothing branches on these.
MS.projectID = rawget(_G, "WOW_PROJECT_ID")
MS.isMainlineFamily = MS.hasSpecs

function MS.ClientName()
	local v, build, _, iface = GetBuildInfo()
	return string.format("%s (build %s, interface %s)", tostring(v), tostring(build), tostring(iface))
end

-- ------------------------------------------------------------------- lookups

-- Returns (name, icon) for whatever "spec" means on this client.
--   Spec-based clients: loot spec, falling back to the active spec
--   Talent-tab clients: point spread, e.g. "31/10/0"
--   Neither:            empty string, and the caller just omits the segment
function MS.GetSpecNameAndIcon()
	if MS.hasLootSpec then
		local ok, lootSpecID = pcall(GetLootSpec)
		if ok and lootSpecID and lootSpecID ~= 0 then
			local ok2, _, name, _, icon = pcall(GetSpecInfoForID, lootSpecID)
			if ok2 and name then
				return name, icon
			end
		end
	end

	if MS.hasSpecs then
		local ok, curIndex = pcall(GetSpec)
		if ok and curIndex then
			local ok2, _, name, _, icon = pcall(GetSpecInfo, curIndex)
			if ok2 and name then
				return name, icon
			end
		end
	end

	if MS.hasTalentTabs then
		local ok, numTabs = pcall(GetNumTalentTabs)
		if ok and numTabs and numTabs > 0 then
			local pts = {}
			for tab = 1, numTabs do
				local total = 0
				local n = select(2, pcall(GetNumTalents, tab)) or 0
				if type(n) ~= "number" then
					n = 0
				end
				for t = 1, n do
					local ok3, _, _, _, _, rank = pcall(GetTalentInfo, tab, t)
					if ok3 and type(rank) == "number" then
						total = total + rank
					end
				end
				pts[#pts + 1] = tostring(total)
			end
			if #pts > 0 then
				return table.concat(pts, "/"), nil
			end
		end
	end

	return "", nil
end

-- ------------------------------------------------------------------- events

-- Registering an event the client doesn't know throws, so each one is guarded
-- individually. A future client dropping one event won't take out the rest.
local SPEC_EVENTS = {
	"PLAYER_SPECIALIZATION_CHANGED",
	"PLAYER_LOOT_SPEC_UPDATED",
	"ACTIVE_TALENT_GROUP_CHANGED",
	"TRAIT_CONFIG_UPDATED",
}

local TALENT_EVENTS = {
	"CHARACTER_POINTS_CHANGED",
	"PLAYER_TALENT_UPDATE",
	"ACTIVE_TALENT_GROUP_CHANGED",
	"PLAYER_LEVEL_UP",
}

local registered = {}

function MS.RegisterSpecEvents(frame)
	if not frame or type(frame.RegisterEvent) ~= "function" then
		return
	end

	local function try(event)
		if registered[event] then
			return
		end
		if pcall(frame.RegisterEvent, frame, event) then
			registered[event] = true
		end
	end

	if MS.hasSpecs or MS.hasLootSpec then
		for _, e in ipairs(SPEC_EVENTS) do
			try(e)
		end
	end

	if MS.hasTalentTabs then
		for _, e in ipairs(TALENT_EVENTS) do
			try(e)
		end
	end

	-- Nothing matched: still refresh on level up so the line isn't stuck blank.
	if not next(registered) then
		try("PLAYER_LEVEL_UP")
	end
end

function MS.IsSpecEvent(event)
	return registered[event] == true
end
