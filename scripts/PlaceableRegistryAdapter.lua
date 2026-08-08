--[[
    FS25 Placeable Registry Adapter
    ===============================
    FS25 verwaltet geladene Placeables in g_currentMission.placeableSystem.placeables.
    Die bestehenden Collector aus AutoDriveFlurkarte.lua greifen aus historischen
    Gruenden auf g_currentMission.placeables zu. Dieser Adapter stellt waehrend der
    beiden betroffenen Collector-Aufrufe kontrolliert die kanonische Registry bereit,
    ohne deren Tier-/Produktionslogik zu duplizieren.
]]

local live = AutoDriveFlurkarteLive

if live == nil then
    print("[FS25_AutoDriveFlurkarte] PlaceableRegistryAdapter: Kernmodul nicht geladen")
    return
end

local originalCollectAnimals = live.collectAnimals
local originalCollectProductions = live.collectProductions

local function countEntries(values)
    local count = 0
    for _ in pairs(values or {}) do
        count = count + 1
    end
    return count
end

local function callWithCanonicalPlaceables(self, collector)
    local mission = g_currentMission
    if mission == nil then
        return collector(self), "none", 0
    end

    local placeableSystem = mission.placeableSystem
    local canonical = placeableSystem ~= nil and placeableSystem.placeables or nil

    if canonical == nil then
        local legacy = mission.placeables or {}
        return collector(self), "legacyMissionPlaceables", countEntries(legacy)
    end

    -- Der alte Zugriff wird nur fuer die Dauer des Collector-Aufrufs gespiegelt.
    -- Danach wird der urspruengliche Missionswert auch bei einem Fehler garantiert
    -- wiederhergestellt.
    local previous = mission.placeables
    mission.placeables = canonical

    local ok, result = pcall(collector, self)

    mission.placeables = previous

    if not ok then
        error(result, 0)
    end

    return result, "placeableSystem", countEntries(canonical)
end

if originalCollectAnimals ~= nil then
    function live:collectAnimals()
        local result, source, placeableCount = callWithCanonicalPlaceables(self, originalCollectAnimals)

        self.animalDiagnostics = self.animalDiagnostics or {}
        self.animalDiagnostics.source = source
        self.animalDiagnostics.placeables = placeableCount

        return result
    end
end

if originalCollectProductions ~= nil then
    function live:collectProductions()
        local result = callWithCanonicalPlaceables(self, originalCollectProductions)
        return result
    end
end

-- ModDesc und JSON-Vertrag bekommen dieselbe Patch-Version.
live.VERSION = "4.5.1"
