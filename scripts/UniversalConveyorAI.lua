-- FS25 UniversalConveyorHelper
-- Extracted from UniversalConveyorSettings.lua to separate responsibilities.

function UniversalConveyorSettings:isSL8022(vehicle)
    if vehicle == nil then return false end
    local metadata = string.lower(table.concat({
        tostring(vehicle.configFileName or ""), tostring(vehicle.configFileNameClean or ""),
        tostring(vehicle.typeName or ""), tostring(vehicle.vehicleName or "")
    }, " "))
    return string.find(metadata, "sl8022", 1, true) ~= nil
        or string.find(metadata, "sl 80-22", 1, true) ~= nil
        or string.find(metadata, "quantum", 1, true) ~= nil
end

function UniversalConveyorSettings:isNativeConveyorMotorRunning(vehicle)
    if vehicle == nil then return false end
    if vehicle.getIsMotorStarted ~= nil then
        local ok, value = pcall(vehicle.getIsMotorStarted, vehicle)
        if ok then return value == true end
    end
    local motorized = vehicle.spec_motorized
    if motorized ~= nil then
        if motorized.isMotorStarted ~= nil then return motorized.isMotorStarted == true end
        if motorized.motorStarted ~= nil then return motorized.motorStarted == true end
    end
    return false
end

function UniversalConveyorSettings:queueNativeConveyorAIStart(vehicle, entry)
    if vehicle == nil or entry == nil then return false end

    vehicle.uchAIHelperStartPending = true
    vehicle.uchAIHelperInitialized = false
    vehicle.uchAIHelperPhase = "fold"
    vehicle.uchAIHelperWait = 0
    vehicle.uchAIHelperFoldRequested = false
    vehicle.uchAIHelperDischargeRequested = false
    vehicle.uchAIHelperAutoStartApplied = false

    -- The AI helper may need to start a conveyor whose motor was switched off.
    -- Reflect AutoStart in the saved UCH setting now, but defer applying it until
    -- after folding and discharge activation so the motor cannot interrupt setup.
    if not self:isNativeConveyorMotorRunning(vehicle) then
        entry.enabled = true
        vehicle.uchAutoTurnOnEnabled = true
        vehicle.uchAIHelperEnableAutoStart = true
        Logging.info("[UniversalConveyorHelper][AI] Motor AUS: UCH-Autostart für KI-Start vorgemerkt | vehicle=%s", tostring(entry.name or entry.typeName))
    else
        vehicle.uchAIHelperEnableAutoStart = false
    end
    return true
end

function UniversalConveyorSettings:setAIEnabled(vehicle, enabled)
    if not self:isSL8022(vehicle) then return false end
    local entry = self:getEntry(vehicle)
    if entry == nil then return false end
    entry.aiEnabled = enabled == true
    vehicle.uchAIHelperEnabled = entry.aiEnabled
    if entry.aiEnabled then
        self:queueNativeConveyorAIStart(vehicle, entry)
    else
        vehicle.uchAIHelperStartPending = false
        vehicle.uchAIHelperPhase = nil
        vehicle.uchAIHelperEnableAutoStart = false
        self:stopNativeConveyorAI(vehicle)
    end
    self:saveSettings()
    Logging.info("[UniversalConveyorHelper][AI] %s | enabled=%s | angle=%s | key=%s | vehicle=%s | pending=%s | server=%s",
        tostring(entry.name or entry.typeName), tostring(entry.aiEnabled), tostring(entry.aiAngle or 30),
        tostring(entry.key), tostring(vehicle), tostring(vehicle.uchAIHelperStartPending),
        tostring(g_currentMission ~= nil and g_currentMission.getIsServer ~= nil and g_currentMission:getIsServer() or g_server ~= nil))
    return true
end

-- SL 80-22 Quantum native AI runtime parameters.
-- AIConveyorBelt:setAIConveyorBeltAngle updates currentAngle, but an already
-- active native AI job may keep its old min/max world yaw. Refresh that range too.
UniversalConveyorSettings.QUANTUM_AI_MAX_SPEED_KMH = 1.0

