-- FS25 Universal Conveyor Helper 1.9.81.1
-- Runtime conveyor detection and shop-category eligibility.
-- Refactor only: behavior intentionally unchanged.

-- UCH helper: logging local to this module.
local function logInfo(message, ...)
    Logging.info("[UniversalConveyorHelper] " .. string.format(message, ...))
end

local function logError(message, ...)
    Logging.error("[UniversalConveyorHelper] " .. string.format(message, ...))
end

function UniversalConveyorHelper:isConveyorVehicle(vehicle)
    if vehicle == nil then
        return false
    end

    -- Our own injected specialization is the most reliable marker.
    if vehicle.spec_uchAutoTurnOn ~= nil
        or vehicle.spec_uchWideDischarge ~= nil
        or vehicle.spec_UniversalAutoTurnOn ~= nil
        or vehicle.spec_UniversalWideDischarge ~= nil
        or vehicle.uchAutoTurnOnRecheckTimer ~= nil
    then
        return true
    end

    -- Important fallback for custom conveyor vehicle types (e.g. S710 variants).
    -- Some mods define their own vehicle type and therefore do not receive our
    -- specialization injection. Detect the real runtime conveyor specialization.
    if vehicle.spec_pickupConveyorBelt ~= nil
        or vehicle.spec_conveyorBelt ~= nil
        or vehicle.spec_aiConveyorBelt ~= nil
    then
        return true
    end

    -- Last safe fallback: a motorized, fill-unit conveyor-like object with the
    -- native turn-on API and a conveyor-like type/config name.
    if vehicle.startMotor ~= nil
        and vehicle.setIsTurnedOn ~= nil
        and vehicle.getIsTurnedOn ~= nil
        and vehicle.spec_motorized ~= nil
    then
        local typeName = string.lower(tostring(vehicle.typeName or ""))
        local configName = string.lower(tostring(vehicle.configFileName or vehicle.configFileNameClean or ""))
        if string.find(typeName, "conveyor", 1, true) ~= nil
            or string.find(typeName, "s710", 1, true) ~= nil
            or string.find(configName, "s710", 1, true) ~= nil
        then
            return true
        end
    end

    return false
end

-- AutoStart is intentionally restricted to the actual in-game shop category.
-- Do not infer eligibility from names or conveyor specializations alone: those
-- are useful for UCH management, but can match unrelated vehicles.
function UniversalConveyorHelper:isShopCategoryConveyorBelt(vehicle)
    if vehicle == nil or g_storeManager == nil or g_storeManager.getItemByXMLFilename == nil then
        return false, "storeItemUnavailable"
    end

    local filenames = {
        vehicle.configFileName,
        vehicle.configFileNameClean,
        vehicle.xmlFilename,
        vehicle.xmlFileName
    }

    local storeItem = nil
    for _, filename in ipairs(filenames) do
        if filename ~= nil and filename ~= "" then
            local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, filename)
            if ok and item ~= nil then
                storeItem = item
                break
            end
        end
    end

    if storeItem == nil then
        return false, "storeItemNotFound"
    end

    local categories = storeItem.categoryNames
    if categories == nil then
        categories = {storeItem.categoryName}
    end

    for _, category in pairs(categories or {}) do
        if string.lower(tostring(category or "")) == "belts" then
            return true, "category=belts"
        end
    end

    return false, "categoryNotBelts"
end

function UniversalConveyorHelper:isAutoStartVehicle(vehicle)
    if not self:isConveyorVehicle(vehicle) then
        return false
    end

    local eligible, reason = self:isShopCategoryConveyorBelt(vehicle)
    if not eligible and vehicle ~= nil and not vehicle.uchAutoStartCategoryLogged then
        vehicle.uchAutoStartCategoryLogged = true
        logInfo("[AUTO_START][CATEGORY_GATE] blockiert | Fahrzeug=%s | Grund=%s",
            tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"),
            tostring(reason))
    elseif eligible and vehicle ~= nil and not vehicle.uchAutoStartCategoryLogged then
        vehicle.uchAutoStartCategoryLogged = true
        logInfo("[AUTO_START][CATEGORY_GATE] erlaubt | Fahrzeug=%s | Kategorie=belts",
            tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"))
    end

    return eligible
end
