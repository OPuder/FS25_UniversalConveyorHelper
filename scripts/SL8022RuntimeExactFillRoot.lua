-- FS25 Universal Conveyor Helper
-- Model-specific fillVolumeBox subtree copied from FS25_AutoDrive_SL8022_Quantum/sl8022.i3d.
-- S710 implementation remains separate and unchanged.
UCHSL8022RuntimeExactFillRoot = {}
UCHSL8022RuntimeExactFillRoot.VERSION = "1.9.83.3"
-- Dedicated SL8022 specialization; runtime integration is model-filtered below.
UCHSL8022RuntimeExactFillRoot.ENABLED = true
UCHSL8022RuntimeExactFillRoot.DEBUG = true

local MOD_DIRECTORY = g_currentModDirectory or ""

local function log(message, ...)
    if Logging ~= nil and Logging.info ~= nil then
        Logging.info("[UniversalConveyorHelper][SL8022_RUNTIME_EXACT_FILL] " .. string.format(message, ...))
    end
end

local function isSL8022(vehicle)
    local identity = string.lower(table.concat({
        tostring(vehicle.configFileName or ""),
        tostring(vehicle.configFileNameClean or ""),
        tostring(vehicle.xmlFilename or ""),
        tostring(vehicle.typeName or "")
    }, " "))
    return (string.find(identity, "sl8022", 1, true) ~= nil
        or string.find(identity, "sl80-22", 1, true) ~= nil
        or string.find(identity, "sl 80-22", 1, true) ~= nil
        or (string.find(identity, "quantum", 1, true) ~= nil and string.find(identity, "sl", 1, true) ~= nil))
        and vehicle.spec_fillUnit ~= nil
        and vehicle.spec_fillVolume ~= nil
end

local function findNodeByName(rootNode, targetName)
    if rootNode == nil or rootNode == 0 or not entityExists(rootNode) then
        return nil
    end
    if getName(rootNode) == targetName then
        return rootNode
    end
    for i = 0, getNumOfChildren(rootNode) - 1 do
        local found = findNodeByName(getChildAt(rootNode, i), targetName)
        if found ~= nil then return found end
    end
    return nil
end

local function resolveMapping(vehicle, name)
    local mappings = vehicle ~= nil and vehicle.i3dMappings or nil
    local entry = type(mappings) == "table" and mappings[name] or nil
    local node = type(entry) == "table" and (entry.node or entry.nodeId or entry) or entry
    if type(node) == "number" and node ~= 0 and entityExists(node) then return node end
    return nil
end

