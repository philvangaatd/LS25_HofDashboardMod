--[[
    FS25_AutoDriveFlurkarte – Vollständiger Live Data Export v3.0
    ============================================================
    Schreibt alle 15 Sekunden eine JSON-Datei nach:
      <UserDocuments>/My Games/FarmingSimulator2025/modSettings/AutoDriveFlurkarte/liveData.json

    Enthält: Hof-Info, Felder, Fahrzeuge, Tiere, Produktion, Verträge, Marktpreise
    Alle Daten direkt aus der FS25-Lua-API – keine XML-Dateien nötig.
    API-Referenz: gdn.giants-software.com/documentation_scripting_fs25.php
]]

local MODNAME = g_currentModName or "FS25_AutoDriveFlurkarte"

AutoDriveFlurkarteLive              = {}
AutoDriveFlurkarteLive.MOD_NAME     = MODNAME
AutoDriveFlurkarteLive.VERSION      = "3.0.0"
AutoDriveFlurkarteLive.SETTINGS_DIR = "AutoDriveFlurkarte"
AutoDriveFlurkarteLive.OUTPUT_FILE  = "liveData.json"
AutoDriveFlurkarteLive.UPDATE_INTERVAL = 15000   -- 15 Sekunden
AutoDriveFlurkarteLive.timer        = 0
AutoDriveFlurkarteLive.isReady      = false

-- Lazy-init nach loadMap
AutoDriveFlurkarteLive.FUEL_TYPES       = nil
AutoDriveFlurkarteLive.GROUND_TYPE_NAMES = {}

-- ======================================================================
-- LIFECYCLE
-- ======================================================================

function AutoDriveFlurkarteLive:loadMap(filename)
    self.isReady = true
    self.timer   = self.UPDATE_INTERVAL

    -- FieldGroundType Reverse-Lookup
    if FieldGroundType ~= nil then
        for k, v in pairs(FieldGroundType) do
            if type(v) == "number" then self.GROUND_TYPE_NAMES[v] = k end
        end
    end

    -- Kraftstofftypen
    self.FUEL_TYPES = {}
    local function addFuel(ft, name, label)
        if ft ~= nil then
            table.insert(self.FUEL_TYPES, {ft = ft, name = name, label = label})
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
            print(string.format("[%s] Export-Fehler: %s", self.MOD_NAME, tostring(err)))
        end
    end
end

-- ======================================================================
-- EXPORT
-- ======================================================================

function AutoDriveFlurkarteLive:exportAllData()
    local data = {
        version   = self.VERSION,
        modName   = self.MOD_NAME,
        timestamp = getDate("%Y-%m-%dT%H:%M:%S"),
        mapName   = self:safeGet(function() return g_currentMission.missionInfo.mapTitle end, "Unknown"),
        currentDay    = self:safeGet(function() return g_currentMission.environment.currentDay    or 0  end, 0),
        daysPerPeriod = self:safeGet(function() return g_currentMission.environment.daysPerPeriod or 24 end, 24),
        farm      = self:collectFarm(),
        fields    = self:collectFields(),
        vehicles  = self:collectVehicles(),
        animals   = self:collectAnimals(),
        productions = self:collectProductions(),
        contracts = self:collectContracts(),
        market    = self:collectMarket(),
    }
    self:writeFile(self:jsonEncode(data))
end

-- Hilfsfunktion: sicheres Ausführen mit Fallback
function AutoDriveFlurkarteLive:safeGet(fn, fallback)
    local ok, val = pcall(fn)
    if ok and val ~= nil then return val end
    return fallback
end

-- ======================================================================
-- HOF-INFORMATIONEN
-- API: g_farmManager, g_currentMission
-- ======================================================================

