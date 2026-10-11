-- FS25 Universal Conveyor Helper 1.9.81.1
-- Conveyor speed limits and speed diagnostics.
-- Refactor only: behavior intentionally unchanged.

-- UCH helper: logging local to this module.
local function logInfo(message, ...)
    Logging.info("[UniversalConveyorHelper] " .. string.format(message, ...))
end

local function logError(message, ...)
    Logging.error("[UniversalConveyorHelper] " .. string.format(message, ...))
end

-- -------------------------------------------------------------------------
-- Runtime speed cap for shop-category conveyor belts only.
-- The two reference conveyor mods use motorized maxForwardSpeed/maxBackwardSpeed
-- values of 25 km/h in their XML. GIANTS stores these motor values in m/s.
-- This reuses the existing global vehicle-list pass; no additional scan is added.
-- -------------------------------------------------------------------------

UniversalConveyorHelper.CONVEYOR_MAX_SPEED_KMH = 25

function UniversalConveyorHelper:applyConveyorSpeedLimit(vehicle)
    if vehicle == nil or vehicle.spec_motorized == nil then
        return false
    end

    -- Apply only to recognized conveyors in the actual shop category "belts".
    if not self:isConveyorVehicle(vehicle) then
        return false
    end

    local eligible, reason = self:isShopCategoryConveyorBelt(vehicle)
    if not eligible then
        return false
    end

    local motor = vehicle.spec_motorized.motor
    if motor == nil then
        if not vehicle.uchSpeedLimitMissingMotorLogged then
            vehicle.uchSpeedLimitMissingMotorLogged = true
            logInfo("[SPEED_LIMIT] übersprungen | Fahrzeug=%s | Grund=spec_motorized.motor fehlt",
                tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"))
        end
        return false
    end

    if vehicle.uchConveyorSpeedLimitApplied then
        return true
    end

    local speedMps = UniversalConveyorHelper.CONVEYOR_MAX_SPEED_KMH / 3.6
    local oldForward = tonumber(motor.maxForwardSpeed)
    local oldBackward = tonumber(motor.maxBackwardSpeed)
    local oldMinForwardRatio = tonumber(motor.minForwardGearRatio)
    local oldMinBackwardRatio = tonumber(motor.minBackwardGearRatio)

    -- Some conveyor vehicles expose a 25 km/h reverse limiter while their
    -- backward transmission ratio still physically limits reverse speed to
    -- 5 km/h. Check the native physical maximum as well as the limiter.
    local physicalBackwardBefore = nil
    if type(motor.calculatePhysicalMaximumBackwardSpeed) == "function" then
        local ok, value = pcall(motor.calculatePhysicalMaximumBackwardSpeed, motor)
        if ok and tonumber(value) ~= nil and tonumber(value) > 0 then
            physicalBackwardBefore = tonumber(value)
        end
    end

    -- maxForwardSpeed/maxBackwardSpeed are only limiters. On the vanilla S710,
    -- the transmission's gear ratios still physically restrict the vehicle to
    -- its original 5 km/h. Scale the affected transmission ratios by the same
    -- factor as the old speed limiter so the native motor can actually reach
    -- the requested speed. Existing 25 km/h conveyor configurations remain
    -- unchanged (factor 1.0).
    local function scaleRatioField(field, factor)
        local value = tonumber(motor[field])
        if value ~= nil then
            motor[field] = value * factor
        end
        local originField = field .. "Origin"
        local originValue = tonumber(motor[originField])
        if originValue ~= nil then
            motor[originField] = originValue * factor
        end
    end

    local function scaleGearTable(gears, factor, seen)
        if type(gears) ~= "table" or seen[gears] then
            return
        end
        seen[gears] = true
        for _, gear in pairs(gears) do
            if type(gear) == "table" and tonumber(gear.ratio) ~= nil then
                gear.ratio = gear.ratio * factor
            end
        end
    end

    local forwardFactor = 1
    if oldForward ~= nil and oldForward > 0 and oldForward < speedMps then
        forwardFactor = oldForward / speedMps
    end
    local backwardFactor = 1
    if oldBackward ~= nil and oldBackward > 0 and oldBackward < speedMps then
        backwardFactor = oldBackward / speedMps
    end
    -- The reverse limiter may already be 25 km/h even though the native
    -- transmission can only reach 5 km/h. In that case derive the ratio
    -- correction from the physical maximum instead of trusting the limiter.
    if physicalBackwardBefore ~= nil and physicalBackwardBefore < speedMps then
        backwardFactor = math.min(backwardFactor, physicalBackwardBefore / speedMps)
    end

    if forwardFactor < 0.999 then
        scaleRatioField("minForwardGearRatio", forwardFactor)
        scaleRatioField("maxForwardGearRatio", forwardFactor)
        scaleRatioField("minGearRatio", forwardFactor)
        scaleRatioField("maxGearRatio", forwardFactor)
    end
    if backwardFactor < 0.999 then
        scaleRatioField("minBackwardGearRatio", backwardFactor)
        scaleRatioField("maxBackwardGearRatio", backwardFactor)
    end

    local seenGearTables = {}
    -- FS25 can use the same forwardGears table for reverse when backwardGears
    -- is nil (or when both references point to the same table). The previous
    -- order marked that shared table as processed with forwardFactor=1 before
    -- reverse could scale it, so the calculated physical maximum increased
    -- while the actual gear ratios stayed unchanged. Apply the stricter factor
    -- once to a shared table; the 25 km/h motor limiter still caps forward speed.
    local sharedDirectionGears = motor.forwardGears ~= nil
        and (motor.backwardGears == nil or motor.backwardGears == motor.forwardGears)
    if sharedDirectionGears then
        scaleGearTable(motor.forwardGears, math.min(forwardFactor, backwardFactor), seenGearTables)
    else
        scaleGearTable(motor.forwardGears, forwardFactor, seenGearTables)
        scaleGearTable(motor.backwardGears, backwardFactor, seenGearTables)
    end
    scaleGearTable(motor.currentGears, motor.currentDirection ~= nil and motor.currentDirection < 0 and backwardFactor or forwardFactor, seenGearTables)

    motor.maxForwardSpeed = speedMps
    motor.maxBackwardSpeed = speedMps
    if motor.maxForwardSpeedOrigin ~= nil then
        motor.maxForwardSpeedOrigin = speedMps
    end
    if motor.maxBackwardSpeedOrigin ~= nil then
        motor.maxBackwardSpeedOrigin = speedMps
    end

    vehicle.uchConveyorSpeedLimitApplied = true
    local physicalBackwardAfter = nil
    if type(motor.calculatePhysicalMaximumBackwardSpeed) == "function" then
        local ok, value = pcall(motor.calculatePhysicalMaximumBackwardSpeed, motor)
        if ok and tonumber(value) ~= nil then
            physicalBackwardAfter = tonumber(value)
        end
    end
    logInfo("[SPEED_LIMIT] gesetzt | Fahrzeug=%s | Kategorie=belts | vorwärts %.2f->%.2f m/s | rückwärts %.2f->%.2f m/s | Übersetzung vorwärts %.3f | rückwärts %.3f | physRueckwaerts %.2f->%.2f m/s | minRatio %.3f->%.3f / %.3f->%.3f | Ziel=%d km/h",
        tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"),
        oldForward or -1,
        speedMps,
        oldBackward or -1,
        speedMps,
        forwardFactor,
        backwardFactor,
        physicalBackwardBefore or -1,
        physicalBackwardAfter or -1,
        oldMinForwardRatio or -1,
        tonumber(motor.minForwardGearRatio) or -1,
        oldMinBackwardRatio or -1,
        tonumber(motor.minBackwardGearRatio) or -1,
        UniversalConveyorHelper.CONVEYOR_MAX_SPEED_KMH)
    return true
end

-- Temporary AutoDrive-target compatibility diagnostics.
-- AutoDrive's TrailerModule calls the unloading vehicle's native
-- getCanDischargeToObject(currentDischargeNode). This log records whether a
-- conveyor exposes the native fill-volume/fill-unit structure needed to be a
-- valid target; it deliberately does not modify AutoDrive or vehicle specs.
function UniversalConveyorHelper:logAutoDriveTargetDiagnostics(vehicle)
    if vehicle == nil or vehicle.uchADTargetDiagLogged then
        return
    end
    if not self:isConveyorVehicle(vehicle) then
        return
    end
    local eligible, reason = self:isShopCategoryConveyorBelt(vehicle)
    if not eligible then
        return
    end

    vehicle.uchADTargetDiagLogged = true
    local fillUnitSpec = vehicle.spec_fillUnit
    local fillVolumeSpec = vehicle.spec_fillVolume
    local dischargeSpec = vehicle.spec_dischargeable
    local conveyorSpec = vehicle.spec_conveyorBelt
    local function safeCall(object, method, ...)
        if object == nil or type(object[method]) ~= "function" then
            return nil
        end
        local ok, a, b = pcall(object[method], object, ...)
        if ok then return a, b end
        return nil
    end
    local currentNode = safeCall(vehicle, "getCurrentDischargeNode")
    local targetObject = safeCall(vehicle, "getConveyorBeltTargetObject")
    local fillUnits = safeCall(vehicle, "getFillUnits")
    local fillUnitCount = type(fillUnits) == "table" and #fillUnits or 0
    local capacity = safeCall(vehicle, "getFillUnitCapacity", 1)
    local fillLevel = safeCall(vehicle, "getFillUnitFillLevel", 1)
    local freeCapacity = safeCall(vehicle, "getFillUnitFreeCapacity", 1)
    local hasTrailerTrigger = vehicle.i3dMappings ~= nil and vehicle.i3dMappings.trailerTrigger ~= nil

    logInfo("[AUTODRIVE_TARGET][STRUCTURE] Fahrzeug=%s | Kategorie=belts | type=%s | spec_fillUnit=%s | spec_fillVolume=%s | spec_dischargeable=%s | spec_conveyorBelt=%s | fillUnits=%d | capacity=%s | fillLevel=%s | freeCapacity=%s | currentDischargeNode=%s | getCanDischargeToObject=%s | getConveyorBeltTargetObject=%s | currentTarget=%s | trailerTriggerMapping=%s | getFillUnitFreeCapacity=%s",
        tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"),
        tostring(vehicle.typeName or "unknown"),
        tostring(fillUnitSpec ~= nil),
        tostring(fillVolumeSpec ~= nil),
        tostring(dischargeSpec ~= nil),
        tostring(conveyorSpec ~= nil),
        fillUnitCount,
        tostring(capacity),
        tostring(fillLevel),
        tostring(freeCapacity),
        tostring(currentNode ~= nil),
        tostring(type(vehicle.getCanDischargeToObject) == "function"),
        tostring(type(vehicle.getConveyorBeltTargetObject) == "function"),
        tostring(targetObject ~= nil),
        tostring(hasTrailerTrigger),
        tostring(type(vehicle.getFillUnitFreeCapacity) == "function"))
end

function UniversalConveyorHelper:getGlobalVehicleList()
    local result = {}
    local seen = {}

    local function addList(source)
        if source == nil then
            return
        end

        for _, vehicle in pairs(source) do
            if vehicle ~= nil and not seen[vehicle] then
                seen[vehicle] = true
                table.insert(result, vehicle)
            end
        end
    end

    if g_currentMission ~= nil then
        if g_currentMission.vehicleSystem ~= nil then
            addList(g_currentMission.vehicleSystem.vehicles)
        end
        addList(g_currentMission.vehicles)

        if g_currentMission.placeableSystem ~= nil then
            addList(g_currentMission.placeableSystem.placeables)
        end
    end

    return result
end

-- Temporary diagnostics: compare the live motor state while a conveyor is moving.
-- This function only logs values; it does not change motor, gear, or speed settings.
function UniversalConveyorHelper:logLiveSpeedDiagnostics(vehicle)
    if vehicle == nil or vehicle.spec_motorized == nil then
        return
    end
    if not self:isConveyorVehicle(vehicle) then
        return
    end
    local eligible = self:isShopCategoryConveyorBelt(vehicle)
    if not eligible then
        return
    end

    local motor = vehicle.spec_motorized.motor
    if motor == nil then
        return
    end

    local speedRaw = tonumber(vehicle.lastSpeedReal) or 0
    local speedKmh = math.abs(speedRaw) * 3.6
    if type(vehicle.getLastSpeed) == "function" then
        local ok, value = pcall(vehicle.getLastSpeed, vehicle)
        if ok and tonumber(value) ~= nil then
            speedKmh = math.abs(tonumber(value))
        end
    end
    -- Only report vehicles that are actually moving; no idle/per-frame log spam.
    if speedKmh < 1 then
        return
    end

    local now = g_time or 0
    local last = tonumber(vehicle.uchLiveSpeedDiagLastTime) or -10000
    if now - last < 1000 then
        return
    end
    vehicle.uchLiveSpeedDiagLastTime = now

    local function safeCall(object, method)
        if object == nil or type(object[method]) ~= "function" then
            return nil
        end
        local ok, value = pcall(object[method], object)
        if ok then return value end
        return nil
    end
    local function num(value)
        local n = tonumber(value)
        return n ~= nil and string.format("%.3f", n) or "nil"
    end
    local physicalBackward = safeCall(motor, "calculatePhysicalMaximumBackwardSpeed")
    local maxBackward = safeCall(motor, "getMaximumBackwardSpeed") or motor.maxBackwardSpeed
    local maxForward = safeCall(motor, "getMaximumForwardSpeed") or motor.maxForwardSpeed
    local gearRatio = safeCall(motor, "getGearRatio") or motor.gearRatio
    local driveDirection = safeCall(motor, "getDrivingDirection")
    local lastSpeedFromMethod = safeCall(vehicle, "getLastSpeed")

    logInfo("[SPEED_DIAG][LIVE] Fahrzeug=%s | speedKmh=%.2f | lastSpeedReal=%s | getLastSpeed=%s | movingDirection=%s | driveDirection=%s | currentDirection=%s | transmissionDirection=%s | gear=%s | targetGear=%s | gearRatio=%s | maxForward=%s | maxBackward=%s | speedLimit=%s | speedLimitAcc=%s | rpmLimit=%s | maxRpm=%s | lastMotorRpm=%s | physicalBackward=%s | minBackwardRatio=%s | maxBackwardRatio=%s | minGearRatio=%s | maxGearRatio=%s | backwardGears=%s | forwardGears=%s",
        tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"),
        speedKmh,
        num(speedRaw),
        num(lastSpeedFromMethod),
        num(vehicle.movingDirection),
        num(driveDirection),
        num(motor.currentDirection),
        num(motor.transmissionDirection),
        tostring(motor.gear),
        tostring(motor.targetGear),
        num(gearRatio),
        num(maxForward),
        num(maxBackward),
        num(motor.speedLimit),
        num(motor.speedLimitAcc),
        num(motor.rpmLimit),
        num(motor.maxRpm),
        num(motor.lastRealMotorRpm),
        num(physicalBackward),
        num(motor.minBackwardGearRatio),
        num(motor.maxBackwardGearRatio),
        num(motor.minGearRatio),
        num(motor.maxGearRatio),
        type(motor.backwardGears) == "table" and tostring(#motor.backwardGears) or "nil",
        type(motor.forwardGears) == "table" and tostring(#motor.forwardGears) or "nil")
end

-- FS25 exposes a separate live motor.speedLimit in addition to the
-- maxBackwardSpeed gearbox limit. The diagnostic log showed this value being
-- set to 5 km/h only while reversing, even after the physical reverse speed
-- and maxBackwardSpeed had been raised to 25 km/h. Raise only that active
-- limit for recognized conveyors while moving backwards; forward behavior is
-- untouched. The engine may refresh the live limit, so this is rechecked by
-- the existing conveyor manager loop.
-- GIANTS or another vehicle-control path can reapply a low live speedLimit
-- through VehicleMotor:setSpeedLimit while reversing. The 500 ms manager pass
-- sees the value reset to 5 km/h, so clamp at the setter source, but only for
-- UCH-recognized conveyor vehicles in the actual shop category "belts".
-- This does not alter other vehicles or the forward speed limit.
function UniversalConveyorHelper:installReverseSpeedLimitSetterHook()
    if self.reverseSpeedLimitSetterHookInstalled then
        return true
    end
    if VehicleMotor == nil or type(VehicleMotor.setSpeedLimit) ~= "function" then
        return false
    end

    local originalSetSpeedLimit = VehicleMotor.setSpeedLimit
    VehicleMotor.setSpeedLimit = function(motor, limit)
        originalSetSpeedLimit(motor, limit)

        local vehicle = motor ~= nil and motor.vehicle or nil
        if vehicle == nil or vehicle.uchConveyorSpeedLimitApplied ~= true then
            return
        end
        if vehicle.movingDirection == nil or vehicle.movingDirection >= 0 then
            return
        end
        if UniversalConveyorHelper == nil
            or not UniversalConveyorHelper:isConveyorVehicle(vehicle)
            or not UniversalConveyorHelper:isShopCategoryConveyorBelt(vehicle) then
            return
        end

        local targetKmh = UniversalConveyorHelper.CONVEYOR_MAX_SPEED_KMH or 25
        local currentLimit = tonumber(motor.speedLimit)
        if currentLimit ~= nil and currentLimit < targetKmh then
            motor.speedLimit = targetKmh
            local now = g_time or 0
            local last = tonumber(vehicle.uchReverseSetterHookLogTime) or -10000
            if now - last >= 1000 then
                vehicle.uchReverseSetterHookLogTime = now
                logInfo("[SPEED_LIMIT][REVERSE_SETTER] live Limit nach nativer Setzung korrigiert | Fahrzeug=%s | angefordert=%.2f km/h | aktiv=%.2f km/h | movingDirection=%.1f",
                    tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"),
                    tonumber(limit) or -1, currentLimit, tonumber(vehicle.movingDirection) or 0)
            end
        end
    end

    self.reverseSpeedLimitSetterHookInstalled = true
    logInfo("[SPEED_LIMIT][REVERSE_SETTER] VehicleMotor.setSpeedLimit Hook installiert | nur erkannte belts bei Rückwärtsfahrt")
    return true
end

function UniversalConveyorHelper:applyConveyorReverseSpeedLimit(vehicle)
    if vehicle == nil or vehicle.spec_motorized == nil or vehicle.movingDirection == nil or vehicle.movingDirection >= 0 then
        return false
    end
    if not vehicle.uchConveyorSpeedLimitApplied or not self:isConveyorVehicle(vehicle) then
        return false
    end
    local eligible = self:isShopCategoryConveyorBelt(vehicle)
    if not eligible then
        return false
    end
    local motor = vehicle.spec_motorized.motor
    if motor == nil then
        return false
    end

    local targetKmh = UniversalConveyorHelper.CONVEYOR_MAX_SPEED_KMH
    local currentLimit = tonumber(motor.speedLimit)
    if currentLimit ~= nil and currentLimit < targetKmh then
        motor.speedLimit = targetKmh
        local now = g_time or 0
        local last = tonumber(vehicle.uchReverseSpeedLimitLogTime) or -10000
        if now - last >= 1000 then
            vehicle.uchReverseSpeedLimitLogTime = now
            logInfo("[SPEED_LIMIT][REVERSE] aktives Limit angehoben | Fahrzeug=%s | vorher=%.2f km/h | nachher=%.2f km/h | movingDirection=%.1f",
                tostring(vehicle.configFileName or vehicle.configFileNameClean or vehicle.typeName or "unknown"),
                currentLimit, targetKmh, tonumber(vehicle.movingDirection) or 0)
        end
        return true
    end
    return false
end
