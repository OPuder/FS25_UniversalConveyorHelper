-- FS25 Universal Conveyor Helper 1.9.68
-- Universal helper for automatic conveyor start, extended discharge range and per-conveyor settings.
-- Specializations are registered manually, following the proven FS25 pattern.

UniversalConveyorHelper = {}
UniversalConveyorHelper.VERSION = "1.9.80.6"
UniversalConveyorHelper.AUTO_START = true
UniversalConveyorHelper.EXTENDED_DISCHARGE = true
UniversalConveyorHelper.DEBUG = true
UniversalConveyorHelper.GLOBAL_START_INTERVAL = 500
UniversalConveyorHelper.GLOBAL_DISCHARGE_INTERVAL = 250
UniversalConveyorHelper.globalStartTimer = 1000
UniversalConveyorHelper.globalDischargeTimer = 1000
UniversalConveyorHelper.globalStartLogged = false
UniversalConveyorHelper.globalDischargeLogged = false
UniversalConveyorHelper.startupLogFinished = false
UniversalConveyorHelper.startupUpdateCount = 0

local MOD_NAME = g_currentModName or "FS25_UniversalConveyorHelper"

-- The specialization manager uses the short registration name, while the
-- vehicle type injection uses the fully qualified mod-specific name.
UniversalConveyorHelper.AUTO_REG_NAME = "uchAutoTurnOn"
UniversalConveyorHelper.DISCHARGE_REG_NAME = "uchWideDischarge"
UniversalConveyorHelper.AUTO_SPEC_NAME = MOD_NAME .. "." .. UniversalConveyorHelper.AUTO_REG_NAME
UniversalConveyorHelper.DISCHARGE_SPEC_NAME = MOD_NAME .. "." .. UniversalConveyorHelper.DISCHARGE_REG_NAME

local function logInfo(message, ...)
    Logging.info("[UniversalConveyorHelper] " .. string.format(message, ...))
end

local function logError(message, ...)
    Logging.error("[UniversalConveyorHelper] " .. string.format(message, ...))
end

logInfo("[LOAD] Universal Conveyor Helper %s geladen | mod=%s", UniversalConveyorHelper.VERSION, tostring(MOD_NAME))

-- -------------------------------------------------------------------------
-- Manual specialization registration
-- -------------------------------------------------------------------------

local function registerSpecialization(regName, className, filename)
    if g_specializationManager == nil then
        logError("[LOAD] g_specializationManager fehlt")
        return false
    end

    local existing = nil
    if g_specializationManager.getSpecializationByName ~= nil then
        existing = g_specializationManager:getSpecializationByName(regName)
    end

    if existing ~= nil then
        logInfo("[LOAD] Spezialisierung bereits registriert: %s", regName)
        return true
    end

    local ok, err = pcall(function()
        g_specializationManager:addSpecialization(
            regName,
            className,
            Utils.getFilename(filename, g_currentModDirectory),
            nil
        )
    end)

    if not ok then
        logError("[LOAD] Registrierung fehlgeschlagen: %s | %s", regName, tostring(err))
        return false
    end

    local found = nil
    if g_specializationManager.getSpecializationByName ~= nil then
        found = g_specializationManager:getSpecializationByName(regName)
    end
    if found == nil and g_specializationManager.getSpecializationObjectByName ~= nil then
        found = g_specializationManager:getSpecializationObjectByName(regName)
    end

    if found ~= nil then
        logInfo("[LOAD] Spezialisierung registriert: %s -> %s", regName, className)
        return true
    end

    logError("[LOAD] Spezialisierung nach Registrierung nicht auffindbar: %s", regName)
    return false
end

local autoSpecRegistered = registerSpecialization(
    UniversalConveyorHelper.AUTO_REG_NAME,
    "UniversalAutoTurnOn",
    "scripts/UniversalAutoTurnOn.lua"
)

local dischargeSpecRegistered = registerSpecialization(
    UniversalConveyorHelper.DISCHARGE_REG_NAME,
    "UniversalWideDischarge",
    "scripts/UniversalWideDischarge.lua"
)

-- S710 ships a second AutoTurnOn specialization. Install our compatibility
-- bridge as soon as the original specialization is available.
if UniversalAutoTurnOn ~= nil and UniversalAutoTurnOn.installS710Bridge ~= nil then
    UniversalAutoTurnOn.installS710Bridge()