function UniversalConveyorSettings:applySL8022NativeAIParameters(vehicle, angle)
    if vehicle == nil then return false end
    local spec = vehicle.spec_aiConveyorBelt
    if spec == nil then return false end

    -- Experimental scale correction: menu angle appears about 10x wider in-game.
    -- Keep the saved/displayed menu value unchanged; convert only at the native AI boundary.
    local menuAngle = math.max(5, math.min(50, math.floor((tonumber(angle) or 30) / 5 + 0.5) * 5))
    local requestedAngle = menuAngle / 10
    -- Direct assignment preserves sub-degree values; the native setter/input step may clamp them.
    spec.currentAngle = requestedAngle

    -- The native specialization multiplies currentSpeed by spec.speed (m/s).
    -- Convert the configured target speed from km/h to m/s. Apply only to the SL 80-22 AI job.
    local maxSpeedMps = self.QUANTUM_AI_MAX_SPEED_KMH / 3.6
    spec.speed = maxSpeedMps

    -- Recalculate the native AI's target yaw window from the conveyor's current
    -- forward direction. This makes angle changes effective while the job runs.
    if vehicle.components ~= nil and vehicle.components[1] ~= nil and vehicle.components[1].node ~= nil
        and localDirectionToWorld ~= nil and MathUtil ~= nil and MathUtil.getYRotationFromDirection ~= nil then
        local dx, _, dz = localDirectionToWorld(vehicle.components[1].node, 0, 0, 1)
        local yRot = MathUtil.getYRotationFromDirection(dx, dz)
        local halfAngle = math.rad(requestedAngle) / 2
        spec.minTargetWorldYRot = yRot - halfAngle
        spec.maxTargetWorldYRot = yRot + halfAngle
    end

    Logging.info("[UniversalConveyorHelper][AI][QUANTUM_PARAMS] menuAngle=%s | nativeAngle=%s | currentAngle=%s | minYaw=%s | maxYaw=%s | speedKmh=%s | vehicle=%s",
        tostring(menuAngle), tostring(requestedAngle), tostring(spec.currentAngle),
        tostring(spec.minTargetWorldYRot), tostring(spec.maxTargetWorldYRot),
        tostring(self.QUANTUM_AI_MAX_SPEED_KMH), tostring(vehicle.configFileName or vehicle.typeName))
    return true
end

function UniversalConveyorSettings:setAIAngle(vehicle, angle)
    if not self:isSL8022(vehicle) then return false end
    local entry = self:getEntry(vehicle)
    if entry == nil then return false end
    angle = math.max(5, math.min(50, math.floor((tonumber(angle) or 30) / 5 + 0.5) * 5))
    entry.aiAngle = angle
    self:applySL8022NativeAIParameters(vehicle, angle)
    self:saveSettings()
    return true
end

function UniversalConveyorSettings:stopNativeConveyorAI(vehicle)
    local aiSystem = g_currentMission ~= nil and g_currentMission.aiSystem or nil
    if aiSystem == nil or vehicle == nil then return end
    local activeJobs = aiSystem.activeJobs or {}
    for _, job in ipairs(activeJobs) do
        local jobVehicle = nil
        if job.vehicleParameter ~= nil and job.vehicleParameter.getVehicle ~= nil then
            local ok, value = pcall(job.vehicleParameter.getVehicle, job.vehicleParameter)
            if ok then jobVehicle = value end
        end
        if jobVehicle == vehicle then
            pcall(aiSystem.stopJob, aiSystem, job, nil)
        end
    end
    if vehicle.aiIsStarted and vehicle.stopAIVehicle ~= nil then
        pcall(vehicle.stopAIVehicle, vehicle, AIVehicle.STOP_REASON_REGULAR)
    end
end

-- H toggles the UCH native AI job only while the player is inside an SL 80-22 Quantum.
-- The action event is registered only for this vehicle context and removed immediately
-- when the player leaves it, so other vehicles keep the game's standard H behaviour.

