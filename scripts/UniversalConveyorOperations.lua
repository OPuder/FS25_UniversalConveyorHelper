-- FS25 UniversalConveyorHelper
-- Extracted from UniversalConveyorSettings.lua to separate responsibilities.

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
            enabled = xmlFile:getBool(key .. "#enabled", false),
            aiEnabled = xmlFile:getBool(key .. "#aiEnabled", false),
            aiAngle = math.max(5, math.min(50, math.floor((xmlFile:getFloat(key .. "#aiAngle", 30) + 0.5) / 5) * 5)),
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
        xmlFile:setBool(key .. "#enabled", entry.enabled == true)
        xmlFile:setBool(key .. "#aiEnabled", entry.aiEnabled == true)
        xmlFile:setFloat(key .. "#aiAngle", entry.aiAngle or 30)
        xmlFile:setString(
            key .. "#typeName",
            entry.typeName or "Förderband"
        )

        i = i + 1
    end

    xmlFile:save()
    xmlFile:delete()
end
