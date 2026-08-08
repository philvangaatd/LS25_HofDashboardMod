--[[
    FS25_AutoDriveFlurkarte – Live Data Export v4.0
    =================================================
    Schreibt alle 15 Sekunden eine JSON-Datei nach:
      <UserDocuments>/My Games/FarmingSimulator2025/modSettings/AutoDriveFlurkarte/liveData.json

    Datenfluss: FS25 Lua API -> liveData.json -> PHP API -> Frontend.
    Der Lua-Mod ist die autoritative Quelle für alle Live-Zustände.
    API-Referenz: https://gdn.giants-software.com/documentation_scripting_fs25.php
]]

local MODNAME = g_currentModName or "FS25_AutoDriveFlurkarte"
local JSON_ARRAY_MT = { __jsonArray = true }

AutoDriveFlurkarteLive                 = {}
AutoDriveFlurkarteLive.MOD_NAME        = MODNAME
AutoDriveFlurkarteLive.VERSION         = "4.0.0"
AutoDriveFlurkarteLive.SETTINGS_DIR    = "AutoDriveFlurkarte"
AutoDriveFlurkarteLive.OUTPUT_FILE     = "liveData.json"
AutoDriveFlurkarteLive.UPDATE_INTERVAL = 15000
AutoDriveFlurkarteLive.timer           = 0
AutoDriveFlurkarteLive.isReady         = false
AutoDriveFlurkarteLive.FUEL_TYPES      = nil
AutoDriveFlurkarteLive.FUEL_BY_INDEX   = nil
AutoDriveFlurkarteLive.GROUND_TYPE_NAMES = {}

-- ======================================================================
-- HILFSFUNKTIONEN
-- ======================================================================

function AutoDriveFlurkarteLive:newArray()
    return setmetatable({}, JSON_ARRAY_MT)
end

function AutoDriveFlurkarteLive:round(value, digits)
    local factor = 10 ^ (digits or 0)
    return math.floor((value or 0) * factor + 0.5) / factor
end

function AutoDriveFlurkarteLive:logError(scope, err)
    print(string.format("[%s] %s: %s", self.MOD_NAME, tostring(scope), tostring(err)))
end

function AutoDriveFlurkarteLive:protected(scope, fn)
    local ok, result = pcall(fn)
    if not ok then
        self:logError(scope, result)
        return false, nil
    end
    return true, result
end

function AutoDriveFlurkarteLive:safeGet(fn, fallback)
    local ok, val = pcall(fn)
    if ok and val ~= nil then return val end
    return fallback
end

function AutoDriveFlurkarteLive:getPlayerFarmId()
    if g_currentMission == nil then return 0 end

    if g_currentMission.getFarmId ~= nil then
        local ok, farmId = pcall(function() return g_currentMission:getFarmId() end)
        if ok and type(farmId) == "number" and farmId > 0 then
            return farmId
        end
    end

    if g_currentMission.player ~= nil then
        return g_currentMission.player.farmId or 0
    end

    return 0
end

-- ======================================================================
-- LIFECYCLE
-- ======================================================================

function AutoDriveFlurkarteLive:loadMap(filename)
    self.isReady = true
    self.timer = self.UPDATE_INTERVAL

    self.GROUND_TYPE_NAMES = {}
    if FieldGroundType ~= nil then
        for name, value in pairs(FieldGroundType) do
            if type(value) == "number" then
                self.GROUND_TYPE_NAMES[value] = name
            end
        end
    end

    self.FUEL_TYPES = self:newArray()
    self.FUEL_BY_INDEX = {}

    local function addFuel(fillTypeIndex, name, label)
        if fillTypeIndex ~= nil then
            local entry = { index = fillTypeIndex, name = name, label = label }
            table.insert(self.FUEL_TYPES, entry)
            self.FUEL_BY_INDEX[fillTypeIndex] = entry
        end
    end

    addFuel(FillType.DIESEL,         "DIESEL",         "Diesel")
    addFuel(FillType.DEF,            "DEF",            "AdBlue")
    addFuel(FillType.ELECTRICCHARGE, "ELECTRICCHARGE", "Strom")
    addFuel(FillType.METHANE,        "METHANE",        "Methan")
    addFuel(FillType.GASOLINE,       "GASOLINE",       "Benzin")

    print(string.format("[%s] v%s aktiv – exportiert alle %ds",
        self.MOD_NAME, self.VERSION, self.UPDATE_INTERVAL / 1000))
