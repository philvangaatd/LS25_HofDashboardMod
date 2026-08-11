-- Collector methods extracted from scripts/HofDashboard.lua.

function HofDashboardLive:getGroundTypeName(value)
    return self.GROUND_TYPE_NAMES[value] or tostring(value or 0)
end

function HofDashboardLive:isWorkedGroundType(value)
    if FieldGroundType == nil then return false end
    return value == FieldGroundType.PLOWED
        or value == FieldGroundType.CULTIVATED
        or value == FieldGroundType.SEEDBED
        or value == FieldGroundType.ROLLED_SEEDBED
        or value == FieldGroundType.ROLLER_LINES
        or value == FieldGroundType.STUBBLE_TILLAGE
        or value == FieldGroundType.RIDGE
        or value == FieldGroundType.GRASS_CUT
end

function HofDashboardLive:isGrowingGroundType(value)
    if FieldGroundType == nil then return false end
    return value == FieldGroundType.SOWN
        or value == FieldGroundType.DIRECT_SOWN
        or value == FieldGroundType.RIDGE_SOWN
        or value == FieldGroundType.PLANTED
        or value == FieldGroundType.GRASS
end

function HofDashboardLive:pointInPolygon(x, z, polygon)
    local inside = false
    local j = #polygon

    for i = 1, #polygon do
        local xi, zi = polygon[i].x, polygon[i].z
        local xj, zj = polygon[j].x, polygon[j].z
        local intersects = ((zi > z) ~= (zj > z))
            and (x < (xj - xi) * (z - zi) / (zj - zi) + xi)
        if intersects then inside = not inside end
        j = i
    end

    return inside
end

function HofDashboardLive:getDominantKey(counts)
    local bestKey = nil
    local bestCount = -1
    for key, count in pairs(counts) do
        if count > bestCount then
            bestKey = key
            bestCount = count
        end
    end
    return bestKey, math.max(0, bestCount)
end

function HofDashboardLive:classifyFieldState(fieldState)
    if fieldState == nil or not fieldState.isValid then return "INVALID", nil end

    -- Frucht- und Bodenzustand sind im FS25 voneinander unabhÃ¤ngige Density-Map-
    -- Informationen. Gerade bei vorbefÃ¼llten Karten kann eine sichtbare Kultur je
    -- nach GrowthState einen Bodentyp wie CULTIVATED melden. Deshalb darf ein
    -- "bearbeiteter" groundType eine tatsÃ¤chlich vorhandene, stehende Kultur nicht
    -- pauschal Ã¼berstimmen.
    local fruitIdx = fieldState.fruitTypeIndex
    local unknownFruit = FruitType ~= nil and FruitType.UNKNOWN or 0
    local fruitType = nil
    if fruitIdx ~= nil and fruitIdx ~= unknownFruit and fruitIdx ~= 0 then
        fruitType = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIdx) or nil
    end

    if fruitType ~= nil then
        local growthState = fieldState.growthState or 0

        if fruitType.getIsWithered ~= nil and fruitType:getIsWithered(growthState) then
            return "WITHERED", fruitType
        end

        -- Bei bereits geschnittener Frucht hat ein anschlieÃŸend bearbeiteter Boden
        -- Vorrang: nach Grubbern/PflÃ¼gen soll der Bereich als TILLED erscheinen und
        -- nicht dauerhaft als abgeerntete Kultur hÃ¤ngen bleiben.
        if fruitType.getIsCut ~= nil and fruitType:getIsCut(growthState) then
            if self:isWorkedGroundType(fieldState.groundType) then
                return "TILLED", nil
            end
            return "HARVESTED", fruitType
        end

        local minHarvest = fruitType.minHarvestingGrowthState or -1
        local maxHarvest = fruitType.maxHarvestingGrowthState or -1
        if minHarvest >= 0 and maxHarvest >= 0
            and growthState >= minHarvest and growthState <= maxHarvest then
            return "READY", fruitType
        end

        -- Jede weitere valide, nicht geschnittene Frucht ist eine stehende Kultur.
        -- Das gilt bewusst auch dann, wenn ihr GrowthState einen CULTIVATED-Ã¤hnlichen
        -- groundType verwendet.
        return "GROWING", fruitType
    end

    if self:isWorkedGroundType(fieldState.groundType) then
        return "TILLED", nil
    end

    return "FALLOW", nil
