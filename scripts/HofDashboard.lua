--[[
    LS25 Hof-Dashboard – Live Connector v5.0
    =================================================
    Schreibt alle 15 Sekunden eine JSON-Datei nach:
      <UserDocuments>/My Games/FarmingSimulator2025/modSettings/LS25HofDashboard/liveData.json

    Datenfluss: FS25 Lua API -> liveData.json -> PHP API -> Frontend.
    Der Lua-Mod ist die autoritative Quelle für alle Live-Zustände.
    API-Referenz: https://gdn.giants-software.com/documentation_scripting_fs25.php
]]

local MODNAME = g_currentModName or "FS25_HofDashboard"
local JSON_ARRAY_MT = { __jsonArray = true }
local RELEASE = HofDashboardRelease

if RELEASE == nil then
    error("[FS25_HofDashboard] scripts/Version.lua wurde nicht vor dem Kernmodul geladen")
end

HofDashboardLive                 = {}
HofDashboardLive.MOD_NAME        = MODNAME
HofDashboardLive.VERSION         = RELEASE.MOD_VERSION
HofDashboardLive.PROTOCOL_VERSION = RELEASE.PROTOCOL_VERSION
HofDashboardLive.MIN_DASHBOARD_VERSION = RELEASE.MIN_DASHBOARD_VERSION
HofDashboardLive.SETTINGS_DIR    = "LS25HofDashboard"
HofDashboardLive.OUTPUT_FILE     = "liveData.json"
HofDashboardLive.UPDATE_INTERVAL = 15000
HofDashboardLive.FIELD_SAMPLE_TARGET = 81
HofDashboardLive.timer           = 0
HofDashboardLive.isReady         = false
HofDashboardLive.FUEL_TYPES      = nil
HofDashboardLive.FUEL_BY_INDEX   = nil
HofDashboardLive.GROUND_TYPE_NAMES = {}

-- ======================================================================
-- HILFSFUNKTIONEN
-- ======================================================================

function HofDashboardLive:newArray()
    return setmetatable({}, JSON_ARRAY_MT)
end

function HofDashboardLive:round(value, digits)
    local factor = 10 ^ (digits or 0)
    return math.floor((value or 0) * factor + 0.5) / factor
end

function HofDashboardLive:logError(scope, err)
    print(string.format("[%s] %s: %s", self.MOD_NAME, tostring(scope), tostring(err)))
end

function HofDashboardLive:protected(scope, fn)
    local ok, result = pcall(fn)
    if not ok then
        self:logError(scope, result)
        return false, nil
    end
    return true, result
end

function HofDashboardLive:safeGet(fn, fallback)
    local ok, val = pcall(fn)
    if ok and val ~= nil then return val end
    return fallback
end

function HofDashboardLive:getPlayerFarmId()
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

function HofDashboardLive:getGroundTypeName(value)
    return self.GROUND_TYPE_NAMES[value] or tostring(value or 0)
end

function HofDashboardLive:isWorkedGroundType(value)
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

function HofDashboardLive:isGrowingGroundType(value)
    if FieldGroundType == nil then return false end
    return value == FieldGroundType.SOWN
        or value == FieldGroundType.DIRECT_SOWN
        or value == FieldGroundType.RIDGE_SOWN
        or value == FieldGroundType.PLANTED
        or value == FieldGroundType.GRASS
end

function HofDashboardLive:pointInPolygon(x, z, polygon)
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

function HofDashboardLive:getDominantKey(counts)
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

function HofDashboardLive:classifyFieldState(fieldState)
    if fieldState == nil or not fieldState.isValid then return "INVALID", nil end

    -- Frucht- und Bodenzustand sind im FS25 voneinander unabhängige Density-Map-
    -- Informationen. Gerade bei vorbefüllten Karten kann eine sichtbare Kultur je
    -- nach GrowthState einen Bodentyp wie CULTIVATED melden. Deshalb darf ein
    -- "bearbeiteter" groundType eine tatsächlich vorhandene, stehende Kultur nicht
    -- pauschal überstimmen.
    local fruitIdx = fieldState.fruitTypeIndex
    local unknownFruit = FruitType ~= nil and FruitType.UNKNOWN or 0
    local fruitType = nil
    if fruitIdx ~= nil and fruitIdx ~= unknownFruit and fruitIdx ~= 0 then
        fruitType = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIdx) or nil
    end

    if fruitType ~= nil then
        local growthState = fieldState.growthState or 0

        if fruitType.getIsWithered ~= nil and fruitType:getIsWithered(growthState) then
            return "WITHERED", fruitType
        end

        -- Bei bereits geschnittener Frucht hat ein anschließend bearbeiteter Boden
        -- Vorrang: nach Grubbern/Pflügen soll der Bereich als TILLED erscheinen und
        -- nicht dauerhaft als abgeerntete Kultur hängen bleiben.
        if fruitType.getIsCut ~= nil and fruitType:getIsCut(growthState) then
            if self:isWorkedGroundType(fieldState.groundType) then
                return "TILLED", nil
            end
            return "HARVESTED", fruitType
        end

        local minHarvest = fruitType.minHarvestingGrowthState or -1
        local maxHarvest = fruitType.maxHarvestingGrowthState or -1
        if minHarvest >= 0 and maxHarvest >= 0
            and growthState >= minHarvest and growthState <= maxHarvest then
            return "READY", fruitType
        end

        -- Jede weitere valide, nicht geschnittene Frucht ist eine stehende Kultur.
        -- Das gilt bewusst auch dann, wenn ihr GrowthState einen CULTIVATED-ähnlichen
        -- groundType verwendet.
        return "GROWING", fruitType
    end

    if self:isWorkedGroundType(fieldState.groundType) then
        return "TILLED", nil
    end

    return "FALLOW", nil
