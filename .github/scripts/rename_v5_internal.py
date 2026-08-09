from pathlib import Path

lua_path = Path('scripts/HofDashboard.lua')
mod_desc_path = Path('modDesc.xml')
readme_path = Path('README.md')
identity_path = Path('scripts/HofDashboardIdentity.lua')

lua = lua_path.read_text(encoding='utf-8')
mod_desc = mod_desc_path.read_text(encoding='utf-8')
readme = readme_path.read_text(encoding='utf-8')

old_class_count = lua.count('AutoDriveFlurkarteLive')
if old_class_count < 10:
    raise SystemExit(f'Unexpected AutoDriveFlurkarteLive occurrence count: {old_class_count}')

# Vollstaendiger technischer Klassen-Rename.
lua = lua.replace('AutoDriveFlurkarteLive', 'HofDashboardLive')

# Externe Mod-Identitaet direkt im Kern verankern; Bridge danach nicht mehr noetig.
lua = lua.replace('FS25_AutoDriveFlurkarte', 'FS25_HofDashboard')
lua = lua.replace('modSettings/AutoDriveFlurkarte/liveData.json', 'modSettings/LS25HofDashboard/liveData.json')
lua = lua.replace('HofDashboardLive.VERSION         = "4.5.0"', 'HofDashboardLive.VERSION         = "5.0.0"')
lua = lua.replace('HofDashboardLive.SETTINGS_DIR    = "AutoDriveFlurkarte"', 'HofDashboardLive.SETTINGS_DIR    = "LS25HofDashboard"')
lua = lua.replace('FS25_HofDashboard – Live Data Export v4.5', 'LS25 Hof-Dashboard – Live Connector v5.0')

# Falls die exakte Header-Zeile durch Encoding/Bindestrich abweicht, zumindest den alten Titel entfernen.
lua = lua.replace('FS25_HofDashboard - Live Data Export v4.5', 'LS25 Hof-Dashboard - Live Connector v5.0')

# Die Identitaets-Bridge wird nicht mehr geladen.
identity_source = '        <sourceFile filename="scripts/HofDashboardIdentity.lua"/>\n'
if identity_source not in mod_desc:
    raise SystemExit('Identity source entry missing from modDesc.xml')
mod_desc = mod_desc.replace(identity_source, '')

old_structure = '''LS25_HofDashboardMod/\n├─ modDesc.xml\n├─ scripts/\n│  ├─ HofDashboard.lua\n│  ├─ HofDashboardIdentity.lua\n│  └─ PlaceableRegistryAdapter.lua\n└─ README.md'''
new_structure = '''LS25_HofDashboardMod/\n├─ modDesc.xml\n├─ scripts/\n│  ├─ HofDashboard.lua\n│  └─ PlaceableRegistryAdapter.lua\n└─ README.md'''
if old_structure not in readme:
    raise SystemExit('README project structure block not found')
readme = readme.replace(old_structure, new_structure)

old_hof_text = '''### `HofDashboard.lua`\n\nEnthält die Collector, JSON-Erzeugung und den zyklischen Export. Während der v5-Migration enthält die Datei intern noch den historischen Klassennamen; dieser wird in einem separaten Cleanup-Schritt vollständig auf `HofDashboardLive` umgestellt.\n\n### `HofDashboardIdentity.lua`\n\nStellt während der Migration bereits die neue externe Identität bereit:\n\n- `FS25_HofDashboard`\n- Version `5.0.0`\n- `LS25HofDashboard` als Settings-Verzeichnis\n'''
new_hof_text = '''### `HofDashboard.lua`\n\nEnthält die zentrale Klasse `HofDashboardLive`, alle Collector, die JSON-Erzeugung und den zyklischen 15-Sekunden-Export.\n'''
if old_hof_text not in readme:
    raise SystemExit('README migration section not found')
readme = readme.replace(old_hof_text, new_hof_text)

# Vertragspruefungen: alte Identitaet darf im aktiven Mod-Code nicht mehr existieren.
for forbidden in [
    'AutoDriveFlurkarteLive',
    'FS25_AutoDriveFlurkarte',
    'modSettings/AutoDriveFlurkarte/liveData.json',
    'SETTINGS_DIR    = "AutoDriveFlurkarte"',
]:
    if forbidden in lua:
        raise SystemExit(f'Forbidden legacy token remains in HofDashboard.lua: {forbidden}')

required = [
    'HofDashboardLive                 = {}',
    'HofDashboardLive.MOD_NAME        = MODNAME',
    'HofDashboardLive.VERSION         = "5.0.0"',
    'HofDashboardLive.SETTINGS_DIR    = "LS25HofDashboard"',
    'addModEventListener(HofDashboardLive)',
]
for token in required:
    if token not in lua:
        raise SystemExit(f'Missing required v5 token: {token}')

lua_path.write_text(lua, encoding='utf-8')
mod_desc_path.write_text(mod_desc, encoding='utf-8')
readme_path.write_text(readme, encoding='utf-8')

if identity_path.exists():
    identity_path.unlink()
