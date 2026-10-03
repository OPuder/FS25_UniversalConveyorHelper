-- Universal Conveyor Helper 1.9.26
-- Per-conveyor settings, persistent names, enable/disable and teleport.

UniversalConveyorSettings = {}

UniversalConveyorSettings.VERSION = "1.9.26"
UniversalConveyorSettings.SETTINGS_FILENAME = "settings.xml"
UniversalConveyorSettings.SETTINGS_ROOT = "settings"

-- Wait until the map/savegame has fully handed over to the playable map before
-- performing the first complete conveyor scan. During the transition from the
-- 100% loading screen, some vehicle objects are still being created.
UniversalConveyorSettings.MAP_READY_DELAY = 3000
-- After the loading screen is finished, some placeables/vehicles can still
-- enter the live mission lists. Keep a short, bounded discovery window instead
-- of scanning forever. New in-game purchases are handled by their lifecycle.
UniversalConveyorSettings.INITIAL_SCAN_WINDOW = 10000
UniversalConveyorSettings.INITIAL_SCAN_INTERVAL = 500

local UniversalConveyorSettings_mt = Class(UniversalConveyorSettings)

function UniversalConveyorSettings.new(modDir, settingsDir, modEnv)
    local self = setmetatable({}, UniversalConveyorSettings_mt)

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

function UniversalConveyorSettings:getVehicleSource(vehicle)
    if vehicle == nil then
        return ""
    end

    local source = vehicle.customEnvironment
        or vehicle.modName
        or vehicle.configFileName
        or vehicle.configFileNameClean
        or vehicle.typeName
        or ""

    source = tostring(source)
    source = string.gsub(source, "^.*[/\\]", "")
    source = string.gsub(source, "%.xml$", "")
    return source
end

function UniversalConveyorSettings:registerRuntimeVehicle(vehicle)
    if vehicle == nil or not self:isManagedConveyor(vehicle) then
        return
    end

    local key = self:getObjectKey(vehicle)
    if key == nil then
        return
    end

    local previous = self.runtimeVehicles[key]
    if previous == nil then
        Logging.info(
            "[UniversalConveyorHelper][LIFECYCLE][RUNTIME_NEW] key=%s | name=%s | type=%s | source=%s",
            tostring(key),
            tostring(self:getDisplayType(vehicle)),
            tostring(vehicle.typeName or ""),
            self:getVehicleSource(vehicle)
        )
        self.lifecycleRuntimeLogged[key] = true
        self.lifecycleRemovedLogged[key] = nil
    elseif previous ~= vehicle then
        Logging.info(
            "[UniversalConveyorHelper][LIFECYCLE][RUNTIME_REPLACE] key=%s | old=%s | new=%s | name=%s | source=%s",
            tostring(key),
            tostring(previous),
            tostring(vehicle),
            tostring(self:getDisplayType(vehicle)),
            self:getVehicleSource(vehicle)
        )
    end

    self.runtimeVehicles[key] = vehicle
end

function UniversalConveyorSettings:getObjectKey(vehicle)
    if vehicle == nil then
        return nil
    end

    local uniqueId = nil

    if vehicle.getUniqueId ~= nil then
        local ok, result = pcall(vehicle.getUniqueId, vehicle)
        if ok then
            uniqueId = result
        end
    end

    if uniqueId == nil or uniqueId == "" then
        uniqueId = vehicle.uniqueId
    end

    if uniqueId ~= nil and uniqueId ~= "" then
        return "uid:" .. tostring(uniqueId)
    end

    if vehicle.rootNode ~= nil then
        local x, y, z = getWorldTranslation(vehicle.rootNode)
        local filename = tostring(vehicle.configFileName or vehicle.typeName or "conveyor")
        return string.format("pos:%s:%.2f:%.2f:%.2f", filename, x, y, z)
    end

    return tostring(vehicle.id or vehicle.typeName or "conveyor")
end

