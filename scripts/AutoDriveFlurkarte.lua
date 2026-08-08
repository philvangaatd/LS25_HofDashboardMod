--[[
    FS25_AutoDriveFlurkarte – Live Data Export v4.1
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
AutoDriveFlurkarteLive.VERSION         = "4.1.0"
AutoDriveFlurkarteLive.SETTINGS_DIR    = "AutoDriveFlurkarte"
AutoDriveFlurkarteLive.OUTPUT_FILE     = "liveData.json"
AutoDriveFlurkarteLive.UPDATE_INTERVAL = 15000
AutoDriveFlurkarteLive.FIELD_SAMPLE_TARGET = 81
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

function AutoDriveFlurkarteLive:getGroundTypeName(value)
    return self.GROUND_TYPE_NAMES[value] or tostring(value or 0)
end

function AutoDriveFlurkarteLive:isWorkedGroundType(value)
    if FieldGroundType == nil then return false end
    return value == FieldGroundType.PLOWED
        or value == FieldGroundType.CULTIVATED
        or value == FieldGroundType.SEEDBED
        or value == FieldGroundType.ROLLED_SEEDBED
        or value == FieldGroundType.ROLLER_LINES
        or value == FieldGroundType.STUBBLE_TILLAGE
        or value == FieldGroundType.RIDGE
        or value == FieldGroundType.GRASS_CUT
end

function AutoDriveFlurkarteLive:isGrowingGroundType(value)
    if FieldGroundType == nil then return false end
    return value == FieldGroundType.SOWN
        or value == FieldGroundType.DIRECT_SOWN
        or value == FieldGroundType.RIDGE_SOWN
        or value == FieldGroundType.PLANTED
        or value == FieldGroundType.GRASS
end

function AutoDriveFlurkarteLive:pointInPolygon(x, z, polygon)
    local inside = false
    local j = #polygon

    for i = 1, #polygon do
        local xi, zi = polygon[i].x, polygon[i].z
        local xj, zj = polygon[j].x, polygon[j].z
        local intersects = ((zi > z) ~= (zj > z))
            and (x < (xj - xi) * (z - zi) / (zj - zi) + xi)
        if intersects then inside = not inside end
        j = i
    end

    return inside
end

function AutoDriveFlurkarteLive:getDominantKey(counts)
    local bestKey = nil
    local bestCount = -1
    for key, count in pairs(counts) do
        if count > bestCount then
            bestKey = key
            bestCount = count
        end
    end
    return bestKey, math.max(0, bestCount)
end

function AutoDriveFlurkarteLive:classifyFieldState(fieldState)
    if fieldState == nil or not fieldState.isValid then return "INVALID", nil end

    -- Ein real bearbeiteter Boden hat Vorrang vor eventuell noch vorhandenen
    -- Fruchtbits. Dadurch wird ein gepflügter/gegrubberter Bereich nicht mehr als
    -- erntereif erkannt, nur weil dort noch ein alter Fruchtzustand gemeldet wird.
    if self:isWorkedGroundType(fieldState.groundType) then
        return "TILLED", nil
    end

    local fruitIdx = fieldState.fruitTypeIndex
    local unknownFruit = FruitType ~= nil and FruitType.UNKNOWN or 0
    if fruitIdx == nil or fruitIdx == unknownFruit or fruitIdx == 0 then
        return "FALLOW", nil
    end

    local fruitType = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIdx) or nil
    if fruitType == nil then
        return "FALLOW", nil
    end

    local growthState = fieldState.growthState or 0
    if fruitType.getIsWithered ~= nil and fruitType:getIsWithered(growthState) then
        return "WITHERED", fruitType
    end
    if fruitType.getIsCut ~= nil and fruitType:getIsCut(growthState) then
        return "HARVESTED", fruitType
    end

    local minHarvest = fruitType.minHarvestingGrowthState or -1
    local maxHarvest = fruitType.maxHarvestingGrowthState or -1
    if minHarvest >= 0 and maxHarvest >= 0
        and growthState >= minHarvest and growthState <= maxHarvest then
        return "READY", fruitType
    end

    return "GROWING", fruitType
end

function AutoDriveFlurkarteLive:sampleField(field)
    local polygon = {}
    local polygonNodes = field:getPolygonPoints() or {}

    for _, point in ipairs(polygonNodes) do
        local x, _, z = getWorldTranslation(point)
        table.insert(polygon, {x = x, z = z})
    end

    local statusCounts = {}
    local groundCounts = {}
    local fruitCounts = {}
    local growthCountsByFruit = {}
    local fruitDescs = {}
    local totalSamples = 0

    local sums = {
        weedState = 0,
        weedFactor = 0,
        stoneLevel = 0,
        sprayLevel = 0,
        sprayType = 0,
        limeLevel = 0,
        rollerLevel = 0,
        plowLevel = 0,
        stubbleShredLevel = 0,
        waterLevel = 0,
    }

    local function addSample(x, z)
        local state = FieldState.new()
        local ok, err = pcall(function() state:update(x, z) end)
        if not ok then
            self:logError("FieldState.update", err)
            return
        end
        if not state.isValid then return end

        local status, fruitType = self:classifyFieldState(state)
        if status == "INVALID" then return end

        totalSamples = totalSamples + 1
        statusCounts[status] = (statusCounts[status] or 0) + 1
        groundCounts[state.groundType] = (groundCounts[state.groundType] or 0) + 1

        -- Frucht nur aus Bereichen übernehmen, die nicht bereits bearbeitet oder leer sind.
        -- So bleibt auf einem vollständig gepflügten Feld keine alte Kultur hängen.
        if fruitType ~= nil and status ~= "TILLED" and status ~= "FALLOW" then
            local fruitIdx = fruitType.index or state.fruitTypeIndex
            if fruitIdx ~= nil then
                fruitCounts[fruitIdx] = (fruitCounts[fruitIdx] or 0) + 1
                fruitDescs[fruitIdx] = fruitType
                growthCountsByFruit[fruitIdx] = growthCountsByFruit[fruitIdx] or {}
                local growthState = state.growthState or 0
                growthCountsByFruit[fruitIdx][growthState] = (growthCountsByFruit[fruitIdx][growthState] or 0) + 1
            end
        end

        sums.weedState = sums.weedState + (state.weedState or 0)
        sums.weedFactor = sums.weedFactor + (state.weedFactor or 0)
        sums.stoneLevel = sums.stoneLevel + (state.stoneLevel or 0)
        sums.sprayLevel = sums.sprayLevel + (state.sprayLevel or 0)
        sums.sprayType = sums.sprayType + (state.sprayType or 0)
        sums.limeLevel = sums.limeLevel + (state.limeLevel or 0)
        sums.rollerLevel = sums.rollerLevel + (state.rollerLevel or 0)
        sums.plowLevel = sums.plowLevel + (state.plowLevel or 0)
        sums.stubbleShredLevel = sums.stubbleShredLevel + (state.stubbleShredLevel or 0)
        sums.waterLevel = sums.waterLevel + (state.waterLevel or 0)
    end

    if #polygon >= 3 then
        local minX, maxX = math.huge, -math.huge
        local minZ, maxZ = math.huge, -math.huge
        for _, point in ipairs(polygon) do
            minX = math.min(minX, point.x)
            maxX = math.max(maxX, point.x)
            minZ = math.min(minZ, point.z)
            maxZ = math.max(maxZ, point.z)
        end

        local spanX = math.max(1, maxX - minX)
        local spanZ = math.max(1, maxZ - minZ)
        local aspect = spanX / spanZ
        local columns = math.ceil(math.sqrt(self.FIELD_SAMPLE_TARGET * aspect))
        columns = math.max(4, math.min(12, columns))
        local rows = math.ceil(self.FIELD_SAMPLE_TARGET / columns)
        rows = math.max(4, math.min(12, rows))

        for row = 1, rows do
            local z = minZ + (row - 0.5) / rows * spanZ
            for column = 1, columns do
                local x = minX + (column - 0.5) / columns * spanX
                if self:pointInPolygon(x, z, polygon) then
                    addSample(x, z)
                end
            end
        end
    end

    -- Sehr kleine/ungewöhnliche Feldpolygone: als Fallback exakt an der Feldmitte
    -- abfragen. Das ist immer noch ein aktueller FieldState.update()-Messpunkt und
    -- nicht der alte, feldweit gecachte field:getFieldState()-Wert.
    if totalSamples == 0 then
        local ok, x, z = pcall(function() return field:getCenterOfFieldWorldPosition() end)
        if ok and x ~= nil and z ~= nil then addSample(x, z) end
    end

    local result = {
        sampleCount = totalSamples,
        fieldStatus = "FALLOW",
        statusPercentages = {
            ready = 0,
            growing = 0,
            harvested = 0,
            tilled = 0,
            withered = 0,
            fallow = 0,
        },
        harvestReady = false,
        isWithered = false,
        fruitType = "NONE",
        fruitTitle = "Brache",
        fruitDesc = nil,
        growthState = 0,
        maxGrowthState = 0,
        growthName = "FALLOW",
        groundType = "NONE",
        weedState = 0,
        weedFactor = 0,
        stoneLevel = 0,
        sprayLevel = 0,
        sprayType = 0,
        limeLevel = 0,
        rollerLevel = 0,
        plowLevel = 0,
        stubbleShredLevel = 0,
        waterLevel = 0,
    }

    if totalSamples == 0 then return result end

    local function pct(status)
        return self:round((statusCounts[status] or 0) / totalSamples * 100, 1)
    end

    result.statusPercentages.ready = pct("READY")
    result.statusPercentages.growing = pct("GROWING")
    result.statusPercentages.harvested = pct("HARVESTED")
    result.statusPercentages.tilled = pct("TILLED")
    result.statusPercentages.withered = pct("WITHERED")
    result.statusPercentages.fallow = pct("FALLOW")

    local dominantStatus, dominantStatusCount = self:getDominantKey(statusCounts)
    local dominantShare = dominantStatusCount / totalSamples
    local significantStates = 0
    for _, count in pairs(statusCounts) do
        if count / totalSamples >= 0.08 then significantStates = significantStates + 1 end
    end

    if dominantStatus ~= nil then
        if significantStates > 1 and dominantShare < 0.85 then
            result.fieldStatus = "MIXED"
        else
            result.fieldStatus = dominantStatus
        end
    end

    result.harvestReady = result.statusPercentages.ready >= 50
    result.isWithered = result.fieldStatus == "WITHERED"

    local dominantGround = self:getDominantKey(groundCounts)
    if dominantGround ~= nil then
        result.groundType = self:getGroundTypeName(dominantGround)
    end

    -- Für die bestehende PHP-Schnittstelle weiterhin einen plausiblen groundType
    -- liefern. fieldStatus bleibt zusätzlich als neue, eindeutige Quelle erhalten.
    if result.fieldStatus == "READY" then
        result.groundType = "HARVEST_READY"
    elseif result.fieldStatus == "GROWING" then
        if dominantGround == nil or not self:isGrowingGroundType(dominantGround) then
            result.groundType = "SOWN"
        end
    elseif result.fieldStatus == "TILLED" and (dominantGround == nil or not self:isWorkedGroundType(dominantGround)) then
        result.groundType = "CULTIVATED"
    elseif result.fieldStatus == "HARVESTED" then
        result.groundType = "GRASS_CUT"
    elseif result.fieldStatus == "MIXED" then
        -- Mischfelder dürfen niemals allein wegen eines verbliebenen erntereifen
        -- Teilbereichs als komplett erntereif erscheinen.
        result.harvestReady = false
        if dominantGround == nil or not self:isWorkedGroundType(dominantGround) then
            result.groundType = "CULTIVATED"
        end
    end

    local dominantFruitIdx = self:getDominantKey(fruitCounts)
    if dominantFruitIdx ~= nil then
        local fruitType = fruitDescs[dominantFruitIdx]
        if fruitType ~= nil then
            result.fruitDesc = fruitType
            result.fruitType = string.upper(fruitType.name or "UNKNOWN")
            result.fruitTitle = (fruitType.fillType and fruitType.fillType.title) or fruitType.name or result.fruitType
            result.maxGrowthState = fruitType.maxHarvestingGrowthState or fruitType.numGrowthStates or 0

            local growthCounts = growthCountsByFruit[dominantFruitIdx] or {}
            local dominantGrowthState = self:getDominantKey(growthCounts)
            result.growthState = dominantGrowthState or 0
        end
    end

    if result.fieldStatus == "READY" then
        result.growthName = "READY_TO_HARVEST"
    elseif result.fieldStatus == "GROWING" then
        result.growthName = "GROWING"
    elseif result.fieldStatus == "HARVESTED" then
        result.growthName = "CUT"
    elseif result.fieldStatus == "WITHERED" then
        result.growthName = "WITHERED"
    elseif result.fieldStatus == "MIXED" then
        result.growthName = "MIXED"
    elseif result.fieldStatus == "TILLED" then
        result.growthName = "TILLED"
    else
        result.growthName = "FALLOW"
    end

    local divisor = totalSamples
    result.weedState = self:round(sums.weedState / divisor, 0)
    result.weedFactor = self:round(sums.weedFactor / divisor, 3)
    result.stoneLevel = self:round(sums.stoneLevel / divisor, 0)
    result.sprayLevel = self:round(sums.sprayLevel / divisor, 0)
    result.sprayType = self:round(sums.sprayType / divisor, 0)
    result.limeLevel = self:round(sums.limeLevel / divisor, 0)
    result.rollerLevel = self:round(sums.rollerLevel / divisor, 0)
    result.plowLevel = self:round(sums.plowLevel / divisor, 0)
    result.stubbleShredLevel = self:round(sums.stubbleShredLevel / divisor, 0)
    result.waterLevel = self:round(sums.waterLevel / divisor, 0)

    return result
end

-- ======================================================================
-- LIFECYCLE
-- ======================================================================

function AutoDriveFlurkarteLive:loadMap(filename)
    self.isReady = true
    self.timer = self.UPDATE_INTERVAL

    self.GROUND_TYPE_NAMES = {}
    if FieldGroundType ~= nil then
        local knownGroundTypes = {
            "NONE", "PLOWED", "CULTIVATED", "SEEDBED", "ROLLED_SEEDBED",
            "ROLLER_LINES", "STUBBLE_TILLAGE", "RIDGE", "GRASS_CUT",
            "SOWN", "DIRECT_SOWN", "RIDGE_SOWN", "PLANTED", "GRASS",
            "HARVEST_READY", "HARVEST_READY_OTHER",
        }
        for _, name in ipairs(knownGroundTypes) do
            local value = FieldGroundType[name]
            if type(value) == "number" then self.GROUND_TYPE_NAMES[value] = name end
        end
        -- Unbekannte/neue GIANTS-Typen zusätzlich aufnehmen.
        for name, value in pairs(FieldGroundType) do
            if type(name) == "string" and type(value) == "number" and self.GROUND_TYPE_NAMES[value] == nil then
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
-- WICHTIG: field:getFieldState() liefert nur einen zusammengefassten Feldzustand.
-- Das ist für laufende Feldarbeit (teilweise geerntet/gepflügt) nicht ausreichend.
-- Wir lesen deshalb mehrere aktuelle FieldState.update(x,z)-Messpunkte innerhalb
-- des echten Feldpolygons und bilden daraus einen belastbaren Feldzustand.
-- GIANTS nutzt FieldState.update(x,z) selbst für die positionsgenaue Feldanalyse.
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
    local sampled = self:sampleField(field)

    return {
        id                = field:getId() or 0,
        farmlandId        = farmland.id or 0,
        farmId            = myFarmId,
        area              = self:round(field.areaHa or 0, 2),
        sampleCount       = sampled.sampleCount,
        fieldStatus       = sampled.fieldStatus,
        statusPercentages = sampled.statusPercentages,
        fruitType         = sampled.fruitType,
        fruitTitle        = sampled.fruitTitle,
        maxGrowthState    = sampled.maxGrowthState,
        growthState       = sampled.growthState,
        growthName        = sampled.growthName,
        harvestReady      = sampled.harvestReady,
        isWithered        = sampled.isWithered,
        groundType        = sampled.groundType,
        weedState         = sampled.weedState,
        weedFactor        = sampled.weedFactor,
        stoneLevel        = sampled.stoneLevel,
        sprayLevel        = sampled.sprayLevel,
        sprayType         = sampled.sprayType,
        limeLevel         = sampled.limeLevel,
        rollerLevel       = sampled.rollerLevel,
        plowLevel         = sampled.plowLevel,
        stubbleShredLevel = sampled.stubbleShredLevel,
        waterLevel        = sampled.waterLevel,
    }
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

    if vehicle.getDirtAmount ~= nil then
        data.dirt = self:round(vehicle:getDirtAmount() or 0, 3)
    end

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

    createFolder(modSettingsDir)
    createFolder(modDir)

    local file, openError = io.open(targetPath, "w")
    if file == nil then
        self:logError("writeFile", openError or "Datei konnte nicht geöffnet werden")
        return
    end

    local ok, writeError = pcall(function()
        file:write(content)
    end)
    pcall(function() file:close() end)

    if not ok then
        self:logError("writeFile", writeError or "Schreiben fehlgeschlagen")
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