end

function AutoDriveFlurkarteLive:deleteMap()
    self.isReady = false
end

function AutoDriveFlurkarteLive:update(dt)
    if not self.isReady or g_currentMission == nil then return end

    self.timer = self.timer + dt
    if self.timer >= self.UPDATE_INTERVAL then
        self.timer = 0
        local ok, err = pcall(function() self:exportAllData() end)
        if not ok then
            self:logError("Export-Fehler", err)
        end
    end
end

-- ======================================================================
-- EXPORT
-- ======================================================================

function AutoDriveFlurkarteLive:exportAllData()
    local data = {
        version       = self.VERSION,
        modName       = self.MOD_NAME,
        timestamp     = getDate("%Y-%m-%dT%H:%M:%S"),
        mapName       = self:safeGet(function() return g_currentMission.missionInfo.mapTitle end, "Unknown"),
        currentDay    = self:safeGet(function() return g_currentMission.environment.currentDay or 0 end, 0),
        daysPerPeriod = self:safeGet(function() return g_currentMission.environment.daysPerPeriod or 24 end, 24),
        farm           = self:collectFarm(),
        fields         = self:collectFields(),
        vehicles       = self:collectVehicles(),
        animals        = self:collectAnimals(),
        productions    = self:collectProductions(),
        contracts      = self:collectContracts(),
        market         = self:collectMarket(),
    }

    self:writeFile(self:jsonEncode(data))
end

-- ======================================================================
-- HOF-INFORMATIONEN
-- ======================================================================

function AutoDriveFlurkarteLive:collectFarm()
    local result = { name = "", farmId = 0, money = 0, loan = 0 }
    local playerFarmId = self:getPlayerFarmId()
    result.farmId = playerFarmId

    local ok, err = pcall(function()
        local farm = nil

        if playerFarmId > 0 and g_farmManager ~= nil and g_farmManager.getFarmById ~= nil then
            farm = g_farmManager:getFarmById(playerFarmId)
        end

        if farm == nil and g_farmManager ~= nil and g_farmManager.getLocalPlayerFarm ~= nil then
            farm = g_farmManager:getLocalPlayerFarm()
        end

        if farm == nil then return end

        result.farmId = playerFarmId > 0 and playerFarmId or (farm.farmId or 0)
        result.name = farm.name or ""

        if type(farm.money) == "number" then
            result.money = math.floor(farm.money)
        elseif type(farm.balance) == "number" then
            result.money = math.floor(farm.balance)
        elseif farm.getMoney ~= nil then
            result.money = math.floor(farm:getMoney() or 0)
        end

        if type(farm.loan) == "number" then
            result.loan = math.floor(farm.loan)
        elseif farm.getLoan ~= nil then
            result.loan = math.floor(farm:getLoan() or 0)
        end
    end)

    if not ok then self:logError("collectFarm", err) end
    return result
end

-- ======================================================================
-- FELDDATEN
--
-- Autoritative Quelle ist Field:getFieldState(). GIANTS verwendet FieldState selbst
-- für Feldmissionen und stellt darüber Frucht, Wachstum, Boden- und Pflegestatus bereit.
-- Keine Ein-Punkt-Abfrage in der Feldmitte mehr: ein einzelner Density-Map-Pixel darf
-- nicht den Zustand eines kompletten Feldes bestimmen.
-- ======================================================================

