-- Collector methods extracted from scripts/HofDashboard.lua.

function HofDashboardLive:getSellingStationName(station)
    local name = ""
    if station ~= nil and station.getName ~= nil then
        name = self:safeGet(function() return station:getName() end, "") or ""
    end
    if name == "" and station ~= nil and station.owningPlaceable ~= nil and station.owningPlaceable.getName ~= nil then
        name = self:safeGet(function() return station.owningPlaceable:getName() end, "") or ""
    end
    if name == "" then name = "Verkaufsstation" end
    return name
end

function HofDashboardLive:collectMarket()
    local result = self:newArray()
    if g_fillTypeManager == nil or g_currentMission == nil then return result end

    local storageSystem = g_currentMission.storageSystem
    if storageSystem == nil or storageSystem.getUnloadingStations == nil then
        self:logError("collectMarket", "StorageSystem/UnloadingStations nicht verfügbar")
        return result
    end

    local fruitFillTypeIndices = {}
    if g_fruitTypeManager ~= nil then
        for _, fruitType in pairs(g_fruitTypeManager.fruitTypes or {}) do
            if fruitType.fillType ~= nil and fruitType.fillType.index ~= nil then
                fruitFillTypeIndices[fruitType.fillType.index] = true
            end
        end
    end

    local unloadingStations = self:safeGet(function()
        return storageSystem:getUnloadingStations()
    end, {}) or {}

    for _, fillType in pairs(g_fillTypeManager.fillTypes or {}) do
        if fillType ~= nil
            and fillType.showOnPriceTable == true
            and fillType.pricePerLiter ~= nil
            and fillType.pricePerLiter > 0 then

            local stations = self:newArray()

            for _, station in pairs(unloadingStations) do
                local accepted = station ~= nil
                    and station.isSellingPoint == true
                    and station.hideFromPricesMenu ~= true

                if accepted then
                    if station.acceptedFillTypes ~= nil then
                        accepted = station.acceptedFillTypes[fillType.index] == true
                    elseif station.getIsFillTypeSupported ~= nil then
                        accepted = self:safeGet(function()
                            return station:getIsFillTypeSupported(fillType.index)
                        end, false) == true
                    else
                        accepted = false
                    end
                end

                if accepted and station.getEffectiveFillTypePrice ~= nil then
                    local pricePerLiter = self:safeGet(function()
                        return station:getEffectiveFillTypePrice(fillType.index)
                    end, 0) or 0

                    if pricePerLiter > 0 then
                        table.insert(stations, {
                            name = self:getSellingStationName(station),
                            pricePer1000L = math.floor(pricePerLiter * 1000 + 0.5),
                        })
                    end
                end
            end

            table.sort(stations, function(a, b)
                if a.pricePer1000L ~= b.pricePer1000L then
                    return a.pricePer1000L > b.pricePer1000L
                end
                return tostring(a.name or "") < tostring(b.name or "")
            end)

            if #stations > 0 then
                local best = stations[1]
                local worst = stations[#stations]
                local basePrice = math.floor(fillType.pricePerLiter * 1000 + 0.5)

                table.insert(result, {
                    fillType = fillType.name or "",
                    title = fillType.title or fillType.name or "",
                    category = fruitFillTypeIndices[fillType.index] and "crop" or "product",
                    unit = "1000L",
                    stationCount = #stations,
                    bestStation = best.name or "",
                    bestPrice = best.pricePer1000L or 0,
                    worstPrice = worst.pricePer1000L or 0,
                    priceSpread = math.max(0, (best.pricePer1000L or 0) - (worst.pricePer1000L or 0)),
                    stations = stations,
                    -- Kompatibilitätsfelder für die bestehende PHP-Schnittstelle.
                    -- pricePerTon ist historisch benannt, enthält aber weiterhin den
                    -- im Spiel üblichen Preis pro 1.000 Liter.
                    pricePerTon = best.pricePer1000L or 0,
                    basePriceTon = basePrice,
                })
            end
        end
    end

    table.sort(result, function(a, b)
        if a.bestPrice ~= b.bestPrice then return a.bestPrice > b.bestPrice end
        return tostring(a.title or "") < tostring(b.title or "")
    end)
    return result
end

-- ======================================================================
-- DATEI SCHREIBEN
-- ======================================================================
