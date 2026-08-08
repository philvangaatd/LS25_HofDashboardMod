from pathlib import Path

lua_path = Path('scripts/AutoDriveFlurkarte.lua')
mod_desc_path = Path('modDesc.xml')

lua = lua_path.read_text(encoding='utf-8')
mod_desc = mod_desc_path.read_text(encoding='utf-8')

lua = lua.replace('FS25_AutoDriveFlurkarte – Live Data Export v4.3', 'FS25_AutoDriveFlurkarte – Live Data Export v4.3.1', 1)
lua = lua.replace('AutoDriveFlurkarteLive.VERSION         = "4.3.0"', 'AutoDriveFlurkarteLive.VERSION         = "4.3.1"', 1)

old = '''function AutoDriveFlurkarteLive:getFillTypeData(fillTypeIndex)\n    if fillTypeIndex == nil or FillType == nil or fillTypeIndex == FillType.UNKNOWN then return nil end\n    local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil\n    if fillType == nil then return nil end\n    local name = string.upper(fillType.name or "UNKNOWN")\n    return {\n        index = fillTypeIndex,\n        name = name,\n        title = fillType.title or fillType.name or name,\n    }\nend\n'''

new = '''function AutoDriveFlurkarteLive:getFillTypeData(fillTypeIndex)\n    if fillTypeIndex == nil or FillType == nil or fillTypeIndex == FillType.UNKNOWN then return nil end\n    local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil\n    if fillType == nil then return nil end\n    local name = string.upper(fillType.name or "UNKNOWN")\n    local title = fillType.title or fillType.name or name\n\n    -- GIANTS lokalisiert DEF auf Deutsch technisch als \"Synthetische Harnstofflösung\".\n    -- Für die Fuhrpark-Anzeige verwenden wir bewusst die im Fahrzeugkontext übliche\n    -- und deutlich kürzere Bezeichnung \"AdBlue\".\n    if name == "DEF" then title = "AdBlue" end\n\n    return {\n        index = fillTypeIndex,\n        name = name,\n        title = title,\n    }\nend\n'''

if old not in lua:
    raise SystemExit('getFillTypeData block not found')
lua = lua.replace(old, new, 1)

if '<version>4.3.0.0</version>' not in mod_desc:
    raise SystemExit('modDesc version not found')
mod_desc = mod_desc.replace('<version>4.3.0.0</version>', '<version>4.3.1.0</version>', 1)

lua_path.write_text(lua, encoding='utf-8')
mod_desc_path.write_text(mod_desc, encoding='utf-8')