function AutoDriveFlurkarteLive:collectFields()
    local result = self:newArray()
    if g_farmlandManager == nil or g_currentMission == nil then return result end

    local myFarmId = self:getPlayerFarmId()
    if myFarmId <= 0 then
        self:logError("collectFields", "Spieler-FarmId konnte nicht ermittelt werden")
        return result
    end

    for _, farmland in pairs(g_farmlandManager.farmlands or {}) do
        if farmland.farmId == myFarmId and farmland.field ~= nil then
            local ok, fieldData = self:protected(
                "processFarmland " .. tostring(farmland.id or "?"),
                function() return self:processFarmland(farmland, myFarmId) end
            )
            if ok and fieldData ~= nil then
                table.insert(result, fieldData)
            end
        end
    end

    table.sort(result, function(a, b) return (a.id or 0) < (b.id or 0) end)
    return result
end

function AutoDriveFlurkarteLive:processFarmland(farmland, myFarmId)
    local field = farmland.field
    local data = {
        id                = field:getId() or 0,
        farmlandId        = farmland.id or 0,
        farmId            = myFarmId,
        area              = self:round(field.areaHa or 0, 2),
        fruitType         = "NONE",
        fruitTitle        = "Brache",
        maxGrowthState    = 0,
        growthState       = 0,
        growthName        = "FALLOW",
        harvestReady      = false,
        isWithered        = false,
        groundType        = "NONE",
        weedState         = 0,
        weedFactor        = 0,
        stoneLevel        = 0,
        sprayLevel        = 0,
        sprayType         = 0,
        limeLevel         = 0,
        rollerLevel       = 0,
        plowLevel         = 0,
        stubbleShredLevel = 0,
        waterLevel        = 0,
    }

    local fieldState = field:getFieldState()
    if fieldState == nil or not fieldState.isValid then
        return data
    end

    data.groundType        = self.GROUND_TYPE_NAMES[fieldState.groundType] or tostring(fieldState.groundType or 0)
    data.weedState         = fieldState.weedState or 0
    data.weedFactor        = fieldState.weedFactor or 0
    data.stoneLevel        = fieldState.stoneLevel or 0
    data.sprayLevel        = fieldState.sprayLevel or 0
    data.sprayType         = fieldState.sprayType or 0
    data.limeLevel         = fieldState.limeLevel or 0
    data.rollerLevel       = fieldState.rollerLevel or 0
    data.plowLevel         = fieldState.plowLevel or 0
    data.stubbleShredLevel = fieldState.stubbleShredLevel or 0
    data.waterLevel        = fieldState.waterLevel or 0

    local fruitIdx = fieldState.fruitTypeIndex
    local unknownFruit = FruitType ~= nil and FruitType.UNKNOWN or 0
    if fruitIdx == nil or fruitIdx == unknownFruit or fruitIdx == 0 then
        return data
    end

    local fruitType = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIdx) or nil
    if fruitType == nil then
        data.fruitType = "UNKNOWN"
        data.fruitTitle = "Unbekannt"
        return data
    end

    local growthState = fieldState.growthState or 0
    data.fruitType = string.upper(fruitType.name or "UNKNOWN")
    data.fruitTitle = (fruitType.fillType and fruitType.fillType.title) or fruitType.name or data.fruitType
    data.growthState = growthState
    data.maxGrowthState = fruitType.maxHarvestingGrowthState or fruitType.numGrowthStates or 0

    -- GIANTS nutzt diese beiden Methoden selbst, z. B. in PlowMission.isAvailableForField().
    local isCut = fruitType.getIsCut ~= nil and fruitType:getIsCut(growthState) or false
    local isWithered = fruitType.getIsWithered ~= nil and fruitType:getIsWithered(growthState) or false

    if isCut then
        data.growthName = "CUT"
        data.harvestReady = false
    elseif isWithered then
        data.growthName = "WITHERED"
        data.isWithered = true
        data.harvestReady = false
    else
        local minHarvest = fruitType.minHarvestingGrowthState or -1
        local maxHarvest = fruitType.maxHarvestingGrowthState or -1

        if minHarvest >= 0 and maxHarvest >= 0
            and growthState >= minHarvest and growthState <= maxHarvest then
            data.growthName = "READY_TO_HARVEST"
            data.harvestReady = true
        elseif growthState > 0 then
            data.growthName = "GROWING"
        else
            data.growthName = "GERMINATING"
        end
    end

    -- Sicherheitsregel: Ein bereits bearbeiteter Boden darf niemals als erntereif
    -- ausgegeben werden, selbst wenn ein Mod-Feld einen veralteten Fruchtzustand meldet.
    local workedGround = data.groundType == "PLOWED"
        or data.groundType == "CULTIVATED"
        or data.groundType == "SEEDBED"
        or data.groundType == "ROLLED_SEEDBED"
        or data.groundType == "ROLLER_LINES"
        or data.groundType == "STUBBLE_TILLAGE"
        or data.groundType == "RIDGE"
        or data.groundType == "GRASS_CUT"

    if workedGround and data.harvestReady then
        data.harvestReady = false
        data.growthName = "CUT"
    end

    return data
