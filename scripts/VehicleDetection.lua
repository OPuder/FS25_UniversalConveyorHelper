-- FS25 Universal Conveyor Helper 1.9.57
-- Vehicle arrival detection.
--
-- Diagnostic-only module for vehicle/implement arrival detection.
-- It traverses tractor/implement relationships, reports nearby fill-unit
-- candidates, but does not unload them or modify AutoDrive/Courseplay. A
-- candidate is not yet proof of fill-type/capacity compatibility.

UniversalConveyorVehicleDetection = {}

UniversalConveyorVehicleDetection.INTERVAL = 500
UniversalConveyorVehicleDetection.RADIUS = 3.0
UniversalConveyorVehicleDetection.timer = 1000
UniversalConveyorVehicleDetection.managerLogged = false
UniversalConveyorVehicleDetection.structureLogged = false

function UniversalConveyorVehicleDetection:getDetectionPoints(conveyor)
    local points = {}

    if conveyor == nil then
        return points
    end

    if conveyor.rootNode ~= nil then
        table.insert(points, {node=conveyor.rootNode, source="root"})
    end

    -- A conveyor's fill-unit nodes are useful diagnostic candidates because
    -- custom conveyor implementations can place their functional area away
    -- from the root node. We do not assume that a particular node is the
    -- intake; we only use them as additional proximity points for this first
    -- detection pass.
    if conveyor.spec_fillUnit ~= nil and type(conveyor.spec_fillUnit.fillUnits) == "table" then
        for fillUnitIndex, fillUnit in pairs(conveyor.spec_fillUnit.fillUnits) do
            if fillUnit ~= nil then
                local node = fillUnit.exactFillRootNode or fillUnit.fillNode or fillUnit.fillRootNode
                if node ~= nil then
                    table.insert(points, {
                        node=node,
                        source="fillUnit[" .. tostring(fillUnitIndex) .. "]"
                    })
                end
            end
        end
    end

    return points
end

function UniversalConveyorVehicleDetection:getVehicleList()
    local result = {}
    local seen = {}

    -- Match the attachment traversal already used by the working discharge
    -- search: a trailer can be attached to a tractor and still be the actual
    -- fill-unit target. Traverse both public APIs and the raw spec table because
    -- different vehicle mods expose the relationship differently.
    local function addVehicle(vehicle)
        if vehicle == nil or seen[vehicle] then
            return
        end

        seen[vehicle] = true
        if not UniversalConveyorHelper:isConveyorVehicle(vehicle) then
            table.insert(result, vehicle)
        end

        if vehicle.getAttachedImplements ~= nil then
            local ok, attached = pcall(vehicle.getAttachedImplements, vehicle)
            if ok and type(attached) == "table" then
                for _, implementData in pairs(attached) do
                    local object = implementData ~= nil and (implementData.object or implementData.implement or implementData.vehicle) or nil
                    if object ~= nil then
                        addVehicle(object)
                    end
                end
            end
        end

        local attacherSpec = vehicle.spec_attacherJoints
        local attachedImplements = attacherSpec ~= nil and attacherSpec.attachedImplements or nil
        if type(attachedImplements) == "table" then
            for _, entry in pairs(attachedImplements) do
                local object = entry ~= nil and (entry.object or entry.implement or entry.vehicle) or nil
                if object ~= nil then
                    addVehicle(object)
                end
            end
        end

        if vehicle.getAttacherVehicle ~= nil then
            local ok, parent = pcall(vehicle.getAttacherVehicle, vehicle)
            if ok and parent ~= nil then
                addVehicle(parent)
            end
        elseif vehicle.attacherVehicle ~= nil then
            addVehicle(vehicle.attacherVehicle)
        end
    end

    local function addList(source)
        if source == nil then
            return
        end
        for _, vehicle in pairs(source) do
            addVehicle(vehicle)
        end
    end

    if g_currentMission ~= nil then
        if g_currentMission.vehicleSystem ~= nil then
            addList(g_currentMission.vehicleSystem.vehicles)
        end
        addList(g_currentMission.vehicles)
        addVehicle(g_currentMission.controlledVehicle)
    end

    return result
end

function UniversalConveyorVehicleDetection:getFillUnitCount(vehicle)
    if vehicle == nil or vehicle.spec_fillUnit == nil or type(vehicle.spec_fillUnit.fillUnits) ~= "table" then
        return 0
    end

    local count = 0
    for _, _ in pairs(vehicle.spec_fillUnit.fillUnits) do
        count = count + 1
    end
    return count