local function addNativeFillVolume(vehicle, i3dRoot)
    local spec = vehicle.spec_fillVolume
    local fillUnitSpec = vehicle.spec_fillUnit
    if spec == nil or fillUnitSpec == nil then
        log("FILLVOLUME_INIT_ABORT | spec_fillVolume/spec_fillUnit fehlt")
        return false
    end

    local baseNode = findNodeByName(i3dRoot, "fillVolume")
    local loadInfoNode = findNodeByName(i3dRoot, "fillVolumeUnloadNode")
    if baseNode == nil or loadInfoNode == nil then
        log("FILLVOLUME_INIT_ABORT | baseNode=%s | loadInfoNode=%s",
            tostring(baseNode ~= nil), tostring(loadInfoNode ~= nil))
        return false
    end
    if getHasClassId == nil or ClassIds == nil or ClassIds.SHAPE == nil
            or not getHasClassId(baseNode, ClassIds.SHAPE) then
        log("FILLVOLUME_INIT_ABORT | fillVolume base node ist keine Shape")
        return false
    end

    spec.volumes = spec.volumes or {}
    spec.fillVolumeDeformersByNode = spec.fillVolumeDeformersByNode or {}
    spec.fillUnitFillVolumeMapping = spec.fillUnitFillVolumeMapping or {}
    spec.loadInfos = spec.loadInfos or {}

    -- Do not duplicate the entry if this callback is retried.
    for _, existing in ipairs(spec.volumes) do
        if existing.baseNode == baseNode then
            log("FILLVOLUME_INIT_SKIP | Runtime-FillVolume bereits vorhanden")
            return true
        end
    end

    local fillUnitIndex = 1
    local capacity = vehicle:getFillUnitCapacity(fillUnitIndex)
    if capacity == nil or capacity <= 0 then
        log("FILLVOLUME_INIT_ABORT | ungültige FillUnit-Kapazität=%s", tostring(capacity))
        return false
    end

    local entry = {
        baseNode = baseNode,
        fillUnitIndex = fillUnitIndex,
        fillUnitFactor = 1.0,
        useFullCapacity = true,
        allSidePlanes = true,
        retessellateTop = false,
        defaultFillType = vehicle:getFillUnitFirstSupportedFillType(fillUnitIndex),
        maxDelta = 0.2,
        maxSurfaceAngle = 35,
        maxPhysicalSurfaceAngle = math.rad(35),
        maxSurfaceDistanceError = 0.05,
        maxSubDivEdgeLength = 0.9,
        syncMaxSubDivEdgeLength = 1.35,
        uvPosition = {0, 0, 0},
        deformers = {},
        lastFillType = FillType.UNKNOWN,
        capacity = capacity,
        fillLevel = 0
    }

    local mapping = spec.fillUnitFillVolumeMapping[fillUnitIndex]
    if mapping == nil then
        mapping = {fillVolumes = {}, sumFactors = 0}
        spec.fillUnitFillVolumeMapping[fillUnitIndex] = mapping
    end
    table.insert(mapping.fillVolumes, entry)
    mapping.sumFactors = (mapping.sumFactors or 0) + entry.fillUnitFactor

    local volumeNode = createFillPlaneShape(baseNode, "fillPlane", entry.capacity, entry.maxDelta,
        entry.maxSurfaceAngle, entry.maxPhysicalSurfaceAngle, entry.maxSurfaceDistanceError,
        entry.maxSubDivEdgeLength, entry.syncMaxSubDivEdgeLength, entry.allSidePlanes, entry.retessellateTop)
    if volumeNode == nil or volumeNode == 0 then
        table.remove(mapping.fillVolumes, #mapping.fillVolumes)
        mapping.sumFactors = math.max(0, mapping.sumFactors - entry.fillUnitFactor)
        log("FILLVOLUME_INIT_ABORT | createFillPlaneShape fehlgeschlagen")
        return false
    end

    entry.volume = volumeNode
    entry.index = #spec.volumes + 1
    entry.heightOffset = getFillPlaneHeightAtLocalPos(volumeNode, 0, 0)
    fillPlaneAdd(volumeNode, 1, 0, 1, 0, 11, 0, 0, 0, 0, 11)
    entry.heightOffset = getFillPlaneHeightAtLocalPos(volumeNode, 0, 0)
    fillPlaneAdd(volumeNode, -1, 0, 1, 0, 11, 0, 0, 0, 0, 11)
    link(baseNode, volumeNode)
    setVisibility(volumeNode, false)

    local fillVolumeMaterial = g_materialManager ~= nil and g_materialManager:getBaseMaterialByName("fillPlane") or nil
    if fillVolumeMaterial ~= nil then
        setMaterial(volumeNode, fillVolumeMaterial, 0)
        if g_fillTypeManager ~= nil and g_terrainNode ~= nil then
            g_fillTypeManager:assignFillTypeTextureArraysFromTerrain(volumeNode, g_terrainNode, true, true, true)
        end
    else
        log("FILLVOLUME_INIT_WARNING | fillPlane Material nicht verfügbar")
    end

    table.insert(spec.volumes, entry)

    local loadInfo = {
        fillVolumeIndex = entry.index,
        nodes = {{
            node = loadInfoNode,
            width = 1.4,
            length = 1.0,
            priority = 1
        }}
    }
    table.insert(spec.loadInfos, loadInfo)

    log("FILLVOLUME_INIT_OK | index=%d | fillUnit=1 | baseNode=%s | plane=%s | loadInfoNode=%s | capacity=%.0f",
        entry.index, tostring(getName(baseNode)), tostring(volumeNode), tostring(getName(loadInfoNode)), capacity)
    return true
end

local function removeNativeFillVolume(vehicle)
    if vehicle == nil or vehicle.spec_fillVolume == nil then
        return
    end
    local spec = vehicle.spec_fillVolume
    local root = vehicle.uchSL8022RuntimeExactFillRoot
    if root == nil then return end
    local baseNode = findNodeByName(root, "fillVolume")

    if spec.volumes ~= nil then
        for i = #spec.volumes, 1, -1 do
            local entry = spec.volumes[i]
            if entry ~= nil and entry.baseNode == baseNode then
                if entry.volume ~= nil and entry.volume ~= 0 and entityExists(entry.volume) then
                    delete(entry.volume)
                end
                table.remove(spec.volumes, i)
                local mapping = spec.fillUnitFillVolumeMapping ~= nil and spec.fillUnitFillVolumeMapping[entry.fillUnitIndex] or nil
                if mapping ~= nil and mapping.fillVolumes ~= nil then
                    for j = #mapping.fillVolumes, 1, -1 do
                        if mapping.fillVolumes[j] == entry then
                            table.remove(mapping.fillVolumes, j)
                            mapping.sumFactors = math.max(0, (mapping.sumFactors or 0) - (entry.fillUnitFactor or 1))
                        end
                    end
                    if #mapping.fillVolumes == 0 then
                        spec.fillUnitFillVolumeMapping[entry.fillUnitIndex] = nil
                    end
                end
            end
        end
    end

    if spec.loadInfos ~= nil then
        for i = #spec.loadInfos, 1, -1 do
            local info = spec.loadInfos[i]
            if info ~= nil and info.nodes ~= nil and info.nodes[1] ~= nil
                    and info.nodes[1].node == findNodeByName(root, "fillVolumeUnloadNode") then
                table.remove(spec.loadInfos, i)
            end
        end
    end
end

local function attachReferenceGeometry(vehicle)
    if UCHSL8022RuntimeExactFillRoot.ENABLED ~= true or not isSL8022(vehicle) then
        return
    end

    if vehicle.uchSL8022RuntimeExactFillRoot ~= nil then
        log("ATTACH_SKIP_ALREADY_PRESENT | vehicle=%s", tostring(vehicle.configFileName or vehicle.xmlFilename))
        return
    end
    if vehicle.uchSL8022RuntimeAttempted then
        log("ATTACH_SKIP_ALREADY_ATTEMPTED | vehicle=%s", tostring(vehicle.configFileName or vehicle.xmlFilename))
        return
    end

    local spec = vehicle.spec_fillUnit
    local fillUnit = spec ~= nil and spec.fillUnits ~= nil and spec.fillUnits[1] or nil
    if fillUnit == nil then
        log("ATTACH_ABORT_NO_FILLUNIT | vehicle=%s", tostring(vehicle.configFileName or vehicle.xmlFilename))
        return
    end
    vehicle.uchSL8022RuntimeAttempted = true

    local filename = Utils.getFilename("assets/SL8022Reference/sl8022.i3d", MOD_DIRECTORY)
    log("REFERENCE_I3D_LOAD_BEGIN | vehicle=%s | path=%s",
        tostring(vehicle.configFileName or vehicle.xmlFilename or vehicle.typeName), filename)

    local referenceRoot = loadI3DFile(filename, false, false, true)
    if referenceRoot == nil or referenceRoot == 0 then
        log("REFERENCE_I3D_LOAD_FAILED | path=%s", filename)
        return
    end

    -- In the reference model, fillVolumeBox is a child of sl8022_vis.
    -- Its transforms are local to that parent; attach it to the matching node
    -- on the live vehicle instead of incorrectly linking it to vehicle.rootNode.
    local referenceVis = findNodeByName(referenceRoot, "sl8022_vis")
    local fillVolumeBox = findNodeByName(referenceRoot, "fillVolumeBox")
    local vehicleVis = findNodeByName(vehicle.rootNode, "sl8022_vis")

    if referenceVis == nil or fillVolumeBox == nil or vehicleVis == nil then
        log("ATTACH_ABORT_NODE_MISSING | referenceVis=%s | fillVolumeBox=%s | vehicleVis=%s",
            tostring(referenceVis ~= nil), tostring(fillVolumeBox ~= nil), tostring(vehicleVis ~= nil))
        delete(referenceRoot)
        return
    end

    -- Ensure the subtree is the expected direct child in the reference hierarchy.
    local actualParent = getParent(fillVolumeBox)
    if actualParent ~= referenceVis then
        log("ATTACH_ABORT_UNEXPECTED_PARENT | fillVolumeBoxParent=%s | expected=sl8022_vis",
            tostring(actualParent ~= nil and getName(actualParent) or "nil"))
        delete(referenceRoot)
        return
    end

    local exactNode = findNodeByName(fillVolumeBox, "exactFillRootNode")
    local fillVolumeNode = findNodeByName(fillVolumeBox, "fillVolume")
    local loadInfoNode = findNodeByName(fillVolumeBox, "fillVolumeUnloadNode")

    if exactNode == nil or fillVolumeNode == nil or loadInfoNode == nil then
        log("ATTACH_ABORT_REQUIRED_NODE_MISSING | exact=%s | fillVolume=%s | loadInfo=%s",
            tostring(exactNode ~= nil), tostring(fillVolumeNode ~= nil), tostring(loadInfoNode ~= nil))
        delete(referenceRoot)
        return
    end

    if CollisionFlag == nil or CollisionFlag.FILLABLE == nil
            or not CollisionFlag.getHasGroupFlagSet(exactNode, CollisionFlag.FILLABLE) then
        log("ATTACH_ABORT_BAD_COLLISION_GROUP | exact=%s", tostring(getName(exactNode)))
        delete(referenceRoot)
        return
    end

    -- Reparent the real reference subtree under the corresponding live model node.
    -- This preserves the reference subtree's local transform relative to sl8022_vis.
    link(vehicleVis, fillVolumeBox)
    if addToPhysics ~= nil then
        addToPhysics(fillVolumeBox)
    end

    -- The reference I3D has been detached from its temporary root; remove the
    -- remainder of the duplicate model, keeping only the required fillVolumeBox subtree.
    delete(referenceRoot)

    if not addNativeFillVolume(vehicle, fillVolumeBox) then
        if removeFromPhysics ~= nil then removeFromPhysics(fillVolumeBox) end
        delete(fillVolumeBox)
        log("ATTACH_ABORT_FILLVOLUME_INIT | vehicle=%s", tostring(vehicle.configFileName or vehicle.xmlFilename))
        return
    end

    -- Replace the stock receiver with the model-specific receiver from the reference.
    local previousNode = fillUnit.exactFillRootNode
    if previousNode ~= nil then
        if spec.exactFillRootNodeToFillUnit ~= nil then
            spec.exactFillRootNodeToFillUnit[previousNode] = nil
        end
        if spec.exactFillRootNodeToExtraDistance ~= nil then
            spec.exactFillRootNodeToExtraDistance[previousNode] = nil
        end
        if g_currentMission ~= nil and g_currentMission.removeNodeObject ~= nil then
            g_currentMission:removeNodeObject(previousNode)
        end
    end

    fillUnit.exactFillRootNode = exactNode
    spec.exactFillRootNodeToFillUnit = spec.exactFillRootNodeToFillUnit or {}
    spec.exactFillRootNodeToExtraDistance = spec.exactFillRootNodeToExtraDistance or {}
    spec.exactFillRootNodeToFillUnit[exactNode] = fillUnit
    spec.exactFillRootNodeToExtraDistance[exactNode] = 0
    spec.hasExactFillRootNodes = true
    if g_currentMission ~= nil and g_currentMission.addNodeObject ~= nil then
        g_currentMission:addNodeObject(exactNode, vehicle)
    end

    vehicle.uchSL8022RuntimeExactFillRoot = fillVolumeBox
    vehicle.uchSL8022RuntimeExactFillRootNode = exactNode
    vehicle.uchSL8022PreviousExactFillRootNode = previousNode

    log("REFERENCE_SUBTREE_ATTACHED | vehicle=%s | parent=%s | subtree=%s | exact=%s | fillVolume=%s | loadInfo=%s",
        tostring(vehicle.configFileName or vehicle.xmlFilename or vehicle.typeName),
        tostring(getName(vehicleVis)), tostring(getName(fillVolumeBox)),
        tostring(exactNode), tostring(fillVolumeNode), tostring(loadInfoNode))
end

function UCHSL8022RuntimeExactFillRoot.attach(vehicle)
    attachReferenceGeometry(vehicle)
end

local function cleanupReferenceGeometry(vehicle)
    if vehicle == nil then return end

    local subtree = vehicle.uchSL8022RuntimeExactFillRoot
    local exactNode = vehicle.uchSL8022RuntimeExactFillRootNode
    local spec = vehicle.spec_fillUnit

    if spec ~= nil and exactNode ~= nil then
        if spec.exactFillRootNodeToFillUnit ~= nil then
            spec.exactFillRootNodeToFillUnit[exactNode] = nil
        end
        if spec.exactFillRootNodeToExtraDistance ~= nil then
            spec.exactFillRootNodeToExtraDistance[exactNode] = nil
        end
        if g_currentMission ~= nil and g_currentMission.removeNodeObject ~= nil then
            g_currentMission:removeNodeObject(exactNode)
        end

        local previousNode = vehicle.uchSL8022PreviousExactFillRootNode
        local fillUnit = spec.fillUnits ~= nil and spec.fillUnits[1] or nil
        if fillUnit ~= nil and previousNode ~= nil and entityExists(previousNode) then
            fillUnit.exactFillRootNode = previousNode
            spec.exactFillRootNodeToFillUnit = spec.exactFillRootNodeToFillUnit or {}
            spec.exactFillRootNodeToExtraDistance = spec.exactFillRootNodeToExtraDistance or {}
            spec.exactFillRootNodeToFillUnit[previousNode] = fillUnit
            spec.exactFillRootNodeToExtraDistance[previousNode] = 0
            if g_currentMission ~= nil and g_currentMission.addNodeObject ~= nil then
                g_currentMission:addNodeObject(previousNode, vehicle)
            end
        end
    end

    removeNativeFillVolume(vehicle)

    if subtree ~= nil and subtree ~= 0 and entityExists(subtree) then
        if removeFromPhysics ~= nil then
            removeFromPhysics(subtree)
        end
        delete(subtree)
    end

    vehicle.uchSL8022RuntimeExactFillRoot = nil
    vehicle.uchSL8022RuntimeExactFillRootNode = nil
    vehicle.uchSL8022PreviousExactFillRootNode = nil
end

function UCHSL8022RuntimeExactFillRoot.cleanup(vehicle)
    cleanupReferenceGeometry(vehicle)
end


-- Dedicated specialization lifecycle: the vanilla SL 80-22 uses conveyorBelt,
-- and may not receive UniversalAutoTurnOn. Type injection filters by conveyor,
-- FillUnit and FillVolume; the runtime callback then filters by SL8022 identity.
function UCHSL8022RuntimeExactFillRoot.prerequisitesPresent(specializations)
    return true
end

function UCHSL8022RuntimeExactFillRoot.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", UCHSL8022RuntimeExactFillRoot)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", UCHSL8022RuntimeExactFillRoot)
end

function UCHSL8022RuntimeExactFillRoot:onPostLoad(savegame)
    log("SPECIALIZATION_POSTLOAD | vehicle=%s",
        tostring(self.configFileName or self.configFileNameClean or self.xmlFilename or self.typeName))
    UCHSL8022RuntimeExactFillRoot.attach(self)
end

function UCHSL8022RuntimeExactFillRoot:onDelete()
    UCHSL8022RuntimeExactFillRoot.cleanup(self)
end

log("SL 80-22 Quantum subtree integration bereit | source=FS25_AutoDrive_SL8022_Quantum/sl8022.i3d")