end

function HofDashboardLive:sampleField(field)
    local polygon = {}
    local polygonNodes = field:getPolygonPoints() or {}

    for _, point in ipairs(polygonNodes) do
        local x, _, z = getWorldTranslation(point)
        table.insert(polygon, {x = x, z = z})
    end

    local statusCounts = {}
    local groundCounts = {}
    local fruitCounts = {}
    local growthCountsByFruit = {}
    local fruitDescs = {}
    local totalSamples = 0

    local sums = {
        weedState = 0,
        weedFactor = 0,
        stoneLevel = 0,
        sprayLevel = 0,
        sprayType = 0,
        limeLevel = 0,
        rollerLevel = 0,
        plowLevel = 0,
        stubbleShredLevel = 0,
        waterLevel = 0,
    }

    local function addSample(x, z)
        local state = FieldState.new()
        local ok, err = pcall(function() state:update(x, z) end)
        if not ok then
            self:logError("FieldState.update", err)
            return
        end
        if not state.isValid then return end

        local status, fruitType = self:classifyFieldState(state)
        if status == "INVALID" then return end

        totalSamples = totalSamples + 1
        statusCounts[status] = (statusCounts[status] or 0) + 1
        groundCounts[state.groundType] = (groundCounts[state.groundType] or 0) + 1

        -- Frucht nur aus Bereichen Ã¼bernehmen, die nicht bereits bearbeitet oder leer sind.
        -- So bleibt auf einem vollstÃ¤ndig gepflÃ¼gten Feld keine alte Kultur hÃ¤ngen.
        if fruitType ~= nil and status ~= "TILLED" and status ~= "FALLOW" then
            local fruitIdx = fruitType.index or state.fruitTypeIndex
            if fruitIdx ~= nil then
                fruitCounts[fruitIdx] = (fruitCounts[fruitIdx] or 0) + 1
                fruitDescs[fruitIdx] = fruitType
                growthCountsByFruit[fruitIdx] = growthCountsByFruit[fruitIdx] or {}
                local growthState = state.growthState or 0
                growthCountsByFruit[fruitIdx][growthState] = (growthCountsByFruit[fruitIdx][growthState] or 0) + 1
            end
        end

        sums.weedState = sums.weedState + (state.weedState or 0)
        sums.weedFactor = sums.weedFactor + (state.weedFactor or 0)
        sums.stoneLevel = sums.stoneLevel + (state.stoneLevel or 0)
        sums.sprayLevel = sums.sprayLevel + (state.sprayLevel or 0)
        sums.sprayType = sums.sprayType + (state.sprayType or 0)
        sums.limeLevel = sums.limeLevel + (state.limeLevel or 0)
        sums.rollerLevel = sums.rollerLevel + (state.rollerLevel or 0)
        sums.plowLevel = sums.plowLevel + (state.plowLevel or 0)
        sums.stubbleShredLevel = sums.stubbleShredLevel + (state.stubbleShredLevel or 0)
        sums.waterLevel = sums.waterLevel + (state.waterLevel or 0)
    end

    if #polygon >= 3 then
        local minX, maxX = math.huge, -math.huge
        local minZ, maxZ = math.huge, -math.huge
        for _, point in ipairs(polygon) do
            minX = math.min(minX, point.x)
            maxX = math.max(maxX, point.x)
            minZ = math.min(minZ, point.z)
            maxZ = math.max(maxZ, point.z)
        end

        local spanX = math.max(1, maxX - minX)
        local spanZ = math.max(1, maxZ - minZ)
        local aspect = spanX / spanZ
        local columns = math.ceil(math.sqrt(self.FIELD_SAMPLE_TARGET * aspect))
        columns = math.max(4, math.min(12, columns))
        local rows = math.ceil(self.FIELD_SAMPLE_TARGET / columns)
        rows = math.max(4, math.min(12, rows))

        for row = 1, rows do
            local z = minZ + (row - 0.5) / rows * spanZ
            for column = 1, columns do
                local x = minX + (column - 0.5) / columns * spanX
                if self:pointInPolygon(x, z, polygon) then
                    addSample(x, z)
                end
            end
        end
    end

    -- Sehr kleine/ungewÃ¶hnliche Feldpolygone: als Fallback exakt an der Feldmitte
    -- abfragen. Das ist immer noch ein aktueller FieldState.update()-Messpunkt und
    -- nicht der alte, feldweit gecachte field:getFieldState()-Wert.
    if totalSamples == 0 then
        local ok, x, z = pcall(function() return field:getCenterOfFieldWorldPosition() end)
        if ok and x ~= nil and z ~= nil then addSample(x, z) end
    end

    local result = {
        sampleCount = totalSamples,
        fieldStatus = "FALLOW",
        statusPercentages = {
            ready = 0,
            growing = 0,
            harvested = 0,
            tilled = 0,
            withered = 0,
            fallow = 0,
        },
        harvestReady = false,
        isWithered = false,
        fruitType = "NONE",
        fruitTitle = "Brache",
        fruitDesc = nil,
        growthState = 0,
        maxGrowthState = 0,
        growthName = "FALLOW",
        groundType = "NONE",
        weedState = 0,
        weedFactor = 0,
        stoneLevel = 0,
        sprayLevel = 0,
        sprayType = 0,
        limeLevel = 0,
        rollerLevel = 0,
        plowLevel = 0,
        stubbleShredLevel = 0,
        waterLevel = 0,
    }

    if totalSamples == 0 then return result end

    local function pct(status)
        return self:round((statusCounts[status] or 0) / totalSamples * 100, 1)
    end

    result.statusPercentages.ready = pct("READY")
    result.statusPercentages.growing = pct("GROWING")
    result.statusPercentages.harvested = pct("HARVESTED")
    result.statusPercentages.tilled = pct("TILLED")
    result.statusPercentages.withered = pct("WITHERED")
    result.statusPercentages.fallow = pct("FALLOW")

    local dominantStatus, dominantStatusCount = self:getDominantKey(statusCounts)
    local dominantShare = dominantStatusCount / totalSamples
    local significantStates = 0
    for _, count in pairs(statusCounts) do
        if count / totalSamples >= 0.08 then significantStates = significantStates + 1 end
    end

    if dominantStatus ~= nil then
        if significantStates > 1 and dominantShare < 0.85 then
            result.fieldStatus = "MIXED"
        else
            result.fieldStatus = dominantStatus
        end
    end

    result.harvestReady = result.statusPercentages.ready >= 50
    result.isWithered = result.fieldStatus == "WITHERED"

    local dominantGround = self:getDominantKey(groundCounts)
    if dominantGround ~= nil then
        result.groundType = self:getGroundTypeName(dominantGround)
    end

    -- FÃ¼r die bestehende PHP-Schnittstelle weiterhin einen plausiblen groundType
    -- liefern. fieldStatus bleibt zusÃ¤tzlich als neue, eindeutige Quelle erhalten.
    if result.fieldStatus == "READY" then
        result.groundType = "HARVEST_READY"
    elseif result.fieldStatus == "GROWING" then
        if dominantGround == nil or not self:isGrowingGroundType(dominantGround) then
            result.groundType = "SOWN"
        end
    elseif result.fieldStatus == "TILLED" and (dominantGround == nil or not self:isWorkedGroundType(dominantGround)) then
        result.groundType = "CULTIVATED"
    elseif result.fieldStatus == "HARVESTED" then
        result.groundType = "GRASS_CUT"
    elseif result.fieldStatus == "MIXED" then
        -- Mischfelder dÃ¼rfen niemals allein wegen eines verbliebenen erntereifen
        -- Teilbereichs als komplett erntereif erscheinen.
        result.harvestReady = false
        if dominantGround == nil or not self:isWorkedGroundType(dominantGround) then
            result.groundType = "CULTIVATED"
        end
    end

    local dominantFruitIdx = self:getDominantKey(fruitCounts)
    if dominantFruitIdx ~= nil then
        local fruitType = fruitDescs[dominantFruitIdx]
        if fruitType ~= nil then
            result.fruitDesc = fruitType
            result.fruitType = string.upper(fruitType.name or "UNKNOWN")
            result.fruitTitle = (fruitType.fillType and fruitType.fillType.title) or fruitType.name or result.fruitType
            result.maxGrowthState = fruitType.maxHarvestingGrowthState or fruitType.numGrowthStates or 0

            local growthCounts = growthCountsByFruit[dominantFruitIdx] or {}
            local dominantGrowthState = self:getDominantKey(growthCounts)
            result.growthState = dominantGrowthState or 0
        end
    end

    if result.fieldStatus == "READY" then
        result.growthName = "READY_TO_HARVEST"
    elseif result.fieldStatus == "GROWING" then
        result.growthName = "GROWING"
    elseif result.fieldStatus == "HARVESTED" then
        result.growthName = "CUT"
    elseif result.fieldStatus == "WITHERED" then
        result.growthName = "WITHERED"
    elseif result.fieldStatus == "MIXED" then
        result.growthName = "MIXED"
    elseif result.fieldStatus == "TILLED" then
        result.growthName = "TILLED"
    else
        result.growthName = "FALLOW"
    end

    local divisor = totalSamples
    result.weedState = self:round(sums.weedState / divisor, 0)
    result.weedFactor = self:round(sums.weedFactor / divisor, 3)
    result.stoneLevel = self:round(sums.stoneLevel / divisor, 0)
    result.sprayLevel = self:round(sums.sprayLevel / divisor, 0)
    result.sprayType = self:round(sums.sprayType / divisor, 0)
    result.limeLevel = self:round(sums.limeLevel / divisor, 0)
    result.rollerLevel = self:round(sums.rollerLevel / divisor, 0)
    result.plowLevel = self:round(sums.plowLevel / divisor, 0)
    result.stubbleShredLevel = self:round(sums.stubbleShredLevel / divisor, 0)
    result.waterLevel = self:round(sums.waterLevel / divisor, 0)

    return result