end

function UniversalConveyorVehicleDetection:getAttachedImplementList(vehicle)
    local result = {}

    if vehicle == nil or vehicle.spec_attacherJoints == nil then
        return result
    end

    local attachedImplements = vehicle.spec_attacherJoints.attachedImplements
    if type(attachedImplements) ~= "table" then
        return result
    end

    for _, entry in pairs(attachedImplements) do
        if entry ~= nil then
            local implement = entry.object or entry.implement or entry.vehicle
            if implement ~= nil then
                table.insert(result, implement)
            end
        end
    end

    return result
end

function UniversalConveyorVehicleDetection:getVehicleLabel(vehicle)
    if vehicle == nil then
        return "nil"
    end

    return tostring(
        vehicle.configFileNameClean
        or vehicle.configFileName
        or vehicle.typeName
        or vehicle.vehicleName
        or "vehicle"
    )
end

-- One-time diagnostic dump for the vehicle/object structure.
-- This deliberately does not change detection or discharge behavior.
function UniversalConveyorVehicleDetection:logVehicleStructures()
    if self.structureLogged then
        return
    end

    local vehicles = self:getVehicleList()
    Logging.info(
        "[UniversalConveyorHelper][VEHICLE_STRUCTURE] Start | Fahrzeuge=%d",
        #vehicles
    )

    for index, vehicle in ipairs(vehicles) do
        local attached = self:getAttachedImplementList(vehicle)
        local fillUnits = self:getFillUnitCount(vehicle)
        local hasFillUnit = vehicle ~= nil and vehicle.spec_fillUnit ~= nil
        local hasAttacher = vehicle ~= nil and vehicle.spec_attacherJoints ~= nil
        local target = self:isTarget(vehicle)

        Logging.info(
            "[UniversalConveyorHelper][VEHICLE_STRUCTURE] #%d | Name=%s | type=%s | fillUnit=%s | fillUnits=%d | attacher=%s | attached=%d | target=%s | root=%s",
            index,
            self:getVehicleLabel(vehicle),
            tostring(vehicle and vehicle.typeName or "nil"),
            tostring(hasFillUnit),
            fillUnits,
            tostring(hasAttacher),
            #attached,
            tostring(target),
            tostring(vehicle and vehicle.rootNode or "nil")
        )

        for attachedIndex, implement in ipairs(attached) do
            Logging.info(
                "[UniversalConveyorHelper][VEHICLE_STRUCTURE] #%d Attached[%d] | Name=%s | type=%s | fillUnit=%s | fillUnits=%d | root=%s",
                index,
                attachedIndex,
                self:getVehicleLabel(implement),
                tostring(implement and implement.typeName or "nil"),
                tostring(implement and implement.spec_fillUnit ~= nil),
                self:getFillUnitCount(implement),
                tostring(implement and implement.rootNode or "nil")
            )
        end
    end

    self.structureLogged = true
    Logging.info("[UniversalConveyorHelper][VEHICLE_STRUCTURE] Ende")
end

function UniversalConveyorVehicleDetection:isTarget(vehicle)
    if vehicle == nil or UniversalConveyorHelper:isConveyorVehicle(vehicle) then
        return false
    end

    -- For this first step we intentionally require a real fill-unit vehicle.
    -- This prevents tractors, players and unrelated map objects from being
    -- reported merely because they pass close to a conveyor.
    return vehicle.spec_fillUnit ~= nil
        and type(vehicle.spec_fillUnit.fillUnits) == "table"
end

