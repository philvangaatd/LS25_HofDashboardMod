# LS25 Hof-Dashboard – Live Connector

Live-Connector für **Farming Simulator 25**.

Der Mod liest aktuelle Zustände direkt aus der FS25-Lua-API und stellt sie dem separaten **LS25 Hof-Dashboard** als lokale JSON-Datei bereit.

Aktuelle Mod-Version: **5.0.1**

## Architektur

```text
Farming Simulator 25
        │
        ▼
FS25_HofDashboard
        │
        ▼
modSettings/LS25HofDashboard/liveData.json
        │
        ▼
PHP API
        │
        ▼
LS25 Hof-Dashboard
```

Für Live-Daten gilt konsequent:

```text
Lua -> liveData.json -> PHP -> Frontend
```

Der Mod ist die autoritative Quelle für den aktuellen FS25-Zustand. PHP und Frontend sollen diese Spiellogik nicht noch einmal unabhängig nachbauen.

## Exportierte Bereiche

Der Connector liefert unter anderem:

- Hofdaten
- Felder und Feldzustände
- Fahrzeuge, Anhänger und Anbaugeräte
- Betriebsstunden, Verschleiß, Dreck und FillUnits
- Diesel, AdBlue und weitere Kraftstoffarten
- Tierhaltungen
- Tierbestand nach Rasse und Alter
- Futter, Wasser, Stroh und Weide
- tierbezogene Outputs wie Milch, Wolle, Eier, Mist und Gülle
- Bienen und Honig
- Produktionsanlagen
- Marktpreise je Verkaufsstation
- Verträge
- Diagnosedaten für einzelne Collector

Die Datei wird standardmäßig alle **15 Sekunden** aktualisiert.

## Ausgabe-Datei

Der neue v5-Pfad lautet:

```text
<My Games>/FarmingSimulator2025/modSettings/LS25HofDashboard/liveData.json
```

Unter einer normalen Windows-Installation typischerweise:

```text
%USERPROFILE%\Documents\My Games\FarmingSimulator2025\modSettings\LS25HofDashboard\liveData.json
```

## Installation

Repository laden:

```powershell
git clone https://github.com/philvangaatd/LS25_HofDashboardMod.git
```

oder vorhandenen Checkout aktualisieren:

```powershell
git pull
```

Der Mod muss anschließend als gültiger FS25-Mod bereitgestellt werden. Das Endprodukt soll unter folgendem Namen im Mods-Ordner liegen:

```text
FS25_HofDashboard.zip
```

Die ZIP muss `modDesc.xml` direkt im Wurzelverzeichnis enthalten.

Beim Laden eines Spielstands den Mod **LS25 Hof-Dashboard – Live Connector** aktivieren und nach dem vollständigen Laden ungefähr 15 Sekunden warten.

## Map-Kompatibilität

Der Connector ist **map-agnostisch** aufgebaut.

Grundsätzlich unterstützt werden:

- Basegame-Maps
- DLC-Maps
- Mod-Maps
- zusätzliche Fruchtarten und FillTypes
- zusätzliche Verkaufsstationen
- zusätzliche Produktionen
- zusätzliche Tierhaltungen

Voraussetzung ist, dass die jeweiligen Inhalte über die normalen GIANTS-FS25-Systeme registriert werden.

Eine Garantie für jede beliebige Mod-Map ist technisch nicht möglich. Eigene Systeme außerhalb der üblichen GIANTS-Registries können zusätzliche Adapter benötigen.

## Felder

Felder werden über die registrierten Field-Objekte und mehrere aktuelle Messpunkte innerhalb des tatsächlichen Feldpolygons analysiert.

Dadurch können unter anderem erkannt werden:

- erntereif
- im Wachstum
- abgeerntet
- gepflügt / gegrubbert
- verdorrt
- brach
- teilweise bearbeitete Mischfelder

Zusätzlich werden Werte wie Fruchtart, GrowthState, GroundType, Unkraut, Kalk, Spray-Level, Pflugstatus, Walzenstatus und Steine exportiert.

## Fuhrpark

Fahrzeuge werden direkt aus dem laufenden `VehicleSystem` gelesen.

Je Fahrzeug, Anhänger oder Anbaugerät können enthalten sein:

- Kategorie
- Marke und Modell
- Anzeigename
- Eigentümer-Farm
- Betriebsstunden
- konfigurierter Shoppreis
- Verschleiß
- Dreck
- Arbeitsstatus
- FillUnits
- Fülltyp
- Füllstand
- Kapazität
- Diesel
- AdBlue
- weitere Kraftstoffe

`vehicleDiagnostics` zeigt zusätzlich, wie viele Objekte gesehen, exportiert, übersprungen oder fehlerhaft verarbeitet wurden.

## Markt

Der Markt verwendet die aktuell registrierten Verkaufsstationen und deren effektiven Livepreis.

