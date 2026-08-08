from pathlib import Path
import re

lua_path = Path('scripts/AutoDriveFlurkarte.lua')
mod_desc_path = Path('modDesc.xml')
lua = lua_path.read_text(encoding='utf-8')
mod_desc = mod_desc_path.read_text(encoding='utf-8')

lua = lua.replace('FS25_AutoDriveFlurkarte – Live Data Export v4.4', 'FS25_AutoDriveFlurkarte – Live Data Export v4.5', 1)
lua = lua.replace('AutoDriveFlurkarteLive.VERSION         = "4.4.0"', 'AutoDriveFlurkarteLive.VERSION         = "4.5.0"', 1)

old_export = '''        animals        = self:collectAnimals(),\n        productions    = self:collectProductions(),'''
new_export = '''        animals        = self:collectAnimals(),\n        animalDiagnostics = self.animalDiagnostics or { seen = 0, exported = 0, failed = 0, skipped = 0 },\n        beehives       = self:collectBeehives(),\n        productions    = self:collectProductions(),'''
if old_export not in lua:
    raise SystemExit('export animals block not found')
lua = lua.replace(old_export, new_export, 1)

new_animals = r'''-- ======================================================================
-- TIERHALTUNG / BIENEN – LIVE
--
-- Der Lua-Mod ist auch hier die autoritative Quelle. Die Daten werden direkt
-- aus den laufenden Husbandry-Specializations gelesen, nicht aus placeables.xml.
-- ======================================================================

function AutoDriveFlurkarteLive:normalizeAnimalFactor(value)
    value = tonumber(value) or 0
    if value > 1 then value = value / 100 end
    return math.max(0, math.min(1, value))
end

function AutoDriveFlurkarteLive:getPlaceableOwnerFarmId(placeable)
    if placeable ~= nil and placeable.getOwnerFarmId ~= nil then
        return self:safeGet(function() return placeable:getOwnerFarmId() end, placeable.ownerFarmId or 0) or 0
    end
    return placeable and (placeable.ownerFarmId or 0) or 0
end

function AutoDriveFlurkarteLive:getHusbandryFill(placeable, fillTypeIndex)
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

function AutoDriveFlurkarteLive:makeHusbandryFillEntry(placeable, fillTypeIndex, extra)
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

function AutoDriveFlurkarteLive:getAnimalSubTypeTitle(subType)
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

function AutoDriveFlurkarteLive:collectAnimals()
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

function AutoDriveFlurkarteLive:processHusbandry(placeable, myFarmId)
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

function AutoDriveFlurkarteLive:countOwnedPalletFillType(fillTypeIndex, myFarmId)
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

function AutoDriveFlurkarteLive:collectBeehives()
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

'''

pattern = re.compile(r'-- ======================================================================\n-- TIERHALTUNG\n-- ======================================================================\n.*?(?=-- ======================================================================\n-- PRODUKTIONSANLAGEN)', re.S)
match = pattern.search(lua)
if not match:
    raise SystemExit('animal section not found')
lua = lua[:match.start()] + new_animals + lua[match.end():]

if '<version>4.4.0.0</version>' not in mod_desc:
    raise SystemExit('modDesc 4.4.0.0 version not found')
mod_desc = mod_desc.replace('<version>4.4.0.0</version>', '<version>4.5.0.0</version>', 1)

lua_path.write_text(lua, encoding='utf-8')
mod_desc_path.write_text(mod_desc, encoding='utf-8')