function AutoDriveFlurkarteLive:collectFarm()
    local result = { name = "", farmId = 0, money = 0, loan = 0 }
    local ok, _ = pcall(function()
        -- g_currentMission:getFarmId() ist die konsistente Quelle
        -- (identisch mit was collectFields() und g_farmlandManager.farmlands.farmId nutzen)
        local playerFarmId = 0
        local ok0, fid = pcall(function() return g_currentMission:getFarmId() end)
        if ok0 and type(fid) == "number" and fid > 0 then
            playerFarmId = fid
        elseif g_currentMission and g_currentMission.player then
            playerFarmId = g_currentMission.player.farmId or 0
        end

        local farm = nil
        -- Farm-Objekt via ID holen (zuverlässigste Methode)
        if playerFarmId > 0 and g_farmManager.getFarmById ~= nil then
            local ok1, f = pcall(function() return g_farmManager:getFarmById(playerFarmId) end)
            if ok1 and f then farm = f end
        end
        -- Fallback: getLocalPlayerFarm()
        if farm == nil and g_farmManager.getLocalPlayerFarm ~= nil then
            local ok2, f = pcall(function() return g_farmManager:getLocalPlayerFarm() end)
            if ok2 and f then farm = f end
        end
        if farm == nil then
            -- Nur farmId setzen damit fields-Filter noch funktioniert
            result.farmId = playerFarmId
            return
        end

        result.farmId = playerFarmId > 0 and playerFarmId or (farm.farmId or 0)
        result.name   = farm.name or ""

        -- Geld: Property oder Methode
        if     type(farm.money)   == "number" then result.money = math.floor(farm.money)
        elseif type(farm.balance) == "number" then result.money = math.floor(farm.balance)
        elseif farm.getMoney ~= nil then
            local ok2, v = pcall(function() return farm:getMoney() end)
            if ok2 and v then result.money = math.floor(v) end
        end
        -- Kredit
        if     type(farm.loan) == "number" then result.loan = math.floor(farm.loan)
        elseif farm.getLoan ~= nil then
            local ok2, v = pcall(function() return farm:getLoan() end)
            if ok2 and v then result.loan = math.floor(v) end
        end
    end)
    return result
end

-- ======================================================================
-- FELDDATEN – korrekte FS25 API aus FarmlandOverview-Mod abgeleitet
-- Statt g_fieldManager:getFields() + getFieldState() (buggy auf Zielonka):
--   → g_farmlandManager.farmlands   für Ownership (farmland.farmId, direkt)
--   → FSDensityMapUtil.getFruitTypeIndexAtWorldPos  für Fruchtart+Wachstum
--   → fruitType.minHarvestingGrowthState / maxHarvestingGrowthState (korrekte Namen!)
-- ======================================================================

function AutoDriveFlurkarteLive:collectFields()
    local result = {}
    if g_farmlandManager == nil or g_currentMission == nil then return result end

    -- Eigene FarmId direkt aus Mission
    local myFarmId = 0
    local ok0, fid = pcall(function() return g_currentMission:getFarmId() end)
    if ok0 and type(fid) == "number" then myFarmId = fid end

    for _, farmland in pairs(g_farmlandManager.farmlands or {}) do
        if farmland.farmId == myFarmId and farmland.field ~= nil then
            local ok2, fd = pcall(function()
                return self:processFarmland(farmland, myFarmId)
            end)
            if ok2 and fd ~= nil then table.insert(result, fd) end
        end
    end

    table.sort(result, function(a, b) return (a.id or 0) < (b.id or 0) end)
    return result
end