function UniversalConveyorSettings:updateQuantumHInput(dt)
    local mission = g_currentMission
    local player = mission ~= nil and mission.player or nil
    local localPlayer = g_localPlayer
    local vehicle = nil
    local source = nil

    -- FS25 can expose the local player and controlled vehicle through different
    -- references depending on loading/input context. Inspect all known candidates.
    if mission ~= nil and mission.controlledVehicle ~= nil then
        vehicle, source = mission.controlledVehicle, "mission.controlledVehicle"
    end

    if vehicle == nil and localPlayer ~= nil then
        if localPlayer.getCurrentVehicle ~= nil then
            local ok, currentVehicle = pcall(localPlayer.getCurrentVehicle, localPlayer)
            if ok and currentVehicle ~= nil then
                vehicle, source = currentVehicle, "g_localPlayer.getCurrentVehicle"
            end
        end
        if vehicle == nil and localPlayer.currentVehicle ~= nil then
            vehicle, source = localPlayer.currentVehicle, "g_localPlayer.currentVehicle"
        end
        if vehicle == nil and localPlayer.vehicle ~= nil then
            vehicle, source = localPlayer.vehicle, "g_localPlayer.vehicle"
        end
    end

    if vehicle == nil and player ~= nil then
        if player.getCurrentVehicle ~= nil then
            local ok, currentVehicle = pcall(player.getCurrentVehicle, player)
            if ok and currentVehicle ~= nil then
                vehicle, source = currentVehicle, "mission.player.getCurrentVehicle"
            end
        end
        if vehicle == nil and player.currentVehicle ~= nil then
            vehicle, source = player.currentVehicle, "mission.player.currentVehicle"
        end
        if vehicle == nil and player.vehicle ~= nil then
            vehicle, source = player.vehicle, "mission.player.vehicle"
        end
    end

    -- Last-resort supported accessor if the mission exposes it.
    if vehicle == nil and mission ~= nil and mission.getControlledVehicle ~= nil then
        local ok, currentVehicle = pcall(mission.getControlledVehicle, mission)
        if ok and currentVehicle ~= nil then
            vehicle, source = currentVehicle, "mission.getControlledVehicle"
        end
    end

    local isQuantum = vehicle ~= nil and self:isSL8022(vehicle) or false
    local input = g_inputBinding
    local vehicleLabel = "nil"
    if vehicle ~= nil then
        vehicleLabel = tostring(vehicle.configFileName or vehicle.configFileNameClean
            or vehicle.typeName or vehicle.vehicleName or vehicle.name or "vehicle-without-name")
    end

    local signature = table.concat({
        tostring(vehicle), tostring(source), tostring(isQuantum), vehicleLabel,
        tostring(player ~= nil), tostring(localPlayer ~= nil),
        tostring(mission ~= nil and mission.controlledVehicle ~= nil),
        tostring(input ~= nil)
    }, "|")

    -- Always emit a heartbeat every ~2 seconds, even if the signature never changes.
    -- This is intentional diagnostic logging to prove whether the manager keeps updating
    -- while the player is seated in the Quantum.
    self.quantumHDiagnosticTimer = (self.quantumHDiagnosticTimer or 0) - (dt or 0)
    local changed = self.quantumHDiagnosticSignature ~= signature
    if changed or self.quantumHDiagnosticTimer <= 0 then
        self.quantumHDiagnosticSignature = signature
        self.quantumHDiagnosticTimer = 2000
        Logging.info("[UniversalConveyorHelper][AI][H_VEHICLE_CHECK] source=%s | vehicle=%s | isQuantum=%s | missionPlayer=%s | localPlayer=%s | missionControlled=%s | inputBinding=%s",
            tostring(source), vehicleLabel, tostring(isQuantum), tostring(player ~= nil),
            tostring(localPlayer ~= nil), tostring(mission ~= nil and mission.controlledVehicle ~= nil),
            tostring(input ~= nil))
        if vehicle ~= nil then
            Logging.info("[UniversalConveyorHelper][AI][H_VEHICLE_DETAILS] object=%s | configFileName=%s | configFileNameClean=%s | typeName=%s | vehicleName=%s | rootVehicle=%s | isServer=%s | isClient=%s",
                tostring(vehicle), tostring(vehicle.configFileName), tostring(vehicle.configFileNameClean),
                tostring(vehicle.typeName), tostring(vehicle.vehicleName), tostring(vehicle.rootVehicle),
                tostring(vehicle.isServer), tostring(vehicle.isClient))
        end
    end

    if input == nil then return end

    if isQuantum then
        if self.quantumHActionEventId == nil then
            local actionName = "UCH_QUANTUM_AI_TOGGLE"
            local ok, registered, eventId, collision = pcall(input.registerActionEvent, input, actionName, self,
                UniversalConveyorSettings.onQuantumHPressed, false, true, false, true)
            Logging.info("[UniversalConveyorHelper][AI][H_REGISTER_ATTEMPT] action=%s | pcallOk=%s | registered=%s | eventId=%s | collision=%s | vehicle=%s",
                actionName, tostring(ok), tostring(registered), tostring(eventId), tostring(collision), vehicleLabel)
            if ok and registered and eventId ~= nil then
                self.quantumHActionEventId = eventId
                self.quantumHVehicle = vehicle
                if input.setActionEventTextVisibility ~= nil then
                    pcall(input.setActionEventTextVisibility, input, eventId, false)
                end
                Logging.info("[UniversalConveyorHelper][AI][H_BIND] registriert | action=%s | vehicle=%s | source=%s",
                    actionName, vehicleLabel, tostring(source))
            else
                Logging.warning("[UniversalConveyorHelper][AI][H_BIND] Registrierung fehlgeschlagen | action=%s | pcallOk=%s | registered=%s | eventId=%s | collision=%s",
                    actionName, tostring(ok), tostring(registered), tostring(eventId), tostring(collision))
            end
        elseif self.quantumHVehicle ~= vehicle then
            if input.removeActionEvent ~= nil then pcall(input.removeActionEvent, input, self.quantumHActionEventId) end
            self.quantumHActionEventId, self.quantumHVehicle = nil, nil
            Logging.info("[UniversalConveyorHelper][AI][H_BIND] Fahrzeugwechsel erkannt; alte H-Aktion entfernt")
        end
    elseif self.quantumHActionEventId ~= nil then
        if input.removeActionEvent ~= nil then pcall(input.removeActionEvent, input, self.quantumHActionEventId) end
        self.quantumHActionEventId, self.quantumHVehicle = nil, nil
        Logging.info("[UniversalConveyorHelper][AI][H_BIND] Quantum verlassen; H-Aktion entfernt")
    end
