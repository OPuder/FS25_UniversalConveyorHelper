-- FS25 Universal Conveyor Helper 1.9.41
-- Universal helper for automatic conveyor start, extended discharge range and per-conveyor settings.
-- Specializations are registered manually, following the proven FS25 pattern.

UniversalConveyorHelper = {}
UniversalConveyorHelper.VERSION = "1.9.41"
UniversalConveyorHelper.AUTO_START = true
UniversalConveyorHelper.EXTENDED_DISCHARGE = true
UniversalConveyorHelper.DEBUG = true
UniversalConveyorHelper.GLOBAL_START_INTERVAL = 500
UniversalConveyorHelper.GLOBAL_DISCHARGE_INTERVAL = 250
UniversalConveyorHelper.globalStartTimer = 1000
UniversalConveyorHelper.globalDischargeTimer = 1000
UniversalConveyorHelper.globalStartLogged = false
UniversalConveyorHelper.globalDischargeLogged = false
UniversalConveyorHelper.aiDiagnosticTimer = 1500
UniversalConveyorHelper.aiDiagnosticDone = false

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

function UniversalConveyorHelper:isAutoStartVehicle(vehicle)
    return self:isConveyorVehicle(vehicle)
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

function UniversalConveyorHelper:runAIDiagnostic()
    if self.aiDiagnosticDone or g_currentMission == nil then
        return
    end

    local vehicles = self:getGlobalVehicleList()
    local conveyorCount = 0
    local aiCount = 0
    local targetApiCount = 0
    local canStartCount = 0

    logInfo("[AI_DIAG] Starte einmalige Förderband-/AI-Diagnose | Objekte=%d", #vehicles)

    for _, vehicle in ipairs(vehicles) do
        if self:isConveyorVehicle(vehicle) then
            conveyorCount = conveyorCount + 1

            local hasConveyor = vehicle.spec_conveyorBelt ~= nil
            local hasAI = vehicle.spec_aiConveyorBelt ~= nil
            local hasDischarge = vehicle.spec_dischargeable ~= nil
            local hasFillUnit = vehicle.spec_fillUnit ~= nil
            local hasCurrentNode = vehicle.getCurrentDischargeNode ~= nil
            local hasTargetApi = vehicle.getConveyorBeltTargetObject ~= nil
            local hasCanDischargeApi = vehicle.getCanDischargeToObject ~= nil
            local hasAIStartApi = vehicle.getCanStartAIVehicle ~= nil
            local hasAIFieldWorkApi = vehicle.getCanStartFieldWork ~= nil
            local hasAIJobApi = vehicle.getStartableAIJob ~= nil
            local hasAIJobCheckApi = vehicle.getHasStartableAIJob ~= nil
            local canStartAI = nil
            local canFieldWork = nil

            if hasAIStartApi then
                local ok, result = pcall(vehicle.getCanStartAIVehicle, vehicle)
                if ok then
                    canStartAI = result == true
                else
                    canStartAI = "ERROR"
                end
            end

            if hasAIFieldWorkApi then
                local ok, result = pcall(vehicle.getCanStartFieldWork, vehicle)
                if ok then
                    canFieldWork = result == true
                else
                    canFieldWork = "ERROR"
                end
            end

            if hasAI then
                aiCount = aiCount + 1
            end
            if hasTargetApi then
                targetApiCount = targetApiCount + 1
            end
            if canStartAI == true then
                canStartCount = canStartCount + 1
            end

            local name = tostring(vehicle.configFileNameClean or vehicle.configFileName or vehicle.typeName or "Förderband")
            local typeName = tostring(vehicle.typeName or "")
            local aiSpec = vehicle.spec_aiConveyorBelt
            local aiState = "none"
            if aiSpec ~= nil then
                aiState = string.format(
                    "allowed=%s currentAngle=%.3f minAngle=%s maxAngle=%s stepSize=%s",
                    tostring(aiSpec.isAllowed),
                    tonumber(aiSpec.currentAngle) or 0,
                    tostring(aiSpec.minAngle),
                    tostring(aiSpec.maxAngle),
                    tostring(aiSpec.stepSize)
                )
            end

            logInfo(
                "[AI_DIAG] %s | type=%s | ConveyorBelt=%s | AIConveyorBelt=%s | Discharge=%s | FillUnit=%s | AD=%s",
                name, typeName, tostring(hasConveyor), tostring(hasAI), tostring(hasDischarge), tostring(hasFillUnit), tostring(vehicle.ad ~= nil)
            )
            logInfo(
                "[AI_DIAG] %s | targetAPI=%s | currentDischargeNode=%s | canDischargeAPI=%s | AIStartAPI=%s/%s | FieldWorkAPI=%s/%s | AIJobAPI=%s | AIJobCheckAPI=%s | %s",
                name, tostring(hasTargetApi), tostring(hasCurrentNode), tostring(hasCanDischargeApi), tostring(hasAIStartApi), tostring(canStartAI), tostring(hasAIFieldWorkApi), tostring(canFieldWork), tostring(hasAIJobApi), tostring(hasAIJobCheckApi), aiState
            )

            if hasCurrentNode then
                local okNode, node = pcall(vehicle.getCurrentDischargeNode, vehicle)
                if okNode and node ~= nil then
                    local hitObject = node.dischargeHitObject
                    local hitUnit = node.dischargeHitObjectUnitIndex
                    logInfo(
                        "[AI_DIAG] %s | dischargeNode=%s | hitObject=%s | hitUnit=%s | fillType=%s",
                        name,
                        tostring(node.index),
                        tostring(hitObject ~= nil),
                        tostring(hitUnit),
                        tostring(node.fillType)
                    )
                end
            end
        end
    end

    logInfo(
        "[AI_DIAG] Fertig | Förderbänder=%d | AIConveyorBelt=%d | TargetAPI=%d | canStartAI=true=%d",
        conveyorCount, aiCount, targetApiCount, canStartCount
    )

    self.aiDiagnosticDone = true
end

function UniversalConveyorHelper:onLoadMapFinished()
    self.globalStartTimer = 1000
    self.globalDischargeTimer = 1000
    self.globalStartLogged = false
    self.globalDischargeLogged = false
    self.aiDiagnosticTimer = 1500
    self.aiDiagnosticDone = false

    if UniversalAutoTurnOn ~= nil and UniversalAutoTurnOn.installS710Bridge ~= nil then
        UniversalAutoTurnOn.installS710Bridge()
    end
end

function UniversalConveyorHelper:update(dt)
    if UniversalAutoTurnOn ~= nil and UniversalAutoTurnOn.installS710Bridge ~= nil then
        UniversalAutoTurnOn.installS710Bridge()
    end

    local delta = dt or 0

    if not self.aiDiagnosticDone then
        self.aiDiagnosticTimer = (self.aiDiagnosticTimer or 0) - delta
        if self.aiDiagnosticTimer <= 0 then
            self:runAIDiagnostic()
        end
    end

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