function UniversalConveyorVehicleDetection:detect()
    if g_currentMission == nil then
        return
    end

    if g_currentMission.isServer ~= nil and not g_currentMission.isServer then
        return
    end

    local conveyors = UniversalConveyorHelper:getGlobalVehicleList()
    local targets = self:getVehicleList()

    -- Diagnostic-only: expose the actual runtime vehicle/attached-implement
    -- structure before we change any detection logic.
    self:logVehicleStructures()

    local detectedCount = 0

    for _, conveyor in ipairs(conveyors) do
        if UniversalConveyorHelper:isConveyorVehicle(conveyor) then
            local enabled = true
            if g_universalConveyorSettings ~= nil and g_universalConveyorSettings.isEnabled ~= nil then
                local okEnabled, resultEnabled = pcall(
                    g_universalConveyorSettings.isEnabled,
                    g_universalConveyorSettings,
                    conveyor
                )
                if okEnabled then
                    enabled = resultEnabled ~= false
                end
            end

            if enabled then
                local points = self:getDetectionPoints(conveyor)
                local bestVehicle = nil
                local bestDistance = math.huge
                local bestSource = nil

                for _, vehicle in ipairs(targets) do
                    if self:isTarget(vehicle) and vehicle ~= conveyor then
                        local vehiclePoints = {}
                        if vehicle.rootNode ~= nil then
                            table.insert(vehiclePoints, vehicle.rootNode)
                        end
                        if vehicle.spec_fillUnit ~= nil and type(vehicle.spec_fillUnit.fillUnits) == "table" then
                            for _, fillUnit in pairs(vehicle.spec_fillUnit.fillUnits) do
                                if fillUnit ~= nil then
                                    local node = fillUnit.exactFillRootNode or fillUnit.fillNode or fillUnit.fillRootNode
                                    if node ~= nil then
                                        table.insert(vehiclePoints, node)
                                    end
                                end
                            end
                        end

                        for _, conveyorPoint in ipairs(points) do
                            local cx, cy, cz = getWorldTranslation(conveyorPoint.node)
                            for _, vehicleNode in ipairs(vehiclePoints) do
                                local vx, vy, vz = getWorldTranslation(vehicleNode)
                                local distance = MathUtil.vector3Length(vx - cx, vy - cy, vz - cz)
                                if distance < bestDistance then
                                    bestDistance = distance
                                    bestVehicle = vehicle
                                    bestSource = conveyorPoint.source
                                end
                            end
                        end
                    end
                end

                local key = nil
                if bestVehicle ~= nil and bestDistance <= self.RADIUS then
                    local conveyorKey = conveyor.uniqueId or conveyor.id or conveyor.rootNode
                    local vehicleKey = bestVehicle.uniqueId or bestVehicle.id or bestVehicle.rootNode
                    key = tostring(conveyorKey) .. "->" .. tostring(vehicleKey)
                    detectedCount = detectedCount + 1

                    if conveyor.uchDetectedVehicleKey ~= key then
                        local conveyorName = tostring(conveyor.configFileNameClean or conveyor.configFileName or conveyor.typeName or "conveyor")
                        local vehicleName = tostring(bestVehicle.configFileNameClean or bestVehicle.configFileName or bestVehicle.typeName or "vehicle")
                        Logging.info(
                            "[UniversalConveyorHelper][VEHICLE_DETECT] Kandidat im Bereich | Förderband=%s | Objekt=%s | Abstand=%.2fm | BandPunkt=%s | Hinweis=FillUnit vorhanden, Entladeeignung wird separat geprüft",
                            conveyorName,
                            vehicleName,
                            bestDistance,
                            tostring(bestSource)
                        )
                        conveyor.uchDetectedVehicleKey = key
                        conveyor.uchDetectedVehicleDistance = bestDistance
                    end
                else
                    if conveyor.uchDetectedVehicleKey ~= nil then
                        local conveyorName = tostring(conveyor.configFileNameClean or conveyor.configFileName or conveyor.typeName or "conveyor")
                        Logging.info(
                            "[UniversalConveyorHelper][VEHICLE_DETECT] Kandidat nicht mehr im Bereich | Förderband=%s | letzterAbstand=%.2fm",
                            conveyorName,
                            tonumber(conveyor.uchDetectedVehicleDistance) or -1
                        )
                    end
                    conveyor.uchDetectedVehicleKey = nil
                    conveyor.uchDetectedVehicleDistance = nil
                end
            end
        end
    end

    if not self.managerLogged then
        self.managerLogged = true
        Logging.info("[UniversalConveyorHelper][VEHICLE_DETECT] Manager aktiv | Radius=%.1fm | erkannte Fahrzeuge=%d", self.RADIUS, detectedCount)
    end
end



function UniversalConveyorVehicleDetection:reset()
    self.timer = 1000
    self.managerLogged = false
    self.structureLogged = false
end

function UniversalConveyorVehicleDetection:update(dt)
    if g_currentMission == nil then
        return
    end

    local delta = dt or 0
    self.timer = (self.timer or 0) - delta

    if self.timer <= 0 then
        self.timer = self.INTERVAL
        self:detect()
    end
end