end

-- -------------------------------------------------------------------------
-- Vehicle type detection
-- -------------------------------------------------------------------------

local function hasSpecialization(typeDef, wantedName)
    if typeDef == nil or typeDef.specializationsByName == nil then
        return false
    end

    local wantedLower = string.lower(wantedName)
    for specName, _ in pairs(typeDef.specializationsByName) do
        if string.lower(tostring(specName)) == wantedLower then
            return true
        end
    end

    return false
end

local function isConveyorType(typeName, typeDef)
    local lowerTypeName = string.lower(tostring(typeName or ""))

    -- Most base/mobile conveyors use a conveyor-specific vehicle type.
    if string.find(lowerTypeName, "conveyor", 1, true) ~= nil then
        return true
    end

    -- Cover custom vehicle types that do not contain "conveyor" in the type name.
    if hasSpecialization(typeDef, "conveyorBelt")
        or hasSpecialization(typeDef, "ConveyorBelt")
        or hasSpecialization(typeDef, "aiConveyorBelt")
        or hasSpecialization(typeDef, "AIConveyorBelt")
    then
        return true
    end

    return false
end

local function addSpecialization(typeManager, typeName, specName)
    local typeDef = typeManager.types[typeName]
    if typeDef == nil then
        return false, "missingType"
    end

    if typeDef.specializationsByName ~= nil and typeDef.specializationsByName[specName] ~= nil then
        return false, "alreadyPresent"
    end

    local ok, result = pcall(function()
        return typeManager:addSpecialization(typeName, specName)
    end)

    if not ok then
        logError("[REGISTER] Fehler bei %s -> %s: %s", tostring(typeName), tostring(specName), tostring(result))
        return false, "exception"
    end

    if result == false then
        return false, "rejected"
    end

    return true, "added"
end

function UniversalConveyorHelper:registerVehicleTypes(typeManager)
    if typeManager == nil or typeManager.typeName ~= "vehicle" then
        return
    end

    if typeManager.types == nil then
        logError("[REGISTER] typeManager.types fehlt")
        return
    end

    logInfo("[REGISTER] Starte Förderband-Type-Scan")

    local scanned = 0
    local conveyorCount = 0
    local autoCount = 0
    local dischargeCount = 0

    for typeName, typeDef in pairs(typeManager.types) do
        scanned = scanned + 1

        if isConveyorType(typeName, typeDef) then
            conveyorCount = conveyorCount + 1

            local hasTurnOn = hasSpecialization(typeDef, "turnOnVehicle")
            local hasDischarge = hasSpecialization(typeDef, "dischargeable")
            local hasFillUnit = hasSpecialization(typeDef, "fillUnit")

            logInfo("[SCAN] Förderband gefunden: %s | TurnOn=%s | Discharge=%s | FillUnit=%s",
                tostring(typeName), tostring(hasTurnOn), tostring(hasDischarge), tostring(hasFillUnit))

            if UniversalConveyorHelper.AUTO_START and autoSpecRegistered and hasTurnOn then
                local added, reason = addSpecialization(typeManager, typeName, UniversalConveyorHelper.AUTO_SPEC_NAME)
                if added or reason == "alreadyPresent" then
                    autoCount = autoCount + 1
                else
                    logError("[REGISTER] AutoStart nicht hinzugefügt: %s | Grund=%s", tostring(typeName), tostring(reason))
                end
            end

            if UniversalConveyorHelper.EXTENDED_DISCHARGE
                and dischargeSpecRegistered
                and hasDischarge
                and hasFillUnit
            then
                local added, reason = addSpecialization(typeManager, typeName, UniversalConveyorHelper.DISCHARGE_SPEC_NAME)
                if added or reason == "alreadyPresent" then
                    dischargeCount = dischargeCount + 1
                else
                    logError("[REGISTER] WideDischarge nicht hinzugefügt: %s | Grund=%s", tostring(typeName), tostring(reason))
                end
            end
        end
    end

    logInfo("[REGISTER] Scan fertig | Types=%d | FörderbandTypes=%d | AutoStart=%d | WideDischarge=%d",
        scanned, conveyorCount, autoCount, dischargeCount)
end

if TypeManager ~= nil and TypeManager.validateTypes ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
    TypeManager.finalizeTypes = Utils.prependedFunction(TypeManager.finalizeTypes, function(typeManager, ...)
        UniversalConveyorHelper:registerVehicleTypes(typeManager)
    end)
    logInfo("[HOOK] TypeManager.finalizeTypes erfolgreich registriert")
