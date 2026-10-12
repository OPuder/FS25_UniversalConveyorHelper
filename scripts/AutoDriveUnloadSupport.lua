-- FS25 Universal Conveyor Helper 1.9.81.8
-- Reference-derived runtime setup for the S710 and SL 80-22 Quantum.
-- This module only adds the native Shovel node data when the required model
-- nodes and FillVolume/LoadInfo structures already exist. It does not create
-- I3D geometry or fabricate missing native FillVolume/trigger objects.
AutoDriveUnloadSupport = {}
AutoDriveUnloadSupport.VERSION = "1.9.83.10"

local function log(message, ...)
    if Logging ~= nil and Logging.info ~= nil then
        Logging.info("[UniversalConveyorHelper][AD_UNLOAD_SUPPORT] " .. string.format(message, ...))
    end
end

local function getModelKind(vehicle)
    local identity = string.lower(table.concat({
        tostring(vehicle.configFileName or ""),
        tostring(vehicle.configFileNameClean or ""),
        tostring(vehicle.typeName or "")
    }, " "))

    if string.find(identity, "s710", 1, true) ~= nil
        or string.find(identity, "s-710", 1, true) ~= nil then
        return "S710"
    end

    -- The Quantum is intentionally deferred until the S710 path is validated.
    if string.find(identity, "sl8022", 1, true) ~= nil
        or string.find(identity, "sl80-22", 1, true) ~= nil
        or string.find(identity, "sl 80-22", 1, true) ~= nil
        or (string.find(identity, "quantum", 1, true) ~= nil and string.find(identity, "sl", 1, true) ~= nil) then
        return "SL8022_DEFERRED"
    end

    return nil
end

local function resolveMapping(vehicle, name)
    local mappings = vehicle ~= nil and vehicle.i3dMappings or nil
    if type(mappings) ~= "table" then
        return nil
    end

    local entry = mappings[name]
    local node = type(entry) == "table" and (entry.node or entry.nodeId or entry) or entry
    if type(node) == "number" and node ~= 0 and entityExists ~= nil and entityExists(node) then
        return node
    end
    return nil
end

local function countEntries(value)
    if type(value) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(value) do n = n + 1 end
    return n
end