end

function UniversalConveyorSettings:onQuantumHPressed(actionName, inputValue)
    local vehicle = self.quantumHVehicle
    Logging.info("[UniversalConveyorHelper][AI][H_PRESS] action=%s | value=%s | vehicle=%s",
        tostring(actionName), tostring(inputValue), tostring(vehicle ~= nil and (vehicle.configFileName or vehicle.typeName) or "nil"))
    if vehicle == nil or not self:isSL8022(vehicle) then return end
    local entry = self:getEntry(vehicle)
    if entry == nil then return end

    local running = vehicle.uchAIHelperInitialized == true or vehicle.uchAIHelperStartPending == true
    self:setAIEnabled(vehicle, not running)
    Logging.info("[UniversalConveyorHelper][AI][H_TOGGLE] requested=%s | vehicle=%s",
        tostring(not running), tostring(entry.name or entry.typeName))
end

function UniversalConveyorSettings:updateNativeConveyorAI(dt)
    -- FS25 uses Mission:getIsServer() as the supported authority check.
    -- Do not gate this state machine on a possibly absent mission.isServer field:
    -- if that field is nil, the whole Quantum setup silently never runs.
    local mission = g_currentMission
    local isServer = false
    if mission ~= nil then
        if mission.getIsServer ~= nil then
            local ok, value = pcall(mission.getIsServer, mission)
            isServer = ok and value == true
        else
            isServer = g_server ~= nil
        end
    end

    if not self.nativeAIDiagnosticLogged then
        self.nativeAIDiagnosticLogged = true
        Logging.info("[UniversalConveyorHelper][AI][UPDATE_GATE] mission=%s | mission.isServer=%s | getIsServer=%s | g_server=%s | allowed=%s",
            tostring(mission ~= nil),
            tostring(mission ~= nil and mission.isServer or "nil"),
            tostring(mission ~= nil and mission.getIsServer ~= nil),
            tostring(g_server ~= nil),
            tostring(isServer))
    end

    if mission == nil or not isServer then return end
    local aiSystem = mission.aiSystem

    for _, entry in pairs(self.entriesByKey) do
        local vehicle = entry.vehicle
        if vehicle ~= nil and self:isSL8022(vehicle) then
            vehicle.uchAIHelperEnabled = entry.aiEnabled == true

            if entry.aiEnabled == true and vehicle.uchAIHelperStartPending then
                if not vehicle.uchAIHelperPendingLogged then
                    vehicle.uchAIHelperPendingLogged = true
                    Logging.info("[UniversalConveyorHelper][AI][PENDING_FOUND] key=%s | entryVehicle=%s | vehicle=%s | type=%s | phase=%s",
                        tostring(entry.key), tostring(entry.vehicle), tostring(vehicle),
                        tostring(vehicle.typeName or vehicle.configFileNameClean or vehicle.configFileName),
                        tostring(vehicle.uchAIHelperPhase))
                end
                vehicle.uchAIHelperWait = (vehicle.uchAIHelperWait or 0) + (dt or 0)
                local phase = vehicle.uchAIHelperPhase or "fold"
                local foldSpec = vehicle.spec_foldable

                if not vehicle.uchAIHelperPhaseLogged or vehicle.uchAIHelperLastLoggedPhase ~= phase then
                    vehicle.uchAIHelperPhaseLogged = true
                    vehicle.uchAIHelperLastLoggedPhase = phase
                    Logging.info("[UniversalConveyorHelper][AI][PHASE] vehicle=%s | phase=%s | aiSystemReady=%s | foldSpec=%s | foldTime=%s | dischargeSpec=%s",
                        tostring(entry.name or entry.typeName), tostring(phase), tostring(aiSystem ~= nil),
                        tostring(foldSpec ~= nil), tostring(foldSpec ~= nil and foldSpec.foldAnimTime or "n/a"),
                        tostring(vehicle.spec_dischargeable ~= nil))
                end

                if phase == "fold" then
                    if foldSpec == nil or vehicle.setFoldDirection == nil then
                        vehicle.uchAIHelperStartPending = false
                        entry.aiEnabled = false
                        self:saveSettings()
                        Logging.warning("[UniversalConveyorHelper][AI] Fold-Vorbereitung nicht verfügbar; KI-Start abgebrochen | vehicle=%s", tostring(entry.name or entry.typeName))
                    else
                        if not vehicle.uchAIHelperFoldRequested then
                            -- The Quantum XML defines turnOnFoldDirection=1 and its folding
                            -- animation runs from 0 to 3 seconds. Use the configured direction
                            -- instead of inverting it (which requested the opposite movement).
                            local foldDirection = foldSpec.turnOnFoldDirection or 1
                            local ok, result = pcall(vehicle.setFoldDirection, vehicle, foldDirection)
                            vehicle.uchAIHelperFoldRequested = ok and result ~= false
                            Logging.info("[UniversalConveyorHelper][AI] Fold-Anforderung (X) | vehicle=%s | direction=%s | targetTime=%s | currentTime=%s | ok=%s | result=%s", tostring(entry.name or entry.typeName), tostring(foldDirection), tostring(foldDirection > 0 and 3 or 0), tostring(foldSpec.foldAnimTime), tostring(ok), tostring(result))
                            if not vehicle.uchAIHelperFoldRequested then
                                vehicle.uchAIHelperStartPending = false
                                entry.aiEnabled = false
                                self:saveSettings()
                                Logging.warning("[UniversalConveyorHelper][AI] Einklappen konnte nicht angefordert werden; KI-Start abgebrochen | vehicle=%s", tostring(entry.name or entry.typeName))
                            end
                        end

                        local foldDirection = foldSpec.turnOnFoldDirection or 1
                        -- Foldable.foldAnimTime is the normalized fold state (0..1).
                        -- The I3D animation duration may be 3 seconds, but that is NOT the
                        -- target value of spec_foldable.foldAnimTime. The latest log confirms
                        -- the wheel movement reaches foldTime=1; comparing it to 3 caused
                        -- UCH to abort before the discharge phase.
                        local foldTarget = foldDirection > 0 and 1 or 0
                        local foldTime = tonumber(foldSpec.foldAnimTime) or 0
                        local folding = math.abs(foldTime - foldTarget) > 0.05
                        if vehicle.uchAIHelperStartPending and vehicle.uchAIHelperWait >= 500 and not folding then
                            vehicle.uchAIHelperPhase = "discharge"
                            vehicle.uchAIHelperWait = 0
                            Logging.info("[UniversalConveyorHelper][AI] Faltbewegung abgeschlossen; aktiviere Abladen | vehicle=%s | foldTime=%s", tostring(entry.name or entry.typeName), tostring(foldTime))
                        elseif vehicle.uchAIHelperWait > 8000 and folding then
                            vehicle.uchAIHelperStartPending = false
                            entry.aiEnabled = false
                            self:saveSettings()
                            Logging.warning("[UniversalConveyorHelper][AI] Faltbewegung wurde nicht bestätigt; KI-Start abgebrochen | vehicle=%s | foldTime=%s | target=%s", tostring(entry.name or entry.typeName), tostring(foldTime), tostring(foldTarget))
                        end
                    end

                elseif phase == "discharge" then
                    local dischargeSpec = vehicle.spec_dischargeable
                    local dischargeNode = vehicle.getCurrentDischargeNode ~= nil and vehicle:getCurrentDischargeNode()
                        or (dischargeSpec ~= nil and dischargeSpec.currentDischargeNode or nil)
                    local targetState = nil
                    local canDischargeObject = false
                    local canDischargeGround = false

                    if dischargeNode ~= nil and vehicle.getCanDischargeToObject ~= nil then
                        local ok, value = pcall(vehicle.getCanDischargeToObject, vehicle, dischargeNode)
                        canDischargeObject = ok and value == true
                    elseif dischargeNode ~= nil then
                        canDischargeObject = dischargeNode.canDischargeToObject == true
                    end
                    if dischargeNode ~= nil and vehicle.getCanDischargeToGround ~= nil then
                        local ok, value = pcall(vehicle.getCanDischargeToGround, vehicle, dischargeNode)
                        canDischargeGround = ok and value == true
                    end

                    if Dischargeable ~= nil then
                        if canDischargeObject then
                            targetState = Dischargeable.DISCHARGE_STATE_OBJECT
                        elseif canDischargeGround then
                            targetState = Dischargeable.DISCHARGE_STATE_GROUND
                        end
                    end

                    Logging.info("[UniversalConveyorHelper][AI][DISCHARGE_CHECK] vehicle=%s | node=%s | nodeIndex=%s | getNodeMethod=%s | canObjectMethod=%s | canGroundMethod=%s | canObject=%s | canGround=%s | targetState=%s | currentState=%s",
                        tostring(entry.name or entry.typeName), tostring(dischargeNode ~= nil),
                        tostring(vehicle.getCurrentDischargeNodeIndex ~= nil and vehicle:getCurrentDischargeNodeIndex() or 0),
                        tostring(vehicle.getCurrentDischargeNode ~= nil),
                        tostring(vehicle.getCanDischargeToObject ~= nil),
                        tostring(vehicle.getCanDischargeToGround ~= nil),
                        tostring(canDischargeObject), tostring(canDischargeGround), tostring(targetState),
                        tostring(dischargeSpec ~= nil and dischargeSpec.currentDischargeState or "n/a"))

                    if dischargeSpec == nil or vehicle.setDischargeState == nil or targetState == nil then
                        vehicle.uchAIHelperStartPending = false
                        entry.aiEnabled = false
                        self:saveSettings()
                        Logging.warning("[UniversalConveyorHelper][AI] Native Abladen nicht möglich: kein gültiger DischargeNode oder weder Objekt- noch Bodenabladen freigegeben | vehicle=%s", tostring(entry.name or entry.typeName))
                    else
                        local currentState = vehicle.getDischargeState ~= nil and vehicle:getDischargeState() or dischargeSpec.currentDischargeState
                        if currentState ~= targetState and not vehicle.uchAIHelperDischargeRequested then
                            local ok, result = pcall(vehicle.setDischargeState, vehicle, targetState)
                            vehicle.uchAIHelperDischargeRequested = ok and result ~= false
                            Logging.info("[UniversalConveyorHelper][AI] Abladen-Anforderung (Steuerung I) | vehicle=%s | state=%s | node=%s | ok=%s | result=%s", tostring(entry.name or entry.typeName), tostring(targetState), tostring(vehicle.getCurrentDischargeNodeIndex ~= nil and vehicle:getCurrentDischargeNodeIndex() or 0), tostring(ok), tostring(result))
                            if not vehicle.uchAIHelperDischargeRequested then
                                vehicle.uchAIHelperStartPending = false
                                entry.aiEnabled = false
                                self:saveSettings()
                                Logging.warning("[UniversalConveyorHelper][AI] Abladen konnte nicht aktiviert werden; KI-Start abgebrochen | vehicle=%s", tostring(entry.name or entry.typeName))
                            end
                        end

                        local activeDischargeState = vehicle.getDischargeState ~= nil and vehicle:getDischargeState() or dischargeSpec.currentDischargeState
                        if vehicle.uchAIHelperStartPending and activeDischargeState == targetState then
                            vehicle.uchAIHelperPhase = "autostart"
                            vehicle.uchAIHelperWait = 0
                            Logging.info("[UniversalConveyorHelper][AI] Abladen aktiv; bereite Motorstart vor | vehicle=%s", tostring(entry.name or entry.typeName))
                        elseif vehicle.uchAIHelperStartPending and vehicle.uchAIHelperWait > 3000 then
                            vehicle.uchAIHelperStartPending = false
                            entry.aiEnabled = false
                            self:saveSettings()
                            Logging.warning("[UniversalConveyorHelper][AI] Abladen-Zustand wurde nicht bestätigt; KI-Start abgebrochen | vehicle=%s | state=%s", tostring(entry.name or entry.typeName), tostring(activeDischargeState))
                        end
                    end

                elseif phase == "autostart" then
                    if not vehicle.uchAIHelperAutoStartApplied then
                        if vehicle.uchAIHelperEnableAutoStart then
                            -- This updates the UCH AutoStart runtime gate and starts the motor only
                            -- after the fold and discharge preparation have completed.
                            self:applyRuntimeState(vehicle)
                        end
                        vehicle.uchAIHelperAutoStartApplied = true
                        vehicle.uchAIHelperMotorWait = 0
                        Logging.info("[UniversalConveyorHelper][AI] AutoStart angefordert; warte auf echten Motor- und Förderbandstatus | vehicle=%s | autoStart=%s",
                            tostring(entry.name or entry.typeName), tostring(entry.enabled == true))
                    end

                    local motorRunning = self:isNativeConveyorMotorRunning(vehicle)
                    local conveyorOn = false
                    local conveyorStateKnown = false
                    if vehicle.getIsTurnedOn ~= nil then
                        local stateOk, stateValue = pcall(vehicle.getIsTurnedOn, vehicle)
                        if stateOk and type(stateValue) == "boolean" then
                            conveyorOn = stateValue
                            conveyorStateKnown = true
                        end
                    end

                    if motorRunning and (conveyorOn or not conveyorStateKnown) then
                        vehicle.uchAIHelperPhase = "startJob"
                        vehicle.uchAIHelperWait = 0
                        vehicle.uchAIHelperMotorWait = nil
                        Logging.info("[UniversalConveyorHelper][AI] Motor/Förderband bereit; native Jobprüfung folgt | vehicle=%s | motorRunning=%s | conveyorOn=%s | stateKnown=%s",
                            tostring(entry.name or entry.typeName), tostring(motorRunning), tostring(conveyorOn),
                            tostring(conveyorStateKnown))
                    elseif (vehicle.uchAIHelperMotorWait or 0) > 8000 then
                        vehicle.uchAIHelperStartPending = false
                        entry.aiEnabled = false
                        vehicle.uchAIHelperPhase = nil
                        vehicle.uchAIHelperEnableAutoStart = false
                        self:saveSettings()
                        Logging.warning("[UniversalConveyorHelper][AI] Motor/Förderband wurde nicht bereit; KI-Start abgebrochen | vehicle=%s | motorRunning=%s | conveyorOn=%s | stateKnown=%s",
                            tostring(entry.name or entry.typeName), tostring(motorRunning), tostring(conveyorOn),
                            tostring(conveyorStateKnown))
                    else
                        vehicle.uchAIHelperMotorWait = (vehicle.uchAIHelperMotorWait or 0) + dt
                    end

                elseif phase == "startJob" then
                    if aiSystem == nil then
                        if not vehicle.uchAIHelperJobWaitLogged then
                            vehicle.uchAIHelperJobWaitLogged = true
                            Logging.warning("[UniversalConveyorHelper][AI][JOB_WAIT] AI-System noch nicht verfügbar; Jobstart wird erneut versucht | vehicle=%s",
                                tostring(entry.name or entry.typeName))
                        end
                    else
                        vehicle.uchAIHelperJobWaitLogged = nil
                    local spec = vehicle.spec_aiConveyorBelt
                    local job = spec ~= nil and spec.conveyorJob or nil
                    if job == nil or vehicle.setAIConveyorBeltAngle == nil then
                        vehicle.uchAIHelperStartPending = false
                        entry.aiEnabled = false
                        self:saveSettings()
                        Logging.warning("[UniversalConveyorHelper][AI] Native AIConveyorBelt/Job fehlt | vehicle=%s", tostring(entry.name or entry.typeName))
                    else
                        self:applySL8022NativeAIParameters(vehicle, entry.aiAngle or 30)
                        local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or (g_currentMission.player and g_currentMission.player.farmId) or 1
                        local applied, applyResult = pcall(job.applyCurrentState, job, vehicle, g_currentMission, farmId, true)
                        if applied and applyResult ~= false then
                            -- applyCurrentState can initialize/reset the native angle window.
                            -- Reapply the requested UCH angle after that initialization but
                            -- before validation and startJob, so the native job sees the setting.
                            self:applySL8022NativeAIParameters(vehicle, entry.aiAngle or 30)
                            Logging.info("[UniversalConveyorHelper][AI][ANGLE_BEFORE_START] requested=%s | current=%s | minYaw=%s | maxYaw=%s | vehicle=%s",
                                tostring(entry.aiAngle or 30),
                                tostring(vehicle.spec_aiConveyorBelt ~= nil and vehicle.spec_aiConveyorBelt.currentAngle or "n/a"),
                                tostring(vehicle.spec_aiConveyorBelt ~= nil and vehicle.spec_aiConveyorBelt.minTargetWorldYRot or "n/a"),
                                tostring(vehicle.spec_aiConveyorBelt ~= nil and vehicle.spec_aiConveyorBelt.maxTargetWorldYRot or "n/a"),
                                tostring(entry.name or entry.typeName))
                        end
                        if applied and job.setValues ~= nil then pcall(job.setValues, job) end
                        local canStart = applied and applyResult ~= false
                        local startError = nil

                        -- Match the native AIManager direct-start path: it validates the
                        -- prepared job and then calls startJob. Do not gate this path with
                        -- getIsStartable(job, nil), because nil is not the player's native
                        -- connection context and can report VEHICLE_IN_USE while the player
                        -- is intentionally sitting in the conveyor.
                        if canStart and job.getIsStartable ~= nil then
                            local checkOk, allowed, errorState = pcall(job.getIsStartable, job, nil)
                            Logging.info("[UniversalConveyorHelper][AI][STARTABLE_DIAGNOSTIC] checkOk=%s | allowed=%s | error=%s | ignoredForDirectStart=true",
                                tostring(checkOk), tostring(allowed), tostring(errorState))
                        end
                        if canStart and job.validate ~= nil then
                            local checkOk, valid, validationError = pcall(job.validate, job, farmId)
                            canStart = checkOk and valid == true
                            if not canStart then startError = validationError end
                        end
                        if canStart then
                            local ok, result = pcall(aiSystem.startJob, aiSystem, job, farmId)
                            if ok and result ~= false then
                                vehicle.uchAIHelperStartPending = false
                                vehicle.uchAIHelperInitialized = true
                                vehicle.uchAIHelperJob = job
                                vehicle.uchAIHelperPhase = nil
                                vehicle.uchAIHelperEnableAutoStart = false
                                Logging.info("[UniversalConveyorHelper][AI] Native AIJobConveyor gestartet | vehicle=%s | angle=%d", tostring(entry.name or entry.typeName), entry.aiAngle or 30)
                            else
                                vehicle.uchAIHelperStartPending = false
                                entry.aiEnabled = false
                                vehicle.uchAIHelperPhase = nil
                                self:saveSettings()
                                Logging.error("[UniversalConveyorHelper][AI] Start fehlgeschlagen: %s", tostring(result))
                            end
                        else
                            vehicle.uchAIHelperStartPending = false
                            entry.aiEnabled = false
                            vehicle.uchAIHelperPhase = nil
                            self:saveSettings()
                            Logging.warning("[UniversalConveyorHelper][AI] Native Job-Validierung fehlgeschlagen | vehicle=%s | error=%s", tostring(entry.name or entry.typeName), tostring(startError))
                        end
                    end
                    end -- aiSystem available
                end

                if vehicle.uchAIHelperWait > 12000 and vehicle.uchAIHelperStartPending then
                    local timedOutPhase = vehicle.uchAIHelperPhase or phase
                    vehicle.uchAIHelperStartPending = false
                    entry.aiEnabled = false
                    vehicle.uchAIHelperPhase = nil
                    self:saveSettings()
                    Logging.warning("[UniversalConveyorHelper][AI] Startablauf überschritt Zeitlimit | vehicle=%s | phase=%s", tostring(entry.name or entry.typeName), tostring(timedOutPhase))
                end

            elseif entry.aiEnabled == true and vehicle.uchAIHelperStartPending == nil and vehicle.uchAIHelperInitialized ~= true then
                -- Restore a saved ON state after loading a savegame, once the vehicle is ready.
                self:queueNativeConveyorAIStart(vehicle, entry)
            end
        end
    end
