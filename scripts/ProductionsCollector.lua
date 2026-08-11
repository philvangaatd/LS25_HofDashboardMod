-- Collector methods extracted from scripts/HofDashboard.lua.

function HofDashboardLive:collectProductions()
    local result = self:newArray()
    if g_currentMission == nil or g_currentMission.placeables == nil then return result end

    for _, placeable in pairs(g_currentMission.placeables) do
        local ok, data = self:protected(
            "processProduction " .. tostring(placeable.typeName or "?"),
            function() return self:processProduction(placeable) end
        )
        if ok and data ~= nil then table.insert(result, data) end
    end

    return result
end

function HofDashboardLive:processProduction(placeable)
    local spec = placeable.spec_productionPoint
    if spec == nil or spec.productionPoint == nil then return nil end

    local farmId = placeable.ownerFarmId or 0
    local playerFarmId = self:getPlayerFarmId()
    if farmId <= 0 or (playerFarmId > 0 and farmId ~= playerFarmId) then return nil end

    local productionPoint = spec.productionPoint
    local data = {
        name        = placeable:getName() or "",
        farmId      = farmId,
        productions = self:newArray(),
        storages    = self:newArray(),
    }

    local activeProductionObjects = {}
    local activeProductionIds = {}
    for _, activeProduction in pairs(productionPoint.activeProductions or {}) do
        activeProductionObjects[activeProduction] = true
        if activeProduction.id ~= nil then
            activeProductionIds[tostring(activeProduction.id)] = true
        end
    end

    local activeInputFillTypes = {}
    local activeOutputFillTypes = {}

    for _, production in pairs(productionPoint.productions or {}) do
        if type(production) == "table" then
            local productionId = tostring(production.id or "")
            local enabled = activeProductionObjects[production] == true
                or (productionId ~= "" and activeProductionIds[productionId] == true)

            if enabled then
                local productionData = {
                    id            = productionId,
                    name          = production.name or "",
                    enabled       = true,
                    status        = production.status or 0,
                    cyclesPerHour = production.cyclesPerHour or 0,
                    inputs        = self:newArray(),
                    outputs       = self:newArray(),
                }

                if production.inputs ~= nil then
                    for _, input in pairs(production.inputs) do
                        local fillTypeIndex = input.type
                        local fillType = fillTypeIndex ~= nil
                            and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
                        if fillTypeIndex ~= nil then activeInputFillTypes[fillTypeIndex] = true end
                        table.insert(productionData.inputs, {
                            fillType = fillType and fillType.name or tostring(fillTypeIndex),
                            amount   = input.amount or 0,
                        })
                    end
                end

                if production.outputs ~= nil then
                    for _, output in pairs(production.outputs) do
                        local fillTypeIndex = output.type
                        local fillType = fillTypeIndex ~= nil
                            and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
                        if fillTypeIndex ~= nil then activeOutputFillTypes[fillTypeIndex] = true end
                        table.insert(productionData.outputs, {
                            fillType = fillType and fillType.name or tostring(fillTypeIndex),
                            amount   = output.amount or 0,
                        })
                    end
                end

                table.insert(data.productions, productionData)
            end
        end
    end

    table.sort(data.productions, function(a, b)
        return tostring(a.name or a.id or "") < tostring(b.name or b.id or "")
    end)

    if productionPoint.storage ~= nil and productionPoint.storage.fillLevels ~= nil then
        for fillTypeIndex, level in pairs(productionPoint.storage.fillLevels) do
            local isInput = activeInputFillTypes[fillTypeIndex] == true
            local isOutput = activeOutputFillTypes[fillTypeIndex] == true

            if isInput or isOutput then
                local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                local fallbackCapacity = productionPoint.storage.capacities
                    and productionPoint.storage.capacities[fillTypeIndex]
                    or productionPoint.storage.capacity
                    or 0
                local capacity = self:safeGet(function()
                    if productionPoint.storage.getCapacity ~= nil then
                        return productionPoint.storage:getCapacity(fillTypeIndex)
                    end
                    return fallbackCapacity
                end, fallbackCapacity)
                local role = isInput and (isOutput and "input_output" or "input") or "output"

                table.insert(data.storages, {
                    fillType = fillType and fillType.name or tostring(fillTypeIndex),
                    title    = fillType and fillType.title or "",
                    role     = role,
                    level    = math.floor(level),
                    capacity = math.floor(capacity),
                    percent  = capacity > 0 and math.floor(math.min(100, level / capacity * 100)) or 0,
                })
            end
        end
    end

    table.sort(data.storages, function(a, b)
        return tostring(a.title or a.fillType or "") < tostring(b.title or b.fillType or "")
    end)

    if #data.productions == 0 then return nil end
    return data
end

-- ======================================================================
-- VERTRÄGE / MISSIONS
-- ======================================================================