end

-- ======================================================================
-- FAHRZEUGDATEN
-- ======================================================================

function AutoDriveFlurkarteLive:collectVehicles()
    local result = self:newArray()
    if g_currentMission == nil or g_currentMission.vehicles == nil then return result end

    for _, vehicle in ipairs(g_currentMission.vehicles) do
        local ok, vehicleData = self:protected(
            "processVehicle " .. tostring(vehicle.typeName or "?"),
            function() return self:processVehicle(vehicle) end
        )
        if ok and vehicleData ~= nil then
            table.insert(result, vehicleData)
        end
    end

    return result
end

function AutoDriveFlurkarteLive:processVehicle(vehicle)
    if vehicle.spec_pallet ~= nil then return nil end

    local ownerId = 0
    if vehicle.getOwnerFarmId ~= nil then
        ownerId = vehicle:getOwnerFarmId() or 0
    end
    if ownerId <= 0 then ownerId = vehicle.ownerFarmId or 0 end
    if ownerId <= 0 then return nil end

    local isMotorized = vehicle.spec_motorized ~= nil
    local isTrailer = vehicle.spec_trailer ~= nil
    local category = "IMPLEMENT"
    if isMotorized then
        category = "VEHICLE"
    elseif isTrailer then
        category = "TRAILER"
    end

    local data = {
        name            = vehicle:getFullName() or "Unbekannt",
        typeName        = vehicle.typeName or "",
        vehicleCategory = category,
        farmId          = ownerId,
        operatingHours  = self:round((vehicle:getOperatingTime() or 0) / 3600000, 1),
        wear            = self:round(vehicle:getVehicleDamage() or 0, 3),
        dirt            = 0,
        price           = math.floor(vehicle:getPrice() or 0),
        fuel            = self:newArray(),
        cargo           = self:newArray(),
        isWorking       = self:safeGet(function() return vehicle:getIsAIActive() end, false),
        uniqueId        = "",
    }

    if vehicle.getUniqueId ~= nil then
        local value = vehicle:getUniqueId()
        if value ~= nil then data.uniqueId = tostring(value) end
    end

    -- Washable registriert getDirtAmount() direkt auf dem Fahrzeugtyp.
    if vehicle.getDirtAmount ~= nil then
        data.dirt = self:round(vehicle:getDirtAmount() or 0, 3)
    end

    -- FillUnit direkt über die offiziell registrierten Fahrzeugfunktionen auslesen.
    -- getFillLevelInformation() erwartet ein HUD-Displayobjekt und ist für diesen Export
    -- nicht die passende API.
    if vehicle.getFillUnits ~= nil then
        for fillUnitIndex, _ in ipairs(vehicle:getFillUnits()) do
            local fillTypeIndex = vehicle:getFillUnitFillType(fillUnitIndex)
            local level = vehicle:getFillUnitFillLevel(fillUnitIndex) or 0
            local capacity = vehicle:getFillUnitCapacity(fillUnitIndex) or 0

            if fillTypeIndex ~= nil and fillTypeIndex ~= FillType.UNKNOWN and capacity > 0 then
                local fuelType = self.FUEL_BY_INDEX and self.FUEL_BY_INDEX[fillTypeIndex] or nil

                if fuelType ~= nil then
                    table.insert(data.fuel, {
                        fillType = fuelType.name,
                        label    = fuelType.label,
                        liters   = self:round(level, 1),
                        capacity = math.floor(capacity),
                        percent  = math.floor(math.min(100, level / capacity * 100)),
                    })
                elseif level > 0.01 then
                    local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
                    local fillTypeName = fillType and fillType.name or ""
                    if fillTypeName ~= "" and fillTypeName ~= "UNKNOWN"
                        and fillTypeName ~= "AIR" and fillTypeName ~= "BALE_NET" then
                        table.insert(data.cargo, {
                            fillType = fillTypeName,
                            title    = fillType and fillType.title or fillTypeName,
                            liters   = self:round(level, 1),
                            capacity = math.floor(capacity),
                            percent  = math.floor(math.min(100, level / capacity * 100)),
                        })
                    end
                end
            end
        end
    end

    return data
