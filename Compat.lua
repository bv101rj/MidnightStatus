-- Compat.lua
-- Normalize Retail vs Classic API differences.
-- Goal: keep MidnightStatus.lua mostly "what the addon does",
-- and keep version/API branching here.

local addonName, MS = ...
MS = MS or {}

-- Project detection
MS.projectID = WOW_PROJECT_ID
MS.isRetail = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)

-- Returns (name, icon) for whatever "spec" means on this client:
-- Retail: loot spec (or current spec)
-- Classic flavors: primary talent tab (most points spent)
function MS.GetSpecNameAndIcon()
  -- Retail: use (loot) specialization APIs
  if MS.isRetail then
    if type(GetLootSpecialization) == "function"
      and type(GetSpecialization) == "function"
      and type(GetSpecializationInfo) == "function"
    then
      local lootSpecID = GetLootSpecialization()
      if lootSpecID and lootSpecID ~= 0 and type(GetSpecializationInfoForSpecID) == "function" then
        local _, name, _, icon = GetSpecializationInfoForSpecID(lootSpecID)
        return name or ("SpecID " .. lootSpecID), icon
      end

      local curIndex = GetSpecialization()
      if curIndex then
        local _, name, _, icon = GetSpecializationInfo(curIndex)
        return name or "Current", icon
      end
    end

    return "None", nil
  end

  -- Classic flavors: use talents
  if type(GetNumTalentTabs) == "function" and type(GetTalentTabInfo) == "function" then
    local numTabs = GetNumTalentTabs() or 0

    local bestName, bestIcon, bestPoints = nil, nil, -1
for i = 1, numTabs do
  -- Classic talent tab signature is:
  -- id, name, description, iconTexture, pointsSpent, ...
  -- Some builds may return a shortened (name, icon, points) signature.
  local a, b, c, d, e = GetTalentTabInfo(i)

  local name, icon, pointsSpent
  if type(a) == "number" and type(b) == "string" then
    -- Canonical classic signature
    name = b
    icon = d
    pointsSpent = e
  else
    -- Fallback/legacy signatures
    name = a
    icon = b
    pointsSpent = c
  end

  pointsSpent = tonumber(pointsSpent) or 0

  if pointsSpent > bestPoints then
    bestName, bestIcon, bestPoints = name, icon, pointsSpent
  end
end

    if bestName then
      return bestName, bestIcon
    end
  end

  return "None", nil
end

-- Register only the events that matter for spec changes on each client.
function MS.RegisterSpecEvents(frame)
  if not frame or type(frame.RegisterEvent) ~= "function" then return end

  -- Retail spec / loot spec changes
  frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
  frame:RegisterEvent("PLAYER_LOOT_SPEC_UPDATED")

  -- Classic talent changes (safe to register everywhere; just won't fire where unsupported)
  frame:RegisterEvent("PLAYER_TALENT_UPDATE")
  frame:RegisterEvent("CHARACTER_POINTS_CHANGED")
  frame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
  frame:RegisterEvent("PLAYER_LEVEL_UP")
end

-- Helper: should we refresh spec for this event?
function MS.IsSpecEvent(event)
  return event == "PLAYER_SPECIALIZATION_CHANGED"
    or event == "PLAYER_LOOT_SPEC_UPDATED"
    or event == "PLAYER_TALENT_UPDATE"
    or event == "CHARACTER_POINTS_CHANGED"
    or event == "ACTIVE_TALENT_GROUP_CHANGED"
    or event == "PLAYER_LEVEL_UP"
end