function AutoDriveFlurkarteLive:processFarmland(farmland, myFarmId)
    local field = farmland.field
    local data = {
        id             = field:getId() or 0,
        farmlandId     = farmland.id  or 0,
        farmId         = myFarmId,
        area           = math.floor((farmland.field.areaHa or 0) * 100 + 0.5) / 100,
        fruitType      = "NONE",
        fruitTitle     = "Brache",
        maxGrowthState = 0,
        growthState    = 0,
        growthName     = "FALLOW",
        harvestReady   = false,
        isWithered     = false,
        groundType     = "NONE",
        weedState      = 0,
        sprayLevel     = 0,
        limeLevel      = 0,
        plowLevel      = 0,
    }

    -- Feldmitte für Density-Map-Abfrage
    local x, z = nil, nil
    local okPos, cx, cz = pcall(function()
        return field:getCenterOfFieldWorldPosition()
    end)
    if okPos and cx ~= nil then x, z = cx, cz end

    if x ~= nil then
        -- Fruchtart + Wachstum NUR aus Density Map am Feldmittelpunkt.
        -- Kein Fallback auf getFieldState().fruitTypeIndex!
        -- Grund: getFieldState() liest das gesamte Polygon (Durchschnitt) →
        -- beim Pflügen zeigt es noch alte Frucht/Erntereif weil 80% des Feldes
        -- noch nicht gepflügt sind. FSDensityMapUtil liest den EXAKTEN Punkt.
        local fruitIdx, growthState = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)

        if fruitIdx ~= nil and fruitIdx ~= 0 then
            data.growthState = growthState or 0
            local ft = g_fruitTypeManager:getFruitTypeByIndex(fruitIdx)
            if ft ~= nil then
                data.fruitType  = string.upper(ft.name or "UNKNOWN")
                data.fruitTitle = (ft.fillType and ft.fillType.title) or ft.name or data.fruitType

                local minH  = ft.minHarvestingGrowthState or -1
                local maxH  = ft.maxHarvestingGrowthState or -1
                local cutSt = ft.cutState or -1
                local withSt = maxH >= 0 and (maxH + 1) or -1
                if ft.maxPreparingGrowthState ~= nil and ft.maxPreparingGrowthState >= 0 then
                    withSt = ft.maxPreparingGrowthState + 1
                end
                data.maxGrowthState = maxH > 0 and maxH or (ft.numGrowthStates or 0)

                local gs = data.growthState
                if cutSt >= 0 and gs == cutSt then
                    data.growthName = "CUT"
                elseif withSt >= 0 and gs == withSt then
                    data.growthName = "WITHERED"; data.isWithered = true
                elseif minH >= 0 and maxH >= 0 and gs >= minH and gs <= maxH then
                    data.growthName = "READY_TO_HARVEST"; data.harvestReady = true
                elseif ft.minPreparingGrowthState ~= nil and ft.minPreparingGrowthState >= 0
                       and gs >= ft.minPreparingGrowthState
                       and gs <= (ft.maxPreparingGrowthState or gs) then
                    data.growthName = "GROWING"
                elseif gs > 0 then
                    data.growthName = "GROWING"
                else
                    data.growthName = "GERMINATING"
                end
            end
        end
        -- fruitIdx == nil/0: Feld ist leer oder Mittelpunkt wurde gerade bearbeitet → FALLOW bleibt

        -- getFieldState() NUR für Boden-Pflegedaten (weed/spray/lime/groundType für Anzeige)
        -- groundType wird NICHT für harvestReady oder Fruchttyp verwendet
        local okFs, fs = pcall(function() return field:getFieldState() end)
        if okFs and fs ~= nil and fs.isValid then
            data.groundType = self.GROUND_TYPE_NAMES[fs.groundType] or tostring(fs.groundType or 0)
            data.weedState  = fs.weedState  or 0
            data.sprayLevel = fs.sprayLevel or 0
            data.limeLevel  = fs.limeLevel  or 0
            data.plowLevel  = fs.plowLevel  or 0
        end
    end
    return data
end

-- ======================================================================
-- FAHRZEUGDATEN
-- API: vehicle:getShowInVehiclesOverview(), vehicle:getOperatingTime() [ms!],
--      vehicle:getVehicleDamage(), vehicle:getPrice()
-- Doku: gdn.giants-software.com/.../class=888 (Vehicle)
-- Hinweis: operatingTime in FS25 ist MILLISEKUNDEN (calculateSellPrice: /60/60/1000)
-- ======================================================================

function AutoDriveFlurkarteLive:collectVehicles()
    local result = {}
    if g_currentMission == nil or g_currentMission.vehicles == nil then return result end

    for _, vehicle in ipairs(g_currentMission.vehicles) do
        local ok, vd = pcall(function() return self:processVehicle(vehicle) end)
        if ok and vd ~= nil then table.insert(result, vd) end
    end
    return result
