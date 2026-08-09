# FS25 AutoDrive Flurkarte – Live Export Mod

Live-Daten-Export für **Farming Simulator 25**.

Der Mod liest den aktuellen Zustand des laufenden Spiels über die FS25-Lua-API und schreibt ihn regelmäßig als lokale JSON-Datei für das separate **LS25 Hof-Dashboard**.

Aktuelle Mod-Version: **4.5.1**

---

## Zweck

Der Mod ist die Live-Datenquelle für das Dashboard.

Die Architektur ist bewusst einfach gehalten:

```text
Farming Simulator 25
        │
        ▼
FS25_AutoDriveFlurkarte
        │
        ▼
liveData.json
        │
        ▼
PHP API
        │
        ▼
LS25 Hof-Dashboard
```

Der Mod entscheidet, was der aktuelle FS25-Zustand ist. PHP und Frontend sollen diese Spiellogik nicht noch einmal unabhängig nachbauen.

---

## Was wird exportiert?

Der Export enthält aktuell unter anderem:

- Hofdaten
- Felder
- Fahrzeuge
- Anhänger
- Anbaugeräte
- Tierhaltungen
- Bienen
- Produktionen
- Marktpreise
- Verträge
- Diagnosedaten einzelner Collector

Die Datei wird standardmäßig alle **15 Sekunden** aktualisiert.

---

## Ausgabe-Datei

Der Mod schreibt nach:

```text
<My Games>/FarmingSimulator2025/modSettings/AutoDriveFlurkarte/liveData.json
```

Unter einer normalen Windows-Installation ist das typischerweise:

```text
%USERPROFILE%\Documents\My Games\FarmingSimulator2025\modSettings\AutoDriveFlurkarte\liveData.json
```

Der tatsächliche `My Games`-Ordner kann durch OneDrive, Benutzerkonfiguration oder eine manuelle Verlagerung abweichen.

---

## Installation

### 1. Repository laden

```powershell
git clone https://github.com/philvangaatd/LS25_Dashboard_Mod.git
```

Oder einen vorhandenen Checkout aktualisieren:

```powershell
git pull
```

### 2. Mod für FS25 bereitstellen

Der Inhalt des Repositories muss als gültiger FS25-Mod im Mods-Ordner liegen bzw. als ZIP gepackt werden.

Beispiel:

```text
%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\FS25_AutoDriveFlurkarte.zip
```

Die ZIP muss `modDesc.xml` im Wurzelverzeichnis enthalten.

### 3. Im Spiel aktivieren

Beim Laden des gewünschten Spielstands:

- `FS25_AutoDriveFlurkarte` aktivieren
- Spielstand vollständig laden
- ungefähr 15 Sekunden warten

Danach sollte `liveData.json` erzeugt bzw. aktualisiert werden.

---

## Kein AutoDrive-Zwang

Trotz des historischen Namens **AutoDriveFlurkarte** benötigt der Live-Export für seine allgemeinen Daten **kein AutoDrive**.

Felder, Fahrzeuge, Markt, Tiere und andere Live-Bereiche werden direkt aus FS25 gelesen.

AutoDrive wird nur vom separaten Dashboard für Funktionen wie Marker und Routen-Editor benötigt.

---

## Felder

Die Felder werden map-unabhängig über die von FS25 registrierten Field-Objekte ausgewertet.

Der Mod untersucht das tatsächliche Feldpolygon und verteilt Messpunkte über die Fläche. Dadurch kann er auch Mischzustände erkennen.

Beispiele:

- vollständig erntereif
- im Wachstum
- abgeerntet
- gepflügt
- gegrubbert
- teilweise abgeerntet und teilweise bearbeitet
- verdorrt
- brach

Zusätzlich können unter anderem folgende Werte exportiert werden:

- Fruchtart
- GrowthState
- GroundType
- Unkraut
- Kalk
- Spray-Level
- Pflugstatus
- Walzenstatus
- Steine
- Stubble-Shred-Level
- Wasserzustand

Ein Feld kann `fieldStatus: "MIXED"` erhalten, wenn mehrere relevante Zustände auf derselben Fläche vorkommen.

Beispiel:

```json
{
  "id": 11,
  "fieldStatus": "MIXED",
  "fruitType": "WHEAT",
  "statusPercentages": {
    "ready": 0,
    "growing": 0,
    "harvested": 42.6,
    "tilled": 57.4,
    "withered": 0,
    "fallow": 0
  }
}
```

---

## Fahrzeuge

Der Fuhrpark wird aus den aktuell von FS25 registrierten Fahrzeugobjekten gelesen.

Unterstützt werden:

