-- Hof-Vorräte aus der laufenden FS25-Welt.
-- Liest Placeables über g_currentMission.placeableSystem.placeables und nutzt
-- die GIANTS-Storage-/ObjectStorage-/BunkerSilo-APIs. Dadurch funktionieren
-- auch kompatible Mod-Lager ohne hart codierte Modnamen.

local function storageNumber(value)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        return 0
    end
    return math.max(0, value)
end

local function tableCount(value)
    if type(value) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

function HofDashboardLive:getStorageOwnerFarmId(placeable)
    if placeable == nil then return 0 end
    if placeable.getOwnerFarmId ~= nil then
        local farmId = self:safeGet(function() return placeable:getOwnerFarmId() end, nil)
        if type(farmId) == "number" then return farmId end
    end
    return tonumber(placeable.ownerFarmId) or 0
end

function HofDashboardLive:getPhysicalStorageOwnerFarmId(storage)
    if storage == nil then return 0 end
    if storage.getOwnerFarmId ~= nil then
        local farmId = self:safeGet(function() return storage:getOwnerFarmId() end, nil)
        if type(farmId) == "number" then return farmId end
    end
    return tonumber(storage.ownerFarmId) or 0
end

function HofDashboardLive:canAccessStoragePlaceable(placeable, ownerFarmId, playerFarmId)
    if placeable == nil then return false end
    if playerFarmId > 0 and ownerFarmId == playerFarmId then return true end

    local mission = g_currentMission
    local accessHandler = mission and mission.accessHandler or nil
    if accessHandler ~= nil and playerFarmId > 0 and accessHandler.canFarmAccess ~= nil then
        local allowed = self:safeGet(function()
            return accessHandler:canFarmAccess(playerFarmId, placeable)
        end, false)
        if allowed == true then return true end
    end

    if accessHandler ~= nil and accessHandler.canPlayerAccess ~= nil then
        local allowed = self:safeGet(function()
            return accessHandler:canPlayerAccess(placeable)
        end, false)
        if allowed == true then return true end
    end

    -- Manche Karten-/Husbandry-Placeables melden ownerFarmId 0, obwohl sie
    -- funktional zum aktuellen Hof gehören. In Singleplayer dürfen solche
    -- Placeables weiter geprüft werden; fremde Farm-IDs werden ausgeschlossen.
    if playerFarmId > 0 then
        return ownerFarmId == 0
    end
    return true
end

function HofDashboardLive:getStorageFillTypeData(fillTypeIndex)
    local fillType = nil
    if fillTypeIndex ~= nil and g_fillTypeManager ~= nil then
        fillType = self:safeGet(function()
            return g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        end, nil)
    end
    return {
        fillType = fillType and fillType.name or tostring(fillTypeIndex or "UNKNOWN"),
        title = fillType and fillType.title or tostring(fillTypeIndex or "Unbekannt"),
    }
end

function HofDashboardLive:newStorageRecord(placeable, index)
    local name = self:safeGet(function()
        if placeable.getName ~= nil then return placeable:getName() end
        return nil
    end, nil)
    if name == nil or name == "" then name = placeable.typeName or "Lager" end

    local customEnvironment = tostring(placeable.customEnvironment or placeable.modName or "")
    return {
        id = tostring(placeable.typeName or "placeable") .. ":" .. tostring(index or 0),
        name = tostring(name),
        type = "storage",
        typeLabel = "Lager",
        farmId = self:getStorageOwnerFarmId(placeable),
        isMod = customEnvironment ~= "",
        modName = customEnvironment,
        capacityLiters = 0,
        objectCount = 0,
        objectCapacity = 0,
        supportsBales = false,
        supportsPallets = false,
        fermentingPercent = nil,
        compactedPercent = nil,
        contents = self:newArray(),
        _contentsByKey = {},
        _supportedFillTypes = {},
    }
end

