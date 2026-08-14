-- Compat.lua
-- Normalise Retail vs Classic API differences so MidnightStatus.lua can stay
-- "what the addon does" rather than "which client am I on".

local addonName, MS = ...

MS.projectID = WOW_PROJECT_ID
MS.isRetail = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)

-- Returns (name, icon) for whatever "spec" means on this client.
--   Retail:  loot spec, falling back to current spec
--   Classic: talent point spread, e.g. "31/10/0"
function MS.GetSpecNameAndIcon()
	if MS.isRetail then
		if type(GetLootSpecialization) == "function" and type(GetSpecializationInfoForSpecID) == "function" then
			local lootSpecID = GetLootSpecialization()
			if lootSpecID and lootSpecID ~= 0 then
				local _, name, _, icon = GetSpecializationInfoForSpecID(lootSpecID)
				if name then
					return name, icon
				end
			end
		end

		if type(GetSpecialization) == "function" and type(GetSpecializationInfo) == "function" then
			local curIndex = GetSpecialization()
			if curIndex then
				local _, name, _, icon = GetSpecializationInfo(curIndex)
				if name then
					return name, icon
				end
			end
		end

		return "", nil
	end

	if
		type(GetNumTalentTabs) == "function"
		and type(GetNumTalents) == "function"
		and type(GetTalentInfo) == "function"
	then
		local numTabs = GetNumTalentTabs()
		if numTabs and numTabs > 0 then
			local pts = {}
			for tab = 1, numTabs do
				local total = 0
				local n = GetNumTalents(tab) or 0
				for t = 1, n do
					local _, _, _, _, rank = GetTalentInfo(tab, t)
					if type(rank) == "number" then
						total = total + rank
					end
				end
				pts[#pts + 1] = tostring(total)
			end
			return table.concat(pts, "/"), nil
		end
	end

	return "", nil
end

function MS.RegisterSpecEvents(frame)
	if not frame or type(frame.RegisterEvent) ~= "function" then
		return
	end

	if MS.isRetail then
		frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
		frame:RegisterEvent("PLAYER_LOOT_SPEC_UPDATED")
	else
		frame:RegisterEvent("CHARACTER_POINTS_CHANGED")
		frame:RegisterEvent("PLAYER_TALENT_UPDATE")
		frame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
	end
end

function MS.IsSpecEvent(event)
	return event == "PLAYER_SPECIALIZATION_CHANGED"
		or event == "PLAYER_LOOT_SPEC_UPDATED"
		or event == "CHARACTER_POINTS_CHANGED"
		or event == "PLAYER_TALENT_UPDATE"
		or event == "ACTIVE_TALENT_GROUP_CHANGED"
end
