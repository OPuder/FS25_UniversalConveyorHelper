-- Universal Conveyor Helper 1.9.26
-- Per-conveyor settings, persistent names, enable/disable and teleport.

UniversalConveyorSettings = {}

UniversalConveyorSettings.VERSION = "1.9.83.25"
UniversalConveyorSettings.SETTINGS_FILENAME = "settings.xml"
UniversalConveyorSettings.SETTINGS_ROOT = "settings"

-- Start the first conveyor scan immediately after the map reports load completion.
-- The scan itself is bounded by INITIAL_SCAN_WINDOW; there is no artificial post-load wait.
UniversalConveyorSettings.MAP_READY_DELAY = 0
-- After the loading screen is finished, some placeables/vehicles can still
-- enter the live mission lists. Keep a short, bounded discovery window instead
-- of scanning forever. New in-game purchases are handled by their lifecycle.
UniversalConveyorSettings.INITIAL_SCAN_WINDOW = 10000
UniversalConveyorSettings.INITIAL_SCAN_INTERVAL = 500

local UniversalConveyorSettings_mt = Class(UniversalConveyorSettings)

function UniversalConveyorSettings.new(modDir, settingsDir, modEnv)
    local self = setmetatable({}, UniversalConveyorSettings_mt)
    -- Keep the live manager instance available to native callbacks. The class
    -- table itself has no entriesByKey and must never be used as the manager.
    UniversalConveyorSettings.instance = self

    self.modDir = modDir
    self.settingsDir = settingsDir
    self.modEnv = modEnv
    self.settingsFilename = settingsDir .. UniversalConveyorSettings.SETTINGS_FILENAME
    self.entriesByKey = {}
    self.currentEntries = {}
    self.pageController = nil
    self.guiController = nil
    self.currentSignature = nil
    self.runtimeVehicles = {}
    self.scanTimer = 0
    self.initialScanActive = false
    self.initialScanRemaining = 0
    self.lastLoggedScanCount = nil

    -- Lifecycle diagnostics for newly created/replaced/removed conveyor objects.
    self.lifecycleSeen = {}
    self.lifecycleRuntimeLogged = {}
    self.lifecycleRemovedLogged = {}

    self.guiInitialized = false

    createFolder(settingsDir)
    self:loadSettings()
    self:addGlobalTextsToBase()

    -- Use the same lifecycle as proven FS25 settings-tab mods.
    addModEventListener(self)

    if g_currentMission ~= nil and g_currentMission.registerToLoadOnMapFinished ~= nil then
        g_currentMission:registerToLoadOnMapFinished(self)
    end

    -- The pause-menu settings frame already exists when the mod is initialized on normal game startup.
    -- Initialize immediately so the tab is present before the first map is opened.
    if g_inGameMenu ~= nil and g_inGameMenu.pageSettings ~= nil then
        self:initializeGui()
    end

    Logging.info(
        "[UniversalConveyorHelper][SETTINGS] Einstellungen geladen | Datei=%s",
        tostring(self.settingsFilename)
    )

    return self
end

function UniversalConveyorSettings:addGlobalTextsToBase()
    -- The pause-menu settings frame lives in the base-game environment.
    -- Copy only explicitly global mod texts into the base i18n table.
    local meta = getmetatable(_G)
    local baseEnv = meta ~= nil and meta.__index or nil
    if baseEnv == nil or baseEnv.g_i18n == nil or g_i18n == nil or g_i18n.texts == nil then
        return
    end

    for name, value in pairs(g_i18n.texts) do
        if string.sub(tostring(name), 1, 7) == "global_" then
            local plainName = string.sub(name, 8)
            pcall(baseEnv.g_i18n.setText, baseEnv.g_i18n, plainName, value)
        end
    end
end

function UniversalConveyorSettings:isEnabled(vehicle)
    if vehicle == nil then
        return true
    end

    -- Persisted settings are authoritative. Runtime markers are only a cache.
    local entry = self:getEntry(vehicle)
    if entry ~= nil then
        local enabled = entry.enabled ~= false
        vehicle.uchAutoTurnOnEnabled = enabled
        return enabled
    end

    if vehicle.uchAutoTurnOnEnabled ~= nil then
        return vehicle.uchAutoTurnOnEnabled == true
    end

    return true