Pro Ware enthält der Export unter anderem:

- beste Verkaufsstation
- besten Preis
- niedrigsten Preis
- Preisspanne
- Anzahl Verkaufsstationen
- vollständige Stationsliste mit Preis pro 1.000 Liter

Damit arbeitet das Dashboard mit tatsächlich erzielbaren Verkaufspreisen statt mit einem theoretischen Saison-Referenzpreis.

## Tiere und Tierhaltungen

Tierhaltungen werden über das FS25-Placeable-/Husbandry-System ausgewertet.

Vorgesehen sind unter anderem:

- Stallname und Tierart
- Anzahl und Kapazität
- Bestand nach Rasse und Alter
- Gesundheit und Reproduktion
- Futter und Futtergruppen
- Wasser
- Stroh
- Weide
- Milch und weitere Flüssigprodukte
- Wolle, Eier und andere Palettenprodukte
- Mist und Gülle

`animalDiagnostics` dient der Diagnose, falls ein Stall oder eine Mod-Husbandry nicht über die erwarteten GIANTS-Schnittstellen gefunden wird.

## Bienen

Der Connector kann unter anderem liefern:

- Anzahl eigener Bienenstöcke
- aktive Bienenstöcke
- Honigproduktion pro Stunde
- wartenden Honig
- fertige Honigpaletten
- Honigmenge auf Paletten
- Palettenlimit

## Produktionen

Produktionsanlagen werden aus den geladenen Placeables und ProductionPoints gelesen.

Ziel ist auch hier eine map- und mod-unabhängige Erkennung, solange die jeweilige Produktion die normalen FS25-Production-Schnittstellen verwendet.

## Verträge

Der Connector liest die aktuell vom Spiel bereitgestellten Missions-/Vertragsdaten aus. Je Vertrag können unter anderem Feld, Typ, Fortschritt, Aktivstatus und Belohnung verfügbar sein.

## AutoDrive

Der Live Connector selbst benötigt **kein AutoDrive**.

AutoDrive ist nur ein Funktionsbereich des separaten Hof-Dashboards, insbesondere für:

- Marker
- Wegpunkte
- Routen
- Karten-/Routen-Editor

Deshalb trägt der Mod seit v5 keinen AutoDrive-Namen mehr.

## Sicherheit

Der Mod ist als **Read-only Live Connector** konzipiert.

Er verändert keine Felder, Fahrzeuge, Tierbestände, Produktionen, Preise oder Verträge und schreibt keine Savegame-XMLs um.

Er schreibt ausschließlich seine eigene lokale Datei:

```text
modSettings/LS25HofDashboard/liveData.json
```

Es werden keine Daten über das Netzwerk übertragen.

## Projektstruktur

```text
LS25_HofDashboardMod/
├─ modDesc.xml
├─ scripts/
│  ├─ Version.lua
│  ├─ HofDashboard.lua
│  └─ PlaceableRegistryAdapter.lua
└─ README.md
```

### `Version.lua`

Enthält die zentrale Mod-Version, die Datenprotokoll-Version und die mindestens
benötigte Dashboard-Version. `modDesc.xml` behält zusätzlich die von GIANTS
verlangte vierteilige Versionsangabe.

### `HofDashboard.lua`

Enthält die zentrale Klasse `HofDashboardLive`, alle Collector, die JSON-Erzeugung und den zyklischen 15-Sekunden-Export.

### `PlaceableRegistryAdapter.lua`

Stellt Tier- und Produktions-Collector die kanonische FS25-Placeable-Registry zur Verfügung.

## JSON-Grundstruktur

```json
{
  "version": "5.0.1",
  "protocolVersion": 1,
  "minimumDashboardVersion": "5.0.1",
  "modName": "FS25_HofDashboard",
  "timestamp": "2026-08-09T03:00:00",
  "farm": {},
  "fields": [],
  "vehicles": [],
  "vehicleDiagnostics": {},
  "animals": [],
  "animalDiagnostics": {},
  "beehives": {},
  "productions": [],
  "market": [],
  "contracts": []
}
```

## Fehlerdiagnose

Im `log.txt` sollte nach dem Laden künftig ein Eintrag mit dem neuen Modnamen erscheinen:

```text
[FS25_HofDashboard] v5.0.1 aktiv
```

Wenn `liveData.json` fehlt:

- prüfen, ob `FS25_HofDashboard.zip` korrekt aufgebaut ist
- prüfen, ob der Mod für den Spielstand aktiviert wurde
- mindestens 15 Sekunden nach vollständigem Laden warten
- `log.txt` auf `[FS25_HofDashboard]`-Fehler prüfen
- `vehicleDiagnostics` bzw. `animalDiagnostics` kontrollieren

## Zugehöriges Dashboard

Das Browser-Dashboard liegt separat unter:

```text
https://github.com/philvangaatd/LS25_HofDashboard
```
