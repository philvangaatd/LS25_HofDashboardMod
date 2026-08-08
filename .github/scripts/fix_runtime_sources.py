from pathlib import Path

lua_path = Path('scripts/AutoDriveFlurkarte.lua')
mod_desc_path = Path('modDesc.xml')

lua = lua_path.read_text(encoding='utf-8')
mod_desc = mod_desc_path.read_text(encoding='utf-8')

lua = lua.replace('FS25_AutoDriveFlurkarte – Live Data Export v4.2', 'FS25_AutoDriveFlurkarte – Live Data Export v4.3', 1)
lua = lua.replace('AutoDriveFlurkarteLive.VERSION         = "4.2.0"', 'AutoDriveFlurkarteLive.VERSION         = "4.3.0"', 1)

old_classify = '''function AutoDriveFlurkarteLive:classifyFieldState(fieldState)
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
'''

new_classify = '''function AutoDriveFlurkarteLive:classifyFieldState(fieldState)
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
'''

if old_classify not in lua:
    raise SystemExit('classifyFieldState source block not found')
lua = lua.replace(old_classify, new_classify, 1)

old_vehicle_source = '''    if g_currentMission == nil or g_currentMission.vehicles == nil then return result end

    local myFarmId = self:getPlayerFarmId()
'''
new_vehicle_source = '''    -- FS25 verwaltet die registrierten Savegame-Fahrzeuge im VehicleSystem.
    -- g_currentMission.vehicles ist in aktuellen Builds nicht die Fahrzeugliste und
    -- kann nil sein, wodurch der bisherige Export sofort mit seen=0 zurückkehrte.
    local vehicleSystem = g_currentMission and g_currentMission.vehicleSystem or nil
    local vehicles = vehicleSystem and vehicleSystem.vehicles or nil
    if vehicles == nil then
        self:logError("collectVehicles", "g_currentMission.vehicleSystem.vehicles nicht verfügbar")
        return result
    end

    local myFarmId = self:getPlayerFarmId()
'''
if old_vehicle_source not in lua:
    raise SystemExit('vehicle source guard not found')
lua = lua.replace(old_vehicle_source, new_vehicle_source, 1)

old_vehicle_loop = '    for _, vehicle in ipairs(g_currentMission.vehicles) do\n'
new_vehicle_loop = '    for _, vehicle in pairs(vehicles) do\n'
if old_vehicle_loop not in lua:
    raise SystemExit('vehicle loop not found')
lua = lua.replace(old_vehicle_loop, new_vehicle_loop, 1)

old_market_condition = '''        if fillType ~= nil and fillType.pricePerLiter ~= nil and fillType.pricePerLiter > 0 then
'''
new_market_condition = '''        -- Nur FillTypes exportieren, die GIANTS selbst für die Preisübersicht
        -- freigibt. Tier-Rassen besitzen ebenfalls pricePerLiter-Werte, sind aber
        -- keine Marktprodukte und haben showOnPriceTable=false.
        if fillType ~= nil
            and fillType.showOnPriceTable == true
            and fillType.pricePerLiter ~= nil
            and fillType.pricePerLiter > 0 then
'''
if old_market_condition not in lua:
    raise SystemExit('market condition not found')
lua = lua.replace(old_market_condition, new_market_condition, 1)

if '<version>4.2.0.0</version>' not in mod_desc:
    raise SystemExit('modDesc version not found')
mod_desc = mod_desc.replace('<version>4.2.0.0</version>', '<version>4.3.0.0</version>', 1)

lua_path.write_text(lua, encoding='utf-8')
mod_desc_path.write_text(mod_desc, encoding='utf-8')
