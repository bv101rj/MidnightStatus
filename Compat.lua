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
  -- Classic flavors: user requested no talents/spec text on the HUD.
  return "", nil
end

-- Register only the events that matter for spec changes on each client.
function MS.RegisterSpecEvents(frame)
  if not frame or type(frame.RegisterEvent) ~= "function" then return end

  -- Retail spec / loot spec changes
  frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
  frame:RegisterEvent("PLAYER_LOOT_SPEC_UPDATED")

  if not MS.isRetail then
    -- Classic talents are intentionally hidden; no spec/talent refresh events needed.
    return
  end
end

-- Helper: should we refresh spec for this event?
function MS.IsSpecEvent(event)
  return event == "PLAYER_SPECIALIZATION_CHANGED"
    or event == "PLAYER_LOOT_SPEC_UPDATED"
end
