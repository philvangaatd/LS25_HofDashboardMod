from pathlib import Path
import re

lua_path = Path('scripts/AutoDriveFlurkarte.lua')
mod_desc_path = Path('modDesc.xml')
lua = lua_path.read_text(encoding='utf-8')
mod_desc = mod_desc_path.read_text(encoding='utf-8')

# Version bump
lua = lua.replace('FS25_AutoDriveFlurkarte – Live Data Export v4.5', 'FS25_AutoDriveFlurkarte – Live Data Export v4.5.1', 1)
lua = lua.replace('AutoDriveFlurkarteLive.VERSION         = "4.5.0"', 'AutoDriveFlurkarteLive.VERSION         = "4.5.1"', 1)
mod_desc = mod_desc.replace('<version>4.5.0.0</version>', '<version>4.5.1.0</version>', 1)

helper = r'''
function AutoDriveFlurkarteLive:getMissionPlaceables()
    local mission = g_currentMission
    if mission == nil then
        return {}, "none"
    end

    -- FS25 verwaltet alle geladenen Placeables kanonisch im PlaceableSystem.
    -- g_currentMission.placeables ist in aktuellen Spielversionen kein verlaesslicher
    -- Registry-Zugriff und kann leer/nil sein, obwohl Ställe/Produktionen existieren.
    if mission.placeableSystem ~= nil and mission.placeableSystem.placeables ~= nil then
        return mission.placeableSystem.placeables, "placeableSystem"
    end

    -- Nur als defensiver Legacy-Fallback behalten.
    if mission.placeables ~= nil then
        return mission.placeables, "legacyMissionPlaceables"
    end

    return {}, "none"
end

'''

marker = 'function AutoDriveFlurkarteLive:collectAnimals()'
if 'function AutoDriveFlurkarteLive:getMissionPlaceables()' not in lua:
    if marker not in lua:
        raise SystemExit('collectAnimals marker not found')
    lua = lua.replace(marker, helper + marker, 1)

old_head = '''function AutoDriveFlurkarteLive:collectAnimals()\n    local result = self:newArray()\n    local diagnostics = { seen = 0, exported = 0, failed = 0, skipped = 0 }\n    self.animalDiagnostics = diagnostics\n\n    if g_currentMission == nil or g_currentMission.placeables == nil then return result end\n    local myFarmId = self:getPlayerFarmId()'''
new_head = '''function AutoDriveFlurkarteLive:collectAnimals()\n    local result = self:newArray()\n    local placeables, placeableSource = self:getMissionPlaceables()\n    local diagnostics = {\n        source = placeableSource,\n        placeables = 0,\n        seen = 0,\n        exported = 0,\n        failed = 0,\n        skipped = 0,\n    }\n    self.animalDiagnostics = diagnostics\n\n    for _ in pairs(placeables) do\n        diagnostics.placeables = diagnostics.placeables + 1\n    end\n\n    if placeableSource == "none" then\n        self:logError("collectAnimals", "Keine Placeable-Registry verfuegbar")\n        return result\n    end\n\n    local myFarmId = self:getPlayerFarmId()'''
if old_head not in lua:
    raise SystemExit('collectAnimals head not found')
lua = lua.replace(old_head, new_head, 1)

# Restrict replacement to the animal collector section.
animal_start = lua.index('function AutoDriveFlurkarteLive:collectAnimals()')
animal_end = lua.index('function AutoDriveFlurkarteLive:processHusbandry', animal_start)
animal_block = lua[animal_start:animal_end]
old_loop = 'for _, placeable in pairs(g_currentMission.placeables) do'
if old_loop not in animal_block:
    raise SystemExit('collectAnimals placeable loop not found')
animal_block = animal_block.replace(old_loop, 'for _, placeable in pairs(placeables) do', 1)
lua = lua[:animal_start] + animal_block + lua[animal_end:]

old_prod = '''function AutoDriveFlurkarteLive:collectProductions()\n    local result = self:newArray()\n    if g_currentMission == nil or g_currentMission.placeables == nil then return result end\n\n    for _, placeable in pairs(g_currentMission.placeables) do'''
new_prod = '''function AutoDriveFlurkarteLive:collectProductions()\n    local result = self:newArray()\n    local placeables = self:getMissionPlaceables()\n\n    for _, placeable in pairs(placeables) do'''
if old_prod not in lua:
    raise SystemExit('collectProductions registry block not found')
lua = lua.replace(old_prod, new_prod, 1)

# Contract checks before writing.
required = [
    'VERSION         = "4.5.1"',
    'mission.placeableSystem.placeables',
    'source = placeableSource',
    'placeables = 0',
    'for _, placeable in pairs(placeables) do',
]
for token in required:
    if token not in lua:
        raise SystemExit(f'missing required token: {token}')

lua_path.write_text(lua, encoding='utf-8')
mod_desc_path.write_text(mod_desc, encoding='utf-8')
