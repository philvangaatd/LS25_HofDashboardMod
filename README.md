# LS25 Hof-Dashboard Mod

Live-Connector-Mod für Landwirtschafts-Simulator 25. Die Mod schreibt aktuelle Spieldaten für das LS25 Hof-Dashboard nach `modSettings/LS25HofDashboard/liveData.json`.

## Aktuelle Version

- Mod: `5.3.0`
- kompatibles Dashboard: ab `5.2.0`
- Protokollversion: `1`
- Live-Export: alle `2 Sekunden`

## Installation

Im normalen Betrieb wird die Mod direkt über das Windows-Dashboard installiert und aktualisiert. Eine separate manuelle Installation ist deshalb normalerweise nicht mehr nötig.

Für eine manuelle Installation:

1. Den aktuellen Release `FS25_HofDashboard.zip` herunterladen.
2. Die ZIP-Datei unverändert in den LS25-Modordner legen.
3. Landwirtschafts-Simulator 25 starten.
4. Die Mod im Spielstand aktivieren.

## Near-Live-Daten

Seit v5.3.0 wird der vollständige Live-Datensatz alle zwei Sekunden exportiert. Das Dashboard kann die Datei häufiger abfragen und neue Exporte dadurch praktisch unmittelbar darstellen, ohne den kompletten Hofzustand auf jedem Spiel-Frame neu zu serialisieren.

## Exportierte Daten

- Hofdaten und Finanzen
- Felder
- Fahrzeuge und Geräte
- Tiere und Bienen
- aktive Produktionen
- Vorräte und kompatible Mod-Lager
- Verträge
- Marktpreise

## Releases

- Mod: https://github.com/philvangaatd/LS25_HofDashboardMod/releases
- Dashboard: https://github.com/philvangaatd/LS25_HofDashboard/releases
