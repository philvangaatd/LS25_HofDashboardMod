--[[
    LS25 Hof-Dashboard – Live Connector v5.2.0
    =================================================
    Schreibt alle 15 Sekunden eine JSON-Datei nach:
      <UserDocuments>/My Games/FarmingSimulator2025/modSettings/LS25HofDashboard/liveData.json

    Datenfluss: FS25 Lua API -> liveData.json -> PHP API -> Frontend.
    Der Lua-Mod ist die autoritative Quelle für alle Live-Zustände.
    API-Referenz: https://gdn.giants-software.com/documentation_scripting_fs25.php
]]

local MODNAME = g_currentModName or "FS25_HofDashboard"
local JSON_ARRAY_MT = { __jsonArray = true }
local RELEASE = HofDashboardRelease

if RELEASE == nil then
    error("[FS25_HofDashboard] scripts/Version.lua wurde nicht vor dem Kernmodul geladen")
end

HofDashboardLive                 = {}
HofDashboardLive.MOD_NAME        = MODNAME
HofDashboardLive.VERSION         = RELEASE.MOD_VERSION
HofDashboardLive.PROTOCOL_VERSION = RELEASE.PROTOCOL_VERSION
HofDashboardLive.MIN_DASHBOARD_VERSION = RELEASE.MIN_DASHBOARD_VERSION
HofDashboardLive.SETTINGS_DIR    = "LS25HofDashboard"
HofDashboardLive.OUTPUT_FILE     = "liveData.json"
HofDashboardLive.UPDATE_INTERVAL = 15000
HofDashboardLive.FIELD_SAMPLE_TARGET = 81
HofDashboardLive.timer           = 0
HofDashboardLive.isReady         = false
HofDashboardLive.FUEL_TYPES      = nil
HofDashboardLive.FUEL_BY_INDEX   = nil
HofDashboardLive.GROUND_TYPE_NAMES = {}

-- ======================================================================
-- HILFSFUNKTIONEN
-- ======================================================================

function HofDashboardLive:newArray()
    return setmetatable({}, JSON_ARRAY_MT)
end

function HofDashboardLive:round(value, digits)
    local factor = 10 ^ (digits or 0)
    return math.floor((value or 0) * factor + 0.5) / factor
end

function HofDashboardLive:logError(scope, err)
    print(string.format("[%s] %s: %s", self.MOD_NAME, tostring(scope), tostring(err)))
end

function HofDashboardLive:protected(scope, fn)
    local ok, result = pcall(fn)
    if not ok then
        self:logError(scope, result)
        return false, nil
    end
    return true, result
end

function HofDashboardLive:safeGet(fn, fallback)
    local ok, val = pcall(fn)
    if ok and val ~= nil then return val end
    return fallback
end

function HofDashboardLive:getPlayerFarmId()
    if g_currentMission == nil then return 0 end

    if g_currentMission.getFarmId ~= nil then
        local ok, farmId = pcall(function() return g_currentMission:getFarmId() end)
        if ok and type(farmId) == "number" and farmId > 0 then
            return farmId
        end
    end

    if g_currentMission.player ~= nil then
        return g_currentMission.player.farmId or 0
    end

    return 0
end

function HofDashboardLive:loadMap(filename)
    self.isReady = true
    self.timer = self.UPDATE_INTERVAL

    self.GROUND_TYPE_NAMES = {}
    if FieldGroundType ~= nil then
        local knownGroundTypes = {
            "NONE", "PLOWED", "CULTIVATED", "SEEDBED", "ROLLED_SEEDBED",
            "ROLLER_LINES", "STUBBLE_TILLAGE", "RIDGE", "GRASS_CUT",
            "SOWN", "DIRECT_SOWN", "RIDGE_SOWN", "PLANTED", "GRASS",
            "HARVEST_READY", "HARVEST_READY_OTHER",
        }
        for _, name in ipairs(knownGroundTypes) do
            local value = FieldGroundType[name]
            if type(value) == "number" then self.GROUND_TYPE_NAMES[value] = name end
        end
        -- Unbekannte/neue GIANTS-Typen zusätzlich aufnehmen.
        for name, value in pairs(FieldGroundType) do
            if type(name) == "string" and type(value) == "number" and self.GROUND_TYPE_NAMES[value] == nil then
                self.GROUND_TYPE_NAMES[value] = name
            end
        end
    end

    self.FUEL_TYPES = self:newArray()
    self.FUEL_BY_INDEX = {}

    local function addFuel(fillTypeIndex, name, label)
        if fillTypeIndex ~= nil then
            local entry = { index = fillTypeIndex, name = name, label = label }
            table.insert(self.FUEL_TYPES, entry)
            self.FUEL_BY_INDEX[fillTypeIndex] = entry
        end
    end

    addFuel(FillType.DIESEL,         "DIESEL",         "Diesel")
    addFuel(FillType.DEF,            "DEF",            "AdBlue")
    addFuel(FillType.ELECTRICCHARGE, "ELECTRICCHARGE", "Strom")
    addFuel(FillType.METHANE,        "METHANE",        "Methan")
    addFuel(FillType.GASOLINE,       "GASOLINE",       "Benzin")

    print(string.format("[%s] v%s aktiv – exportiert alle %ds",
        self.MOD_NAME, self.VERSION, self.UPDATE_INTERVAL / 1000))
