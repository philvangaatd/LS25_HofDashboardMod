HofDashboardRelease = {
    MOD_VERSION = "5.0.1",
    PROTOCOL_VERSION = 1,
    MIN_DASHBOARD_VERSION = "5.0.1",
}

function addModEventListener(_) end

dofile("scripts/HofDashboard.lua")

local tomato = {
    id = "tomato",
    name = "Tomaten",
    status = 2,
    cyclesPerHour = 44,
    inputs = {{ type = 1, amount = 1 }},
    outputs = {{ type = 2, amount = 1 }},
}
local strawberry = {
    id = "strawberry",
    name = "Erdbeeren",
    status = 0,
    cyclesPerHour = 22,
    inputs = {},
    outputs = {},
}

g_currentMission = {
    getFarmId = function() return 1 end,
}
g_fillTypeManager = {
    getFillTypeByIndex = function(_, index)
        local fillTypes = {
            [1] = { name = "WATER", title = "Wasser" },
            [2] = { name = "TOMATO", title = "Tomaten" },
            [3] = { name = "STRAWBERRY", title = "Erdbeeren" },
        }
        return fillTypes[index] or { name = tostring(index), title = tostring(index) }
    end,
}

local placeable = {
    ownerFarmId = 1,
    getName = function() return "Mittleres Foliengewächshaus" end,
    spec_productionPoint = {
        productionPoint = {
            productions = {tomato, strawberry},
            activeProductions = {tomato},
            storage = {
                fillLevels = {
                    [1] = 6800,
                    [2] = 1250,
                    [3] = 400,
                },
                capacities = {
                    [1] = 10000,
                    [2] = 5000,
                    [3] = 5000,
                },
            },
        },
    },
}

local result = HofDashboardLive:processProduction(placeable)
assert(result ~= nil, "Produktionsanlage wurde nicht exportiert")
assert(#result.productions == 1, "Es duerfen nur aktive Produktionsketten exportiert werden")

local byId = {}
for _, production in ipairs(result.productions) do
    byId[production.id] = production
end

assert(byId.tomato ~= nil and byId.tomato.enabled == true, "Aktive Tomatenproduktion wurde nicht erkannt")
assert(byId.strawberry == nil, "Inaktive Erdbeerproduktion wurde exportiert")
assert(byId.tomato.status == 2, "Laufstatus wurde nicht exportiert")
assert(#byId.tomato.inputs == 1 and byId.tomato.inputs[1].fillType == "WATER", "Produktionsinput fehlt")
assert(#byId.tomato.outputs == 1 and byId.tomato.outputs[1].fillType == "TOMATO", "Produktionsoutput fehlt")

local storagesByFillType = {}
for _, storage in ipairs(result.storages) do
    storagesByFillType[storage.fillType] = storage
end

assert(storagesByFillType.WATER ~= nil, "Wasserbestand fehlt")
assert(storagesByFillType.WATER.role == "input", "Wasser wurde nicht als Betriebsstoff erkannt")
assert(storagesByFillType.WATER.level == 6800 and storagesByFillType.WATER.capacity == 10000, "Wasserbestand ist falsch")
assert(storagesByFillType.TOMATO ~= nil, "Produzierte Tomaten fehlen")
assert(storagesByFillType.TOMATO.role == "output", "Tomaten wurden nicht als Produkt erkannt")
assert(storagesByFillType.TOMATO.level == 1250, "Produzierte Tomatenmenge ist falsch")
assert(storagesByFillType.STRAWBERRY == nil, "Lager einer inaktiven Produktion wurde exportiert")

local json = HofDashboardLive:jsonEncode(result)
assert(json:find('"enabled":true', 1, true) ~= nil, "Aktivstatus fehlt im JSON")
assert(json:find('"id":"tomato"', 1, true) ~= nil, "Produktions-ID fehlt im JSON")
assert(json:find('"fillType":"WATER"', 1, true) ~= nil, "Wasser fehlt im JSON")
assert(json:find('"fillType":"TOMATO"', 1, true) ~= nil, "Produktbestand fehlt im JSON")

print("production_export_test: ok")