end

function AutoDriveFlurkarteLive:processVehicle(vehicle)
    -- Paletten immer überspringen
    if vehicle.spec_pallet ~= nil then return nil end

    -- Eigentumscheck: getOwnerFarmId() Methode (laut Vehicle-Doku class=888)
    local ownerId = 0
    if vehicle.getOwnerFarmId ~= nil then
        local ok, val = pcall(function() return vehicle:getOwnerFarmId() end)
        if ok and type(val) == "number" then ownerId = val end
    end
    -- Fallback: direkte Property
    if ownerId <= 0 then ownerId = vehicle.ownerFarmId or 0 end
    -- Fallback 2: PropertyState (OWNED=1, LEASED=2 → Spieler-Fahrzeug)
    if ownerId <= 0 and vehicle.getPropertyState ~= nil then
        local ok, ps = pcall(function() return vehicle:getPropertyState() end)
        if ok and ps ~= nil then
            -- VehiclePropertyState.OWNED=1, LEASED=2 bedeutet es gehört dem Spieler
            if ps == 1 or ps == 2 then ownerId = 1 end
        end
    end
    if ownerId <= 0 then return nil end

    -- Kategorie
    local isMotorized = vehicle.spec_motorized ~= nil
    local isTrailer   = vehicle.spec_trailer   ~= nil
    local category    = "IMPLEMENT"
    if isMotorized then category = "VEHICLE" elseif isTrailer then category = "TRAILER" end

    local data = {
        name            = vehicle:getFullName() or "Unbekannt",
        typeName        = vehicle.typeName or "",
        vehicleCategory = category,
        farmId          = vehicle.ownerFarmId or 0,
        -- operatingTime: Vehicle-Doku zeigt "/60/60/1000" → Millisekunden!
        operatingHours  = math.floor((vehicle:getOperatingTime() or 0) / 3600000 * 10) / 10,
        -- getVehicleDamage() ist die offizielle Methode (Vehicle-Doku)
        wear            = math.floor((vehicle:getVehicleDamage() or 0) * 1000) / 1000,
        dirt            = 0,
        price           = math.floor(vehicle:getPrice() or 0),
        fuel            = {},
        cargo           = {},
        isWorking       = vehicle:getIsAIActive(),
        uniqueId        = "",
    }

    -- uniqueId für zuverlässiges Matching mit vehicles.xml (Vehicle-Doku: getUniqueId())
    if vehicle.getUniqueId ~= nil then
        local ok, val = pcall(function() return vehicle:getUniqueId() end)
        if ok and val ~= nil then data.uniqueId = tostring(val) end
    end

    -- Dreck via Washable-Spec
    if vehicle.spec_washable ~= nil then
        local ok, val = pcall(function() return vehicle.spec_washable:getDirtAmount() end)
        if ok and val ~= nil then data.dirt = math.floor(val * 1000) / 1000 end
    end

    -- Kraftstoff: bekannte Typen direkt abfragen
    local fuelTypeSet = {}
    for _, ft in ipairs(self.FUEL_TYPES) do
        local unit = vehicle:getFirstFillUnitWithType(ft.ft)
        if unit ~= nil then
            local level    = vehicle:getFillUnitFillLevel(unit) or 0
            local capacity = vehicle:getFillUnitCapacity(unit)  or 0
            if capacity > 0 then
                table.insert(data.fuel, {
                    fillType = ft.name,
                    label    = ft.label,
                    liters   = math.floor(level * 10) / 10,
                    capacity = math.floor(capacity),
                    percent  = math.floor(math.min(100, level / capacity * 100)),
                })
                fuelTypeSet[ft.ft] = true
            end
        end
    end

    -- Ladung: alle übrigen Fülleinheiten
    local fillInfos = {}
    vehicle:getFillLevelInformation(fillInfos)
    for _, info in ipairs(fillInfos) do
        if not fuelTypeSet[info.fillType] then
            local cap = info.capacity or 0
            local lvl = info.fillLevel or 0
            if cap > 0 and lvl > 0.01 then
                local ftName, ftTitle = "", info.title or ""
                if info.fillType ~= nil then
                    local ft = g_fillTypeManager:getFillTypeByIndex(info.fillType)
                    if ft ~= nil then
                        ftName  = ft.name  or ""
                        ftTitle = ft.title or ftTitle
                    end
                end
                if ftName ~= "" and ftName ~= "UNKNOWN"
                    and ftName ~= "AIR" and ftName ~= "BALE_NET" then
                    table.insert(data.cargo, {
                        fillType = ftName,
                        title    = ftTitle,
                        liters   = math.floor(lvl * 10) / 10,
                        capacity = math.floor(cap),
                        percent  = math.floor(math.min(100, lvl / cap * 100)),
                    })
                end
            end
        end
    end
    return data