end

function HofDashboardLive:deleteMap()
    self.isReady = false
end

function HofDashboardLive:update(dt)
    if not self.isReady or g_currentMission == nil then return end

    self.timer = self.timer + dt
    if self.timer >= self.UPDATE_INTERVAL then
        self.timer = 0
        local ok, err = pcall(function() self:exportAllData() end)
        if not ok then
            self:logError("Export-Fehler", err)
        end
    end
end

-- ======================================================================
-- EXPORT
-- ======================================================================

function HofDashboardLive:exportAllData()
    local vehicles = self:collectVehicles()
    local data = {
        version       = self.VERSION,
        protocolVersion = self.PROTOCOL_VERSION,
        minimumDashboardVersion = self.MIN_DASHBOARD_VERSION,
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
        animalDiagnostics = self.animalDiagnostics or { seen = 0, exported = 0, failed = 0, skipped = 0 },
        beehives       = self:collectBeehives(),
        productions    = self:collectProductions(),
        storages       = self:collectStorages(),
        contracts      = self:collectContracts(),
        market         = self:collectMarket(),
    }

    self:writeFile(self:jsonEncode(data))
end

-- ======================================================================
-- HOF-INFORMATIONEN
-- ======================================================================

function HofDashboardLive:collectFarm()
    local result = { name = "", farmId = 0, money = 0, loan = 0 }
    local playerFarmId = self:getPlayerFarmId()
    result.farmId = playerFarmId

    local ok, err = pcall(function()
        local farm = nil

        if playerFarmId > 0 and g_farmManager ~= nil and g_farmManager.getFarmById ~= nil then
            farm = g_farmManager:getFarmById(playerFarmId)
        end

        if farm == nil and g_farmManager ~= nil and g_farmManager.getLocalPlayerFarm ~= nil then
            farm = g_farmManager:getLocalPlayerFarm()
        end

        if farm == nil then return end

        result.farmId = playerFarmId > 0 and playerFarmId or (farm.farmId or 0)
        result.name = farm.name or ""

        if type(farm.money) == "number" then
            result.money = math.floor(farm.money)
        elseif type(farm.balance) == "number" then
            result.money = math.floor(farm.balance)
        elseif farm.getMoney ~= nil then
            result.money = math.floor(farm:getMoney() or 0)
        end

        if type(farm.loan) == "number" then
            result.loan = math.floor(farm.loan)
        elseif farm.getLoan ~= nil then
            result.loan = math.floor(farm:getLoan() or 0)
        end
    end)

    if not ok then self:logError("collectFarm", err) end
    return result
end

-- ======================================================================
function HofDashboardLive:writeFile(content)
    local base = getUserProfileAppPath()
    local modSettingsDir = base .. "modSettings/"
    local modDir = modSettingsDir .. self.SETTINGS_DIR .. "/"
    local targetPath = modDir .. self.OUTPUT_FILE

    createFolder(modSettingsDir)
    createFolder(modDir)

    local file, openError = io.open(targetPath, "w")
    if file == nil then
        self:logError("writeFile", openError or "Datei konnte nicht geöffnet werden")
        return
    end

    local ok, writeError = pcall(function()
        file:write(content)
    end)
    pcall(function() file:close() end)

    if not ok then
        self:logError("writeFile", writeError or "Schreiben fehlgeschlagen")
    end
end

-- ======================================================================
-- JSON ENCODER
-- ======================================================================

function HofDashboardLive:jsonEncode(value)
    local valueType = type(value)

    if valueType == "nil" then
        return "null"
    elseif valueType == "boolean" then
        return value and "true" or "false"
    elseif valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        if math.floor(value) == value and math.abs(value) < 2^53 then
            return string.format("%d", value)
        end
        return string.format("%.4f", value)
    elseif valueType == "string" then
        value = value:gsub('\\', '\\\\')
            :gsub('"', '\\"')
            :gsub('\n', '\\n')
            :gsub('\r', '\\r')
            :gsub('\t', '\\t')
        return '"' .. value .. '"'
    elseif valueType == "table" then
        local meta = getmetatable(value)
        local forceArray = meta ~= nil and meta.__jsonArray == true
        local length = #value
        local keyCount = 0
        for _ in pairs(value) do keyCount = keyCount + 1 end

        local parts = {}
        if forceArray or (length > 0 and keyCount == length) then
            for i = 1, length do
                parts[i] = self:jsonEncode(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end

        for key, item in pairs(value) do
            if type(key) == "string" then
                table.insert(parts, self:jsonEncode(key) .. ":" .. self:jsonEncode(item))
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end

    return self:jsonEncode(tostring(value))
end

-- ======================================================================
-- REGISTRIEREN
-- ======================================================================

addModEventListener(HofDashboardLive)