function UniversalConveyorSettings:getDisplayType(vehicle)
    if vehicle == nil then
        return "Förderband"
    end

    local name = vehicle.configFileNameClean
        or vehicle.configFileName
        or vehicle.typeName
        or "Förderband"

    name = tostring(name)
    name = string.gsub(name, "^.*[/\\]", "")
    name = string.gsub(name, "%.xml$", "")

    if name == "" then
        name = "Förderband"
    end

    return name
end

function UniversalConveyorSettings:getEntry(vehicle)
    if vehicle == nil then
        return nil
    end

    local key = self:getObjectKey(vehicle)
    if key == nil then
        return nil
    end

    local entry = self.entriesByKey[key]

    if entry == nil then
        entry = {
            key = key,
            vehicle = vehicle,
            name = self:getDisplayType(vehicle),
            enabled = true,
            typeName = self:getDisplayType(vehicle)
        }

        self.entriesByKey[key] = entry
    else
        entry.vehicle = vehicle
        entry.typeName = self:getDisplayType(vehicle)

        if entry.name == nil or entry.name == "" then
            entry.name = entry.typeName
        end
    end

    return entry
end

function UniversalConveyorSettings:isManagedConveyor(vehicle)
    if vehicle == nil then
        return false
    end

    -- Own specialization / runtime markers.
    if vehicle.spec_uchAutoTurnOn ~= nil
        or vehicle.spec_uchWideDischarge ~= nil
        or vehicle.spec_UniversalAutoTurnOn ~= nil
        or vehicle.spec_UniversalWideDischarge ~= nil
        or vehicle.uchAutoTurnOnRecheckTimer ~= nil
        or vehicle.uchWideDischargeDebugState ~= nil
        or vehicle.uchWideDischargeDisabled ~= nil
    then
        return true
    end

    -- Also accept custom conveyor vehicle types that do not inherit our
    -- specialization. This keeps the GUI and persistent settings in sync with
    -- the global auto-start fallback.
    if vehicle.spec_pickupConveyorBelt ~= nil
        or vehicle.spec_conveyorBelt ~= nil
        or vehicle.spec_aiConveyorBelt ~= nil
    then
        return true
    end

    -- Fallback for custom S710/conveyor vehicle types that expose the native
    -- motor/turn-on API but no public conveyor specialization field.
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

function UniversalConveyorSettings:buildSignature(list)
    local parts = {}

    for i, entry in ipairs(list) do
        parts[i] = tostring(entry.key) .. "|" .. tostring(entry.name or "") .. "|" .. tostring(entry.enabled)
    end

    return table.concat(parts, "\n")
end

function UniversalConveyorSettings:collectLiveConveyors()
    local live = {}
    local seenVehicles = {}

    local function addList(source)
        if source == nil then
            return
        end

        for _, vehicle in pairs(source) do
            if vehicle ~= nil and not seenVehicles[vehicle] and self:isManagedConveyor(vehicle) then
                seenVehicles[vehicle] = true
                local key = self:getObjectKey(vehicle)
                if key ~= nil and live[key] == nil then
                    live[key] = vehicle
                end
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

    return live
end

