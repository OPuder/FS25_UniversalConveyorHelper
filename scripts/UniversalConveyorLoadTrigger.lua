-- FS25 Universal Conveyor Helper - native pickup trigger compatibility
-- Adds a GIANTS Shovel pickup node to pickup-conveyor vehicles which expose a
-- known intake node but do not define a shovelNode in their own XML.
-- This does not replace or wrap AutoDrive input handling.

UniversalConveyorLoadTrigger = {}
UniversalConveyorLoadTrigger.VERSION = "1.9.83.10"

local function log(message, ...)
    if Logging ~= nil and Logging.info ~= nil then
        Logging.info("[UniversalConveyorHelper][LOAD_TRIGGER] " .. string.format(message, ...))
    end
end

local function getIntakeNode(vehicle)
    local mappings = vehicle ~= nil and vehicle.i3dMappings or nil
    if type(mappings) == "table" then
        local preferred = {"pickUpNode", "pickupNode", "shovel", "shovelNode", "pickup", "pickUp"}
        for _, name in ipairs(preferred) do
            local entry = mappings[name]
            local node = type(entry) == "table" and (entry.node or entry.nodeId or entry) or entry
            if type(node) == "number" and node ~= 0 and entityExists(node) then
                return node, name
            end
        end
    end

    -- Conservative fallback: use a fill-unit root only when no explicit intake
    -- mapping exists. This is better than guessing the vehicle root and is
    -- logged so a tester can verify the resulting trigger position.
    local units = vehicle ~= nil and vehicle.spec_fillUnit ~= nil and vehicle.spec_fillUnit.fillUnits or nil
    if type(units) == "table" then
        for index, unit in pairs(units) do
            local node = unit ~= nil and (unit.exactFillRootNode or unit.fillRootNode or unit.fillNode) or nil
            if type(node) == "number" and node ~= 0 and entityExists(node) then
                return node, "fillUnit[" .. tostring(index) .. "]"
            end
        end
    end
    return nil, nil
end

local function addRuntimeShovelNode(vehicle)
    if vehicle == nil or vehicle.spec_pickupConveyorBelt == nil or vehicle.spec_shovel == nil then
        return
    end

    local spec = vehicle.spec_shovel
    if type(spec.shovelNodes) ~= "table" or #spec.shovelNodes > 0 then
        return
    end

    if vehicle.spec_fillUnit == nil or vehicle.getFillUnitCapacity == nil then
        return
    end

    local node, source = getIntakeNode(vehicle)
    if node == nil then
        log("Kein sicherer Aufnahmeknoten gefunden: %s", tostring(vehicle.configFileName or vehicle.typeName or "unknown"))
        return
    end

    local fillUnitIndex = 1
    if spec.shovelNodes ~= nil and spec.shovelNodes[1] ~= nil then
        fillUnitIndex = spec.shovelNodes[1].fillUnitIndex or 1
    end

    local shovelNode = {
        node = node,
        fillUnitIndex = fillUnitIndex,
        loadInfoIndex = 1,
        width = 2,
        length = 2,
        yOffset = -0.5,
        zOffset = 0,
        needsMovement = false,
        lastPosition = {0, 0, 0},
        fillLitersPerSecond = 10000,
        needsActivation = true,
        needsAttacherVehicle = false,
        resetFillLevel = false,
        ignoreFillLevel = false,
        ignoreFarmlandState = true,
        allowsSmoothing = false,
        uchRuntimeLoadTrigger = true
    }

    table.insert(spec.shovelNodes, shovelNode)
    vehicle.uchRuntimeLoadTriggerAdded = true
    log("Runtime-Ladebereich ergänzt: %s | nodeSource=%s | fillUnit=%d | Breite/Länge=2m",
        tostring(vehicle.configFileName or vehicle.typeName or "unknown"), tostring(source), fillUnitIndex)
end

if Shovel ~= nil and Shovel.onLoad ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
    Shovel.onLoad = Utils.appendedFunction(Shovel.onLoad, addRuntimeShovelNode)
    log("Shovel.onLoad-Kompatibilitätsbrücke registriert")
else
    log("Shovel.onLoad-Brücke nicht registriert: GIANTS Shovel-Spezialisierung nicht verfügbar")
end
