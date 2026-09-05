-- Live map entities (players + vehicles) for LS25 Hof-Dashboard.

function HofDashboardLive:collectLiveMapEntities()
    local result = {
        players = self:newArray(),
        vehicles = self:newArray(),
    }

    local myFarmId = self:getPlayerFarmId()

    local playerSystem = g_currentMission and g_currentMission.playerSystem or nil
    local missionPlayers = playerSystem and playerSystem.players or nil
    if missionPlayers ~= nil then
        for _, player in pairs(missionPlayers) do
            local farmId = player.farmId or 0
            if myFarmId <= 0 or farmId == myFarmId then
                local ok, x, z, yaw = pcall(function()
                    if player.getMapPositionAndLookYaw ~= nil then
                        return player:getMapPositionAndLookYaw()
                    end
                    local node = player.rootNode
                    if node ~= nil and entityExists(node) then
                        local px, _, pz = getWorldTranslation(node)
                        local _, ry, _ = getWorldRotation(node)
                        return px, pz, ry
                    end
                    return nil, nil, nil
                end)
                if ok and type(x) == "number" and type(z) == "number" then
                    local name = player.nickname or player.name or "Spieler"
                    table.insert(result.players, {
                        id = tostring(player.uniqueUserId or player.userId or name),
                        name = tostring(name),
                        farmId = farmId,
                        x = self:round(x, 2),
                        z = self:round(z, 2),
                        yaw = self:round(yaw or 0, 4),
                        isLocal = player == g_currentMission.player,
                    })
                end
            end
        end
    elseif g_currentMission and g_currentMission.player ~= nil then
        local player = g_currentMission.player
        local x, z, yaw = self:safeGet(function()
            if player.getMapPositionAndLookYaw ~= nil then
                return player:getMapPositionAndLookYaw()
            end
            local px, _, pz = getWorldTranslation(player.rootNode)
            local _, ry, _ = getWorldRotation(player.rootNode)
            return px, pz, ry
        end, nil)
        if type(x) == "number" and type(z) == "number" then
            table.insert(result.players, {
                id = tostring(player.uniqueUserId or player.userId or "local"),
                name = tostring(player.nickname or player.name or "Spieler"),
                farmId = player.farmId or myFarmId,
                x = self:round(x, 2),
                z = self:round(z, 2),
                yaw = self:round(yaw or 0, 4),
                isLocal = true,
            })
        end
    end

    local vehicleSystem = g_currentMission and g_currentMission.vehicleSystem or nil
    local vehicles = vehicleSystem and vehicleSystem.vehicles or nil
    if vehicles ~= nil then
        for _, vehicle in pairs(vehicles) do
            if vehicle ~= nil and vehicle.spec_pallet == nil then
                local ownerId = self:getVehicleOwnerFarmId(vehicle)
                if myFarmId <= 0 or ownerId == myFarmId then
                    local node = vehicle.rootNode or (vehicle.components and vehicle.components[1] and vehicle.components[1].node) or nil
                    if node ~= nil and entityExists(node) then
                        local ok, x, _, z = pcall(getWorldTranslation, node)
                        if ok and type(x) == "number" and type(z) == "number" then
                            local _, ry, _ = getWorldRotation(node)
                            local store = self:getVehicleStoreInfo(vehicle)
                            local speed = 0
                            if vehicle.getLastSpeed ~= nil then
                                speed = self:safeGet(function() return vehicle:getLastSpeed() * 3600 end, 0) or 0
                            elseif type(vehicle.lastSpeedReal) == "number" then
                                speed = math.abs(vehicle.lastSpeedReal * 3600)
                            end
                            local uniqueId = ""
                            if vehicle.getUniqueId ~= nil then
                                uniqueId = tostring(self:safeGet(function() return vehicle:getUniqueId() end, "") or "")
                            end
                            if uniqueId == "" then uniqueId = tostring(vehicle.id or vehicle.rootNode or store.name) end

                            table.insert(result.vehicles, {
                                id = uniqueId,
                                farmId = ownerId,
                                name = store.name,
                                brand = store.brand,
                                model = store.model,
                                category = self:getVehicleCategory(vehicle),
                                x = self:round(x, 2),
                                z = self:round(z, 2),
                                yaw = self:round(ry or 0, 4),
                                speedKph = self:round(speed, 1),
                                isControlled = vehicle == g_currentMission.controlledVehicle,
                                isWorking = self:safeGet(function() return vehicle:getIsAIActive() end, false),
                            })
                        end
                    end
                end
            end
        end
    end

    return result
end