function UniversalConveyorSettings:diagnoseLifecycle(live)
    live = live or {}

    for key, vehicle in pairs(live) do
        local previous = self.lifecycleSeen[key]
        if previous == nil then
            Logging.info(
                "[UniversalConveyorHelper][LIFECYCLE][LIVE_NEW] key=%s | name=%s | type=%s | source=%s",
                tostring(key),
                tostring(self:getDisplayType(vehicle)),
                tostring(vehicle.typeName or ""),
                self:getVehicleSource(vehicle)
            )
        elseif previous ~= vehicle then
            Logging.info(
                "[UniversalConveyorHelper][LIFECYCLE][LIVE_REPLACE] key=%s | old=%s | new=%s | name=%s | source=%s",
                tostring(key),
                tostring(previous),
                tostring(vehicle),
                tostring(self:getDisplayType(vehicle)),
                self:getVehicleSource(vehicle)
            )
        else
            self.lifecycleRemovedLogged[key] = nil
        end

        self.lifecycleSeen[key] = vehicle
    end

    -- A runtime entry that is no longer in any live mission list is exactly
    -- what we need to see when diagnosing temporary shop objects.
    for key, vehicle in pairs(self.runtimeVehicles) do
        if live[key] == nil and not self.lifecycleRemovedLogged[key] then
            Logging.info(
                "[UniversalConveyorHelper][LIFECYCLE][LIVE_REMOVE] key=%s | name=%s | type=%s | source=%s | runtimeStillHas=true",
                tostring(key),
                tostring(self:getDisplayType(vehicle)),
                tostring(vehicle.typeName or ""),
                self:getVehicleSource(vehicle)
            )
            self.lifecycleRemovedLogged[key] = true
        end
    end
end