end

-- ======================================================================
-- TIERHALTUNG
-- ======================================================================

function AutoDriveFlurkarteLive:collectAnimals()
    local result = self:newArray()
    if g_currentMission == nil or g_currentMission.placeables == nil then return result end

    for _, placeable in pairs(g_currentMission.placeables) do
        local ok, data = self:protected(
            "processHusbandry " .. tostring(placeable.typeName or "?"),
            function() return self:processHusbandry(placeable) end
        )
        if ok and data ~= nil then table.insert(result, data) end
    end

    return result
end

function AutoDriveFlurkarteLive:processHusbandry(placeable)
    local spec = placeable.spec_animalHusbandry
    if spec == nil then return nil end

    local data = {
        species      = "",
        name         = placeable:getName() or "",
        farmId       = placeable.ownerFarmId or 0,
        numAnimals   = 0,
        health       = 0,
        reproduction = 0,
        clusters     = self:newArray(),
    }

    local clusters = nil
    if spec.getAnimalClusters ~= nil then
        clusters = spec:getAnimalClusters()
    elseif spec.animalClusters ~= nil then
        clusters = spec.animalClusters
    end

    if clusters ~= nil then
        local totalAnimals = 0
        local weightedHealth = 0
        local weightedReproduction = 0

        for _, cluster in pairs(clusters) do
            local num = cluster.numAnimals or (cluster.getNumAnimals and cluster:getNumAnimals()) or 0
            local health = cluster.health or 0
            local reproduction = cluster.reproductionEfficiency or cluster.reproduction or 0

            if health > 1 then health = health / 100 end
            if reproduction > 1 then reproduction = reproduction / 100 end

            totalAnimals = totalAnimals + num
            weightedHealth = weightedHealth + health * num
            weightedReproduction = weightedReproduction + reproduction * num

            if data.species == "" then
                data.species = cluster.species
                    or (cluster.animalType and cluster.animalType.name)
                    or ""
            end

            table.insert(data.clusters, {
                numAnimals   = num,
                health       = self:round(health, 3),
                reproduction = self:round(reproduction, 3),
            })
        end

        data.numAnimals = totalAnimals
        if totalAnimals > 0 then
            data.health = self:round(weightedHealth / totalAnimals, 3)
            data.reproduction = self:round(weightedReproduction / totalAnimals, 3)
        end
    end

    if data.numAnimals == 0 and #data.clusters == 0 then return nil end
    return data
end