else
    logError("[HOOK] TypeManager.finalizeTypes / Utils.prependedFunction nicht verfügbar")
end



-- -------------------------------------------------------------------------
-- Global automatic-start manager
--
-- Placed conveyors can be update-culled by FS25 until the player approaches.
-- Their own specialization onUpdate/onUpdateTick is therefore not sufficient
-- for an unattended auto-start. This global listener retries the native
-- TurnOnVehicle start call independently of the conveyor's local update loop.
-- -------------------------------------------------------------------------

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

function UniversalConveyorHelper:globalStartConveyors()
    if g_currentMission == nil then
        return
    end

    if g_currentMission.isServer ~= nil and not g_currentMission.isServer then
        return
    end

    local vehicles = self:getGlobalVehicleList()
    local count = 0

    for _, vehicle in ipairs(vehicles) do
        -- Speed adjustment is independent from the per-conveyor AutoStart setting.
        -- The function itself checks both conveyor identity and shop category.
        self:applyConveyorSpeedLimit(vehicle)
        self:applyConveyorReverseSpeedLimit(vehicle)
        self:logLiveSpeedDiagnostics(vehicle)

        if self:isAutoStartVehicle(vehicle) then
            count = count + 1

            local enabled = true
            if g_universalConveyorSettings ~= nil
                and g_universalConveyorSettings.isEnabled ~= nil
            then
                local okEnabled, resultEnabled = pcall(
                    g_universalConveyorSettings.isEnabled,
                    g_universalConveyorSettings,
                    vehicle
                )
                if okEnabled then
                    enabled = resultEnabled ~= false
                end
            end

            if enabled then
                if vehicle.uchAutoTurnOnEnabled == nil then
                    vehicle.uchAutoTurnOnEnabled = true
                end

                local ok, err = pcall(function()
                    if UniversalAutoTurnOn ~= nil and UniversalAutoTurnOn.doRecheck ~= nil then
                        UniversalAutoTurnOn.doRecheck(vehicle)
                    end
                end)

                if not ok then
                    logError("[AUTO_START][GLOBAL] Recheck-Fehler: %s", tostring(err))
                end
            else
                vehicle.uchAutoTurnOnEnabled = false
                vehicle.uchAutoTurnOnDone = true
                if vehicle.uchAutoTurnOnStartedByHelper and UniversalAutoTurnOn ~= nil and UniversalAutoTurnOn.disableBySettings ~= nil then
                    local ok, err = pcall(UniversalAutoTurnOn.disableBySettings, vehicle)
                    if not ok then
                        logError("[AUTO_START][GLOBAL] Deaktivierungs-Fehler: %s", tostring(err))
                    end
                end
            end
        end
    end

    if not self.globalStartLogged then
        self.globalStartLogged = true
        logInfo("[AUTO_START][GLOBAL] Manager aktiv | Förderbänder=%d", count)
    end
end

-- Vehicle arrival detection is implemented in VehicleDetection.lua.

function UniversalConveyorHelper:globalDischargeConveyors()
    if g_currentMission == nil then
        return
    end

    if g_currentMission.isServer ~= nil and not g_currentMission.isServer then
        return
    end

    if UniversalWideDischarge == nil or UniversalWideDischarge.doGlobalUpdate == nil then
        return
    end

    local vehicles = self:getGlobalVehicleList()
    local count = 0

    for _, vehicle in ipairs(vehicles) do
        if self:isConveyorVehicle(vehicle)
            and vehicle.spec_dischargeable ~= nil
            and vehicle.spec_fillUnit ~= nil
        then
            local enabled = true
            if g_universalConveyorSettings ~= nil and g_universalConveyorSettings.isEnabled ~= nil then
                local okEnabled, resultEnabled = pcall(
                    g_universalConveyorSettings.isEnabled,
                    g_universalConveyorSettings,
                    vehicle
                )
                if okEnabled then
                    enabled = resultEnabled ~= false
                end
            end

            if enabled then
                count = count + 1
                UniversalWideDischarge:doGlobalUpdate(vehicle)
            end
        end
    end

    if not self.globalDischargeLogged then
        self.globalDischargeLogged = true
        logInfo("[DISCHARGE][GLOBAL] Manager aktiv | Förderbänder=%d", count)
    end
