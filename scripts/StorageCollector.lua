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

    local fillLevels = type(storage.fillLevels) == "table" and storage.fillLevels or {}
    for fillTypeIndex, fillLevel in pairs(fillLevels) do
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
    if farmId <= 0 or (playerFarmId > 0 and farmId ~= playerFarmId) then return nil end

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

    if not recognized then return nil end

    table.sort(record.contents, function(a, b)
        return tostring(a.title or a.fillType or "") < tostring(b.title or b.fillType or "")
    end)
    record._contentsByKey = nil
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

    table.sort(result, function(a, b)
        local nameCompare = tostring(a.name or "") < tostring(b.name or "")
        if tostring(a.name or "") == tostring(b.name or "") then
            return tostring(a.typeLabel or "") < tostring(b.typeLabel or "")
        end
        return nameCompare
    end)

    return result
end