-- ======================================================================
-- PRODUKTIONSANLAGEN
-- ======================================================================

function AutoDriveFlurkarteLive:collectProductions()
    local result = self:newArray()
    if g_currentMission == nil or g_currentMission.placeables == nil then return result end

    for _, placeable in pairs(g_currentMission.placeables) do
        local ok, data = self:protected(
            "processProduction " .. tostring(placeable.typeName or "?"),
            function() return self:processProduction(placeable) end
        )
        if ok and data ~= nil then table.insert(result, data) end
    end

    return result
end

function AutoDriveFlurkarteLive:processProduction(placeable)
    local spec = placeable.spec_productionPoint
    if spec == nil or spec.productionPoint == nil then return nil end

    local farmId = placeable.ownerFarmId or 0
    local playerFarmId = self:getPlayerFarmId()
    if farmId <= 0 or (playerFarmId > 0 and farmId ~= playerFarmId) then return nil end

    local productionPoint = spec.productionPoint
    local data = {
        name        = placeable:getName() or "",
        farmId      = farmId,
        productions = self:newArray(),
        storages    = self:newArray(),
    }

    if productionPoint.getProductions ~= nil then
        for _, production in ipairs(productionPoint:getProductions()) do
            local productionData = {
                name          = production.name or "",
                status        = tostring(production.status or ""),
                cyclesPerHour = production.cyclesPerHour or 0,
                inputs        = self:newArray(),
                outputs       = self:newArray(),
            }

            if production.inputs ~= nil then
                for _, input in ipairs(production.inputs) do
                    local fillType = g_fillTypeManager:getFillTypeByIndex(input.type)
                    table.insert(productionData.inputs, {
                        fillType = fillType and fillType.name or tostring(input.type),
                        amount   = input.amount or 0,
                    })
                end
            end

            if production.outputs ~= nil then
                for _, output in ipairs(production.outputs) do
                    local fillType = g_fillTypeManager:getFillTypeByIndex(output.type)
                    table.insert(productionData.outputs, {
                        fillType = fillType and fillType.name or tostring(output.type),
                        amount   = output.amount or 0,
                    })
                end
            end

            table.insert(data.productions, productionData)
        end
    end

    if productionPoint.storage ~= nil and productionPoint.storage.fillLevels ~= nil then
        for fillTypeIndex, level in pairs(productionPoint.storage.fillLevels) do
            if level > 0 then
                local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                local capacity = productionPoint.storage.capacities
                    and productionPoint.storage.capacities[fillTypeIndex] or 0

                table.insert(data.storages, {
                    fillType = fillType and fillType.name or tostring(fillTypeIndex),
                    title    = fillType and fillType.title or "",
                    level    = math.floor(level),
                    capacity = math.floor(capacity),
                    percent  = capacity > 0 and math.floor(math.min(100, level / capacity * 100)) or 0,
                })
            end
        end
    end

    if #data.productions == 0 and #data.storages == 0 then return nil end
    return data
end

-- ======================================================================
-- VERTRÄGE / MISSIONS
-- ======================================================================

function AutoDriveFlurkarteLive:collectContracts()
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

function AutoDriveFlurkarteLive:processMission(mission)
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