end

-- ======================================================================
-- LIFECYCLE
-- ======================================================================

-- ======================================================================
-- FELDDATEN
--
-- WICHTIG: field:getFieldState() liefert nur einen zusammengefassten Feldzustand.
-- Das ist fÃ¼r laufende Feldarbeit (teilweise geerntet/gepflÃ¼gt) nicht ausreichend.
-- Wir lesen deshalb mehrere aktuelle FieldState.update(x,z)-Messpunkte innerhalb
-- des echten Feldpolygons und bilden daraus einen belastbaren Feldzustand.
-- GIANTS nutzt FieldState.update(x,z) selbst fÃ¼r die positionsgenaue Feldanalyse.
-- ======================================================================

function HofDashboardLive:collectFields()
    local result = self:newArray()
    if g_farmlandManager == nil or g_currentMission == nil then return result end

    local myFarmId = self:getPlayerFarmId()
    if myFarmId <= 0 then
        self:logError("collectFields", "Spieler-FarmId konnte nicht ermittelt werden")
        return result
    end

    for _, farmland in pairs(g_farmlandManager.farmlands or {}) do
        if farmland.farmId == myFarmId and farmland.field ~= nil then
            local ok, fieldData = self:protected(
                "processFarmland " .. tostring(farmland.id or "?"),
                function() return self:processFarmland(farmland, myFarmId) end
            )
            if ok and fieldData ~= nil then
                table.insert(result, fieldData)
            end
        end
    end

    table.sort(result, function(a, b) return (a.id or 0) < (b.id or 0) end)
    return result