end

function HofDashboardLive:sampleField(field)
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

function HofDashboardLive:loadMap(filename)
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

function HofDashboardLive:deleteMap()
    self.isReady = false
end

function HofDashboardLive:update(dt)
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

function HofDashboardLive:exportAllData()
    local vehicles = self:collectVehicles()
    local data = {
        version       = self.VERSION,
        protocolVersion = self.PROTOCOL_VERSION,
        minimumDashboardVersion = self.MIN_DASHBOARD_VERSION,
        modName       = self.MOD_NAME,
        timestamp     = getDate("%Y-%m-%dT%H:%M:%S"),
        mapName       = self:safeGet(function() return g_currentMission.missionInfo.mapTitle end, "Unknown"),
        currentDay    = self:safeGet(function() return g_currentMission.environment.currentDay or 0 end, 0),
        daysPerPeriod = self:safeGet(function() return g_currentMission.environment.daysPerPeriod or 24 end, 24),
        farm           = self:collectFarm(),
        fields         = self:collectFields(),
        vehicles       = vehicles,
        vehicleDiagnostics = self.vehicleDiagnostics or { seen = 0, exported = #vehicles, failed = 0, skipped = 0 },
        animals        = self:collectAnimals(),
        animalDiagnostics = self.animalDiagnostics or { seen = 0, exported = 0, failed = 0, skipped = 0 },
        beehives       = self:collectBeehives(),
        productions    = self:collectProductions(),
        contracts      = self:collectContracts(),
        market         = self:collectMarket(),
    }

    self:writeFile(self:jsonEncode(data))
end

-- ======================================================================
-- HOF-INFORMATIONEN
-- ======================================================================

function HofDashboardLive:collectFarm()
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

function HofDashboardLive:collectFields()
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

function HofDashboardLive:processFarmland(farmland, myFarmId)
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

function HofDashboardLive:collectVehicles()
    local result = self:newArray()
    local diagnostics = { seen = 0, exported = 0, failed = 0, skipped = 0 }
    self.vehicleDiagnostics = diagnostics

    -- FS25 verwaltet die registrierten Savegame-Fahrzeuge im VehicleSystem.
    -- g_currentMission.vehicles ist in aktuellen Builds nicht die Fahrzeugliste und
    -- kann nil sein, wodurch der bisherige Export sofort mit seen=0 zurückkehrte.
    local vehicleSystem = g_currentMission and g_currentMission.vehicleSystem or nil
    local vehicles = vehicleSystem and vehicleSystem.vehicles or nil
    if vehicles == nil then
        self:logError("collectVehicles", "g_currentMission.vehicleSystem.vehicles nicht verfügbar")
        return result
    end

    local myFarmId = self:getPlayerFarmId()
    if myFarmId <= 0 then
        self:logError("collectVehicles", "Spieler-FarmId konnte nicht ermittelt werden")
        return result
    end

    for _, vehicle in pairs(vehicles) do
        diagnostics.seen = diagnostics.seen + 1
        local ok, vehicleData = self:protected(
            "processVehicle " .. tostring(vehicle.typeName or "?"),
            function() return self:processVehicle(vehicle, myFarmId) end
        )
        if not ok then
            diagnostics.failed = diagnostics.failed + 1
        elseif vehicleData ~= nil then
            diagnostics.exported = diagnostics.exported + 1
            table.insert(result, vehicleData)
        else
            diagnostics.skipped = diagnostics.skipped + 1
        end
    end

    table.sort(result, function(a, b)
        if a.vehicleCategory ~= b.vehicleCategory then
            return tostring(a.vehicleCategory) < tostring(b.vehicleCategory)
        end
        return tostring(a.name or "") < tostring(b.name or "")
    end)

    return result
end

function HofDashboardLive:getVehicleOwnerFarmId(vehicle)
    local ownerId = 0
    if vehicle.getOwnerFarmId ~= nil then
        ownerId = self:safeGet(function() return vehicle:getOwnerFarmId() end, 0) or 0
    end
    if ownerId <= 0 then ownerId = vehicle.ownerFarmId or 0 end
    return ownerId
end

function HofDashboardLive:getVehicleCategory(vehicle)
    if vehicle.spec_motorized ~= nil or vehicle.spec_enterable ~= nil or vehicle.spec_drivable ~= nil then
        return "VEHICLE"
    end
    if vehicle.spec_trailer ~= nil then return "TRAILER" end
    return "IMPLEMENT"
end

function HofDashboardLive:getVehicleStoreInfo(vehicle)
    local info = {
        brand = "",
        model = "",
        name = "",
        shopPrice = 0,
        configFileName = vehicle.configFileName or "",
    }

    local storeItem = nil
    if g_storeManager ~= nil and info.configFileName ~= "" then
        storeItem = self:safeGet(function()
            return g_storeManager:getItemByXMLFilename(info.configFileName)
        end, nil)
    end

    info.model = self:safeGet(function() return vehicle:getName() end, "") or ""
    if info.model == "" and storeItem ~= nil then info.model = storeItem.name or "" end
    if info.model == "" then info.model = vehicle.typeName or "Unbekannt" end

    if storeItem ~= nil and g_brandManager ~= nil then
        local brand = self:safeGet(function() return g_brandManager:getBrandByIndex(storeItem.brandIndex) end, nil)
        if brand ~= nil then info.brand = brand.title or brand.name or "" end
    end

    if storeItem ~= nil and StoreItemUtil ~= nil and StoreItemUtil.getDefaultPrice ~= nil then
        info.shopPrice = math.floor(self:safeGet(function()
            return StoreItemUtil.getDefaultPrice(storeItem, vehicle.configurations or {})
        end, 0) or 0)
    end
    if info.shopPrice <= 0 and vehicle.getPrice ~= nil then
        info.shopPrice = math.floor(self:safeGet(function() return vehicle:getPrice() end, 0) or 0)
    end

    if info.brand ~= "" then
        info.name = info.brand .. " " .. info.model
    else
        info.name = info.model
    end
    info.name = info.name:gsub("^%s+", ""):gsub("%s+$", "")
    return info
end

function HofDashboardLive:getFillTypeData(fillTypeIndex)
    if fillTypeIndex == nil or FillType == nil or fillTypeIndex == FillType.UNKNOWN then return nil end
    local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
    if fillType == nil then return nil end
    local name = string.upper(fillType.name or "UNKNOWN")
    local title = fillType.title or fillType.name or name

    -- GIANTS lokalisiert DEF auf Deutsch technisch als "Synthetische Harnstofflösung".
    -- Für die Fuhrpark-Anzeige verwenden wir bewusst die im Fahrzeugkontext übliche
    -- und deutlich kürzere Bezeichnung "AdBlue".
    if name == "DEF" then title = "AdBlue" end

    return {
        index = fillTypeIndex,
        name = name,
        title = title,
    }
end

function HofDashboardLive:isIgnoredVehicleFillType(name)
    return name == "AIR" or name == "BALE_NET" or name == "UNKNOWN"
end

function HofDashboardLive:processVehicle(vehicle, myFarmId)
    if vehicle == nil or vehicle.spec_pallet ~= nil then return nil end

    local ownerId = self:getVehicleOwnerFarmId(vehicle)
    if ownerId ~= myFarmId then return nil end

    local store = self:getVehicleStoreInfo(vehicle)
    local category = self:getVehicleCategory(vehicle)
    local operatingMs = 0
    if vehicle.getOperatingTime ~= nil then
        operatingMs = self:safeGet(function() return vehicle:getOperatingTime() end, 0) or 0
    end

    local data = {
        uniqueId        = "",
        farmId          = ownerId,
        vehicleCategory = category,
        vehicleType     = category,
        typeName        = vehicle.typeName or "",
        configFileName  = store.configFileName,
        brand           = store.brand,
        model           = store.model,
        name            = store.name,
        shopPrice       = store.shopPrice,
        price           = store.shopPrice, -- Kompatibilitätsalias für bestehende UI
        operatingHours  = self:round(operatingMs / 3600000, 1),
        wear            = 0,
        dirt            = 0,
        isWorking       = self:safeGet(function() return vehicle:getIsAIActive() end, false),
        fuel            = self:newArray(),
        cargo           = self:newArray(),
        fillUnits       = self:newArray(),
    }

    if vehicle.getUniqueId ~= nil then
        local value = self:safeGet(function() return vehicle:getUniqueId() end, nil)
        if value ~= nil then data.uniqueId = tostring(value) end
    end

    if vehicle.getDamageAmount ~= nil then
        data.wear = self:round(self:safeGet(function() return vehicle:getDamageAmount() end, 0) or 0, 3)
    elseif vehicle.getVehicleDamage ~= nil then
        data.wear = self:round(self:safeGet(function() return vehicle:getVehicleDamage() end, 0) or 0, 3)
    end

    if vehicle.getDirtAmount ~= nil then
        data.dirt = self:round(self:safeGet(function() return vehicle:getDirtAmount() end, 0) or 0, 3)
    end

    if vehicle.getFillUnits ~= nil then
        local fillUnits = self:safeGet(function() return vehicle:getFillUnits() end, {}) or {}
        for fillUnitIndex, _ in ipairs(fillUnits) do
            local capacity = self:safeGet(function() return vehicle:getFillUnitCapacity(fillUnitIndex) end, 0) or 0
            if capacity > 0 then
                local level = self:safeGet(function() return vehicle:getFillUnitFillLevel(fillUnitIndex) end, 0) or 0
                local fillTypeIndex = self:safeGet(function() return vehicle:getFillUnitFillType(fillUnitIndex) end, FillType.UNKNOWN)
                local supported = {}
                if vehicle.getFillUnitSupportedFillTypes ~= nil then
                    supported = self:safeGet(function() return vehicle:getFillUnitSupportedFillTypes(fillUnitIndex) end, {}) or {}
                end

                -- GIANTS zeigt bei einer leeren Unit mit genau einem unterstützten Typ
                -- ebenfalls diesen Typ an. Das übernehmen wir für Diesel/AdBlue/Saatgut etc.
                if fillTypeIndex == nil or fillTypeIndex == FillType.UNKNOWN then
                    local onlyIndex = nil
                    local count = 0
                    for supportedIndex, enabled in pairs(supported) do
                        if enabled then
                            onlyIndex = supportedIndex
                            count = count + 1
                        end
                    end
                    if count == 1 then fillTypeIndex = onlyIndex end
                end

                local current = self:getFillTypeData(fillTypeIndex)
                local supportedList = self:newArray()
                local hasDisplayableSupportedType = false
                local fuelSupported = false
                for supportedIndex, enabled in pairs(supported) do
                    if enabled then
                        local entry = self:getFillTypeData(supportedIndex)
                        if entry ~= nil then
                            table.insert(supportedList, entry)
                            if not self:isIgnoredVehicleFillType(entry.name) then hasDisplayableSupportedType = true end
                            if self.FUEL_BY_INDEX ~= nil and self.FUEL_BY_INDEX[supportedIndex] ~= nil then fuelSupported = true end
                        end
                    end
                end

                local currentName = current and current.name or "UNKNOWN"
                local shouldShow = not self:isIgnoredVehicleFillType(currentName) or hasDisplayableSupportedType
                if shouldShow then
                    local isFuel = (self.FUEL_BY_INDEX ~= nil and self.FUEL_BY_INDEX[fillTypeIndex] ~= nil) or fuelSupported
                    local kind = isFuel and "FUEL" or "CARGO"
                    local percent = math.floor(math.min(100, math.max(0, level / capacity * 100)) + 0.5)
                    local fillEntry = {
                        index = fillUnitIndex,
                        kind = kind,
                        fillType = current and current.name or "UNKNOWN",
                        title = current and current.title or (level > 0.01 and "Unbekannt" or "Leer"),
                        liters = self:round(level, 1),
                        capacity = self:round(capacity, 1),
                        percent = percent,
                        supportedFillTypes = supportedList,
                    }
                    table.insert(data.fillUnits, fillEntry)

                    local compatibilityEntry = {
                        fillType = fillEntry.fillType,
                        label = fillEntry.title,
                        title = fillEntry.title,
                        liters = fillEntry.liters,
                        capacity = fillEntry.capacity,
                        percent = fillEntry.percent,
                    }
                    if kind == "FUEL" then
                        table.insert(data.fuel, compatibilityEntry)
                    else
                        table.insert(data.cargo, compatibilityEntry)
                    end
                end
            end
        end
    end

    return data
end

-- ======================================================================
-- TIERHALTUNG / BIENEN – LIVE
--
-- Der Lua-Mod ist auch hier die autoritative Quelle. Die Daten werden direkt
-- aus den laufenden Husbandry-Specializations gelesen, nicht aus placeables.xml.
-- ======================================================================

function HofDashboardLive:normalizeAnimalFactor(value)
    value = tonumber(value) or 0
    if value > 1 then value = value / 100 end
    return math.max(0, math.min(1, value))
end

function HofDashboardLive:getPlaceableOwnerFarmId(placeable)
    if placeable ~= nil and placeable.getOwnerFarmId ~= nil then
        return self:safeGet(function() return placeable:getOwnerFarmId() end, placeable.ownerFarmId or 0) or 0
    end
    return placeable and (placeable.ownerFarmId or 0) or 0
end

function HofDashboardLive:getHusbandryFill(placeable, fillTypeIndex)
    if fillTypeIndex == nil then return 0, 0 end
    local level = 0
    local capacity = 0
    if placeable.getHusbandryFillLevel ~= nil then
        level = self:safeGet(function() return placeable:getHusbandryFillLevel(fillTypeIndex) end, 0) or 0
    end
    if placeable.getHusbandryCapacity ~= nil then
        capacity = self:safeGet(function() return placeable:getHusbandryCapacity(fillTypeIndex) end, 0) or 0
    end
    return math.max(0, level), math.max(0, capacity)
end

function HofDashboardLive:makeHusbandryFillEntry(placeable, fillTypeIndex, extra)
    local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
    if fillType == nil then return nil end
    local level, capacity = self:getHusbandryFill(placeable, fillTypeIndex)
    local entry = {
        fillType = string.upper(fillType.name or "UNKNOWN"),
        title = fillType.title or fillType.name or "Unbekannt",
        level = self:round(level, 1),
        capacity = self:round(capacity, 1),
        percent = capacity > 0 and math.floor(math.min(100, level / capacity * 100) + 0.5) or 0,
    }
    if extra ~= nil then
        for key, value in pairs(extra) do entry[key] = value end
    end
    return entry
end

function HofDashboardLive:getAnimalSubTypeTitle(subType)
    if subType == nil then return "Unbekannt" end
    if type(subType.title) == "string" and subType.title ~= "" then return subType.title end

    local fillTypeIndex = subType.fillTypeIndex
    if fillTypeIndex == nil and type(subType.fillType) == "number" then fillTypeIndex = subType.fillType end
    if fillTypeIndex == nil and type(subType.name) == "string" and g_fillTypeManager ~= nil then
        fillTypeIndex = self:safeGet(function() return g_fillTypeManager:getFillTypeIndexByName(subType.name) end, nil)
    end
    if fillTypeIndex ~= nil and g_fillTypeManager ~= nil then
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillType ~= nil and fillType.title ~= nil and fillType.title ~= "" then return fillType.title end
    end

    return tostring(subType.name or "Unbekannt")
end

function HofDashboardLive:collectAnimals()
    local result = self:newArray()
    local diagnostics = { seen = 0, exported = 0, failed = 0, skipped = 0 }
    self.animalDiagnostics = diagnostics

    if g_currentMission == nil or g_currentMission.placeables == nil then return result end
    local myFarmId = self:getPlayerFarmId()
    if myFarmId <= 0 then
        self:logError("collectAnimals", "Spieler-FarmId konnte nicht ermittelt werden")
        return result
    end

    for _, placeable in pairs(g_currentMission.placeables) do
        if placeable ~= nil and placeable.spec_husbandryAnimals ~= nil then
            diagnostics.seen = diagnostics.seen + 1
            local ok, data = self:protected(
                "processHusbandry " .. tostring(placeable.typeName or "?"),
                function() return self:processHusbandry(placeable, myFarmId) end
            )
            if not ok then
                diagnostics.failed = diagnostics.failed + 1
            elseif data ~= nil then
                diagnostics.exported = diagnostics.exported + 1
                table.insert(result, data)
            else
                diagnostics.skipped = diagnostics.skipped + 1
            end
        end
    end

    table.sort(result, function(a, b)
        if (a.totalAnimals or 0) ~= (b.totalAnimals or 0) then
            return (a.totalAnimals or 0) > (b.totalAnimals or 0)
        end
        return tostring(a.name or "") < tostring(b.name or "")
    end)
    return result
end

function HofDashboardLive:processHusbandry(placeable, myFarmId)
    local specAnimals = placeable.spec_husbandryAnimals
    if specAnimals == nil then return nil end

    local farmId = self:getPlaceableOwnerFarmId(placeable)
    if farmId ~= myFarmId then return nil end

    local animalTypeIndex = 0
    if placeable.getAnimalTypeIndex ~= nil then
        animalTypeIndex = self:safeGet(function() return placeable:getAnimalTypeIndex() end, 0) or 0
    else
        animalTypeIndex = specAnimals.animalTypeIndex or 0
    end

    local animalSystem = g_currentMission and g_currentMission.animalSystem or nil
    local animalType = animalSystem and animalSystem:getTypeByIndex(animalTypeIndex) or nil
    local animalTypeName = animalType and tostring(animalType.name or "") or tostring(animalTypeIndex)

    local clusters = self:newArray()
    local sourceClusters = {}
    if placeable.getClusters ~= nil then
        sourceClusters = self:safeGet(function() return placeable:getClusters() end, {}) or {}
    elseif specAnimals.clusterSystem ~= nil and specAnimals.clusterSystem.getClusters ~= nil then
        sourceClusters = self:safeGet(function() return specAnimals.clusterSystem:getClusters() end, {}) or {}
    end

    local totalAnimals = 0
    local weightedHealth = 0
    local weightedReproduction = 0

    for _, cluster in ipairs(sourceClusters) do
        local count = cluster.getNumAnimals ~= nil
            and (self:safeGet(function() return cluster:getNumAnimals() end, 0) or 0)
            or (cluster.numAnimals or 0)
        local age = cluster.getAge ~= nil
            and (self:safeGet(function() return cluster:getAge() end, 0) or 0)
            or (cluster.age or 0)
        local subTypeIndex = cluster.getSubTypeIndex ~= nil
            and self:safeGet(function() return cluster:getSubTypeIndex() end, cluster.subTypeIndex)
            or cluster.subTypeIndex
        local subType = animalSystem and subTypeIndex ~= nil and animalSystem:getSubTypeByIndex(subTypeIndex) or nil

        local health = cluster.health
        if cluster.getHealth ~= nil then health = self:safeGet(function() return cluster:getHealth() end, health) end
        health = self:normalizeAnimalFactor(health)

        local reproduction = cluster.reproduction or cluster.reproductionEfficiency or 0
        if cluster.getReproduction ~= nil then
            reproduction = self:safeGet(function() return cluster:getReproduction() end, reproduction)
        end
        reproduction = self:normalizeAnimalFactor(reproduction)

        local isPregnant = cluster.isPregnant == true
        if cluster.getIsPregnant ~= nil then isPregnant = self:safeGet(function() return cluster:getIsPregnant() end, isPregnant) == true end
        local isParent = cluster.isParent == true
        if cluster.getIsParent ~= nil then isParent = self:safeGet(function() return cluster:getIsParent() end, isParent) == true end

        totalAnimals = totalAnimals + count
        weightedHealth = weightedHealth + health * count
        weightedReproduction = weightedReproduction + reproduction * count

        table.insert(clusters, {
            subTypeIndex = subTypeIndex or 0,
            subType = subType and tostring(subType.name or "") or "",
            breedTitle = self:getAnimalSubTypeTitle(subType),
            ageMonths = self:round(age, 1),
            numAnimals = count,
            health = self:round(health, 3),
            reproduction = self:round(reproduction, 3),
            isPregnant = isPregnant,
            isParent = isParent,
        })
    end

    table.sort(clusters, function(a, b)
        if tostring(a.breedTitle) ~= tostring(b.breedTitle) then return tostring(a.breedTitle) < tostring(b.breedTitle) end
        return (a.ageMonths or 0) > (b.ageMonths or 0)
    end)

    local maxAnimals = placeable.getMaxNumOfAnimals ~= nil
        and (self:safeGet(function() return placeable:getMaxNumOfAnimals() end, 0) or 0)
        or (specAnimals.maxNumAnimals or 0)
    local productivity = placeable.getGlobalProductionFactor ~= nil
        and (self:safeGet(function() return placeable:getGlobalProductionFactor() end, 0) or 0)
        or 0
    productivity = self:normalizeAnimalFactor(productivity)

    local data = {
        uniqueId = "",
        name = self:safeGet(function() return placeable:getName() end, "Tierhaltung") or "Tierhaltung",
        farmId = farmId,
        animalTypeIndex = animalTypeIndex,
        animalType = string.upper(animalTypeName),
        totalAnimals = totalAnimals,
        maxAnimals = math.max(0, maxAnimals),
        freeSlots = math.max(0, maxAnimals - totalAnimals),
        occupancyPercent = maxAnimals > 0 and math.floor(math.min(100, totalAnimals / maxAnimals * 100) + 0.5) or 0,
        productivity = self:round(productivity, 3),
        health = totalAnimals > 0 and self:round(weightedHealth / totalAnimals, 3) or 0,
        reproduction = totalAnimals > 0 and self:round(weightedReproduction / totalAnimals, 3) or 0,
        clusters = clusters,
        food = { enabled = false, level = 0, capacity = 0, percent = 0, fillTypes = self:newArray(), groups = self:newArray() },
        water = { enabled = false, automatic = false, level = 0, capacity = 0, percent = 0, litersPerHour = 0 },
        straw = { enabled = false, level = 0, capacity = 0, percent = 0, litersPerHour = 0 },
        meadow = { enabled = false, level = 0, capacity = 0, percent = 0, fillTypes = self:newArray() },
        outputs = self:newArray(),
    }

    if placeable.getUniqueId ~= nil then
        local uid = self:safeGet(function() return placeable:getUniqueId() end, nil)
        if uid ~= nil then data.uniqueId = tostring(uid) end
    elseif placeable.uniqueId ~= nil then
        data.uniqueId = tostring(placeable.uniqueId)
    end

    -- Futter: aktuelle Füllstände + Gruppen und deren Produktionsgewicht.
    local foodSpec = placeable.spec_husbandryFood
    if foodSpec ~= nil then
        data.food.enabled = true
        local totalFood = placeable.getTotalFood ~= nil
            and (self:safeGet(function() return placeable:getTotalFood() end, 0) or 0)
            or 0
        local foodCapacity = placeable.getFoodCapacity ~= nil
            and (self:safeGet(function() return placeable:getFoodCapacity() end, foodSpec.capacity or 0) or 0)
            or (foodSpec.capacity or 0)
        data.food.level = self:round(totalFood, 1)
        data.food.capacity = self:round(foodCapacity, 1)
        data.food.percent = foodCapacity > 0 and math.floor(math.min(100, totalFood / foodCapacity * 100) + 0.5) or 0

        for fillTypeIndex, level in pairs(foodSpec.fillLevels or {}) do
            local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
            if fillType ~= nil then
                table.insert(data.food.fillTypes, {
                    fillType = string.upper(fillType.name or "UNKNOWN"),
                    title = fillType.title or fillType.name or "Unbekannt",
                    level = self:round(level or 0, 1),
                })
            end
        end
        table.sort(data.food.fillTypes, function(a, b) return tostring(a.title) < tostring(b.title) end)

        local animalFoodSystem = g_currentMission and g_currentMission.animalFoodSystem or nil
        if animalFoodSystem ~= nil and animalFoodSystem.getAnimalFood ~= nil then
            local animalFood = self:safeGet(function() return animalFoodSystem:getAnimalFood(animalTypeIndex) end, nil)
            if animalFood ~= nil then
                for _, group in pairs(animalFood.groups or {}) do
                    local level = 0
                    local groupFillTypes = self:newArray()
                    for _, fillTypeIndex in pairs(group.fillTypes or {}) do
                        local amount = (foodSpec.fillLevels or {})[fillTypeIndex] or 0
                        level = level + amount
                        local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
                        if fillType ~= nil then
                            table.insert(groupFillTypes, {
                                fillType = string.upper(fillType.name or "UNKNOWN"),
                                title = fillType.title or fillType.name or "Unbekannt",
                                level = self:round(amount, 1),
                            })
                        end
                    end
                    table.insert(data.food.groups, {
                        title = tostring(group.title or "Futtergruppe"),
                        level = self:round(level, 1),
                        capacity = self:round(foodCapacity, 1),
                        percent = foodCapacity > 0 and math.floor(math.min(100, level / foodCapacity * 100) + 0.5) or 0,
                        productionWeight = self:round(group.productionWeight or 0, 3),
                        fillTypes = groupFillTypes,
                    })
                end
            end
        end
    end

    -- Wasser.
    local waterSpec = placeable.spec_husbandryWater
    if waterSpec ~= nil then
        data.water.enabled = true
        data.water.automatic = waterSpec.automaticWaterSupply == true
        data.water.litersPerHour = self:round(waterSpec.litersPerHour or 0, 2)
        if waterSpec.fillType ~= nil then
            local entry = self:makeHusbandryFillEntry(placeable, waterSpec.fillType)
            if entry ~= nil then
                data.water.fillType = entry.fillType
                data.water.title = entry.title
                data.water.level = entry.level
                data.water.capacity = entry.capacity
                data.water.percent = entry.percent
            end
        end
    end

    -- Stroh als Input und Mist als dazugehöriger Output.
    local strawSpec = placeable.spec_husbandryStraw
    if strawSpec ~= nil then
        data.straw.enabled = true
        data.straw.litersPerHour = self:round(strawSpec.inputLitersPerHour or 0, 2)
        local strawFillType = strawSpec.inputFillType or (FillType and FillType.STRAW)
        if strawFillType ~= nil then
            local entry = self:makeHusbandryFillEntry(placeable, strawFillType)
            if entry ~= nil then
                data.straw.fillType = entry.fillType
                data.straw.title = entry.title
                data.straw.level = entry.level
                data.straw.capacity = entry.capacity
                data.straw.percent = entry.percent
            end
        end

        local manureFillType = strawSpec.outputFillType or (FillType and FillType.MANURE)
        if strawSpec.isManureActive ~= false and manureFillType ~= nil then
            local output = self:makeHusbandryFillEntry(placeable, manureFillType, {
                kind = "MANURE",
                litersPerHour = self:round(strawSpec.outputLitersPerHour or 0, 2),
            })
            if output ~= nil then table.insert(data.outputs, output) end
        end
    end

    -- Weide/Meadow. FS25 hält hier eigene aktuelle FillLevels/Capacities.
    local meadowSpec = placeable.spec_husbandryMeadow
    if meadowSpec ~= nil then
        data.meadow.enabled = true
        local totalLevel = 0
        local totalCapacity = 0
        for fillTypeIndex, level in pairs(meadowSpec.fillLevels or {}) do
            local capacity = (meadowSpec.capacities or {})[fillTypeIndex] or 0
            local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
            totalLevel = totalLevel + (level or 0)
            totalCapacity = totalCapacity + capacity
            if fillType ~= nil then
                table.insert(data.meadow.fillTypes, {
                    fillType = string.upper(fillType.name or "UNKNOWN"),
                    title = fillType.title or fillType.name or "Weide",
                    level = self:round(level or 0, 1),
                    capacity = self:round(capacity, 1),
                    percent = capacity > 0 and math.floor(math.min(100, (level or 0) / capacity * 100) + 0.5) or 0,
                })
            end
        end
        data.meadow.level = self:round(totalLevel, 1)
        data.meadow.capacity = self:round(totalCapacity, 1)
        data.meadow.percent = totalCapacity > 0 and math.floor(math.min(100, totalLevel / totalCapacity * 100) + 0.5) or 0
    end

    -- Milch/Büffelmilch und sonstige flüssige Tierprodukte.
    local milkSpec = placeable.spec_husbandryMilk
    if milkSpec ~= nil and milkSpec.hasMilkProduction ~= false then
        local seen = {}
        for _, fillTypeIndex in ipairs(milkSpec.fillTypes or {}) do seen[fillTypeIndex] = true end
        for fillTypeIndex, _ in pairs(milkSpec.litersPerHour or {}) do seen[fillTypeIndex] = true end
        for fillTypeIndex, _ in pairs(seen) do
            local output = self:makeHusbandryFillEntry(placeable, fillTypeIndex, {
                kind = "LIQUID",
                litersPerHour = self:round((milkSpec.litersPerHour or {})[fillTypeIndex] or 0, 2),
            })
            if output ~= nil then table.insert(data.outputs, output) end
        end
    end

    -- Palettenprodukte generisch: Eier, Wolle, Ziegenmilch und Mod-Produkte.
    local palletSpec = placeable.spec_husbandryPallets
    if palletSpec ~= nil then
        local seen = {}
        for _, fillTypeIndex in ipairs(palletSpec.fillTypes or {}) do seen[fillTypeIndex] = true end
        for fillTypeIndex, _ in pairs(palletSpec.litersPerHour or {}) do seen[fillTypeIndex] = true end
        for fillTypeIndex, _ in pairs(palletSpec.pendingLiters or {}) do seen[fillTypeIndex] = true end
        for fillTypeIndex, _ in pairs(seen) do
            local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
            if fillType ~= nil then
                local level = (palletSpec.fillLevels or {})[fillTypeIndex] or 0
                local capacity = (palletSpec.capacities or {})[fillTypeIndex] or 0
                table.insert(data.outputs, {
                    kind = "PALLET",
                    fillType = string.upper(fillType.name or "UNKNOWN"),
                    title = fillType.title or fillType.name or "Produkt",
                    level = self:round(level, 1),
                    capacity = self:round(capacity, 1),
                    percent = capacity > 0 and math.floor(math.min(100, level / capacity * 100) + 0.5) or 0,
                    pendingLiters = self:round((palletSpec.pendingLiters or {})[fillTypeIndex] or 0, 1),
                    litersPerHour = self:round((palletSpec.litersPerHour or {})[fillTypeIndex] or 0, 2),
                    palletLimitReached = palletSpec.palletLimitReached == true,
                })
            end
        end
    end

    -- Gülle.
    local liquidSpec = placeable.spec_husbandryLiquidManure
    if liquidSpec ~= nil then
        local fillTypeIndex = liquidSpec.fillType or (FillType and FillType.LIQUIDMANURE)
        if fillTypeIndex ~= nil then
            local output = self:makeHusbandryFillEntry(placeable, fillTypeIndex, {
                kind = "LIQUID_MANURE",
                litersPerHour = self:round(liquidSpec.litersPerHour or 0, 2),
            })
            if output ~= nil then table.insert(data.outputs, output) end
        end
    end

    table.sort(data.outputs, function(a, b) return tostring(a.title or "") < tostring(b.title or "") end)
    return data
end

function HofDashboardLive:countOwnedPalletFillType(fillTypeIndex, myFarmId)
    local count = 0
    local liters = 0
    local vehicleSystem = g_currentMission and g_currentMission.vehicleSystem or nil
    for _, vehicle in pairs(vehicleSystem and vehicleSystem.vehicles or {}) do
        if vehicle ~= nil and vehicle.spec_pallet ~= nil and self:getVehicleOwnerFarmId(vehicle) == myFarmId and vehicle.getFillUnits ~= nil then
            local fillUnits = self:safeGet(function() return vehicle:getFillUnits() end, {}) or {}
            for fillUnitIndex, _ in ipairs(fillUnits) do
                local currentFillType = self:safeGet(function() return vehicle:getFillUnitFillType(fillUnitIndex) end, nil)
                if currentFillType == fillTypeIndex then
                    count = count + 1
                    liters = liters + (self:safeGet(function() return vehicle:getFillUnitFillLevel(fillUnitIndex) end, 0) or 0)
                    break
                end
            end
        end
    end
    return count, liters
end

function HofDashboardLive:collectBeehives()
    local result = {
        hiveCount = 0,
        activeHiveCount = 0,
        honeyLitersPerHour = 0,
        pendingHoneyLiters = 0,
        finishedPallets = 0,
        honeyOnPalletsLiters = 0,
        hasSpawner = false,
        palletLimitReached = false,
        hives = self:newArray(),
    }

    local mission = g_currentMission
    local system = mission and mission.beehiveSystem or nil
    local myFarmId = self:getPlayerFarmId()
    if system == nil or myFarmId <= 0 then return result end

    local hives = system.getBeehives ~= nil
        and (self:safeGet(function() return system:getBeehives() end, {}) or {})
        or (system.beehivesSortedRadius or {})

    for _, hive in ipairs(hives) do
        local ownerFarmId = self:getPlaceableOwnerFarmId(hive)
        if ownerFarmId == myFarmId and hive.spec_beehive ~= nil then
            local spec = hive.spec_beehive
            local active = spec.isProductionActive == true
            local rate = math.max(0, spec.honeyPerHour or 0)
            result.hiveCount = result.hiveCount + 1
            if active then result.activeHiveCount = result.activeHiveCount + 1 end
            result.honeyLitersPerHour = result.honeyLitersPerHour + (active and rate or 0)
            table.insert(result.hives, {
                name = self:safeGet(function() return hive:getName() end, "Bienenstock") or "Bienenstock",
                active = active,
                honeyLitersPerHour = self:round(rate, 2),
                actionRadius = self:round(spec.actionRadius or 0, 1),
            })
        end
    end

    if system.getFarmBeehivePalletSpawner ~= nil then
        local spawner = self:safeGet(function() return system:getFarmBeehivePalletSpawner(myFarmId) end, nil)
        if spawner ~= nil and spawner.spec_beehivePalletSpawner ~= nil then
            local spec = spawner.spec_beehivePalletSpawner
            result.hasSpawner = true
            result.pendingHoneyLiters = self:round(spec.pendingLiters or 0, 1)
            result.palletLimitReached = spec.palletLimitReached == true
        end
    end

    local honeyFillType = g_fillTypeManager and g_fillTypeManager:getFillTypeIndexByName("HONEY") or nil
    if honeyFillType ~= nil then
        local palletCount, palletLiters = self:countOwnedPalletFillType(honeyFillType, myFarmId)
        result.finishedPallets = palletCount
        result.honeyOnPalletsLiters = self:round(palletLiters, 1)
    end

    result.honeyLitersPerHour = self:round(result.honeyLitersPerHour, 2)
    return result
end

-- ======================================================================
-- PRODUKTIONSANLAGEN
-- ======================================================================

function HofDashboardLive:collectProductions()
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

function HofDashboardLive:processProduction(placeable)
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

function HofDashboardLive:getSellingStationName(station)
    local name = ""
    if station ~= nil and station.getName ~= nil then
        name = self:safeGet(function() return station:getName() end, "") or ""
    end
    if name == "" and station ~= nil and station.owningPlaceable ~= nil and station.owningPlaceable.getName ~= nil then
        name = self:safeGet(function() return station.owningPlaceable:getName() end, "") or ""
    end
    if name == "" then name = "Verkaufsstation" end
    return name
end

function HofDashboardLive:collectMarket()
    local result = self:newArray()
    if g_fillTypeManager == nil or g_currentMission == nil then return result end

    local storageSystem = g_currentMission.storageSystem
    if storageSystem == nil or storageSystem.getUnloadingStations == nil then
        self:logError("collectMarket", "StorageSystem/UnloadingStations nicht verfügbar")
        return result
    end

    local fruitFillTypeIndices = {}
    if g_fruitTypeManager ~= nil then
        for _, fruitType in pairs(g_fruitTypeManager.fruitTypes or {}) do
            if fruitType.fillType ~= nil and fruitType.fillType.index ~= nil then
                fruitFillTypeIndices[fruitType.fillType.index] = true
            end
        end
    end

    local unloadingStations = self:safeGet(function()
        return storageSystem:getUnloadingStations()
    end, {}) or {}

    for _, fillType in pairs(g_fillTypeManager.fillTypes or {}) do
        if fillType ~= nil
            and fillType.showOnPriceTable == true
            and fillType.pricePerLiter ~= nil
            and fillType.pricePerLiter > 0 then

            local stations = self:newArray()

            for _, station in pairs(unloadingStations) do
                local accepted = station ~= nil
                    and station.isSellingPoint == true
                    and station.hideFromPricesMenu ~= true

                if accepted then
                    if station.acceptedFillTypes ~= nil then
                        accepted = station.acceptedFillTypes[fillType.index] == true
                    elseif station.getIsFillTypeSupported ~= nil then
                        accepted = self:safeGet(function()
                            return station:getIsFillTypeSupported(fillType.index)
                        end, false) == true
                    else
                        accepted = false
                    end
                end

                if accepted and station.getEffectiveFillTypePrice ~= nil then
                    local pricePerLiter = self:safeGet(function()
                        return station:getEffectiveFillTypePrice(fillType.index)
                    end, 0) or 0

                    if pricePerLiter > 0 then
                        table.insert(stations, {
                            name = self:getSellingStationName(station),
                            pricePer1000L = math.floor(pricePerLiter * 1000 + 0.5),
                        })
                    end
                end
            end

            table.sort(stations, function(a, b)
                if a.pricePer1000L ~= b.pricePer1000L then
                    return a.pricePer1000L > b.pricePer1000L
                end
                return tostring(a.name or "") < tostring(b.name or "")
            end)

            if #stations > 0 then
                local best = stations[1]
                local worst = stations[#stations]
                local basePrice = math.floor(fillType.pricePerLiter * 1000 + 0.5)

                table.insert(result, {
                    fillType = fillType.name or "",
                    title = fillType.title or fillType.name or "",
                    category = fruitFillTypeIndices[fillType.index] and "crop" or "product",
                    unit = "1000L",
                    stationCount = #stations,
                    bestStation = best.name or "",
                    bestPrice = best.pricePer1000L or 0,
                    worstPrice = worst.pricePer1000L or 0,
                    priceSpread = math.max(0, (best.pricePer1000L or 0) - (worst.pricePer1000L or 0)),
                    stations = stations,
                    -- Kompatibilitätsfelder für die bestehende PHP-Schnittstelle.
                    -- pricePerTon ist historisch benannt, enthält aber weiterhin den
                    -- im Spiel üblichen Preis pro 1.000 Liter.
                    pricePerTon = best.pricePer1000L or 0,
                    basePriceTon = basePrice,
                })
            end
        end
    end

    table.sort(result, function(a, b)
        if a.bestPrice ~= b.bestPrice then return a.bestPrice > b.bestPrice end
        return tostring(a.title or "") < tostring(b.title or "")
    end)
    return result
end

-- ======================================================================
-- DATEI SCHREIBEN
-- ======================================================================

function HofDashboardLive:writeFile(content)
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

function HofDashboardLive:jsonEncode(value)
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

addModEventListener(HofDashboardLive)