function HofDashboardLive:addStorageContent(record, fillTypeIndex, level, capacity, objectCount, objectKind, fallbackTitle)
    if record == nil then return end
    local fillData = self:getStorageFillTypeData(fillTypeIndex)
    local fillTypeName = fillData.fillType
    local title = fillData.title
    if (fillTypeIndex == nil or fillTypeName == "UNKNOWN" or fillTypeName == "nil") and fallbackTitle ~= nil and fallbackTitle ~= "" then
        fillTypeName = "OBJECT:" .. tostring(fallbackTitle)
        title = tostring(fallbackTitle)
    end

    local key = string.upper(tostring(fillTypeName)) .. ":" .. tostring(fallbackTitle or "")
    local entry = record._contentsByKey[key]
    if entry == nil then
        entry = {
            fillType = fillTypeName,
            title = title,
            level = 0,
            capacity = 0,
            percent = 0,
            objectCount = 0,
            objectKind = objectKind or "",
        }
        record._contentsByKey[key] = entry
        table.insert(record.contents, entry)
    end

    entry.level = entry.level + storageNumber(level)
    entry.capacity = math.max(entry.capacity, storageNumber(capacity))
    entry.objectCount = entry.objectCount + math.max(0, math.floor(storageNumber(objectCount)))
    if entry.objectKind == "" and objectKind ~= nil then entry.objectKind = objectKind end
    if entry.capacity > 0 then
        entry.percent = math.floor(math.min(100, entry.level / entry.capacity * 100) + 0.5)
    end
end

function HofDashboardLive:addPhysicalStorage(record, storage, seenStorages)
    if record == nil or storage == nil or seenStorages[storage] then return false end
    seenStorages[storage] = true

    local supportedFillTypes = self:safeGet(function()
        if storage.getSupportedFillTypes ~= nil then return storage:getSupportedFillTypes() end
        return storage.fillTypes
    end, storage.fillTypes or {})
    if type(supportedFillTypes) ~= "table" then supportedFillTypes = {} end

    local fillLevels = self:safeGet(function()
        if storage.getFillLevels ~= nil then return storage:getFillLevels() end
        return storage.fillLevels
    end, storage.fillLevels or {})
    if type(fillLevels) ~= "table" then fillLevels = {} end

    local commonCapacity = storageNumber(storage.capacity)
    if commonCapacity <= 0 and type(storage.capacities) == "table" then
        for _, capacity in pairs(storage.capacities) do
            commonCapacity = math.max(commonCapacity, storageNumber(capacity))
        end
    end
    record.capacityLiters = math.max(record.capacityLiters, commonCapacity)

    for fillTypeIndex, accepted in pairs(supportedFillTypes) do
        if accepted == true then record._supportedFillTypes[fillTypeIndex] = true end
    end

    for fillTypeIndex, fillLevel in pairs(fillLevels) do
        record._supportedFillTypes[fillTypeIndex] = true
        local fallbackCapacity = type(storage.capacities) == "table" and storage.capacities[fillTypeIndex] or storage.capacity or 0
        local capacity = self:safeGet(function()
            if storage.getCapacity ~= nil then return storage:getCapacity(fillTypeIndex) end
            return fallbackCapacity
        end, fallbackCapacity)
        local level = storageNumber(fillLevel)
        if level > 0 then
            self:addStorageContent(record, fillTypeIndex, level, capacity, 0, "", nil)
        end
    end
    return true
end

function HofDashboardLive:addStationStorageCollection(record, station, collectionName, seenStorages)
    if station == nil then return false end
    local collection = station[collectionName]
    if type(collection) ~= "table" then return false end
    local added = false
    for key, value in pairs(collection) do
        local storage = type(value) == "table" and value or (type(key) == "table" and key or nil)
        if storage ~= nil and self:addPhysicalStorage(record, storage, seenStorages) then added = true end
    end
    return added
end

function HofDashboardLive:addPlaceableStationStorages(record, placeable, seenStorages)
    local storageSystem = g_currentMission and g_currentMission.storageSystem or nil
    if storageSystem == nil then return false end
    local added = false

    local loadingStations = storageSystem.loadingStations or {}
    for key, value in pairs(loadingStations) do
        local station = type(key) == "table" and key or value
        if station ~= nil and station.owningPlaceable == placeable then
            if self:addStationStorageCollection(record, station, "sourceStorages", seenStorages) then added = true end
        end
    end

    local unloadingStations = storageSystem.unloadingStations or {}
    for key, value in pairs(unloadingStations) do
        local station = type(key) == "table" and key or value
        if station ~= nil and station.owningPlaceable == placeable then
            if self:addStationStorageCollection(record, station, "targetStorages", seenStorages) then added = true end
        end
    end
    return added