end

function HofDashboardLive:processFarmland(farmland, myFarmId)
    local field = farmland.field
    local sampled = self:sampleField(field)

    return {
        id                = field:getId() or 0,
        farmlandId        = farmland.id or 0,
        farmId            = myFarmId,
        area              = self:round(field.areaHa or 0, 2),
        sampleCount       = sampled.sampleCount,
        fieldStatus       = sampled.fieldStatus,
        statusPercentages = sampled.statusPercentages,
        fruitType         = sampled.fruitType,
        fruitTitle        = sampled.fruitTitle,
        maxGrowthState    = sampled.maxGrowthState,
        growthState       = sampled.growthState,
        growthName        = sampled.growthName,
        harvestReady      = sampled.harvestReady,
        isWithered        = sampled.isWithered,
        groundType        = sampled.groundType,
        weedState         = sampled.weedState,
        weedFactor        = sampled.weedFactor,
        stoneLevel        = sampled.stoneLevel,
        sprayLevel        = sampled.sprayLevel,
        sprayType         = sampled.sprayType,
        limeLevel         = sampled.limeLevel,
        rollerLevel       = sampled.rollerLevel,
        plowLevel         = sampled.plowLevel,
        stubbleShredLevel = sampled.stubbleShredLevel,
        waterLevel        = sampled.waterLevel,
    }
end
