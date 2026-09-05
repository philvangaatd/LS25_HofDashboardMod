-- Ergänzende Laufzeit-Fixes für die Vorrats-Erkennung.
-- Wird nach StorageCollector.lua geladen und überschreibt gezielt einzelne Helfer.

local hdOriginalProcessStoragePlaceable = HofDashboardLive.processStoragePlaceable
local hdOriginalGetStoredObjectSnapshot = HofDashboardLive.getStoredObjectSnapshot

local function hdStorageNumber(value)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        return 0
    end
    return math.max(0, value)
end

local function hdSafeBool(value)
    return value == true
end

local function hdLooksLikeStorage(value)
    if type(value) ~= "table" then return false end
    if value.getFillLevels ~= nil or value.getFillLevel ~= nil or value.getCapacity ~= nil then return true end
    if type(value.fillLevels) == "table" or type(value.fillTypes) == "table" or type(value.capacities) == "table" then return true end
    return false
end

function HofDashboardLive:isStoragePlaceableAlive(placeable)
    if placeable == nil then return false end
    if hdSafeBool(placeable.isDeleted) or hdSafeBool(placeable.isDeleting) or hdSafeBool(placeable.isRemoved) then return false end

    if placeable.getIsDeleted ~= nil then
        local deleted = self:safeGet(function() return placeable:getIsDeleted() end, false)
        if deleted == true then return false end
    end

    local rootNode = placeable.rootNode or placeable.nodeId
    if type(rootNode) == "number" then
        if rootNode == 0 then return false end
        if entityExists ~= nil then
            local exists = self:safeGet(function() return entityExists(rootNode) end, true)
            if exists == false then return false end
        end
    end
    return true
end

function HofDashboardLive:getStoredObjectSnapshot(abstractObject)
    local snapshot = hdOriginalGetStoredObjectSnapshot(self, abstractObject)
    if snapshot == nil then return nil end

    local titleLower = string.lower(tostring(snapshot.title or ""))
    if snapshot.objectKind == "object" then
        if string.find(titleLower, "ballen", 1, true) ~= nil or string.find(titleLower, "bale", 1, true) ~= nil then
            snapshot.objectKind = "bale"
        elseif string.find(titleLower, "palette", 1, true) ~= nil or string.find(titleLower, "pallet", 1, true) ~= nil then
            snapshot.objectKind = "pallet"
        end
    end
    return snapshot
end

function HofDashboardLive:stationBelongsToPlaceable(station, placeable)
    if station == nil or placeable == nil then return false end
    if station.owningPlaceable == placeable or station.placeable == placeable or station.ownerPlaceable == placeable then return true end
    if station.getOwningPlaceable ~= nil then
        local owner = self:safeGet(function() return station:getOwningPlaceable() end, nil)
        if owner == placeable then return true end
    end
    return false
end

function HofDashboardLive:addPlaceableStationStorages(record, placeable, seenStorages)
    local storageSystem = g_currentMission and g_currentMission.storageSystem or nil
    if storageSystem == nil then return false end
    local added = false

    local function addFromCollection(collection)
        if type(collection) ~= "table" then return end
        for key, value in pairs(collection) do
            local storage = nil
            if hdLooksLikeStorage(value) then
                storage = value
            elseif type(value) == "table" and hdLooksLikeStorage(value.storage) then
                storage = value.storage
            elseif hdLooksLikeStorage(key) then
                storage = key
            end
            if storage ~= nil and self:addPhysicalStorage(record, storage, seenStorages) then added = true end
        end
    end

    for key, value in pairs(storageSystem.loadingStations or {}) do
        local station = type(key) == "table" and key or value
        if self:stationBelongsToPlaceable(station, placeable) then
            addFromCollection(station.sourceStorages)
            addFromCollection(station.targetStorages)
        end
    end
    for key, value in pairs(storageSystem.unloadingStations or {}) do
        local station = type(key) == "table" and key or value
        if self:stationBelongsToPlaceable(station, placeable) then
            addFromCollection(station.targetStorages)
            addFromCollection(station.sourceStorages)
        end
    end

    for specName, spec in pairs(placeable) do
        if type(specName) == "string" and string.sub(specName, 1, 5) == "spec_" and type(spec) == "table" then
            for _, fieldName in ipairs({ "loadingStation", "unloadingStation" }) do
                local station = spec[fieldName]
                if type(station) == "table" then
                    addFromCollection(station.sourceStorages)
                    addFromCollection(station.targetStorages)
                end
            end
        end
    end

    return added
end

function HofDashboardLive:addGenericSpecStorages(record, placeable, seenStorages)
    local added = false
    local visited = {}

    local function tryValue(value, depth)
        if type(value) ~= "table" or visited[value] then return end
        visited[value] = true
        if hdLooksLikeStorage(value) then
            if self:addPhysicalStorage(record, value, seenStorages) then added = true end
            return
        end
        if depth <= 0 then return end
        for key, child in pairs(value) do
            if type(key) == "string" then
                local lower = string.lower(key)
                if string.find(lower, "storage", 1, true) ~= nil or string.find(lower, "station", 1, true) ~= nil then
                    tryValue(child, depth - 1)
                end
            end
        end
    end

    for specName, spec in pairs(placeable) do
        if type(specName) == "string" and string.sub(specName, 1, 5) == "spec_" and type(spec) == "table" then
            tryValue(spec, 2)
        end
    end
    return added
end

function HofDashboardLive:refineStorageRecordType(record, placeable)
    if record == nil or placeable == nil then return end

    if placeable.spec_objectStorage ~= nil then
        record.type, record.typeLabel = "objectStorage", "Ballen-/Palettenlager"
        return
    end
    if placeable.spec_manureHeap ~= nil then
        record.type, record.typeLabel = "manureHeap", "Misthaufen"
        return
    end
    if placeable.spec_bunkerSilo ~= nil then
        record.type, record.typeLabel = "bunkerSilo", "Fahrsilo"
        return
    end

    local isHusbandry = placeable.spec_husbandry ~= nil
        or placeable.spec_husbandryAnimals ~= nil
        or placeable.spec_husbandryFood ~= nil
    if isHusbandry then
        record.type, record.typeLabel = "husbandry", "Tierstall"
        return
    end

    if placeable.spec_productionPoint ~= nil then
        record.type, record.typeLabel = "productionStorage", "Produktionslager"
        return
    end

    self:classifyStorageRecord(record)
end

function HofDashboardLive:processStoragePlaceable(placeable, index, seenStorages)
    if not self:isStoragePlaceableAlive(placeable) then return nil end

    local record = hdOriginalProcessStoragePlaceable(self, placeable, index, seenStorages)
    if record == nil then
        local farmId = self:getStorageOwnerFarmId(placeable)
        local playerFarmId = self:getPlayerFarmId()
        if not self:canAccessStoragePlaceable(placeable, farmId, playerFarmId) then return nil end

        record = self:newStorageRecord(placeable, index)
        local recognized = self:addGenericSpecStorages(record, placeable, seenStorages)
        if not recognized then return nil end
        self.storageDiagnostics.recognized = self.storageDiagnostics.recognized + 1
    else
        if #record.contents == 0 and hdStorageNumber(record.capacityLiters) <= 0 and hdStorageNumber(record.objectCapacity) <= 0 then
            self:addGenericSpecStorages(record, placeable, seenStorages)
        end
    end

    self:refineStorageRecordType(record, placeable)

    if record.type == "bunkerSilo"
        and #record.contents == 0
        and hdStorageNumber(record.capacityLiters) <= 0 then
        return nil
    end

    record._contentsByKey = nil
    record._supportedFillTypes = nil
    return record
end
