-- FS25 Universal Conveyor Helper
-- Diagnostic-only inspection of native nodes relevant to AutoDrive unload-target support.
-- Does not create triggers, alter discharge behavior, or modify other mods.
AutoDriveUnloadNodeDiagnostics = {}
AutoDriveUnloadNodeDiagnostics.VERSION = "1.9.82.9"

local function log(message, ...)
    if Logging ~= nil and Logging.info ~= nil then
        Logging.info("[UniversalConveyorHelper][AD_UNLOAD_NODES] " .. string.format(message, ...))
    end
end

local function nodeFromMapping(vehicle, name)
    local mappings = vehicle ~= nil and vehicle.i3dMappings or nil
    if type(mappings) ~= "table" then return nil end
    local entry = mappings[name]
    if entry == nil then return nil end
    local node = type(entry) == "table" and (entry.node or entry.nodeId or entry) or entry
    if type(node) == "number" and node ~= 0 and entityExists ~= nil and entityExists(node) then
        return node
    end
    return nil
end

local function countTable(value)
    if type(value) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

local function inspectVehicle(vehicle)
    if vehicle == nil or vehicle.uchADUnloadNodeDiagnosticsDone then return end
    if vehicle.spec_dischargeable == nil and vehicle.spec_conveyorBelt == nil and vehicle.spec_pickupConveyorBelt == nil then return end
    vehicle.uchADUnloadNodeDiagnosticsDone = true

    local name = tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown")
    local mappings = {
        "trailerTrigger", "newFillVolume", "newLoadInfo", "newExactFillRootNode",
        "pickUpNode", "shovel", "pipeRaycastNode", "dischargeNode", "fillAutoAimTargetNode"
    }
    local values = {}
    for _, mappingName in ipairs(mappings) do
        values[#values + 1] = mappingName .. "=" .. (nodeFromMapping(vehicle, mappingName) ~= nil and "present" or "missing")
    end

    local fillVolume = vehicle.spec_fillVolume
    local shovel = vehicle.spec_shovel
    local dischargeable = vehicle.spec_dischargeable
    local fillVolumes = fillVolume ~= nil and fillVolume.volumes or nil
    local loadInfos = fillVolume ~= nil and fillVolume.loadInfos or nil
    local unloadInfos = fillVolume ~= nil and fillVolume.unloadInfos or nil
    local shovelNodes = shovel ~= nil and shovel.shovelNodes or nil
    local activeFillUnit = vehicle.spec_fillUnit ~= nil and vehicle.spec_fillUnit.fillUnits ~= nil and vehicle.spec_fillUnit.fillUnits[1] or nil
    local exactFillRootNode = activeFillUnit ~= nil and activeFillUnit.exactFillRootNode or nil
    local dischargeNodes = dischargeable ~= nil and dischargeable.dischargeNodes or nil

    local loadInfoDetails = {}
    if type(loadInfos) == "table" then
        for index, info in pairs(loadInfos) do
            local nodes = {}
            if type(info) == "table" and type(info.nodes) == "table" then
                for nodeIndex, nodeEntry in pairs(info.nodes) do
                    nodes[#nodes + 1] = tostring(nodeIndex) .. ":" .. tostring(type(nodeEntry) == "table" and nodeEntry.node or nodeEntry)
                end
            end
            loadInfoDetails[#loadInfoDetails + 1] = tostring(index) .. "(nodes=" .. table.concat(nodes, ",") .. ")"
        end
    end

    local nativeMethods = {
        "getCurrentDischargeNode", "getCanDischargeToObject", "getDischargeFillType",
        "setDischargeState", "getFillVolumeLoadInfo", "addFillUnitFillLevel"
    }
    local methodDetails = {}
    for _, methodName in ipairs(nativeMethods) do
        methodDetails[#methodDetails + 1] = methodName .. "=" .. tostring(type(vehicle[methodName]) == "function")
    end

    log("STRUCTURE | vehicle=%s | spec_fillVolume=%s | volumes=%d | loadInfos=%d[%s] | unloadInfos=%d | spec_shovel=%s | shovelNodes=%d | spec_dischargeable=%s | dischargeNodes=%d | exactFillRootNode=%s | exactRootRegistered=%s | nativeMethods=%s | %s",
        name,
        tostring(fillVolume ~= nil), countTable(fillVolumes), countTable(loadInfos), table.concat(loadInfoDetails, ";"), countTable(unloadInfos),
        tostring(shovel ~= nil), countTable(shovelNodes), tostring(dischargeable ~= nil), countTable(dischargeNodes),
        tostring(exactFillRootNode), tostring(exactFillRootNode ~= nil and vehicle.spec_fillUnit.exactFillRootNodeToFillUnit ~= nil and vehicle.spec_fillUnit.exactFillRootNodeToFillUnit[exactFillRootNode] ~= nil),
        table.concat(methodDetails, ","), table.concat(values, " | "))

    if nodeFromMapping(vehicle, "trailerTrigger") == nil then
        log("LIMIT | vehicle=%s | trailerTrigger fehlt als I3D-Mapping; UCH kann keinen echten physischen Trigger allein durch einen Lua-Tabelleneintrag erzeugen", name)
    end
    if nodeFromMapping(vehicle, "newFillVolume") == nil or nodeFromMapping(vehicle, "newLoadInfo") == nil then
        log("LIMIT | vehicle=%s | Referenz-FillVolume/LoadInfo-Knoten nicht vollständig vorhanden; native FillVolume-Struktur nicht blind ergänzen", name)
    end
end

-- Attach to the UCH specialization event that is actually registered on vehicle types.
-- The GIANTS Vehicle class dispatches onPostLoad through specialization event listeners;
-- Vehicle.onPostLoad is not the event handler to wrap.
if UniversalAutoTurnOn ~= nil and UniversalAutoTurnOn.onPostLoad ~= nil
        and Utils ~= nil and Utils.appendedFunction ~= nil then
    UniversalAutoTurnOn.onPostLoad = Utils.appendedFunction(UniversalAutoTurnOn.onPostLoad, inspectVehicle)
    log("Post-load node diagnostics registered via UniversalAutoTurnOn.onPostLoad")
else
    log("Post-load node diagnostics not registered: UCH onPostLoad specialization handler unavailable")
end