end

-- ======================================================================
-- TIERHALTUNG
-- In FS25 sind Nutztiere in Placeables mit spec_animalHusbandry (nicht in
-- der Animals-Doku – dort ist nur der Hund!).
-- API: g_currentMission.placeables, placeable.spec_animalHusbandry
-- ======================================================================

function AutoDriveFlurkarteLive:collectAnimals()
    local result = {}
    if g_currentMission == nil or g_currentMission.placeables == nil then return result end

    for _, placeable in pairs(g_currentMission.placeables) do
        local ok, data = pcall(function()
            return self:processHusbandry(placeable)
        end)
        if ok and data ~= nil then table.insert(result, data) end
    end
    return result
end

function AutoDriveFlurkarteLive:processHusbandry(placeable)
    local spec = placeable.spec_animalHusbandry
    if spec == nil then return nil end

    local data = {
        species     = "",
        name        = placeable:getName() or "",
        farmId      = placeable.ownerFarmId or 0,
        numAnimals  = 0,
        health      = 0,
        reproduction = 0,
        clusters    = {},
    }

    -- Tierspezies aus dem ersten Cluster ermitteln
    local clusters = nil
    if spec.getAnimalClusters ~= nil then
        clusters = spec:getAnimalClusters()
    elseif spec.animalClusters ~= nil then
        clusters = spec.animalClusters
    end

    if clusters ~= nil then
        local totalAnimals = 0
        local totalHealth  = 0
        local totalRepro   = 0
        local clusterCount = 0

        for _, cluster in pairs(clusters) do
            local num    = cluster.numAnimals  or (cluster.getNumAnimals and cluster:getNumAnimals()) or 0
            local health = cluster.health or 0
            local repro  = cluster.reproductionEfficiency or cluster.reproduction or 0

            -- Normalisieren (manche Werte >1 = Prozent-Skalierung)
            if health > 1  then health = health / 100 end
            if repro  > 1  then repro  = repro  / 100 end

            totalAnimals = totalAnimals + num
            totalHealth  = totalHealth  + health
            totalRepro   = totalRepro   + repro
            clusterCount = clusterCount + 1

            if data.species == "" then
                data.species = cluster.species
                    or (cluster.animalType and cluster.animalType.name)
                    or ""
            end

            table.insert(data.clusters, {
                numAnimals   = num,
                health       = math.floor(health * 1000) / 1000,
                reproduction = math.floor(repro  * 1000) / 1000,
            })
        end

        data.numAnimals  = totalAnimals
        data.health      = clusterCount > 0 and math.floor(totalHealth / clusterCount * 1000) / 1000 or 0
        data.reproduction = clusterCount > 0 and math.floor(totalRepro  / clusterCount * 1000) / 1000 or 0
    end

    if data.numAnimals == 0 and #data.clusters == 0 then return nil end
    return data
end

-- ======================================================================
-- PRODUKTIONSANLAGEN
-- In FS25: Placeables mit spec_productionPoint
-- ======================================================================

function AutoDriveFlurkarteLive:collectProductions()
    local result = {}
    if g_currentMission == nil or g_currentMission.placeables == nil then return result end

    for _, placeable in pairs(g_currentMission.placeables) do
        local ok, data = pcall(function()
            return self:processProduction(placeable)
        end)
        if ok and data ~= nil then table.insert(result, data) end
    end
    return result
