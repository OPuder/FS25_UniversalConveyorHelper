-- FS25 Universal Conveyor Helper
-- Experimental: attach the reference S710's native exactFillRootNode geometry at runtime.
-- This is deliberately restricted to S710 and does not alter other conveyor models.

UCHS710RuntimeExactFillRoot = {}
UCHS710RuntimeExactFillRoot.VERSION = "1.9.83.10"
UCHS710RuntimeExactFillRoot.DEBUG = true

-- Capture the mod directory while this mod is being loaded. GIANTS may change
-- g_currentModDirectory while loading other mods, so do not read it in a later callback.
local MOD_DIRECTORY = g_currentModDirectory or ""

local function log(message, ...)
    if Logging ~= nil and Logging.info ~= nil then
        Logging.info("[UniversalConveyorHelper][S710_RUNTIME_EXACT_FILL] " .. string.format(message, ...))
    end
end

local function isS710(vehicle)
    local filename = string.lower(tostring(vehicle.configFileName or vehicle.xmlFilename or ""))
    local typeName = string.lower(tostring(vehicle.typeName or ""))
    -- The stock Giants S710 exposes Shovel/FillVolume, but may not expose
    -- pickupConveyorBelt. Do not require that optional specialization here.
    return (string.find(filename, "s710", 1, true) ~= nil or string.find(typeName, "s710", 1, true) ~= nil)
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
    local childCount = getNumOfChildren(rootNode)
    for i = 0, childCount - 1 do
        local found = findNodeByName(getChildAt(rootNode, i), targetName)
        if found ~= nil then
            return found
        end
    end
    return nil
end

local function attachReferenceGeometry(vehicle)
    if not isS710(vehicle) then
        return
    end
    log("POSTLOAD_CALLBACK | vehicle=%s | fillUnitSpec=%s | fillVolumeSpec=%s | pickupConveyorBeltSpec=%s",
        tostring(vehicle.configFileName or vehicle.xmlFilename or vehicle.typeName or "unknown"),
        tostring(vehicle.spec_fillUnit ~= nil), tostring(vehicle.spec_fillVolume ~= nil),
        tostring(vehicle.spec_pickupConveyorBelt ~= nil))
    if vehicle.uchS710RuntimeExactFillRoot ~= nil then
        log("Übersprungen: Runtime-I3D bereits vorhanden | vehicle=%s", tostring(vehicle.configFileName))
        return
    end

    local spec = vehicle.spec_fillUnit
    local fillUnit = spec ~= nil and spec.fillUnits ~= nil and spec.fillUnits[1] or nil
    if fillUnit == nil then
        log("ABBRUCH: keine FillUnit 1 | vehicle=%s", tostring(vehicle.configFileName))
        return
    end
    if fillUnit.exactFillRootNode ~= nil then
        log("Übersprungen: S710 besitzt bereits exactFillRootNode=%s", tostring(getName(fillUnit.exactFillRootNode)))
        return
    end

    local filename = Utils.getFilename("assets/S710ExactFillRoot.i3d", MOD_DIRECTORY)
    local i3dRoot = loadI3DFile(filename, false, false, false)
    if i3dRoot == nil or i3dRoot == 0 then
        log("FEHLER: I3D konnte nicht geladen werden: %s", filename)
        return
    end

    local exactNode = findNodeByName(i3dRoot, "exactFillRootNode")
    if exactNode == nil then
        delete(i3dRoot)
        log("FEHLER: exactFillRootNode fehlt in der geladenen Test-I3D")
        return
    end

    if CollisionFlag == nil or CollisionFlag.FILLABLE == nil or not CollisionFlag.getHasGroupFlagSet(exactNode, CollisionFlag.FILLABLE) then
        delete(i3dRoot)
        log("FEHLER: geladene Shape hat nicht die erwartete FILLABLE-Kollisionsgruppe")
        return
    end

    -- The copied subtree keeps the reference model's original local placement.
    -- Link the neutral I3D root to the S710 component root before physics registration.
    link(vehicle.rootNode, i3dRoot)
    if addToPhysics ~= nil then
        addToPhysics(i3dRoot)
    end

    -- Mirror the native FillUnit registration performed by Giants during XML loading.
    fillUnit.exactFillRootNode = exactNode
    spec.exactFillRootNodeToFillUnit = spec.exactFillRootNodeToFillUnit or {}
    spec.exactFillRootNodeToExtraDistance = spec.exactFillRootNodeToExtraDistance or {}
    spec.exactFillRootNodeToFillUnit[exactNode] = fillUnit
    spec.exactFillRootNodeToExtraDistance[exactNode] = 0
    spec.hasExactFillRootNodes = true
    if g_currentMission ~= nil and g_currentMission.addNodeObject ~= nil then
        g_currentMission:addNodeObject(exactNode, vehicle)
    end

    vehicle.uchS710RuntimeExactFillRoot = i3dRoot
    vehicle.uchS710RuntimeExactFillRootNode = exactNode
    log("TEST-SHAPE REGISTRIERT | vehicle=%s | root=%s | exact=%s | fillUnit=1 | node=%s",
        tostring(vehicle.configFileName), tostring(getName(i3dRoot)), tostring(getName(exactNode)), tostring(exactNode))
end

function UCHS710RuntimeExactFillRoot.attach(vehicle)
    attachReferenceGeometry(vehicle)
end

local function cleanupReferenceGeometry(vehicle)
    local i3dRoot = vehicle ~= nil and vehicle.uchS710RuntimeExactFillRoot or nil
    if i3dRoot ~= nil and i3dRoot ~= 0 and entityExists(i3dRoot) then
        if removeFromPhysics ~= nil then
            removeFromPhysics(i3dRoot)
        end
        delete(i3dRoot)
    end
    if vehicle ~= nil then
        vehicle.uchS710RuntimeExactFillRoot = nil
        vehicle.uchS710RuntimeExactFillRootNode = nil
    end
end

function UCHS710RuntimeExactFillRoot.cleanup(vehicle)
    cleanupReferenceGeometry(vehicle)
end

-- The UCH specialization calls these callbacks directly from its own event
-- methods. This avoids relying on a late function wrapper to prove execution.
if UniversalAutoTurnOn ~= nil then
    log("S710 runtime exactFill callbacks exposed for direct onPostLoad/onDelete calls")
else
    log("FEHLER: UniversalAutoTurnOn ist beim Laden des Runtime-Moduls nicht verfügbar")
end