end

function UniversalConveyorHelper:onLoadMapFinished()
    self.globalStartTimer = 1000
    self.globalDischargeTimer = 1000
    self.globalStartLogged = false
    self.globalDischargeLogged = false
    self.startupLogFinished = false
    self.startupUpdateCount = 0

    local gameTime = nil
    if getTime ~= nil then
        local ok, value = pcall(getTime)
        if ok then
            gameTime = value
        end
    end

    logInfo(
        "[STARTUP] onLoadMapFinished | gameTime=%s | controlledVehicle=%s | vehicleSystem=%s",
        tostring(gameTime),
        tostring(g_currentMission ~= nil and g_currentMission.controlledVehicle ~= nil),
        tostring(g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil)
    )

    if UniversalConveyorVehicleDetection ~= nil and UniversalConveyorVehicleDetection.reset ~= nil then
        UniversalConveyorVehicleDetection:reset()
    end

    if UniversalAutoTurnOn ~= nil and UniversalAutoTurnOn.installS710Bridge ~= nil then
        UniversalAutoTurnOn.installS710Bridge()
    end
end

function UniversalConveyorHelper:update(dt)
    if not self.startupLogFinished then
        self.startupUpdateCount = (self.startupUpdateCount or 0) + 1

        local gameTime = nil
        if getTime ~= nil then
            local ok, value = pcall(getTime)
            if ok then
                gameTime = value
            end
        end

        logInfo(
            "[STARTUP] erster Update | updateNr=%d | dt=%.2f | gameTime=%s | controlledVehicle=%s | player=%s",
            self.startupUpdateCount,
            tonumber(dt) or 0,
            tostring(gameTime),
            tostring(g_currentMission ~= nil and g_currentMission.controlledVehicle ~= nil),
            tostring(g_currentMission ~= nil and g_currentMission.player ~= nil)
        )
        self.startupLogFinished = true
    end

    if UniversalAutoTurnOn ~= nil and UniversalAutoTurnOn.installS710Bridge ~= nil then
        UniversalAutoTurnOn.installS710Bridge()
    end

    -- Install once after scripts are initialized. This catches the native
    -- setter that repeatedly restores the 5 km/h reverse limit between manager
    -- passes; no extra vehicle scan is introduced.
    self:installReverseSpeedLimitSetterHook()

    local delta = dt or 0

    self.globalStartTimer = (self.globalStartTimer or 0) - delta
    self.globalDischargeTimer = (self.globalDischargeTimer or 0) - delta

    if self.globalStartTimer <= 0 then
        self.globalStartTimer = self.GLOBAL_START_INTERVAL
        self:globalStartConveyors()
    end

    if self.globalDischargeTimer <= 0 then
        self.globalDischargeTimer = self.GLOBAL_DISCHARGE_INTERVAL
        self:globalDischargeConveyors()
    end

    if UniversalConveyorVehicleDetection ~= nil and UniversalConveyorVehicleDetection.update ~= nil then
        UniversalConveyorVehicleDetection:update(delta)
    end
end

-- IMPORTANT: Do not hook VehicleSystem.update/addVehicle here.
-- Those engine-level hooks can interfere with vehicle registration/spawning.
-- The helper uses its normal ModEventListener update and the conveyor
-- specialization listeners instead.

addModEventListener(UniversalConveyorHelper)

-- -------------------------------------------------------------------------
-- Settings manager bootstrap
-- -------------------------------------------------------------------------

if UniversalConveyorSettings ~= nil and g_universalConveyorSettings == nil then
    local settingsBase = nil
    if getUserProfileAppPath ~= nil then
        settingsBase = getUserProfileAppPath()
    end

    if settingsBase ~= nil then
        local settingsDir = settingsBase .. "modSettings/" .. tostring(MOD_NAME) .. "/"
        local ok, result = pcall(function()
            return UniversalConveyorSettings.new(
                g_currentModDirectory,
                settingsDir,
                _G
            )
        end)

        if ok then
            g_universalConveyorSettings = result
            logInfo("[SETTINGS] Manager erstellt | Verzeichnis=%s", tostring(settingsDir))
        else
            logError("[SETTINGS] Manager konnte nicht erstellt werden: %s", tostring(result))
        end
    else
        logError("[SETTINGS] getUserProfileAppPath nicht verfügbar")
    end
end
