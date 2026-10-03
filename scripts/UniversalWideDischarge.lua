-- FS25 Universal Conveyor Helper 1.8.0
-- Robust automatic discharge for conveyors including S710.

UniversalWideDischarge = {}
UniversalWideDischarge.SEARCH_RADIUS = 12.0
UniversalWideDischarge.TRANSFER_LITERS_PER_SEC = 800
UniversalWideDischarge.OWN_FILL_UNIT_INDEX = 1
UniversalWideDischarge.DEBUG = true
UniversalWideDischarge.GLOBAL_INTERVAL = 250
UniversalWideDischarge.GLOBAL_LOCAL_GUARD = 125

local function debugState(vehicle, state, details)
    if not UniversalWideDischarge.DEBUG or vehicle == nil then return end
    if vehicle.uchWideDischargeDebugState == state then return end
    vehicle.uchWideDischargeDebugState = state
    local name = tostring(vehicle.configFileNameClean or vehicle.configFileName or vehicle.typeName or "source")
    Logging.info("[UniversalConveyorHelper][DISCHARGE][DEBUG] %s | state=%s%s", name, tostring(state), details ~= nil and (" | " .. tostring(details)) or "")
end

function UniversalWideDischarge.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Dischargeable, specializations)
        and SpecializationUtil.hasSpecialization(FillUnit, specializations)
end

function UniversalWideDischarge.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", UniversalWideDischarge)
end

function UniversalWideDischarge:onUpdate(dt)
    if g_universalConveyorSettings ~= nil and g_universalConveyorSettings.registerRuntimeVehicle ~= nil then
        g_universalConveyorSettings:registerRuntimeVehicle(self)
    end
    if not self.isServer or self.uchWideDischargeDisabled then return end

    -- The global helper also executes discharge for culled/uncontrolled conveyors.
    -- Avoid doing the exact same transfer twice in the same short window.
    local now = g_currentMission ~= nil and g_currentMission.time or 0
    if self.uchWideDischargeGlobalTick ~= nil
        and now - self.uchWideDischargeGlobalTick < UniversalWideDischarge.GLOBAL_LOCAL_GUARD
    then
        return
    end

    local ok, err = pcall(UniversalWideDischarge.doUpdate, self, dt)
    if not ok then
        self.uchWideDischargeDisabled = true
        Logging.error("[UniversalConveyorHelper][DISCHARGE] Fehler, Funktion wird für dieses Fahrzeug deaktiviert: " .. tostring(err))
    end
end

function UniversalWideDischarge:doGlobalUpdate(vehicle)
    if vehicle == nil or not vehicle.isServer or vehicle.uchWideDischargeDisabled then
        return
    end

    local now = g_currentMission ~= nil and g_currentMission.time or 0
    local last = vehicle.uchWideDischargeGlobalTick
    if last == nil then
        vehicle.uchWideDischargeGlobalTick = now
        return
    end

    local elapsed = now - last
    if elapsed < UniversalWideDischarge.GLOBAL_INTERVAL then
        return
    end

    -- Mark before execution so a local onUpdate cannot immediately duplicate it.
    vehicle.uchWideDischargeGlobalTick = now

    local ok, err = pcall(UniversalWideDischarge.doUpdate, vehicle, elapsed)
    if not ok then
        vehicle.uchWideDischargeDisabled = true
        Logging.error("[UniversalConveyorHelper][DISCHARGE][GLOBAL] Fehler, Funktion wird für dieses Fahrzeug deaktiviert: " .. tostring(err))
    end
end