end

function HofDashboardLive:classifyStorageRecord(record)
    if record == nil or record.type ~= "storage" then return end
    local names = {}
    local count = 0
    for fillTypeIndex in pairs(record._supportedFillTypes or {}) do
        local data = self:getStorageFillTypeData(fillTypeIndex)
        names[string.upper(tostring(data.fillType))] = true
        count = count + 1
    end
    if count == 1 and names.LIQUIDMANURE then
        record.type, record.typeLabel = "liquidManure", "Güllebehälter"
    elseif count == 1 and names.MANURE then
        record.type, record.typeLabel = "manureHeap", "Misthaufen"
    elseif count == 1 and names.DIGESTATE then
        record.type, record.typeLabel = "digestate", "Gärrestlager"
    end
end

function HofDashboardLive:getStoredObjectSnapshot(abstractObject)
    if abstractObject == nil then return nil end
    local realObject = self:safeGet(function()
        if abstractObject.getRealObject ~= nil then return abstractObject:getRealObject() end
        return nil
    end, nil)
    local object = realObject or abstractObject

    local fillTypeIndex = self:safeGet(function()
        if object.getFillType ~= nil then return object:getFillType() end
        return nil
    end, nil)
    if fillTypeIndex == nil then
        fillTypeIndex = object.fillTypeIndex or object.fillType or abstractObject.fillTypeIndex or abstractObject.fillType
    end

    local fillLevel = self:safeGet(function()
        if object.getFillLevel ~= nil then return object:getFillLevel() end
        return nil
    end, nil)
    if fillLevel == nil then
        fillLevel = object.fillLevel or object.liters or abstractObject.fillLevel or abstractObject.liters or 0
    end

    local title = self:safeGet(function()
        if abstractObject.getDialogText ~= nil then return abstractObject:getDialogText() end
        return nil
    end, nil)
    local className = tostring(abstractObject.REFERENCE_CLASS_NAME or "")
    local classLower = string.lower(className)
    local objectKind = "object"
    if string.find(classLower, "bale", 1, true) ~= nil then objectKind = "bale"
    elseif string.find(classLower, "pallet", 1, true) ~= nil then objectKind = "pallet" end

    return {
        fillTypeIndex = fillTypeIndex,
        fillLevel = storageNumber(fillLevel),
        title = tostring(title or className or "Lagerobjekt"),
        objectKind = objectKind,
    }
end

