-- Collector methods extracted from scripts/HofDashboard.lua.

function HofDashboardLive:collectContracts()
    local result = self:newArray()
    if g_missionManager == nil then return result end

    local missions = nil
    local ok, err = pcall(function() missions = g_missionManager:getMissions() end)
    if not ok then
        self:logError("getMissions", err)
        missions = g_missionManager.missions
    end
    if missions == nil then return result end

    for _, mission in pairs(missions) do
        local missionOk, missionData = self:protected(
            "processMission " .. tostring(mission.type or mission.className or "?"),
            function() return self:processMission(mission) end
        )
        if missionOk and missionData ~= nil then table.insert(result, missionData) end
    end

    return result
end

function HofDashboardLive:processMission(mission)
    if mission == nil then return nil end

    local data = {
        type     = tostring(mission.type or mission.className or ""),
        title    = "",
        reward   = 0,
        fieldId  = 0,
        isActive = false,
        progress = 0,
        deadline = 0,
        farmId   = mission.farmId or 0,
    }

    if mission.getTitle ~= nil then
        data.title = tostring(mission:getTitle() or "")
    end

    if mission.getReward ~= nil then
        data.reward = math.floor(mission:getReward() or 0)
    elseif mission.reward ~= nil then
        data.reward = math.floor(mission.reward)
    end

    if mission.field ~= nil then
        if mission.field.getId ~= nil then
            data.fieldId = mission.field:getId() or 0
        elseif mission.field.id ~= nil then
            data.fieldId = mission.field.id
        end
    end

    if mission.getIsActive ~= nil then
        data.isActive = mission:getIsActive() == true
    elseif mission.status ~= nil then
        data.isActive = tostring(mission.status) == "ACTIVE"
    end

    if mission.getProgress ~= nil then
        data.progress = math.floor((mission:getProgress() or 0) * 100)
    elseif mission.completionProgress ~= nil then
        data.progress = math.floor((mission.completionProgress or 0) * 100)
    end

    return data
end

-- ======================================================================
-- MARKTPREISE
-- ======================================================================
