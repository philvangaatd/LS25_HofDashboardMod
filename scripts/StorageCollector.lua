-- Collector für Hof-Vorräte aus den standardisierten FS25-Storage-Spezialisierungen.
-- Unterstützt dadurch auch Mod-Placeables, sofern sie die GIANTS-APIs verwenden.

local function storageNumber(value)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        return 0
    end
    return math.max(0, value)
end

function HofDashboardLive:getStorageOwnerFarmId(placeable)
    if placeable == nil then return 0 end
    if placeable.getOwnerFarmId ~= nil then
        local value = self:safeGet(function() return placeable:getOwnerFarmId() end, nil)
        if type(value) == "number" then return value end
    end
    return placeable.ownerFarmId or 0
end

function HofDashboardLive:getPhysicalStorageOwnerFarmId(storage)
    if storage == nil then return 0 end
    if storage.getOwnerFarmId ~= nil then
        local value = self:safeGet(function() return storage:getOwnerFarmId() end, nil)
        if type(value) == "number" then return value end
    end
    return storage.ownerFarmId or 0
end

function HofDashboardLive:canAccessStoragePlaceable(placeable, ownerFarmId, playerFarmId)
    if placeable == nil then return false end
    if playerFarmId > 0 and ownerFarmId == playerFarmId then return true end

    local mission = g_currentMission
    local accessHandler = mission and mission.accessHandler or nil
    if accessHandler ~= nil and playerFarmId > 0 and accessHandler.canFarmAccess ~= nil then
        local canAccess = self:safeGet(function()
            return accessHandler:canFarmAccess(playerFarmId, placeable)
        end, false)
        if canAccess == true then return true end
    end

    if accessHandler ~= nil and accessHandler.canPlayerAccess ~= nil then
        local canAccess = self:safeGet(function()
            return accessHandler:canPlayerAccess(placeable)
        end, false)
        if canAccess == true then return true end
    end

    return playerFarmId <= 0 and ownerFarmId > 0
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

function HofDashboardLive:addStorageContent(record, fillTypeIndex, level, capacity, objectCount, objectKind, fallbackTitle)
    if record == nil then return end

    local fillData = self:getStorageFillTypeData(fillTypeIndex)
    local fillTypeName = fillData.fillType
    local title = fillData.title
    if (fillTypeIndex == nil or fillTypeName == "UNKNOWN" or fillTypeName == "nil") and fallbackTitle ~= nil and fallbackTitle ~= "" then
        fillTypeName = "OBJECT:" .. tostring(fallbackTitle)
        title = tostring(fallbackTitle)
    end

    local key = string.upper(tostring(fillTypeName))
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
    entry.capacity = entry.capacity + storageNumber(capacity)
    entry.objectCount = entry.objectCount + math.max(0, math.floor(storageNumber(objectCount)))
    if entry.objectKind == "" and objectKind ~= nil then entry.objectKind = objectKind end
    if entry.capacity > 0 then
        entry.percent = math.floor(math.min(100, entry.level / entry.capacity * 100) + 0.5)
    end
end

function HofDashboardLive:addPhysicalStorage(record, storage, seenStorages)
    if record == nil or storage == nil or seenStorages[storage] then return false end
    seenStorages[storage] = true

    local capacityLiters = storageNumber(storage.capacity)
    if capacityLiters <= 0 and type(storage.capacities) == "table" then
        for _, value in pairs(storage.capacities) do
            capacityLiters = capacityLiters + storageNumber(value)
        end
    end
    record.capacityLiters = record.capacityLiters + capacityLiters

    local supportedFillTypes = type(storage.fillTypes) == "table" and storage.fillTypes or {}
    for fillTypeIndex, accepted in pairs(supportedFillTypes) do
        if accepted == true then
            record._supportedFillTypes[fillTypeIndex] = true
        end
    end

    local fillLevels = type(storage.fillLevels) == "table" and storage.fillLevels or {}
    for fillTypeIndex, fillLevel in pairs(fillLevels) do
        record._supportedFillTypes[fillTypeIndex] = true
        local level = storageNumber(fillLevel)
        if level > 0 then
            local fallbackCapacity = storage.capacities and storage.capacities[fillTypeIndex]
                or storage.capacity
                or 0
            local capacity = self:safeGet(function()
                if storage.getCapacity ~= nil then
                    return storage:getCapacity(fillTypeIndex)
                end
                return fallbackCapacity
            end, fallbackCapacity)
            self:addStorageContent(record, fillTypeIndex, level, capacity, 0, "", nil)
        end
    end

    return true