function AutoDriveFlurkarteLive:collectMarket()
    local result = self:newArray()
    if g_fillTypeManager == nil then return result end

    local fruitFillTypeIndices = {}
    if g_fruitTypeManager ~= nil then
        for _, fruitType in pairs(g_fruitTypeManager.fruitTypes or {}) do
            if fruitType.fillType ~= nil and fruitType.fillType.index ~= nil then
                fruitFillTypeIndices[fruitType.fillType.index] = true
            end
        end
    end

    local economyManager = g_currentMission and g_currentMission.economyManager

    -- Keine willkürliche Preisobergrenze: auch hochwertige Produktionsgüter müssen
    -- im Markt-Tab ankommen.
    for _, fillType in pairs(g_fillTypeManager.fillTypes or {}) do
        if fillType ~= nil and fillType.pricePerLiter ~= nil and fillType.pricePerLiter > 0 then
            local basePrice = fillType.pricePerLiter * 1000
            local currentPrice = basePrice

            if economyManager ~= nil and economyManager.getPriceMultiplier ~= nil then
                local ok, multiplier = pcall(function()
                    return economyManager:getPriceMultiplier(fillType.index)
                end)
                if ok and multiplier ~= nil and multiplier > 0 then
                    currentPrice = basePrice * multiplier
                end
            end

            if currentPrice > 1 then
                table.insert(result, {
                    fillType     = fillType.name or "",
                    title        = fillType.title or fillType.name or "",
                    pricePerTon  = math.floor(currentPrice),
                    basePriceTon = math.floor(basePrice),
                    category     = fruitFillTypeIndices[fillType.index] and "crop" or "product",
                })
            end
        end
    end

    table.sort(result, function(a, b) return a.pricePerTon > b.pricePerTon end)
    return result
end

-- ======================================================================
-- DATEI SCHREIBEN
-- ======================================================================

function AutoDriveFlurkarteLive:writeFile(content)
    local base = getUserProfileAppPath()
    local modSettingsDir = base .. "modSettings/"
    local modDir = modSettingsDir .. self.SETTINGS_DIR .. "/"
    local targetPath = modDir .. self.OUTPUT_FILE
    local tempPath = targetPath .. ".tmp"

    createFolder(modSettingsDir)
    createFolder(modDir)

    -- Erst vollständig in eine temporäre Datei schreiben. So kann PHP niemals eine
    -- halb geschriebene JSON-Datei lesen.
    local file, openError = io.open(tempPath, "w")
    if file == nil then
        self:logError("writeFile", openError or "Temporäre Datei konnte nicht geöffnet werden")
        return
    end

    local ok, writeError = file:write(content)
    file:close()
    if not ok then
        self:logError("writeFile", writeError or "Schreiben fehlgeschlagen")
        os.remove(tempPath)
        return
    end

    -- Windows überschreibt beim Rename eine existierende Datei nicht zuverlässig.
    -- Die Zieldatei wird deshalb erst nach erfolgreichem Temp-Write ersetzt.
    os.remove(targetPath)
    local renamed, renameError = os.rename(tempPath, targetPath)
    if not renamed then
        self:logError("writeFile rename", renameError or "Umbenennen fehlgeschlagen")
    end
end

-- ======================================================================
-- JSON ENCODER
-- ======================================================================

function AutoDriveFlurkarteLive:jsonEncode(value)
    local valueType = type(value)

    if valueType == "nil" then
        return "null"
    elseif valueType == "boolean" then
        return value and "true" or "false"
    elseif valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        if math.floor(value) == value and math.abs(value) < 2^53 then
            return string.format("%d", value)
        end
        return string.format("%.4f", value)
    elseif valueType == "string" then
        value = value:gsub('\\', '\\\\')
            :gsub('"', '\\"')
            :gsub('\n', '\\n')
            :gsub('\r', '\\r')
            :gsub('\t', '\\t')
        return '"' .. value .. '"'
    elseif valueType == "table" then
        local meta = getmetatable(value)
        local forceArray = meta ~= nil and meta.__jsonArray == true
        local length = #value
        local keyCount = 0
        for _ in pairs(value) do keyCount = keyCount + 1 end

        local parts = {}
        if forceArray or (length > 0 and keyCount == length) then
            for i = 1, length do
                parts[i] = self:jsonEncode(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end

        for key, item in pairs(value) do
            if type(key) == "string" then
                table.insert(parts, self:jsonEncode(key) .. ":" .. self:jsonEncode(item))
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end

    return self:jsonEncode(tostring(value))
end

-- ======================================================================
-- REGISTRIEREN
-- ======================================================================

addModEventListener(AutoDriveFlurkarteLive)
