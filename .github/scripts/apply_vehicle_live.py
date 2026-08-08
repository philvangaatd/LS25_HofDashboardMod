from pathlib import Path

lua_path = Path('scripts/AutoDriveFlurkarte.lua')
moddesc_path = Path('modDesc.xml')
lua = lua_path.read_text(encoding='utf-8')
moddesc = moddesc_path.read_text(encoding='utf-8')


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'{label}: expected one match, got {count}')
    return text.replace(old, new, 1)


def replace_between(text: str, start: str, end: str, replacement: str, label: str) -> str:
    a = text.find(start)
    if a < 0:
        raise RuntimeError(f'{label}: start marker missing')
    b = text.find(end, a)
    if b < 0:
        raise RuntimeError(f'{label}: end marker missing')
    return text[:a] + replacement + text[b:]


lua = replace_once(lua, 'Live Data Export v4.1', 'Live Data Export v4.2', 'header version')
lua = replace_once(lua, 'AutoDriveFlurkarteLive.VERSION         = "4.1.0"', 'AutoDriveFlurkarteLive.VERSION         = "4.2.0"', 'runtime version')

old_export = '''function AutoDriveFlurkarteLive:exportAllData()
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
end'''
new_export = '''function AutoDriveFlurkarteLive:exportAllData()
    local vehicles = self:collectVehicles()
    local data = {
        version       = self.VERSION,
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
        productions    = self:collectProductions(),
        contracts      = self:collectContracts(),
        market         = self:collectMarket(),
    }

    self:writeFile(self:jsonEncode(data))
end'''
lua = replace_once(lua, old_export, new_export, 'exportAllData')

vehicle_block = r'''function AutoDriveFlurkarteLive:collectVehicles()
    local result = self:newArray()
    local diagnostics = { seen = 0, exported = 0, failed = 0, skipped = 0 }
    self.vehicleDiagnostics = diagnostics

    if g_currentMission == nil or g_currentMission.vehicles == nil then return result end

    local myFarmId = self:getPlayerFarmId()
    if myFarmId <= 0 then
        self:logError("collectVehicles", "Spieler-FarmId konnte nicht ermittelt werden")
        return result
    end

    for _, vehicle in ipairs(g_currentMission.vehicles) do
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

function AutoDriveFlurkarteLive:getVehicleOwnerFarmId(vehicle)
    local ownerId = 0
    if vehicle.getOwnerFarmId ~= nil then
        ownerId = self:safeGet(function() return vehicle:getOwnerFarmId() end, 0) or 0
    end
    if ownerId <= 0 then ownerId = vehicle.ownerFarmId or 0 end
    return ownerId
end

function AutoDriveFlurkarteLive:getVehicleCategory(vehicle)
    if vehicle.spec_motorized ~= nil or vehicle.spec_enterable ~= nil or vehicle.spec_drivable ~= nil then
        return "VEHICLE"
    end
    if vehicle.spec_trailer ~= nil then return "TRAILER" end
    return "IMPLEMENT"
end

function AutoDriveFlurkarteLive:getVehicleStoreInfo(vehicle)
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

function AutoDriveFlurkarteLive:getFillTypeData(fillTypeIndex)
    if fillTypeIndex == nil or FillType == nil or fillTypeIndex == FillType.UNKNOWN then return nil end
    local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
    if fillType == nil then return nil end
    local name = string.upper(fillType.name or "UNKNOWN")
    return {
        index = fillTypeIndex,
        name = name,
        title = fillType.title or fillType.name or name,
    }
end

function AutoDriveFlurkarteLive:isIgnoredVehicleFillType(name)
    return name == "AIR" or name == "BALE_NET" or name == "UNKNOWN"
end

function AutoDriveFlurkarteLive:processVehicle(vehicle, myFarmId)
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

'''

lua = replace_between(
    lua,
    'function AutoDriveFlurkarteLive:collectVehicles()',
    '-- ======================================================================\n-- TIERHALTUNG',
    vehicle_block,
    'vehicle export block',
)

moddesc = replace_once(moddesc, '<version>4.1.0.0</version>', '<version>4.2.0.0</version>', 'modDesc version')

lua_path.write_text(lua, encoding='utf-8')
moddesc_path.write_text(moddesc, encoding='utf-8')