end

function HofDashboardLive:addStationStorages(record, station, collectionName, seenStorages)
    if record == nil or station == nil then return false end
    local collection = station[collectionName]
    if type(collection) ~= "table" then return false end

    local added = false
    for key, value in pairs(collection) do
        local storage = nil
        if type(value) == "table" then
            storage = value
        elseif type(key) == "table" then
            storage = key
        end
        if storage ~= nil and self:addPhysicalStorage(record, storage, seenStorages) then
            added = true
        end
    end
    return added
end

function HofDashboardLive:addOwnedStationStorages(record, placeable, seenStorages)
    local mission = g_currentMission
    local storageSystem = mission and mission.storageSystem or nil
    if storageSystem == nil then return false end

    local added = false
    local loadingStations = self:safeGet(function()
        return storageSystem.getLoadingStations and storageSystem:getLoadingStations() or storageSystem.loadingStations
    end, storageSystem.loadingStations or {})
    for station, value in pairs(loadingStations or {}) do
        local candidate = type(station) == "table" and station or value
        if candidate ~= nil and candidate.owningPlaceable == placeable then
            if self:addStationStorages(record, candidate, "sourceStorages", seenStorages) then added = true end
        end
    end

    local unloadingStations = self:safeGet(function()
        return storageSystem.getUnloadingStations and storageSystem:getUnloadingStations() or storageSystem.unloadingStations
    end, storageSystem.unloadingStations or {})
    for station, value in pairs(unloadingStations or {}) do
        local candidate = type(station) == "table" and station or value
        if candidate ~= nil and candidate.owningPlaceable == placeable then
            if self:addStationStorages(record, candidate, "targetStorages", seenStorages) then added = true end
        end
    end

    return added
end

function HofDashboardLive:classifyStorageRecord(record)
    if record == nil or record.type ~= "storage" then return end

    local names = {}
    for fillTypeIndex, _ in pairs(record._supportedFillTypes or {}) do
        local data = self:getStorageFillTypeData(fillTypeIndex)
        names[string.upper(tostring(data.fillType))] = true
    end

    if names.LIQUIDMANURE and next(names, "LIQUIDMANURE") == nil then
        record.type = "liquidManure"
        record.typeLabel = "Güllebehälter"
    elseif names.MANURE and next(names, "MANURE") == nil then
        record.type = "manureHeap"
        record.typeLabel = "Misthaufen"
    elseif names.DIGESTATE and next(names, "DIGESTATE") == nil then
        record.type = "digestate"
        record.typeLabel = "Gärrestlager"
    end
end