- Fahrzeuge
- Anhänger
- Anbaugeräte
- Marke
- Modell
- Anzeigename
- Eigentümer-Farm
- Betriebsstunden
- Shoppreis der aktuellen Konfiguration
- Verschleiß
- Dreck
- Arbeitsstatus
- FillUnits
- Füllstände
- Kapazitäten
- unterstützte FillTypes
- Diesel
- AdBlue
- weitere Kraftstoffarten
- Anhänger- und Geräteinhalte

Leere FillUnits können ebenfalls exportiert werden, sofern FS25 ihre unterstützten FillTypes bereitstellt.

### Diagnosedaten

Der Export enthält `vehicleDiagnostics`, beispielsweise:

```json
{
  "seen": 25,
  "exported": 13,
  "failed": 0,
  "skipped": 12
}
```

Damit lässt sich erkennen, ob Fahrzeuge nicht gefunden, bewusst übersprungen oder bei der Verarbeitung fehlgeschlagen sind.

---

## Marktpreise

Der Mod exportiert **echte effektive Verkaufspreise je Verkaufsstation**.

Er verwendet die aktuell im laufenden Spiel registrierten Selling-/Unloading-Stations und deren effektiven Preis für den jeweiligen FillType.

Pro Ware können enthalten sein:

- FillType
- Titel
- Kategorie
- bester Preis
- beste Station
- niedrigster Preis
- Preisspanne
- Anzahl Verkaufsstationen
- vollständige Stationsliste

Beispiel:

```json
{
  "fillType": "WHEAT",
  "title": "Weizen",
  "unit": "1000L",
  "bestStation": "Sarow AG",
  "bestPrice": 361,
  "worstPrice": 355,
  "priceSpread": 6,
  "stationCount": 2,
  "stations": [
    {
      "name": "Sarow AG",
      "pricePer1000L": 361
    },
    {
      "name": "Hohenmocker AG",
      "pricePer1000L": 355
    }
  ]
}
```

Nur FillTypes, die für die Preisübersicht vorgesehen sind und tatsächlich von einer sichtbaren Verkaufsstation angenommen werden, sollen im Markt landen.

---

## Tiere und Tierhaltungen

Der Tierexport ist für die normalen FS25-Husbandry-Systeme ausgelegt.

Aktuell werden Tierhaltungen über das **PlaceableSystem** entdeckt. Version 4.5.1 enthält dafür einen Registry-Adapter, weil moderne FS25-Spielstände ihre geladenen Placeables über `g_currentMission.placeableSystem.placeables` verwalten.

Pro Haltung sind unter anderem vorgesehen:

- Stallname
- Tierart
- Anzahl Tiere
- maximale Kapazität
- freie Plätze
- Rasse
- Alter
- Anzahl je Rasse und Altersgruppe
- Gesundheit
- Reproduktion
- Trächtigkeit / Elterntier, sofern verfügbar
- Produktivität
- Futter
- Futtergruppen
- Wasser
- Stroh
- Weide
- Mist
- Gülle
- Milch
- Palettenprodukte wie Wolle oder Eier

### Diagnosedaten

`animalDiagnostics` soll anzeigen, ob die Placeables überhaupt gefunden wurden.

Beispiel:

```json
{
  "source": "placeableSystem",
  "placeables": 120,
  "seen": 1,
  "exported": 1,
  "failed": 0,
  "skipped": 0
}
```

Gerade bei Mod-Ställen ist diese Diagnose wichtig, da manche Placeables eigene Spezialisierungen verwenden können.

---

## Bienen

Bienen werden über das FS25-Beehive-System separat ausgewertet.

Der Export kann unter anderem enthalten:

- Anzahl eigener Bienenstöcke
- aktive Bienenstöcke
- Honigproduktion pro Stunde
- wartenden Honig
- fertige Honigpaletten
- Honigmenge auf Paletten
- Palettenlimit
- Aktionsradius je Bienenstock

---

## Produktionen

Produktionsgebäude werden aus den geladenen Placeables ausgewertet.

Seit Version 4.5.1 verwendet auch dieser Collector dieselbe kanonische Placeable-Registry wie der Tierbereich.

Dadurch soll die Produktionslogik ebenfalls map- und mod-unabhängig bleiben, solange das jeweilige Gebäude die normalen FS25-Placeable-/Production-Systeme verwendet.

---

## Verträge

Der Mod liest die aktuell von FS25 bereitgestellten Missions-/Vertragsdaten aus.

Je Vertrag können unter anderem enthalten sein:

- Feld
- Typ
- Titel
- Fortschritt
- Aktivstatus
- Belohnung
- Deadline, sofern vorhanden

Welche Werte vollständig verfügbar sind, hängt vom jeweiligen Vertragstyp und der FS25-Laufzeitlogik ab.

---

## Map-Kompatibilität

Der Mod ist **map-agnostisch** konzipiert.

Es gibt keine feste Liste unterstützter Maps.

Grundsätzlich funktionieren:

