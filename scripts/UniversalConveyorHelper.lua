-- FS25 Universal Conveyor Helper 1.9.68
-- Universal helper for automatic conveyor start, extended discharge range and per-conveyor settings.
-- Specializations are registered manually, following the proven FS25 pattern.

UniversalConveyorHelper = {}
UniversalConveyorHelper.VERSION = "1.9.83.5"
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
UniversalConveyorHelper.SL8022_REG_NAME = "uchSL8022RuntimeExactFillRoot"
UniversalConveyorHelper.SL8022_SPEC_NAME = MOD_NAME .. "." .. UniversalConveyorHelper.SL8022_REG_NAME

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

local sl8022SpecRegistered = registerSpecialization(
    UniversalConveyorHelper.SL8022_REG_NAME,
    "UCHSL8022RuntimeExactFillRoot",
    "scripts/SL8022RuntimeExactFillRoot.lua"
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
    if hasSpecialization(typeDef, "pickupConveyorBelt")
        or hasSpecialization(typeDef, "conveyorBelt")
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

            -- Native AutoDrive I-trigger compatibility: make the GIANTS shovel
            -- specialization available to pickup-conveyor vehicle types. The
            -- runtime bridge only adds a node when a safe intake node is found.
            if hasSpecialization(typeDef, "pickupConveyorBelt") then
                local shovelSpec = nil
                local bunkerSpec = nil
                if g_specializationManager ~= nil and g_specializationManager.getSpecializationByName ~= nil then
                    shovelSpec = g_specializationManager:getSpecializationByName("shovel")
                    bunkerSpec = g_specializationManager:getSpecializationByName("bunkerSiloInteractor")
                end
                if shovelSpec ~= nil and bunkerSpec ~= nil then
                    local shovelName = shovelSpec.name or "shovel"
                    local bunkerName = bunkerSpec.name or "bunkerSiloInteractor"
                    if not hasSpecialization(typeDef, shovelName) then
                        local added, reason = addSpecialization(typeManager, typeName, shovelName)
                        if added or reason == "alreadyPresent" then
                            logInfo("[LOAD_TRIGGER] Shovel-Spezialisierung für %s verfügbar", tostring(typeName))
                        else
                            logInfo("[LOAD_TRIGGER] Shovel-Spezialisierung nicht ergänzt: %s | %s", tostring(typeName), tostring(reason))
                        end
                    end
                    if not hasSpecialization(typeDef, bunkerName) then
                        local added, reason = addSpecialization(typeManager, typeName, bunkerName)
                        if not added and reason ~= "alreadyPresent" then
                            logInfo("[LOAD_TRIGGER] BunkerSiloInteractor nicht ergänzt: %s | %s", tostring(typeName), tostring(reason))
                        end
                    end
                else
                    logInfo("[LOAD_TRIGGER] Native Shovel-Spezialisierung nicht verfügbar für %s", tostring(typeName))
                end
            end

            local hasTurnOn = hasSpecialization(typeDef, "turnOnVehicle")
            local hasDischarge = hasSpecialization(typeDef, "dischargeable")
            local hasFillUnit = hasSpecialization(typeDef, "fillUnit")
            local hasFillVolume = hasSpecialization(typeDef, "fillVolume")

            -- Register the SL8022 runtime callback independently of AutoTurnOn.
            -- This is required for vanilla conveyorBelt types without turnOnVehicle.
            if sl8022SpecRegistered and hasFillUnit and hasFillVolume then
                local added, reason = addSpecialization(typeManager, typeName, UniversalConveyorHelper.SL8022_SPEC_NAME)
                if added or reason == "alreadyPresent" then
                    logInfo("[SL8022] Runtime-Spezialisierung verfügbar: %s | reason=%s", tostring(typeName), tostring(reason))
                else
                    logError("[SL8022] Runtime-Spezialisierung nicht hinzugefügt: %s | reason=%s", tostring(typeName), tostring(reason))
                end
            end

            logInfo("[SCAN] Förderband gefunden: %s | TurnOn=%s | Discharge=%s | FillUnit=%s | FillVolume=%s",
                tostring(typeName), tostring(hasTurnOn), tostring(hasDischarge), tostring(hasFillUnit), tostring(hasFillVolume))

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
        self:logAutoDriveTargetDiagnostics(vehicle)

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
