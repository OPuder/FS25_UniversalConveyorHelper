-- FS25 Universal Conveyor Helper 1.9.23
-- Automatic start based directly on the proven S710_WW AutoTurnOn behavior.
-- Immediate attempt after load + very short retry + update/onUpdateTick fallback.

UniversalAutoTurnOn = {}

UniversalAutoTurnOn.RECHECK_TIMER = 5
UniversalAutoTurnOn.RETRY_TIMER = 250
UniversalAutoTurnOn.MAX_RETRIES = 40

local function uchName(self)
    return tostring(self.configFileNameClean or self.configFileName or self.typeName or "unknown")
end

-- The original S710 mod ships its own global AutoTurnOn specialization.
-- These markers are specific to that implementation and let the Universal
-- Helper take exclusive control without changing any other conveyor type.
local function isNativeS710AutoTurnOn(self)
    if self == nil then
        return false
    end

    if self.autoTurnOnRecheckTimer ~= nil or self.autoTurnOnRecheckDone ~= nil then
        return true
    end

    local typeName = string.lower(tostring(self.typeName or ""))
    local configName = string.lower(tostring(self.configFileName or self.configFileNameClean or ""))

    return string.find(typeName, "s710", 1, true) ~= nil
        or string.find(configName, "s710", 1, true) ~= nil
end

local function suppressNativeS710AutoTurnOn(self)
    if not isNativeS710AutoTurnOn(self) then
        return
    end

    -- Prevent the original S710 specialization from independently starting
    -- the conveyor. The Universal Helper becomes the single controller.
    self.autoTurnOnRecheckDone = true
    self.autoTurnOnRecheckTimer = math.huge
end

function UniversalAutoTurnOn.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(TurnOnVehicle, specializations)
end

function UniversalAutoTurnOn.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", UniversalAutoTurnOn)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", UniversalAutoTurnOn)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdateTick", UniversalAutoTurnOn)
end

function UniversalAutoTurnOn:onPostLoad(savegame)
    self.uchAutoTurnOnRecheckTimer = UniversalAutoTurnOn.RECHECK_TIMER
    self.uchAutoTurnOnRetryTimer = UniversalAutoTurnOn.RETRY_TIMER
    self.uchAutoTurnOnRetries = 0
    self.uchAutoTurnOnDone = false
    self.uchAutoTurnOnEnabled = nil
    self.uchAutoTurnOnStartedByHelper = false
    self.uchAutoTurnOnFirstUpdateLogged = false

    if isNativeS710AutoTurnOn(self) then
        suppressNativeS710AutoTurnOn(self)
        Logging.info("[UniversalConveyorHelper][S710] Native AutoTurnOn übernommen: %s", uchName(self))
    end

    Logging.info("[UniversalConveyorHelper][AUTO_START][INIT] %s | waiting=%sms", uchName(self), tostring(UniversalAutoTurnOn.RECHECK_TIMER))
end

function UniversalAutoTurnOn:onUpdate(dt)
    UniversalAutoTurnOn.uchAutoTurnOnUpdate(self, dt)
end

function UniversalAutoTurnOn:onUpdateTick(dt)
    UniversalAutoTurnOn.uchAutoTurnOnUpdate(self, dt)
end

function UniversalAutoTurnOn:uchAutoTurnOnUpdate(dt)
    if not self.isServer or self.uchAutoTurnOnDone then
        return
    end

    if self.uchAutoTurnOnEnabled == false then
        self.uchAutoTurnOnDone = true
        return
    end

    if g_universalConveyorSettings ~= nil and not g_universalConveyorSettings:isEnabled(self) then
        self.uchAutoTurnOnEnabled = false
        self.uchAutoTurnOnDone = true
        suppressNativeS710AutoTurnOn(self)
        return
    end

    suppressNativeS710AutoTurnOn(self)

    if not self.uchAutoTurnOnFirstUpdateLogged then
        self.uchAutoTurnOnFirstUpdateLogged = true
        Logging.info("[UniversalConveyorHelper][AUTO_START][UPDATE] %s | isServer=%s | dt=%s",
            uchName(self), tostring(self.isServer), tostring(dt))
    end

    self.uchAutoTurnOnRecheckTimer = (self.uchAutoTurnOnRecheckTimer or 0) - dt

    if self.uchAutoTurnOnRecheckTimer > 0 then
        return
    end

    self.uchAutoTurnOnRecheckTimer = UniversalAutoTurnOn.RETRY_TIMER
    self.uchAutoTurnOnRetryTimer = UniversalAutoTurnOn.RETRY_TIMER

    self.uchAutoTurnOnRetries = (self.uchAutoTurnOnRetries or 0) + 1

    local ok, err = pcall(UniversalAutoTurnOn.doRecheck, self)
    if not ok then
        Logging.error("[UniversalConveyorHelper][AUTO_START] Recheck-Fehler %s: %s", uchName(self), tostring(err))
    end

    if self.uchAutoTurnOnRetries >= UniversalAutoTurnOn.MAX_RETRIES and not self.uchAutoTurnOnDone then
        self.uchAutoTurnOnDone = true
        Logging.warning("[UniversalConveyorHelper][AUTO_START] Timeout %s | retries=%d",
            uchName(self), self.uchAutoTurnOnRetries)
    end
