-- FS25 UniversalConveyorHelper
-- Extracted from UniversalConveyorSettings.lua to separate responsibilities.

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
            enabled = false,
            aiEnabled = false,
            aiAngle = 30,
            typeName = self:getDisplayType(vehicle)
        }

        self.entriesByKey[key] = entry
    else
        entry.vehicle = vehicle
        entry.typeName = self:getDisplayType(vehicle)
        if entry.enabled == nil then entry.enabled = false end
        if entry.aiEnabled == nil then entry.aiEnabled = false end
        if entry.aiAngle == nil then entry.aiAngle = 30 end

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

    -- Keep the settings GUI aligned with the same shop-category gate used by
    -- UCH AutoStart. Genuine conveyor-like objects outside the "belts" shop
    -- category (for example Hu_super) must not become configurable UCH entries.
    -- If the store item cannot be resolved, retain the existing native detection
    -- rather than hiding otherwise valid modded conveyors without evidence.
    if UniversalConveyorHelper ~= nil
        and UniversalConveyorHelper.isShopCategoryConveyorBelt ~= nil
    then
        local eligible, reason = UniversalConveyorHelper:isShopCategoryConveyorBelt(vehicle)
        if not eligible and reason == "categoryNotBelts" then
            return false
        end
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