end

function UniversalConveyorSettings:setEnabled(vehicle, enabled)
    local entry = self:getEntry(vehicle)
    if entry == nil then
        return
    end

    entry.enabled = enabled == true
    vehicle.uchAutoTurnOnEnabled = entry.enabled

    Logging.info("[UniversalConveyorHelper][SETTINGS] setEnabled %s = %s", tostring(entry.name or entry.typeName or "Förderband"), entry.enabled and "AN" or "AUS")
    self:applyRuntimeState(vehicle)
    self:saveSettings()
end

function UniversalConveyorSettings:initializeGui()
    if self.guiInitialized then
        return true
    end

    if UniversalConveyorSettingsGui == nil then
        Logging.error("[UniversalConveyorHelper][SETTINGS] UniversalConveyorSettingsGui fehlt")
        return false
    end

    if InGameMenuSettingsFrame == nil or InGameMenuSettingsFrame.SUB_CATEGORY == nil then
        Logging.warning("[UniversalConveyorHelper][SETTINGS] Settings-Frame noch nicht bereit")
        return false
    end

    Logging.info("[UniversalConveyorHelper][SETTINGS] GUI-Initialisierung gestartet")

    local ok, controller = pcall(function()
        local gui = UniversalConveyorSettingsGui.new(self)
        return gui:addPage(3)
    end)

    if not ok or controller == nil then
        Logging.error("[UniversalConveyorHelper][SETTINGS] GUI-Initialisierung fehlgeschlagen: %s", tostring(controller))
        return false
    end

    self.guiController = controller
    self.pageController = controller
    self.guiInitialized = true

    Logging.info("[UniversalConveyorHelper][SETTINGS] GUI-Initialisierung abgeschlossen")
    return true
end

function UniversalConveyorSettings:onLoadMapFinished()
    self:initializeGui()
    self.currentSignature = nil
    self.scanTimer = UniversalConveyorSettings.MAP_READY_DELAY
    self.initialScanActive = true
    self.initialScanRemaining = UniversalConveyorSettings.INITIAL_SCAN_WINDOW

    Logging.info(
        "[UniversalConveyorHelper][MAP_READY] Map-Ladevorgang abgeschlossen | erster Förderband-Scan in %dms | Initial-Scanfenster=%dms",
        UniversalConveyorSettings.MAP_READY_DELAY,
        UniversalConveyorSettings.INITIAL_SCAN_WINDOW
    )
end



-- Apply the saved UCH angle at the exact native AIConveyorBelt start callback.
-- Other conveyor types are passed through untouched.
function UniversalConveyorSettings:update(dt)
    self.installQuantumAngleStartHook()
    local delta = dt or 0
    self:updateQuantumHInput(delta)
    self:updateNativeConveyorAI(delta)
    self.scanTimer = (self.scanTimer or 0) - delta

    if self.scanTimer > 0 then
        return
    end

    local pageOpen = self.pageController ~= nil and self.pageController.isOpen

    -- During the short post-load window we deliberately allow a few additional
    -- discovery passes. This covers savegame objects that become available
    -- shortly after the loading screen reaches 100%, without introducing a
    -- permanent background scan.
    if self.initialScanActive then
        self.scanTimer = UniversalConveyorSettings.INITIAL_SCAN_INTERVAL
        self.initialScanRemaining = (self.initialScanRemaining or 0) - UniversalConveyorSettings.INITIAL_SCAN_INTERVAL

        if self.currentSignature == nil then
            Logging.info("[UniversalConveyorHelper][MAP_READY] Förderband-Erstscan wird jetzt ausgeführt")
        end

        self:scanConveyors(false)

        if self.initialScanRemaining <= 0 then
            self.initialScanActive = false
            self.initialScanRemaining = 0
            Logging.info("[UniversalConveyorHelper][MAP_READY] Initial-Scanfenster beendet | Förderbänder=%d", #self.currentEntries)
        end
        return
    end

    -- Once the initial window is closed, the settings page may explicitly
    -- refresh its list. There is no permanent polling of the map here.
    if pageOpen then
        self.scanTimer = 1000
        self:scanConveyors(false)
    end
end

function UniversalConveyorSettings:deleteMap()
    self.currentEntries = {}
    self.currentSignature = nil
end
