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
        local names = {[1] = "WATER", [2] = "TOMATO"}
        return { name = names[index] or tostring(index) }
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
                fillLevels = {},
                capacities = {},
            },
        },
    },
}

local result = HofDashboardLive:processProduction(placeable)
assert(result ~= nil, "Produktionsanlage wurde nicht exportiert")
assert(#result.productions == 2, "Produktionsketten wurden nicht aus productionPoint.productions gelesen")

local byId = {}
for _, production in ipairs(result.productions) do
    byId[production.id] = production
end

assert(byId.tomato ~= nil and byId.tomato.enabled == true, "Aktive Tomatenproduktion wurde nicht erkannt")
assert(byId.strawberry ~= nil and byId.strawberry.enabled == false, "Inaktive Erdbeerproduktion wurde falsch erkannt")
assert(byId.tomato.status == 2, "Laufstatus wurde nicht exportiert")
assert(#byId.tomato.inputs == 1 and byId.tomato.inputs[1].fillType == "WATER", "Produktionsinput fehlt")
assert(#byId.tomato.outputs == 1 and byId.tomato.outputs[1].fillType == "TOMATO", "Produktionsoutput fehlt")

local json = HofDashboardLive:jsonEncode(result)
assert(json:find('"enabled":true', 1, true) ~= nil, "Aktivstatus fehlt im JSON")
assert(json:find('"id":"tomato"', 1, true) ~= nil, "Produktions-ID fehlt im JSON")

print("production_export_test: ok")