end

function UniversalAutoTurnOn:getRunningState(vehicle)
    if vehicle == nil then
        return false, false
    end

    if vehicle.getIsTurnedOn ~= nil then
        local ok, value = pcall(vehicle.getIsTurnedOn, vehicle)
        if ok and value == true then
            return true, true
        end
        if ok and value == false then
            -- A valid native false is a meaningful result. Keep checking
            -- the motor state because some conveyor types do not expose a
            -- normal TurnOnVehicle flag.
        end
    end

    if vehicle.getIsMotorStarted ~= nil then
        local ok, value = pcall(vehicle.getIsMotorStarted, vehicle)
        if ok and value == true then
            return true, true
        end
        if ok and value == false then
            return false, true
        end
    end

    return false, false
end

function UniversalAutoTurnOn:stopNative(vehicle)
    if vehicle == nil then
        return false, "vehicle=nil"
    end

    local stopped = false
    local used = {}

    -- Prefer the normal TurnOnVehicle path when it exists.
    if vehicle.setIsTurnedOn ~= nil then
        local ok, result = pcall(vehicle.setIsTurnedOn, vehicle, false, true)
        used[#used + 1] = "setIsTurnedOn:" .. tostring(ok)
        if ok and result ~= false then
            stopped = true
        end
    end

    -- Some valid conveyor types (notably conveyors without TurnOnVehicle)
    -- expose only the motor API. Use it when needed or when the motor still
    -- reports running.
    local running = false
    if vehicle.getIsMotorStarted ~= nil then
        local ok, value = pcall(vehicle.getIsMotorStarted, vehicle)
        if ok then
            running = value == true
        end
    end

    if (not stopped or running) and vehicle.stopMotor ~= nil then
        local ok, result = pcall(vehicle.stopMotor, vehicle, true)
        used[#used + 1] = "stopMotor:" .. tostring(ok)
        if ok and result ~= false then
            stopped = true
        end
    end

    local stillRunning = false
    if vehicle.getIsMotorStarted ~= nil then
        local ok, value = pcall(vehicle.getIsMotorStarted, vehicle)
        if ok then
            stillRunning = value == true
        end
    end

    return stopped and not stillRunning, table.concat(used, ",")
end

function UniversalAutoTurnOn:doRecheck()
    if not self.isServer then
        Logging.info("[UniversalConveyorHelper][AUTO_START] %s | kein Server", uchName(self))
        return
    end

    if self.uchAutoTurnOnEnabled == false then
        self.uchAutoTurnOnDone = true
        Logging.info("[UniversalConveyorHelper][AUTO_START] Deaktiviert (Runtime-Gate): %s", uchName(self))
        return
    end

    if g_universalConveyorSettings ~= nil and not g_universalConveyorSettings:isEnabled(self) then
        self.uchAutoTurnOnEnabled = false
        self.uchAutoTurnOnDone = true
        Logging.info("[UniversalConveyorHelper][AUTO_START] Deaktiviert (Settings): %s", uchName(self))
        return
    end

    local name = uchName(self)

    suppressNativeS710AutoTurnOn(self)

    local startOk = false
    local running, stateKnown = UniversalAutoTurnOn:getRunningState(self)
    if running then
        self.uchAutoTurnOnDone = true
        self.uchAutoTurnOnStartedByHelper = false
        Logging.info("[UniversalConveyorHelper][AUTO_START] Bereits aktiv: %s", name)
        return
    end
    local motorResult = nil
    local turnResult = nil

    if self.startMotor ~= nil then
        local ok, result = pcall(self.startMotor, self, true)
        motorResult = result
        startOk = ok and result ~= false
        Logging.info("[UniversalConveyorHelper][AUTO_START] %s | startMotor ok=%s result=%s",
            name, tostring(ok), tostring(result))
    else
        Logging.info("[UniversalConveyorHelper][AUTO_START] %s | startMotor=nil", name)
    end

    if self.setIsTurnedOn ~= nil then
        local ok, result = pcall(self.setIsTurnedOn, self, true, true)
        turnResult = result
        startOk = startOk or (ok and result ~= false)
        Logging.info("[UniversalConveyorHelper][AUTO_START] %s | setIsTurnedOn ok=%s result=%s",
            name, tostring(ok), tostring(result))
    else
        Logging.info("[UniversalConveyorHelper][AUTO_START] %s | setIsTurnedOn=nil", name)
    end

    local nowRunning, nowKnown = UniversalAutoTurnOn:getRunningState(self)
    Logging.info(
        "[UniversalConveyorHelper][AUTO_START] %s | nach Start running=%s stateKnown=%s",
        name, tostring(nowRunning), tostring(nowKnown)
    )
    if nowRunning then
        self.uchAutoTurnOnDone = true
        self.uchAutoTurnOnStartedByHelper = true
        suppressNativeS710AutoTurnOn(self)
        Logging.info("[UniversalConveyorHelper][AUTO_START] ERFOLG: %s | vom Helper gestartet", name)
        return
    end

    if not startOk then
        Logging.info("[UniversalConveyorHelper][AUTO_START] %s | noch nicht startbar", name)
    end
end


function UniversalAutoTurnOn.disableBySettings(self, forceStop)
    if self == nil then
        return
    end

    self.uchAutoTurnOnEnabled = false
    self.uchAutoTurnOnDone = true
    suppressNativeS710AutoTurnOn(self)

    -- Settings OFF is an explicit runtime stop. The optional forceStop flag is
    -- used by the settings UI so a conveyor that is currently on is actually
    -- switched off, regardless of whether AutoStart originally started it.
    if not forceStop and not self.uchAutoTurnOnStartedByHelper then
        Logging.info("[UniversalConveyorHelper][AUTO_START] AUS: bereits manuell/extern aktiv, nicht gestoppt: %s", uchName(self))
        return
    end

    local stopped, method = UniversalAutoTurnOn:stopNative(self)

    self.uchAutoTurnOnStartedByHelper = false

    Logging.info(
        "[UniversalConveyorHelper][AUTO_START] AUS angewendet: %s | gestoppt=%s | methode=%s",
        uchName(self),
        tostring(stopped),
        tostring(method)
    )
end

-- -------------------------------------------------------------------------
-- Bridge to the original S710 AutoTurnOn specialization
-- -------------------------------------------------------------------------
-- The S710 mod exposes a global `AutoTurnOn.doRecheck`. Its own onUpdate
-- invokes that function after a few milliseconds. We redirect only S710
-- instances to this helper so the GUI AN/AUS state controls the actual
-- conveyor and the two AutoStart implementations cannot fight each other.

function UniversalAutoTurnOn.installS710Bridge()
    if _G.AutoTurnOn == nil or _G.AutoTurnOn.doRecheck == nil then
        return false
    end

    if _G.AutoTurnOn.__uchS710BridgeInstalled then
        return true
    end

    local original = _G.AutoTurnOn.doRecheck
    _G.AutoTurnOn.__uchOriginalDoRecheck = original

    _G.AutoTurnOn.doRecheck = function(nativeSelf, ...)
        if isNativeS710AutoTurnOn(nativeSelf) then
            suppressNativeS710AutoTurnOn(nativeSelf)

            if nativeSelf.uchAutoTurnOnEnabled == false then
                return
            end

            if g_universalConveyorSettings ~= nil
                and g_universalConveyorSettings.isEnabled ~= nil
            then
                local okEnabled, enabled = pcall(
                    g_universalConveyorSettings.isEnabled,
                    g_universalConveyorSettings,
                    nativeSelf
                )
                if okEnabled and not enabled then
                    nativeSelf.uchAutoTurnOnEnabled = false
                    nativeSelf.uchAutoTurnOnDone = true
                    return
                end
            end

            if UniversalAutoTurnOn ~= nil and UniversalAutoTurnOn.doRecheck ~= nil then
                return UniversalAutoTurnOn.doRecheck(nativeSelf)
            end

            return
        end

        return original(nativeSelf, ...)
    end

    _G.AutoTurnOn.__uchS710BridgeInstalled = true
    Logging.info("[UniversalConveyorHelper][S710] Native AutoTurnOn Bridge installiert")
    return true
end

UniversalAutoTurnOn.installS710Bridge()