function UniversalConveyorSettings:scanConveyors(skipUiUpdate)
    local list = {}
    local activeKeys = {}
    local seenVehicles = {}
    local seenKeys = {}
    local liveConveyors = self:collectLiveConveyors()

    self:diagnoseLifecycle(liveConveyors)

    -- Drop stale runtime references after they have been logged.
    -- This keeps temporary Shop objects from surviving in the GUI cache.
    local staleRuntimeKeys = {}
    for key, _ in pairs(self.runtimeVehicles) do
        if liveConveyors[key] == nil then
            staleRuntimeKeys[#staleRuntimeKeys + 1] = key
        end
    end
    for _, key in ipairs(staleRuntimeKeys) do
        self.runtimeVehicles[key] = nil
    end

    local function addVehicle(vehicle)
        if vehicle == nil or seenVehicles[vehicle] then
            return
        end
        seenVehicles[vehicle] = true

        if self:isManagedConveyor(vehicle) then
            local objectKey = self:getObjectKey(vehicle)
            if objectKey == nil or seenKeys[objectKey] then
                return
            end
            seenKeys[objectKey] = true

            local prior = self.lifecycleSeen[objectKey]
            if prior == nil then
                Logging.info(
                    "[UniversalConveyorHelper][LIFECYCLE][SCAN_NEW] key=%s | name=%s | type=%s | source=%s",
                    tostring(objectKey),
                    tostring(self:getDisplayType(vehicle)),
                    tostring(vehicle.typeName or ""),
                    self:getVehicleSource(vehicle)
                )
            elseif prior ~= vehicle then
                Logging.info(
                    "[UniversalConveyorHelper][LIFECYCLE][SOURCE_REPLACE] key=%s | old=%s | new=%s | name=%s | source=%s",
                    tostring(objectKey),
                    tostring(prior),
                    tostring(vehicle),
                    tostring(self:getDisplayType(vehicle)),
                    self:getVehicleSource(vehicle)
                )
            end

            self:registerRuntimeVehicle(vehicle)
            local entry = self:getEntry(vehicle)
            if entry ~= nil then
                -- Mirror the persisted setting directly onto the live vehicle.
                -- This gives the AutoStart specialization a deterministic runtime gate
                -- even when the custom conveyor type is not using our injected spec.
                vehicle.uchAutoTurnOnEnabled = entry.enabled ~= false
                if not vehicle.uchAutoTurnOnEnabled then
                    vehicle.uchAutoTurnOnDone = true
                end

                table.insert(list, entry)
                activeKeys[entry.key] = true
            end
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
        if g_currentMission.placeableSystem ~= nil then
            addList(g_currentMission.placeableSystem.placeables)
        end
    end

    -- Runtime registration is merged last only for objects that are still live.
    addList(self.runtimeVehicles)

    table.sort(list, function(a, b)
        local an = string.lower(tostring(a.name or ""))
        local bn = string.lower(tostring(b.name or ""))

        if an == bn then
            return tostring(a.key) < tostring(b.key)
        end

        return an < bn
    end)

    for key, _ in pairs(self.entriesByKey) do
        if not activeKeys[key] then
            self.entriesByKey[key] = nil
        end
    end

    self.currentEntries = list

    if self.lastLoggedScanCount ~= #list then
        self.lastLoggedScanCount = #list
        Logging.info(
            "[UniversalConveyorHelper][SETTINGS] Scan Förderbänder | gefunden=%d | runtime=%d | aktiv=%d",
            #list,
            table.getn(self.runtimeVehicles or {}),
            table.getn(g_currentMission ~= nil and (g_currentMission.vehicles or {}) or {})
        )
    end

    local signature = self:buildSignature(list)
    local changed = signature ~= self.currentSignature
    self.currentSignature = signature

    if not skipUiUpdate
        and changed
        and self.pageController ~= nil
        and self.pageController.isOpen
        and self.pageController.updateConveyors ~= nil
    then
        self.pageController:updateConveyors(list)
    end

    return list, changed
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

function UniversalConveyorSettings:setName(vehicle, name)
    local entry = self:getEntry(vehicle)
    if entry == nil then
        return
    end

    name = tostring(name or "")
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")

    if name == "" then
        name = entry.typeName or "Förderband"
    end

    entry.name = name
    self.currentSignature = nil
    self:saveSettings()
end

function UniversalConveyorSettings:applyRuntimeState(vehicle)
    if vehicle == nil then
        return
    end

    local enabled = self:isEnabled(vehicle)

    if not enabled then
        vehicle.uchAutoTurnOnEnabled = false
        vehicle.uchAutoTurnOnDone = true

        -- S710 compatibility: suppress the original mod's independent
        -- AutoTurnOn loop as well.
        if vehicle.autoTurnOnRecheckDone ~= nil or vehicle.autoTurnOnRecheckTimer ~= nil then
            vehicle.autoTurnOnRecheckDone = true
            vehicle.autoTurnOnRecheckTimer = math.huge
        end

        -- The UI switch is an explicit runtime ON/OFF switch. When set to OFF,
        -- stop the conveyor immediately as well as disabling future AutoStart.
        if UniversalAutoTurnOn ~= nil and UniversalAutoTurnOn.disableBySettings ~= nil then
            local ok, err = pcall(UniversalAutoTurnOn.disableBySettings, vehicle, true)
            if not ok then
                Logging.error(
                    "[UniversalConveyorHelper][SETTINGS] AutoStart-Abschalten fehlgeschlagen: %s",
                    tostring(err)
                )
            end
        elseif vehicle.setIsTurnedOn ~= nil then
            local ok, err = pcall(vehicle.setIsTurnedOn, vehicle, false, true)
            if not ok then
                Logging.error(
                    "[UniversalConveyorHelper][SETTINGS] Direktes Abschalten fehlgeschlagen: %s",
                    tostring(err)
                )
            end
        end

        Logging.info("[UniversalConveyorHelper][SETTINGS] Laufzeitstatus AUS angewendet: %s", tostring(vehicle.configFileNameClean or vehicle.configFileName or vehicle.typeName or "Förderband"))
        return
    end

    vehicle.uchAutoTurnOnEnabled = true
    vehicle.uchAutoTurnOnDone = false

    -- S710 compatibility: keep its native loop disabled; the Universal Helper
    -- performs the actual start.
    if vehicle.autoTurnOnRecheckDone ~= nil or vehicle.autoTurnOnRecheckTimer ~= nil then
        vehicle.autoTurnOnRecheckDone = true
        vehicle.autoTurnOnRecheckTimer = math.huge
    end

    if UniversalAutoTurnOn ~= nil and UniversalAutoTurnOn.doRecheck ~= nil then
        local ok, err = pcall(UniversalAutoTurnOn.doRecheck, vehicle)
        if not ok then
            Logging.error(
                "[UniversalConveyorHelper][SETTINGS] AutoStart-Anwendung fehlgeschlagen: %s",
                tostring(err)
            )
        end
    end
end

function UniversalConveyorSettings:teleportToConveyor(vehicle)
    if vehicle == nil or vehicle.rootNode == nil or g_localPlayer == nil then
        Logging.warning(
            "[UniversalConveyorHelper][SETTINGS] Teleport fehlgeschlagen: Förderband oder Spieler nicht verfügbar"
        )
        return false
    end

    local x, y, z = getWorldTranslation(vehicle.rootNode)
    local dx, _, dz = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
    local distance = 3.0

    local tx = x + dx * distance
    local tz = z + dz * distance
    local ty = y + 1.0

    if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        local terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, tx, 0, tz)
        if terrainY ~= nil then
            ty = terrainY + 1.0
        end
    end

    local ok, err = pcall(function()
        g_localPlayer:teleportTo(tx, ty, tz, true, false)

        if g_localPlayer.setMovementYaw ~= nil then
            local lookX = x - tx
            local lookZ = z - tz

            if lookX ~= 0 or lookZ ~= 0 then
                g_localPlayer:setMovementYaw(MathUtil.getYRotationFromDirection(lookX, lookZ))
            end
        end
    end)

    if ok then
        Logging.info(
            "[UniversalConveyorHelper][SETTINGS] Teleport zu Förderband: %.2f / %.2f / %.2f",
            tx, ty, tz
        )
        return true
    else
        Logging.error(
            "[UniversalConveyorHelper][SETTINGS] Teleport fehlgeschlagen: %s",
            tostring(err)
        )
        return false
    end