function HofDashboardLive:addObjectStorage(record, placeable, spec)
    record.type = "objectStorage"
    record.typeLabel = "Ballen-/Palettenlager"
    record.objectCapacity = math.max(0, math.floor(storageNumber(spec.capacity)))
    record.supportsBales = spec.supportsBales ~= false
    record.supportsPallets = spec.supportsPallets ~= false

    local objectInfos = self:safeGet(function()
        if placeable.getObjectStorageObjectInfos ~= nil then return placeable:getObjectStorageObjectInfos() end
        return spec.objectInfos
    end, spec.objectInfos or {})

    if type(objectInfos) == "table" and #objectInfos > 0 then
        for _, info in ipairs(objectInfos) do
            local first = info.objects and info.objects[1] or nil
            local snapshot = self:getStoredObjectSnapshot(first)
            local count = math.max(0, math.floor(storageNumber(info.numObjects or (info.objects and #info.objects) or 0)))
            record.objectCount = record.objectCount + count
            if snapshot ~= nil then
                self:addStorageContent(record, snapshot.fillTypeIndex, snapshot.fillLevel * count, 0, count, snapshot.objectKind, snapshot.title)
            end
        end
        return
    end

    local storedObjects = type(spec.storedObjects) == "table" and spec.storedObjects or {}
    record.objectCount = #storedObjects
    for _, abstractObject in ipairs(storedObjects) do
        local snapshot = self:getStoredObjectSnapshot(abstractObject)
        if snapshot ~= nil then
            self:addStorageContent(record, snapshot.fillTypeIndex, snapshot.fillLevel, 0, 1, snapshot.objectKind, snapshot.title)
        end
    end
end

function HofDashboardLive:addBunkerSilo(record, spec)
    local bunker = spec and spec.bunkerSilo or nil
    if bunker == nil then return false end
    record.type = "bunkerSilo"
    record.typeLabel = "Fahrsilo"
    record.compactedPercent = storageNumber(bunker.compactedPercent)
    record.fermentingPercent = math.floor(storageNumber(bunker.fermentingPercent) * 100 + 0.5)

    local fillTypeIndex = bunker.inputFillType
    if bunker.state == BunkerSilo.STATE_CLOSED then
        fillTypeIndex = bunker.fermentingFillType
    elseif bunker.state == BunkerSilo.STATE_FERMENTED or bunker.state == BunkerSilo.STATE_DRAIN then
        fillTypeIndex = bunker.outputFillType
    end
    local level = storageNumber(bunker.fillLevel)
    if level > 0 then
        self:addStorageContent(record, fillTypeIndex, level, 0, 0, "", nil)
    end
    return true
end

function HofDashboardLive:processStoragePlaceable(placeable, index, seenStorages)
    if placeable == nil then return nil end
    local farmId = self:getStorageOwnerFarmId(placeable)
    local playerFarmId = self:getPlayerFarmId()
    if not self:canAccessStoragePlaceable(placeable, farmId, playerFarmId) then return nil end

    self.storageDiagnostics.accessible = self.storageDiagnostics.accessible + 1
    local record = self:newStorageRecord(placeable, index)
    local recognized = false

    local siloSpec = placeable.spec_silo
    if siloSpec ~= nil then
        recognized = true
        record.type, record.typeLabel = "silo", "Silo"
        if type(siloSpec.storages) == "table" then
            for _, storage in pairs(siloSpec.storages) do self:addPhysicalStorage(record, storage, seenStorages) end
        end
        -- getFillLevels() berücksichtigt auch über Stationen angebundene Erweiterungen.
        local levels = self:safeGet(function()
            if placeable.getFillLevels ~= nil then return placeable:getFillLevels() end
            return nil
        end, nil)
        if type(levels) == "table" and #record.contents == 0 then
            for fillTypeIndex, level in pairs(levels) do
                if storageNumber(level) > 0 then self:addStorageContent(record, fillTypeIndex, level, 0, 0, "", nil) end
            end
        end
    end

    local extensionSpec = placeable.spec_siloExtension
    if extensionSpec ~= nil and extensionSpec.storage ~= nil then
        recognized = true
        record.type, record.typeLabel = "siloExtension", "Silo-Erweiterung"
        self:addPhysicalStorage(record, extensionSpec.storage, seenStorages)
    end

    local manureSpec = placeable.spec_manureHeap
    if manureSpec ~= nil and manureSpec.manureHeap ~= nil then
        recognized = true
        record.type, record.typeLabel = "manureHeap", "Misthaufen"
        self:addPhysicalStorage(record, manureSpec.manureHeap, seenStorages)
    end

    local liquidSpec = placeable.spec_husbandryLiquidManure
    if liquidSpec ~= nil and liquidSpec.fillType ~= nil then
        recognized = true
        if record.type == "storage" then record.type, record.typeLabel = "liquidManure", "Güllebehälter" end
        record._supportedFillTypes[liquidSpec.fillType] = true
        local level = self:safeGet(function()
            if placeable.getHusbandryFillLevel ~= nil then return placeable:getHusbandryFillLevel(liquidSpec.fillType) end
            return 0
        end, 0)
        local capacity = self:safeGet(function()
            if placeable.getHusbandryCapacity ~= nil then return placeable:getHusbandryCapacity(liquidSpec.fillType) end
            return 0
        end, 0)
        record.capacityLiters = math.max(record.capacityLiters, storageNumber(capacity))
        if storageNumber(level) > 0 then self:addStorageContent(record, liquidSpec.fillType, level, capacity, 0, "", nil) end
    end

    local objectSpec = placeable.spec_objectStorage
    if objectSpec ~= nil then
        recognized = true
        self:addObjectStorage(record, placeable, objectSpec)
    end

    if placeable.spec_bunkerSilo ~= nil then
        recognized = self:addBunkerSilo(record, placeable.spec_bunkerSilo) or recognized
    end

    -- Generischer GIANTS-Fallback für Tanks/Lager, die ausschließlich über
    -- Loading-/UnloadingStations an das StorageSystem angebunden sind.
    if self:addPlaceableStationStorages(record, placeable, seenStorages) then recognized = true end

    if not recognized then return nil end
    self.storageDiagnostics.recognized = self.storageDiagnostics.recognized + 1
    self:classifyStorageRecord(record)
    table.sort(record.contents, function(a, b)
        return tostring(a.title or a.fillType or "") < tostring(b.title or b.fillType or "")
    end)
    record._contentsByKey = nil
    record._supportedFillTypes = nil
    return record
end

function HofDashboardLive:createFallbackStorageRecord(storage, index, seenStorages)
    if storage == nil or seenStorages[storage] then return nil end
    local playerFarmId = self:getPlayerFarmId()
    local farmId = self:getPhysicalStorageOwnerFarmId(storage)
    if playerFarmId > 0 and farmId > 0 and farmId ~= playerFarmId then return nil end

    local record = {
        id = "storageSystem:" .. tostring(index),
        name = "Hof-Lager " .. tostring(index),
        type = "storage", typeLabel = "Lager", farmId = farmId,
        isMod = false, modName = "", capacityLiters = 0,
        objectCount = 0, objectCapacity = 0, supportsBales = false, supportsPallets = false,
        contents = self:newArray(), _contentsByKey = {}, _supportedFillTypes = {},
    }
    if not self:addPhysicalStorage(record, storage, seenStorages) then return nil end
    self:classifyStorageRecord(record)
    record._contentsByKey = nil
    record._supportedFillTypes = nil
    return record
end

function HofDashboardLive:collectStorages()
    local result = self:newArray()
    self.storageDiagnostics = { placeablesSeen = 0, accessible = 0, recognized = 0, exported = 0, registeredStoragesSeen = 0 }
    if g_currentMission == nil then return result end

    -- WICHTIG: Placeables liegen in FS25 im PlaceableSystem. Die frühere
    -- Abfrage g_currentMission.placeables war auf aktuellen FS25-Versionen nil
    -- und führte deshalb immer zu einer leeren Vorratsliste.
    local placeables = nil
    if g_currentMission.placeableSystem ~= nil then
        placeables = g_currentMission.placeableSystem.placeables
    end
    if type(placeables) ~= "table" then placeables = g_currentMission.placeables end
    if type(placeables) ~= "table" then return result end

    local seenStorages = {}
    local index = 0
    for _, placeable in pairs(placeables) do
        index = index + 1
        self.storageDiagnostics.placeablesSeen = self.storageDiagnostics.placeablesSeen + 1
        local ok, data = self:protected("processStorage " .. tostring(placeable and placeable.typeName or "?"), function()
            return self:processStoragePlaceable(placeable, index, seenStorages)
        end)
        if ok and data ~= nil then table.insert(result, data) end
    end

    local storageSystem = g_currentMission.storageSystem
    if storageSystem ~= nil then
        local storages = storageSystem.storages or {}
        local storageIndex = 0
        for key, value in pairs(storages) do
            storageIndex = storageIndex + 1
            self.storageDiagnostics.registeredStoragesSeen = self.storageDiagnostics.registeredStoragesSeen + 1
            local storage = type(key) == "table" and key or value
            local ok, data = self:protected("fallbackStorage " .. tostring(storageIndex), function()
                return self:createFallbackStorageRecord(storage, storageIndex, seenStorages)
            end)
            if ok and data ~= nil then table.insert(result, data) end
        end
    end

    table.sort(result, function(a, b)
        if tostring(a.name or "") == tostring(b.name or "") then
            return tostring(a.typeLabel or "") < tostring(b.typeLabel or "")
        end
        return tostring(a.name or "") < tostring(b.name or "")
    end)
    self.storageDiagnostics.exported = #result
    return result
end