function HofDashboardLive:getStoredObjectSnapshot(abstractObject)
    if abstractObject == nil then return nil end

    local realObject = self:safeGet(function()
        if abstractObject.getRealObject ~= nil then
            return abstractObject:getRealObject()
        end
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

    local dialogText = self:safeGet(function()
        if abstractObject.getDialogText ~= nil then return abstractObject:getDialogText() end
        return nil
    end, nil)

    local className = tostring(abstractObject.REFERENCE_CLASS_NAME or "")
    local classNameLower = string.lower(className)
    local objectKind = "object"
    if string.find(classNameLower, "bale", 1, true) ~= nil then
        objectKind = "bale"
    elseif string.find(classNameLower, "pallet", 1, true) ~= nil then
        objectKind = "pallet"
    end

    return {
        fillTypeIndex = fillTypeIndex,
        fillLevel = storageNumber(fillLevel),
        title = tostring(dialogText or className or "Lagerobjekt"),
        objectKind = objectKind,
    }
end

function HofDashboardLive:processStoragePlaceable(placeable, placeableIndex, seenStorages)
    if placeable == nil then return nil end

    local farmId = self:getStorageOwnerFarmId(placeable)
    local playerFarmId = self:getPlayerFarmId()
    if not self:canAccessStoragePlaceable(placeable, farmId, playerFarmId) then return nil end

    local placeableName = self:safeGet(function()
        if placeable.getName ~= nil then return placeable:getName() end
        return nil
    end, nil)
    if placeableName == nil or placeableName == "" then
        placeableName = placeable.typeName or "Lager"
    end

    local customEnvironment = tostring(placeable.customEnvironment or placeable.modName or "")
    local record = {
        id = tostring(placeable.typeName or "placeable") .. ":" .. tostring(placeableIndex or 0),
        name = tostring(placeableName),
        type = "storage",
        typeLabel = "Lager",
        farmId = farmId,
        isMod = customEnvironment ~= "",
        modName = customEnvironment,
        capacityLiters = 0,
        objectCount = 0,
        objectCapacity = 0,
        supportsBales = false,
        supportsPallets = false,
        contents = self:newArray(),
        _contentsByKey = {},
        _supportedFillTypes = {},
    }
    local recognized = false

    local siloSpec = placeable.spec_silo
    if siloSpec ~= nil and type(siloSpec.storages) == "table" then
        recognized = true
        record.type = "silo"
        record.typeLabel = "Silo"
        for _, storage in pairs(siloSpec.storages) do
            self:addPhysicalStorage(record, storage, seenStorages)
        end
    end

    local extensionSpec = placeable.spec_siloExtension
    if extensionSpec ~= nil and extensionSpec.storage ~= nil then
        recognized = true
        record.type = "siloExtension"
        record.typeLabel = "Silo-Erweiterung"
        self:addPhysicalStorage(record, extensionSpec.storage, seenStorages)
    end

    local manureSpec = placeable.spec_manureHeap
    if manureSpec ~= nil and manureSpec.manureHeap ~= nil then
        recognized = true
        record.type = "manureHeap"
        record.typeLabel = "Misthaufen"
        self:addPhysicalStorage(record, manureSpec.manureHeap, seenStorages)
    end

    local liquidManureSpec = placeable.spec_husbandryLiquidManure
    if liquidManureSpec ~= nil and liquidManureSpec.fillType ~= nil then
        recognized = true
        if record.type == "storage" then
            record.type = "liquidManure"
            record.typeLabel = "Güllebehälter"
        end
        record._supportedFillTypes[liquidManureSpec.fillType] = true
        local fillData = self:getStorageFillTypeData(liquidManureSpec.fillType)
        local contentKey = string.upper(tostring(fillData.fillType))
        if record._contentsByKey[contentKey] == nil then
            local level = self:safeGet(function()
                if placeable.getHusbandryFillLevel ~= nil then
                    return placeable:getHusbandryFillLevel(liquidManureSpec.fillType)
                end
                return 0
            end, 0)
            local capacity = self:safeGet(function()
                if placeable.getHusbandryCapacity ~= nil then
                    return placeable:getHusbandryCapacity(liquidManureSpec.fillType)
                end
                return 0
            end, 0)
            record.capacityLiters = record.capacityLiters + storageNumber(capacity)
            if storageNumber(level) > 0 then
                self:addStorageContent(record, liquidManureSpec.fillType, level, capacity, 0, "", nil)
            end
        end
    end

    local objectStorageSpec = placeable.spec_objectStorage
    if objectStorageSpec ~= nil then
        recognized = true
        record.type = "objectStorage"
        record.typeLabel = "Ballen-/Palettenlager"
        record.objectCapacity = math.max(0, math.floor(storageNumber(objectStorageSpec.capacity)))
        record.supportsBales = objectStorageSpec.supportsBales == true
        record.supportsPallets = objectStorageSpec.supportsPallets == true

        local storedObjects = type(objectStorageSpec.storedObjects) == "table" and objectStorageSpec.storedObjects or {}
        record.objectCount = #storedObjects
        for _, abstractObject in ipairs(storedObjects) do
            local snapshot = self:getStoredObjectSnapshot(abstractObject)
            if snapshot ~= nil then
                self:addStorageContent(
                    record,
                    snapshot.fillTypeIndex,
                    snapshot.fillLevel,
                    0,
                    1,
                    snapshot.objectKind,
                    snapshot.title
                )
            end
        end
    end

    -- Einige Standalone-Tanks und Mod-Placeables hängen ihre Storage-Objekte nur
    -- an Loading-/UnloadingStations. Diese Verbindung ist Teil des GIANTS-
    -- StorageSystems und wird deshalb als generischer Fallback ausgewertet.
    if not recognized and self:addOwnedStationStorages(record, placeable, seenStorages) then
        recognized = true
        self:classifyStorageRecord(record)
    end

    if not recognized then return nil end

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
    if playerFarmId > 0 and farmId ~= playerFarmId then return nil end
    if playerFarmId <= 0 and farmId <= 0 then return nil end

    local storageName = self:safeGet(function()
        if storage.getName ~= nil then return storage:getName() end
        return nil
    end, nil)
    if storageName == nil or storageName == "" then storageName = "Hof-Lager " .. tostring(index) end

    local record = {
        id = "storageSystem:" .. tostring(index),
        name = tostring(storageName),
        type = "storage",
        typeLabel = "Lager",
        farmId = farmId,
        isMod = false,
        modName = "",
        capacityLiters = 0,
        objectCount = 0,
        objectCapacity = 0,
        supportsBales = false,
        supportsPallets = false,
        contents = self:newArray(),
        _contentsByKey = {},
        _supportedFillTypes = {},
    }

    if not self:addPhysicalStorage(record, storage, seenStorages) then return nil end
    self:classifyStorageRecord(record)
    table.sort(record.contents, function(a, b)
        return tostring(a.title or a.fillType or "") < tostring(b.title or b.fillType or "")
    end)
    record._contentsByKey = nil
    record._supportedFillTypes = nil
    return record
end

function HofDashboardLive:collectStorages()
    local result = self:newArray()
    if g_currentMission == nil or g_currentMission.placeables == nil then return result end

    local seenStorages = {}
    local placeableIndex = 0
    for _, placeable in pairs(g_currentMission.placeables) do
        placeableIndex = placeableIndex + 1
        local ok, data = self:protected(
            "processStorage " .. tostring(placeable and placeable.typeName or "?"),
            function() return self:processStoragePlaceable(placeable, placeableIndex, seenStorages) end
        )
        if ok and data ~= nil then table.insert(result, data) end
    end

    -- Letzter Sicherheitsnetz-Fallback: vom GIANTS StorageSystem registrierte,
    -- dem Spielerhof gehörende Storages aufnehmen, die keine bekannte
    -- Placeable-Spezialisierung offenlegen. Bereits gefundene Storages sind
    -- durch seenStorages ausgeschlossen.
    local storageSystem = g_currentMission.storageSystem
    if storageSystem ~= nil then
        local storages = self:safeGet(function()
            return storageSystem.getStorages and storageSystem:getStorages() or storageSystem.storages
        end, storageSystem.storages or {})
        local storageIndex = 0
        for storage, value in pairs(storages or {}) do
            storageIndex = storageIndex + 1
            local candidate = type(storage) == "table" and storage or value
            local ok, data = self:protected(
                "fallbackStorage " .. tostring(storageIndex),
                function() return self:createFallbackStorageRecord(candidate, storageIndex, seenStorages) end
            )
            if ok and data ~= nil then table.insert(result, data) end
        end
    end

    table.sort(result, function(a, b)
        local nameCompare = tostring(a.name or "") < tostring(b.name or "")
        if tostring(a.name or "") == tostring(b.name or "") then
            return tostring(a.typeLabel or "") < tostring(b.typeLabel or "")
        end
        return nameCompare
    end)

    return result
end