end

function UniversalConveyorSettings:loadSettings()
    local xmlFile = XMLFile.loadIfExists(
        "UniversalConveyorHelperSettings",
        self.settingsFilename
    )

    if xmlFile == nil then
        return
    end

    local i = 0

    while true do
        local key = string.format(
            "%s.conveyor(%d)",
            UniversalConveyorSettings.SETTINGS_ROOT,
            i
        )

        local objectKey = xmlFile:getString(key .. "#key")

        if objectKey == nil then
            break
        end

        self.entriesByKey[objectKey] = {
            key = objectKey,
            name = xmlFile:getString(key .. "#name") or "Förderband",
            enabled = xmlFile:getBool(key .. "#enabled", true),
            typeName = xmlFile:getString(key .. "#typeName") or "Förderband",
            vehicle = nil
        }

        i = i + 1
    end

    xmlFile:delete()
end

function UniversalConveyorSettings:saveSettings()
    local xmlFile = XMLFile.create(
        "UniversalConveyorHelperSettings",
        self.settingsFilename,
        UniversalConveyorSettings.SETTINGS_ROOT
    )

    if xmlFile == nil then
        Logging.error(
            "[UniversalConveyorHelper][SETTINGS] Konnte settings.xml nicht erstellen: %s",
            tostring(self.settingsFilename)
        )
        return
    end

    xmlFile:setString(
        UniversalConveyorSettings.SETTINGS_ROOT .. "#version",
        UniversalConveyorSettings.VERSION
    )

    local i = 0

    for _, entry in pairs(self.entriesByKey) do
        local key = string.format(
            "%s.conveyor(%d)",
            UniversalConveyorSettings.SETTINGS_ROOT,
            i
        )

        xmlFile:setString(key .. "#key", entry.key)
        xmlFile:setString(
            key .. "#name",
            entry.name or entry.typeName or "Förderband"
        )
        xmlFile:setBool(key .. "#enabled", entry.enabled ~= false)
        xmlFile:setString(
            key .. "#typeName",
            entry.typeName or "Förderband"
        )

        i = i + 1
    end

    xmlFile:save()
    xmlFile:delete()
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

function UniversalConveyorSettings:update(dt)
    local delta = dt or 0
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