- Basegame-Maps
- DLC-Maps
- Mod-Maps
- Maps mit zusätzlichen Fruchtarten
- Maps mit zusätzlichen FillTypes
- Maps mit eigenen Verkaufsstellen
- Maps mit eigenen Produktionen
- Maps mit eigenen Tierhaltungen

Voraussetzung ist, dass diese Inhalte über die normalen GIANTS-FS25-Systeme registriert werden.

### Warum das funktioniert

Der Mod verwendet zur Laufzeit unter anderem die von FS25 verwalteten:

- Field-Objekte
- FruitType-/FillType-Manager
- VehicleSystem
- PlaceableSystem
- Husbandry-Spezialisierungen
- Beehive-Systeme
- Storage-/Selling-Stations

Damit sind keine kartenspezifischen IDs notwendig.

### Grenzen

Eine Garantie für jede beliebige Mod-Map ist technisch nicht möglich.

Zusätzliche Anpassungen können nötig sein, wenn eine Map oder ein Mod:

- eigene Systeme außerhalb der üblichen GIANTS-Registries verwendet
- Standard-Spezialisierungen vollständig ersetzt
- ungewöhnliche oder fehlerhafte Feldpolygone liefert
- eigene Tier- oder Produktionslogik ohne normale Husbandry-/Production-Schnittstellen implementiert

Solche Fälle sollen über Diagnosedaten möglichst eindeutig erkennbar sein.

---

## Sicherheit

Der Mod ist als **Read-only Live-Exporter** konzipiert.

Er verändert keine:

- Felder
- Fahrzeuge
- Tierbestände
- Produktionen
- Marktpreise
- Verträge
- Spielstand-XMLs

Der Mod schreibt ausschließlich seine eigene lokale Datei:

```text
modSettings/AutoDriveFlurkarte/liveData.json
```

Es werden keine Daten über das Netzwerk übertragen.

---

## Projektstruktur

```text
LS25_Dashboard_Mod/
├─ modDesc.xml
├─ scripts/
│  ├─ AutoDriveFlurkarte.lua
│  └─ PlaceableRegistryAdapter.lua
└─ README.md
```

### `AutoDriveFlurkarte.lua`

Enthält die eigentlichen Collector, JSON-Erzeugung und den 15-Sekunden-Export.

### `PlaceableRegistryAdapter.lua`

Stellt Tier- und Produktions-Collector die aktuelle FS25-Placeable-Registry zur Verfügung.

---

## JSON-Grundstruktur

Die genaue Struktur entwickelt sich mit dem Projekt weiter. Aktuell enthält `liveData.json` typischerweise unter anderem:

```json
{
  "version": "4.5.1",
  "modName": "FS25_AutoDriveFlurkarte",
  "timestamp": "2026-08-09T02:00:00",
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

Das Dashboard sollte sich möglichst auf diesen Vertrag verlassen, statt dieselben Zustände nochmals selbst aus Savegame-Dateien zu rekonstruieren.

---

## Fehlerdiagnose

### Mod wird nicht geladen

In `log.txt` nach folgendem Eintrag suchen:

```text
[FS25_AutoDriveFlurkarte] v4.5.1 aktiv
```

Zusätzlich prüfen:

- Ist die ZIP korrekt aufgebaut?
- Liegt `modDesc.xml` direkt im ZIP-Wurzelverzeichnis?
- Ist der Mod für den Spielstand aktiviert?

### `liveData.json` wird nicht erzeugt

Prüfen:

- Spielstand vollständig geladen?
- mindestens 15 Sekunden gewartet?
- `log.txt` auf `[FS25_AutoDriveFlurkarte]`-Fehler prüfen
- Schreibrechte im `modSettings`-Ordner vorhanden?

### Fahrzeuge fehlen

`vehicleDiagnostics` prüfen.

### Tierhaltungen fehlen

`animalDiagnostics` prüfen.

Wichtig sind besonders:

- `source`
- `placeables`
- `seen`
- `exported`
- `failed`
- `skipped`

Wenn `placeables > 0`, aber `seen = 0`, wurde die Placeable-Registry gefunden, jedoch keine kompatible Husbandry erkannt.

Wenn `seen > 0`, aber `exported = 0`, liegt das Problem in einer späteren Filter- oder Verarbeitungsstufe.

---

## Zugehöriges Dashboard

Dieses Repository enthält nur den FS25-Live-Export-Mod.

Das Browser-Dashboard befindet sich separat unter:

```text
https://github.com/philvangaatd/LS25_Dashboard
```

---

## Entwicklungsprinzip

Für Live-Daten gilt im Projekt konsequent:

```text
Lua -> liveData.json -> PHP -> Frontend
```

Neue Live-Funktionen sollten deshalb bevorzugt im Mod sauber aus der FS25-Laufzeit ermittelt und anschließend nur noch durch PHP und Frontend transportiert bzw. dargestellt werden.