end

function UniversalConveyorSettings.installQuantumAngleStartHook()
    if UniversalConveyorSettings.quantumAngleHookInstalled then return end
    if AIConveyorBelt == nil or AIConveyorBelt.onAIFieldWorkerStart == nil then
        Logging.warning("[UniversalConveyorHelper][AI][ANGLE_HOOK] AIConveyorBelt callback not available")
        return
    end
    local original = AIConveyorBelt.onAIFieldWorkerStart
    AIConveyorBelt.onAIFieldWorkerStart = function(vehicle, ...)
        local manager = UniversalConveyorSettings.instance
        if manager ~= nil and vehicle ~= nil and manager:isSL8022(vehicle) then
            local entry = manager:getEntry(vehicle)
            local menuAngle = entry ~= nil and tonumber(entry.aiAngle) or nil
            if menuAngle ~= nil and vehicle.spec_aiConveyorBelt ~= nil then
                local spec = vehicle.spec_aiConveyorBelt
                local nativeAngle = menuAngle / 10
                -- Must match applySL8022NativeAIParameters and run before native yaw initialization.
                spec.currentAngle = nativeAngle
                Logging.info("[UniversalConveyorHelper][AI][ANGLE_HOOK] applying scale=0.1 | menuAngle=%s | nativeAngle=%s | vehicle=%s",
                    tostring(menuAngle), tostring(nativeAngle), tostring(entry.name or entry.typeName))
            end
        end
        original(vehicle, ...)
        local manager = UniversalConveyorSettings.instance
        if vehicle ~= nil and manager ~= nil and manager:isSL8022(vehicle)
            and vehicle.spec_aiConveyorBelt ~= nil then
            local spec = vehicle.spec_aiConveyorBelt
            -- Keep the native angle value used by the working visual angle correction,
            -- but restore the sweep range from the user's menu angle. The native callback
            -- builds this range from spec.currentAngle (scaled to 0.1 for this Quantum),
            -- which leaves only a 0.5-degree sweep for a 5-degree menu setting.
            local entry = manager:getEntry(vehicle)
            local menuAngle = entry ~= nil and tonumber(entry.aiAngle) or nil
            if menuAngle ~= nil and vehicle.components ~= nil and vehicle.components[1] ~= nil
                and vehicle.components[1].node ~= nil and localDirectionToWorld ~= nil
                and MathUtil ~= nil and MathUtil.getYRotationFromDirection ~= nil then
                local dx, _, dz = localDirectionToWorld(vehicle.components[1].node, 0, 0, 1)
                local yRot = MathUtil.getYRotationFromDirection(dx, dz)
                local halfSweep = math.rad(math.max(5, math.min(50, menuAngle))) / 2
                spec.minTargetWorldYRot = yRot - halfSweep
                spec.maxTargetWorldYRot = yRot + halfSweep
            end
            Logging.info("[UniversalConveyorHelper][AI][ANGLE_HOOK] native range restored | minYaw=%s | maxYaw=%s | currentAngle=%s | menuSweepAngle=%s | vehicle=%s",
                tostring(spec.minTargetWorldYRot), tostring(spec.maxTargetWorldYRot), tostring(spec.currentAngle),
                tostring(menuAngle), tostring(entry ~= nil and (entry.name or entry.typeName) or "unknown"))
        end
    end
    UniversalConveyorSettings.quantumAngleHookInstalled = true
    Logging.info("[UniversalConveyorHelper][AI][ANGLE_HOOK] native start hook installed")
end