end

function AutoDriveFlurkarteLive:processProduction(placeable)
    local spec = placeable.spec_productionPoint
    if spec == nil then return nil end

    local pp = spec.productionPoint
    if pp == nil then return nil end

    -- Nur eigene Produktionen
    local farmId = placeable.ownerFarmId or 0
    if farmId == 0 then return nil end

    local data = {
        name       = placeable:getName() or "",
        farmId     = farmId,
        productions = {},
        storages    = {},
    }

    -- Produktionen
    if pp.getProductions ~= nil then
        for _, prod in ipairs(pp:getProductions()) do
            local pData = {
                name      = prod.name or "",
                status    = tostring(prod.status or ""),
                cyclesPerHour = prod.cyclesPerHour or 0,
                inputs    = {},
                outputs   = {},
            }
            if prod.inputs ~= nil then
                for _, inp in ipairs(prod.inputs) do
                    local ft = g_fillTypeManager:getFillTypeByIndex(inp.type)
                    table.insert(pData.inputs, {
                        fillType = ft and ft.name or tostring(inp.type),
                        amount   = inp.amount or 0,
                    })
                end
            end
            if prod.outputs ~= nil then
                for _, out in ipairs(prod.outputs) do
                    local ft = g_fillTypeManager:getFillTypeByIndex(out.type)
                    table.insert(pData.outputs, {
                        fillType = ft and ft.name or tostring(out.type),
                        amount   = out.amount or 0,
                    })
                end
            end
            table.insert(data.productions, pData)
        end
    end

    -- Füllstände der Lager
    if pp.storage ~= nil and pp.storage.fillLevels ~= nil then
        for fillType, level in pairs(pp.storage.fillLevels) do
            if level > 0 then
                local ft = g_fillTypeManager:getFillTypeByIndex(fillType)
                local cap = pp.storage.capacities and pp.storage.capacities[fillType] or 0
                table.insert(data.storages, {
                    fillType = ft and ft.name or tostring(fillType),
                    title    = ft and ft.title or "",
                    level    = math.floor(level),
                    capacity = math.floor(cap),
                    percent  = cap > 0 and math.floor(math.min(100, level / cap * 100)) or 0,
                })
            end
        end
    end

    if #data.productions == 0 and #data.storages == 0 then return nil end
    return data
end

-- ======================================================================
-- VERTRÄGE / MISSIONS
-- API: g_missionManager
-- ======================================================================

function AutoDriveFlurkarteLive:collectContracts()
    local result = {}
    if g_missionManager == nil then return result end

    local missions = nil
    local ok = pcall(function()
        missions = g_missionManager:getMissions()
    end)
    if not ok or missions == nil then
        -- Fallback: direkte Property
        missions = g_missionManager.missions
    end
    if missions == nil then return result end

    for _, mission in pairs(missions) do
        local mok, mdata = pcall(function()
            return self:processMission(mission)
        end)
        if mok and mdata ~= nil then table.insert(result, mdata) end
    end
    return result
end

function AutoDriveFlurkarteLive:processMission(mission)
    if mission == nil then return nil end

    local data = {
        type       = tostring(mission.type or mission.className or ""),
        title      = "",
        reward     = 0,
        fieldId    = 0,
        isActive   = false,
        progress   = 0,
        deadline   = 0,
        farmId     = 0,
    }

    -- Titel
    if mission.getTitle ~= nil then
        local ok, t = pcall(function() return mission:getTitle() end)
        if ok and t then data.title = tostring(t) end
    end

    -- Belohnung
    if mission.getReward ~= nil then
        local ok, r = pcall(function() return mission:getReward() end)
        if ok and r then data.reward = math.floor(r) end
    elseif mission.reward ~= nil then
        data.reward = math.floor(mission.reward)
    end

    -- Feld-ID
    if mission.field ~= nil and mission.field.id ~= nil then
        data.fieldId = mission.field.id
    elseif mission.field ~= nil and mission.field.getId ~= nil then
        local ok, fid = pcall(function() return mission.field:getId() end)
        if ok and fid then data.fieldId = fid end
    end

    -- Status
    if mission.getIsActive ~= nil then
        local ok, a = pcall(function() return mission:getIsActive() end)
        if ok then data.isActive = a == true end
    elseif mission.status ~= nil then
        data.isActive = (mission.status == "ACTIVE")
    end

    -- Fortschritt (0-1)
    if mission.getProgress ~= nil then
        local ok, p = pcall(function() return mission:getProgress() end)
        if ok and p then data.progress = math.floor(p * 100) end
    elseif mission.completionProgress ~= nil then
        data.progress = math.floor((mission.completionProgress or 0) * 100)
    end

    -- Farm-ID
    data.farmId = mission.farmId or 0

    return data
