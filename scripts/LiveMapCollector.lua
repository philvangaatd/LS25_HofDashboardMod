-- Live map augmentation for the existing farm and vehicle exports.
-- Loaded after HofDashboard.lua + VehiclesCollector.lua so it can wrap both collectors
-- without introducing a second telemetry file/protocol.

local originalCollectFarm = HofDashboardLive.collectFarm
local originalProcessVehicle = HofDashboardLive.processVehicle

local function nodeExists(node)
    if node == nil then return false end
    if entityExists ~= nil then
        local ok, exists = pcall(entityExists, node)
        return ok and exists == true
    end
    return true
end

function HofDashboardLive:getLiveMapPlayers(myFarmId)
    local result = self:newArray()
    local playerSystem = g_currentMission and g_currentMission.playerSystem or nil
    local missionPlayers = playerSystem and playerSystem.players or nil

    local function appendPlayer(player)
        if player == nil then return end
        local farmId = player.farmId or 0
        if myFarmId > 0 and farmId > 0 and farmId ~= myFarmId then return end

        local ok, x, z, yaw = pcall(function()
            if player.getMapPositionAndLookYaw ~= nil then
                return player:getMapPositionAndLookYaw()
            end
            if nodeExists(player.rootNode) then
                local px, _, pz = getWorldTranslation(player.rootNode)
                local _, ry, _ = getWorldRotation(player.rootNode)
                return px, pz, ry
            end
            return nil, nil, nil
        end)
        if not ok or type(x) ~= "number" or type(z) ~= "number" then return end

        table.insert(result, {
            id = tostring(player.uniqueUserId or player.userId or (#result + 1)),
            name = tostring(player.nickname or player.name or "Spieler"),
            farmId = farmId,
            x = self:round(x, 2),
            z = self:round(z, 2),
            yaw = self:round(yaw or 0, 4),
            isLocal = player == (g_currentMission and g_currentMission.player or nil),
        })
    end

    if missionPlayers ~= nil then
        for _, player in pairs(missionPlayers) do appendPlayer(player) end
    elseif g_currentMission ~= nil then
        appendPlayer(g_currentMission.player)
    end

    return result
end

function HofDashboardLive:collectFarm()
    local result = originalCollectFarm(self)
    result.players = self:getLiveMapPlayers(result.farmId or self:getPlayerFarmId())
    return result
end

function HofDashboardLive:processVehicle(vehicle, myFarmId)
    local data = originalProcessVehicle(self, vehicle, myFarmId)
    if data == nil or vehicle == nil then return data end

    local node = vehicle.rootNode
    if not nodeExists(node) and vehicle.components ~= nil and vehicle.components[1] ~= nil then
        node = vehicle.components[1].node
    end
    if not nodeExists(node) then return data end

    local ok, x, _, z = pcall(getWorldTranslation, node)
    if not ok or type(x) ~= "number" or type(z) ~= "number" then return data end

    local _, yaw, _ = getWorldRotation(node)
    local speedKph = 0
    if vehicle.getLastSpeed ~= nil then
        speedKph = self:safeGet(function() return math.abs(vehicle:getLastSpeed() * 3600) end, 0) or 0
    elseif type(vehicle.lastSpeedReal) == "number" then
        speedKph = math.abs(vehicle.lastSpeedReal * 3600)
    end

    data.mapX = self:round(x, 2)
    data.mapZ = self:round(z, 2)
    data.mapYaw = self:round(yaw or 0, 4)
    data.speedKph = self:round(speedKph, 1)
    data.isControlled = vehicle == (g_currentMission and g_currentMission.controlledVehicle or nil)
    return data
end