-- S710-only receiver-node fallback. The reference mod adds a dedicated exact
-- fill root in its I3D, but the stock S710 does not contain that node. Its
-- existing pickUpNode is at the intended intake side, so test it as the native
-- FillUnit receiver point instead of inventing geometry. This does not create a
-- physical trigger or a fill-volume mesh; it only exposes the receiver node.
local function ensureNativeExactFillRootNode(vehicle)
    if vehicle == nil or vehicle.uchADExactFillRootSetupDone then
        return
    end
    if getModelKind(vehicle) ~= "S710" then
        return
    end
    -- The stock Giants S710 is not guaranteed to expose the optional
    -- pickupConveyorBelt specialization. The actual requirements for this
    -- receiver-node registration are the native FillUnit and FillVolume specs.
    if vehicle.spec_fillUnit == nil or vehicle.spec_fillVolume == nil then
        log("EXACT_FILL_ROOT_SKIP | vehicle=%s | native FillUnit/FillVolume specialization unavailable | fillUnit=%s | fillVolume=%s",
            tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"),
            tostring(vehicle.spec_fillUnit ~= nil), tostring(vehicle.spec_fillVolume ~= nil))
        return
    end

    local fillUnitSpec = vehicle.spec_fillUnit
    local fillUnit = type(fillUnitSpec.fillUnits) == "table" and fillUnitSpec.fillUnits[1] or nil
    if fillUnit == nil then
        return
    end

    -- An XML-defined native node always wins; do not replace it.
    if fillUnit.exactFillRootNode ~= nil then
        vehicle.uchADExactFillRootSetupDone = true
        return
    end

    local node = resolveMapping(vehicle, "newExactFillRootNode")
    local nodeSource = "newExactFillRootNode"

    if node == nil then
        node = resolveMapping(vehicle, "exactFillRootNode")
        nodeSource = "exactFillRootNode"
    end

    -- During the focused runtime-I3D experiment, do not pre-register the stock
    -- pickUpNode as a fake exact-fill root. Leave the slot free for the real
    -- physical Shape loaded by S710RuntimeExactFillRoot.
    if node == nil and UCHS710RuntimeExactFillRoot ~= nil then
        vehicle.uchADExactFillRootSetupDone = true
        log("RUNTIME_I3D_PENDING | vehicle=%s | stock pickUpNode fallback skipped; awaiting physical test Shape",
            tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"))
        return
    end

    -- Legacy fallback for cases where the runtime-I3D experiment is not loaded.
    if node == nil then
        node = resolveMapping(vehicle, "pickUpNode")
        nodeSource = "pickUpNode"
    end
    if node == nil then
        log("EXACT_FILL_ROOT_SKIP | vehicle=%s | neither dedicated root nor pickUpNode exists",
            tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"))
        return
    end

    -- A dedicated exact-fill root from a reference I3D must have the native
    -- FILLABLE group. The stock pickUpNode fallback is a transform/position
    -- point, not a physical collision trigger, and is deliberately handled
    -- separately. AutoDrive detection still has to be validated in-game.
    if nodeSource ~= "pickUpNode" and CollisionFlag ~= nil
        and CollisionFlag.getHasGroupFlagSet ~= nil and CollisionFlag.FILLABLE ~= nil
        and not CollisionFlag.getHasGroupFlagSet(node, CollisionFlag.FILLABLE)
    then
        log("EXACT_FILL_ROOT_SKIP | vehicle=%s | dedicated root lacks FILLABLE group; checking pickUpNode fallback",
            tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"))
        node = resolveMapping(vehicle, "pickUpNode")
        nodeSource = "pickUpNode"
        if node == nil then
            vehicle.uchADExactFillRootSetupDone = true
            return
        end
    end

    fillUnit.exactFillRootNode = node
    fillUnitSpec.exactFillRootNodeToFillUnit = fillUnitSpec.exactFillRootNodeToFillUnit or {}
    fillUnitSpec.exactFillRootNodeToExtraDistance = fillUnitSpec.exactFillRootNodeToExtraDistance or {}
    fillUnitSpec.exactFillRootNodeToFillUnit[node] = fillUnit
    fillUnitSpec.exactFillRootNodeToExtraDistance[node] = 0
    fillUnitSpec.hasExactFillRootNodes = true

    if g_currentMission ~= nil and g_currentMission.addNodeObject ~= nil then
        g_currentMission:addNodeObject(node, vehicle)
    end

    vehicle.uchADExactFillRootSetupDone = true
    log("EXACT_FILL_ROOT_APPLIED | vehicle=%s | fillUnit=1 | node=%s | source=%s | native FillUnit root registered; physical trigger not created",
        tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"),
        tostring(node), nodeSource)
end

local function applyReferenceShovelData(vehicle)
    if vehicle == nil then
        return
    end

    ensureNativeExactFillRootNode(vehicle)

    if vehicle.uchADUnloadSupportChecked then
        return
    end

    local modelKind = getModelKind(vehicle)
    if modelKind == nil then
        return
    end
    vehicle.uchADUnloadSupportChecked = true

    if modelKind == "SL8022_DEFERRED" then
        log("DEFERRED | SL 80-22 Quantum bleibt unverändert, bis der S710 im Spiel bestätigt ist | vehicle=%s",
            tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"))
        return
    end

    local spec = vehicle.spec_shovel
    local fillUnitSpec = vehicle.spec_fillUnit
    local fillVolumeSpec = vehicle.spec_fillVolume
    local shovelNodes = spec ~= nil and spec.shovelNodes or nil
    local volumes = fillVolumeSpec ~= nil and fillVolumeSpec.volumes or nil
    local loadInfos = fillVolumeSpec ~= nil and fillVolumeSpec.loadInfos or nil

    local intakeName = modelKind == "S710" and "pickUpNode" or "shovel"
    local intakeNode = resolveMapping(vehicle, intakeName)
    local fillVolumeNode = resolveMapping(vehicle, "newFillVolume")
    local loadInfoNode = resolveMapping(vehicle, "newLoadInfo")
    local trailerTriggerNode = resolveMapping(vehicle, "trailerTrigger")

    log("REFERENCE | model=%s | vehicle=%s | intake=%s | fillVolumeNode=%s | loadInfoNode=%s | trailerTrigger=%s | fillUnits=%s | volumes=%d | loadInfos=%d | existingShovelNodes=%d",
        modelKind,
        tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"),
        tostring(intakeNode ~= nil), tostring(fillVolumeNode ~= nil), tostring(loadInfoNode ~= nil),
        tostring(trailerTriggerNode ~= nil), tostring(fillUnitSpec ~= nil), countEntries(volumes),
        countEntries(loadInfos), countEntries(shovelNodes))

    if spec == nil or type(shovelNodes) ~= "table" then
        log("SKIP | model=%s | GIANTS Shovel-Spezialisierung oder shovelNodes fehlen; keine Laufzeit-Ergänzung", modelKind)
        return
    end

    -- If the native XML already supplied a shovelNode, never overwrite it.
    if #shovelNodes > 0 then
        local details = {}
        for index, existingNode in ipairs(shovelNodes) do
            details[#details + 1] = string.format("%d(node=%s,fillUnit=%s,loadInfo=%s)",
                index, tostring(existingNode.node), tostring(existingNode.fillUnitIndex), tostring(existingNode.loadInfoIndex))
        end
        log("KEEP | model=%s | native shovelNodes bereits vorhanden (%d) | %s; unverändert",
            modelKind, #shovelNodes, table.concat(details, "; "))
        return
    end

    if intakeNode == nil then
        log("SKIP | model=%s | Referenz-Aufnahmeknoten '%s' fehlt; keinen Knoten erfinden", modelKind, intakeName)
        return
    end

    if fillUnitSpec == nil or vehicle.getFillUnitCapacity == nil then
        log("SKIP | model=%s | FillUnit-Struktur fehlt", modelKind)
        return
    end

    -- Native Shovel uses loadInfoIndex to resolve fill-volume loading geometry.
    -- Do not add a node if the corresponding native LoadInfo structure did not load.
    if countEntries(loadInfos) == 0 then
        log("SKIP | model=%s | native FillVolume-LoadInfo fehlt; shovelNode nicht isoliert ergänzen", modelKind)
        return
    end

    local nodeConfig
    if modelKind == "S710" then
        nodeConfig = {
            node = intakeNode,
            fillUnitIndex = 1,
            loadInfoIndex = 1,
            width = 4,
            length = 4,
            yOffset = -0.5,
            zOffset = 0,
            needsMovement = false,
            lastPosition = {0, 0, 0},
            fillLitersPerSecond = 5,
            needsActivation = true,
            needsAttacherVehicle = false,
            resetFillLevel = false,
            ignoreFillLevel = false,
            ignoreFarmlandState = true,
            allowsSmoothing = false,
            uchReferenceModel = "S710"
        }
    else
        nodeConfig = {
            node = intakeNode,
            fillUnitIndex = 1,
            loadInfoIndex = 1,
            width = 2,
            length = 2,
            yOffset = -0.5,
            zOffset = 0,
            needsMovement = false,
            lastPosition = {0, 0, 0},
            fillLitersPerSecond = 10,
            needsActivation = true,
            needsAttacherVehicle = false,
            resetFillLevel = false,
            ignoreFillLevel = false,
            ignoreFarmlandState = true,
            allowsSmoothing = false,
            uchReferenceModel = "SL8022"
        }
    end

    table.insert(shovelNodes, nodeConfig)
    vehicle.uchADReferenceShovelNodeAdded = true

    log("APPLIED | model=%s | node=%s | fillUnitIndex=1 | loadInfoIndex=1 | width=%.1f | length=%.1f | needsActivation=true | trailerTrigger=%s | Hinweis=Trigger-Erkennung im Spiel separat testen",
        modelKind, intakeName, nodeConfig.width, nodeConfig.length, tostring(trailerTriggerNode ~= nil))
end

-- Shovel.onLoad can run before FillUnit and FillVolume have finished loading.
-- Keep its existing reference setup, but retry the S710 receiver-root fallback
-- from the UCH specialization's onPostLoad event, when the complete vehicle
-- specialization state is available. This only registers the existing node;
-- it does not fabricate FillVolume geometry or a physical trailer trigger.
if Shovel ~= nil and Shovel.onLoad ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
    Shovel.onLoad = Utils.appendedFunction(Shovel.onLoad, applyReferenceShovelData)
    log("GIANTS Shovel.onLoad reference setup registered")
else
    log("GIANTS Shovel.onLoad reference setup not registered: Shovel API unavailable")
end

if UniversalAutoTurnOn ~= nil and UniversalAutoTurnOn.onPostLoad ~= nil
        and Utils ~= nil and Utils.appendedFunction ~= nil then
    UniversalAutoTurnOn.onPostLoad = Utils.appendedFunction(UniversalAutoTurnOn.onPostLoad, function(vehicle)
        ensureNativeExactFillRootNode(vehicle)
    end)
    log("S710 exact-fill-root fallback registered for post-load retry")
else
    log("S710 exact-fill-root post-load retry not registered: UCH onPostLoad unavailable")
end