end

-- ======================================================================
-- MARKTPREISE
-- ======================================================================

function AutoDriveFlurkarteLive:collectMarket()
    local result = {}
    if g_fillTypeManager == nil then return result end

    -- Einmalig: Set aller FillType-Indizes die zu einem Fruchtyp gehören
    local fruitFillTypeIndices = {}
    if g_fruitTypeManager ~= nil then
        for _, ft in pairs(g_fruitTypeManager.fruitTypes or {}) do
            if ft.fillType ~= nil and ft.fillType.index ~= nil then
                fruitFillTypeIndices[ft.fillType.index] = true
            end
        end
    end

    local econManager = g_currentMission and g_currentMission.economyManager

    for _, ft in pairs(g_fillTypeManager.fillTypes) do
        if ft ~= nil and ft.pricePerLiter ~= nil and ft.pricePerLiter > 0
           and ft.pricePerLiter <= 2.0 then
            local basePrice = ft.pricePerLiter * 1000
            local currentPrice = basePrice

            if econManager ~= nil then
                local ok, mult = pcall(function()
                    return econManager:getPriceMultiplier(ft.index)
                end)
                if ok and mult ~= nil and mult > 0 then
                    currentPrice = basePrice * mult
                end
            end

            if currentPrice > 1 then
                -- Kategorie: Frucht (Acker-Anbau) oder Produkt (Verarbeitung/Tier)
                local isFruit = fruitFillTypeIndices[ft.index] == true
                table.insert(result, {
                    fillType     = ft.name or "",
                    title        = ft.title or ft.name or "",
                    pricePerTon  = math.floor(currentPrice),
                    basePriceTon = math.floor(basePrice),
                    category     = isFruit and "crop" or "product",
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
    local base   = getUserProfileAppPath()
    local modDir = base .. "modSettings/" .. self.SETTINGS_DIR .. "/"
    createFolder(base .. "modSettings/")
    createFolder(modDir)
    local file = io.open(modDir .. self.OUTPUT_FILE, "w")
    if file then file:write(content); file:close() end
end

-- ======================================================================
-- JSON ENCODER
-- ======================================================================

function AutoDriveFlurkarteLive:jsonEncode(val)
    local t = type(val)
    if t == "nil" then return "null"
    elseif t == "boolean" then return val and "true" or "false"
    elseif t == "number" then
        if val ~= val or val == math.huge or val == -math.huge then return "null" end
        if math.floor(val) == val and math.abs(val) < 2^53 then
            return string.format("%d", val)
        else return string.format("%.4f", val) end
    elseif t == "string" then
        val = val:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')
        return '"' .. val .. '"'
    elseif t == "table" then
        local len = #val
        local kc  = 0; for _ in pairs(val) do kc = kc + 1 end
        local parts = {}
        if len > 0 and kc == len then
            for i = 1, len do parts[i] = self:jsonEncode(val[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                if type(k) == "string" then
                    table.insert(parts, '"'..k..'":' .. self:jsonEncode(v))
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else return '"' .. tostring(val) .. '"' end
end

-- ======================================================================
-- REGISTRIEREN
-- ======================================================================

addModEventListener(AutoDriveFlurkarteLive)