local function collectVehicles()
    local result = {}
    local seen = {}

    local function addVehicle(v)
        if v == nil or seen[v] then return end
        seen[v] = true
        table.insert(result, v)

        -- Attached trailers/implements can be omitted from the active vehicle list
        -- until a player enters the towing vehicle. Recursively add them here so
        -- the conveyor target is independent of player control state.
        -- Traverse attached implements through both the public method and the
        -- raw attachment table. Some parked vehicles only expose one of these
        -- before they become player-controlled.
        if v.getAttachedImplements ~= nil then
            local ok, implements = pcall(v.getAttachedImplements, v)
            if ok and implements ~= nil then
                for _, implementData in pairs(implements) do
                    local object = implementData ~= nil and implementData.object or nil
                    if object ~= nil then
                        addVehicle(object)
                    end
                end
            end
        end

        local attached = v.attachedImplements
        if type(attached) == "table" then
            for _, implementData in pairs(attached) do
                local object = implementData ~= nil and implementData.object or nil
                if object ~= nil then
                    addVehicle(object)
                end
            end
        end

        if v.spec_attacherJoints ~= nil and type(v.spec_attacherJoints.attachedImplements) == "table" then
            for _, implementData in pairs(v.spec_attacherJoints.attachedImplements) do
                local object = implementData ~= nil and implementData.object or nil
                if object ~= nil then
                    addVehicle(object)
                end
            end
        end

        if v.getAttacherVehicle ~= nil then
            local ok, parent = pcall(v.getAttacherVehicle, v)
            if ok and parent ~= nil then
                addVehicle(parent)
            end
        elseif v.attacherVehicle ~= nil then
            addVehicle(v.attacherVehicle)
        end
    end

    local function addList(list)
        if list == nil then return end
        for _, v in pairs(list) do
            addVehicle(v)
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

local function getFillUnitCompatibility(vehicle, fillUnitIndex, wantedFillType)
    if vehicle == nil or vehicle.spec_fillUnit == nil or vehicle.spec_fillUnit.fillUnits == nil then
        return false, 0, "noFillUnit", nil
    end

    local fillUnit = vehicle.spec_fillUnit.fillUnits[fillUnitIndex]
    if fillUnit == nil then
        return false, 0, "missingFillUnit", nil
    end

    local free = 0
    local capacitySource = "api"
    if vehicle.getFillUnitFreeCapacity ~= nil then
        local okCapacity, result = pcall(vehicle.getFillUnitFreeCapacity, vehicle, fillUnitIndex)
        if okCapacity and result ~= nil then
            free = math.max(0, result)
        end
    end

    -- Some trailers report 0 free capacity until they are player-controlled.
    -- Fall back to the actual FillUnit capacity/fillLevel stored on the spec.
    if free <= 0 then
        local capacity = tonumber(fillUnit.capacity)
        local currentLevel = tonumber(fillUnit.fillLevel)
        if capacity ~= nil and currentLevel ~= nil and capacity > currentLevel then
            free = capacity - currentLevel
            capacitySource = "spec"
        end
    end

    if free <= 0 then
        return false, 0, "noCapacity", capacitySource
    end

    local supports = nil
    local supportSource = "api"
    if vehicle.getFillUnitSupportsFillType ~= nil then
        local okSupports, resultSupports = pcall(vehicle.getFillUnitSupportsFillType, vehicle, fillUnitIndex, wantedFillType)
        if okSupports then
            supports = resultSupports == true
        end
    end

    -- Check the raw supportedFillTypes table as a second source of truth.
    if supports ~= true and type(fillUnit.supportedFillTypes) == "table" then
        if fillUnit.supportedFillTypes[wantedFillType] ~= nil then
            supports = fillUnit.supportedFillTypes[wantedFillType] == true or fillUnit.supportedFillTypes[wantedFillType] ~= 0
            supportSource = "spec"
        end
    end

    local currentType = nil
    if vehicle.getFillUnitFillType ~= nil then
        local okType, resultType = pcall(vehicle.getFillUnitFillType, vehicle, fillUnitIndex)
        if okType then
            currentType = resultType
        end
    end
    if currentType == nil then
        currentType = fillUnit.fillType
    end

    if supports ~= true and (currentType == nil or currentType == FillType.UNKNOWN or currentType == wantedFillType) then
        -- Only use the conservative fallback for a real discharge-capable target.
        if vehicle.spec_dischargeable ~= nil then
            supports = true
            supportSource = "dischargeFallback"
        end
    end

    local state = supports == true and "compatible" or "incompatible"
    return supports == true, free, state .. ":support=" .. tostring(supportSource) .. ":capacity=" .. tostring(capacitySource), currentType
end

function UniversalWideDischarge.doUpdate(self, dt)
    if g_universalConveyorSettings ~= nil and not g_universalConveyorSettings:isEnabled(self) then
        debugState(self, "disabledBySettings")
        return
    end
    if self.getIsTurnedOn == nil or not self:getIsTurnedOn() then
        debugState(self, "off")
        return
    end

    local ownFillUnitIndex = UniversalWideDischarge.OWN_FILL_UNIT_INDEX
    local fillLevel = self:getFillUnitFillLevel(ownFillUnitIndex)
    if fillLevel == nil or fillLevel <= 0 then
        debugState(self, "empty", "fillLevel=" .. tostring(fillLevel))
        return
    end

    local fillType = self:getFillUnitFillType(ownFillUnitIndex)
    if fillType == nil or fillType == FillType.UNKNOWN then
        debugState(self, "unknownFillType", "fillType=" .. tostring(fillType))
        return
    end

    local dischargeSpec = self.spec_dischargeable
    if dischargeSpec == nil or dischargeSpec.dischargeNodes == nil or dischargeSpec.dischargeNodes[1] == nil then
        debugState(self, "noDischargeNode")
        return
    end
    local dischargeNode = dischargeSpec.dischargeNodes[1].node
    if dischargeNode == nil then
        debugState(self, "noDischargeNode")
        return
    end

    local dx, dy, dz = getWorldTranslation(dischargeNode)
    local vehicles = collectVehicles()
    if #vehicles == 0 then
        debugState(self, "noVehicleList")
        return
    end

    local bestTarget, bestFillUnitIndex, bestDistance, bestFree = nil, nil, math.huge, 0
    local nearCount, fillUnitCount, compatibleCount = 0, 0, 0
    local firstNearName, firstNearDistance, firstNearState, firstNearFree, firstNearType = nil, nil, nil, nil, nil

    for _, vehicle in ipairs(vehicles) do
        if vehicle ~= self and vehicle.rootNode ~= nil and vehicle.spec_fillUnit ~= nil and vehicle.spec_fillUnit.fillUnits ~= nil then
            local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
            local distance = MathUtil.vector3Length(vx - dx, vy - dy, vz - dz)

            -- A trailer's root node can sit several metres away from its actual
            -- loading area. Also consider its fill-unit nodes when available.
            local bestVehicleDistance = distance
            if vehicle.spec_fillUnit.fillUnits ~= nil then
                for fillUnitIndex, fillUnit in pairs(vehicle.spec_fillUnit.fillUnits) do
                    local node = fillUnit ~= nil and (fillUnit.exactFillRootNode or fillUnit.fillNode) or nil
                    if node ~= nil and getWorldTranslation ~= nil then
                        local fx, fy, fz = getWorldTranslation(node)
                        local d = MathUtil.vector3Length(fx - dx, fy - dy, fz - dz)
                        if d < bestVehicleDistance then
                            bestVehicleDistance = d
                        end
                    end
                end
            end
            distance = bestVehicleDistance
            if distance <= UniversalWideDischarge.SEARCH_RADIUS then
                nearCount = nearCount + 1
                if firstNearName == nil then
                    firstNearName = tostring(vehicle.configFileNameClean or vehicle.configFileName or vehicle.typeName or "target")
                    firstNearDistance = distance
                end
                for fillUnitIndex, _ in ipairs(vehicle.spec_fillUnit.fillUnits) do
                    fillUnitCount = fillUnitCount + 1
                    local compatible, freeCapacity, compatibilityState, currentType = getFillUnitCompatibility(vehicle, fillUnitIndex, fillType)

                    -- A tractor can have a fuel fillUnit near the conveyor.
                    -- Only consider it as a material target when the vehicle is
                    -- actually discharge-capable or the fillUnit explicitly
                    -- accepts this material.
                    if compatible and currentType ~= nil and currentType ~= FillType.UNKNOWN and currentType ~= fillType then
                        compatible = false
                        compatibilityState = compatibilityState .. ":currentTypeMismatch"
                    end
                    if firstNearName ~= nil and firstNearState == nil then
                        firstNearState = compatibilityState
                        firstNearFree = freeCapacity
                        firstNearType = currentType
                    end
                    if compatible then
                        compatibleCount = compatibleCount + 1
                        if distance < bestDistance then
                            bestTarget = vehicle
                            bestFillUnitIndex = fillUnitIndex
                            bestDistance = distance
                            bestFree = freeCapacity
                        end
                    end
                end
            end
        end
    end

    if bestTarget == nil or bestFillUnitIndex == nil then
        debugState(self, "noTarget", string.format("fillType=%s | radius=%.1f | vehicles=%d | near=%d | fillUnits=%d | compatible=%d | controlled=%s | candidate=%s | candidateDist=%.2f | candidateFree=%.1f | candidateState=%s | candidateFillType=%s", tostring(fillType), UniversalWideDischarge.SEARCH_RADIUS, #vehicles, nearCount, fillUnitCount, compatibleCount, tostring(g_currentMission ~= nil and g_currentMission.controlledVehicle ~= nil), tostring(firstNearName), tonumber(firstNearDistance or -1), tonumber(firstNearFree or -1), tostring(firstNearState), tostring(firstNearType)))
        return
    end

    local delta = math.min(fillLevel, UniversalWideDischarge.TRANSFER_LITERS_PER_SEC * dt / 1000, bestFree)
    if delta <= 0 then
        debugState(self, "zeroDelta", "fillLevel=" .. tostring(fillLevel) .. " | free=" .. tostring(bestFree))
        return
    end

    local farmId = self:getOwnerFarmId()
    local sourceBefore = fillLevel
    local targetBefore = bestTarget:getFillUnitFillLevel(bestFillUnitIndex) or 0

    local sourceCallOk = pcall(self.addFillUnitFillLevel, self, farmId, ownFillUnitIndex, -delta, fillType, ToolType.UNDEFINED, nil)
    if not sourceCallOk then
        debugState(self, "sourceTransferFailed")
        return
    end

    local targetCallOk, targetCallResult = pcall(bestTarget.addFillUnitFillLevel, bestTarget, farmId, bestFillUnitIndex, delta, fillType, ToolType.UNDEFINED, nil)
    local targetAfter = bestTarget:getFillUnitFillLevel(bestFillUnitIndex) or targetBefore
    local sourceAfter = self:getFillUnitFillLevel(ownFillUnitIndex) or sourceBefore

    if not targetCallOk or targetCallResult == false or targetAfter <= targetBefore + 0.001 then
        pcall(self.addFillUnitFillLevel, self, farmId, ownFillUnitIndex, delta, fillType, ToolType.UNDEFINED, nil)
        debugState(self, "targetTransferFailed", string.format("targetCall=%s | before=%.1f | after=%.1f | sourceBefore=%.1f | sourceAfter=%.1f", tostring(targetCallOk), targetBefore, targetAfter, sourceBefore, sourceAfter))
        return
    end

    if sourceAfter >= sourceBefore - 0.001 then
        debugState(self, "sourceNotReduced", string.format("before=%.1f | after=%.1f | targetBefore=%.1f | targetAfter=%.1f", sourceBefore, sourceAfter, targetBefore, targetAfter))
        return
    end

    if g_currentMission.time ~= nil and (self.uchWideDischargeLastLog or 0) + 1000 < g_currentMission.time then
        self.uchWideDischargeLastLog = g_currentMission.time
        Logging.info("[UniversalConveyorHelper][DISCHARGE] ERFOLG: %s -> %s | Abstand=%.2fm | Menge=%.1f | fillType=%s | ZielVorher=%.1f | ZielNachher=%.1f",
            tostring(self.configFileNameClean or self.configFileName or self.typeName or "source"),
            tostring(bestTarget.configFileNameClean or bestTarget.configFileName or bestTarget.typeName or "target"),
            bestDistance, delta, tostring(fillType), targetBefore, targetAfter)
    end
end
