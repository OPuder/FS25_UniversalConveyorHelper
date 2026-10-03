-- Universal Conveyor Helper 1.9.38
-- Controller for the custom Förderbänder settings page.

UniversalConveyorSettingsPage = {}

local UniversalConveyorSettingsPage_mt = Class(UniversalConveyorSettingsPage, FrameElement)
local baseDir = g_currentModDirectory

function UniversalConveyorSettingsPage.register(settingsManager)
    local page = UniversalConveyorSettingsPage.new()
    page.controller = settingsManager

    local guiPath = Utils.getFilename("gui/UniversalConveyorSettingsPage.xml", baseDir)
    local loaded = g_gui:loadGui(guiPath, "UniversalConveyorSettingsPage", page)

    if loaded == nil then
        Logging.error("[UniversalConveyorHelper][SETTINGS] GUI konnte nicht geladen werden: %s", tostring(guiPath))
        return nil
    end

    Logging.info("[UniversalConveyorHelper][SETTINGS] GUI-Datei geladen: %s", tostring(guiPath))
    return page
end

function UniversalConveyorSettingsPage.new(customMt)
    local self = FrameElement.new(nil, customMt or UniversalConveyorSettingsPage_mt)
    self.controller = nil
    self.rows = {}
    self.elementToRow = {}
    self.elementToInfo = {}
    self.isOpen = false
    self.isRefreshing = false
    self.nameDrafts = {}
    self.focusedRowIndex = nil
    self.lastInfoElement = nil
    return self
end

function UniversalConveyorSettingsPage:setInfo(text)
    if self.uchInfoText ~= nil then
        self.uchInfoText:setText(text or "")
    end
end

function UniversalConveyorSettingsPage:updateInfoForElement(element)
    if element == nil or self.rows == nil then
        return
    end

    local rowIndex = self.elementToRow[element]
    local infoKind = self.elementToInfo[element]

    -- Mouse highlighting can land on a child element of a composite control.
    -- Walk up the GUI hierarchy until we reach the registered control.
    local current = element
    while rowIndex == nil and current ~= nil do
        current = current.parent
        if current ~= nil then
            rowIndex = self.elementToRow[current]
            infoKind = self.elementToInfo[current]
        end
    end

    if rowIndex == nil or self.rows[rowIndex] == nil then
        return
    end

    local rowData = self.rows[rowIndex]
    local text = nil

    if infoKind == "type" or element == rowData.typeText then
        text = g_i18n:getText("uch_ui_typeInfo")
    elseif infoKind == "name" or element == rowData.nameInput then
        text = g_i18n:getText("uch_ui_nameInfo")
    elseif infoKind == "automation" or element == rowData.enabled then
        text = g_i18n:getText("uch_ui_automationInfo")
    elseif infoKind == "teleport" or element == rowData.teleport then
        text = g_i18n:getText("uch_ui_teleportInfo")
    end

    if text ~= nil then
        self.lastInfoElement = element
        self.focusedRowIndex = rowIndex
        self:setInfo(text)
    end
end

function UniversalConveyorSettingsPage:update(dt)
    UniversalConveyorSettingsPage:superClass().update(self, dt)

    if not self.isOpen then
        return
    end

    -- FS25 keeps mouse highlight and keyboard/controller focus as separate
    -- states. The FocusManager stores the element currently under the mouse
    -- in currentFocusData.highlightElement. Always prefer that element so the
    -- help text follows the mouse when moving from one control to another.
    local highlightedElement = nil
    if FocusManager ~= nil and FocusManager.currentFocusData ~= nil then
        highlightedElement = FocusManager.currentFocusData.highlightElement
    end

    if highlightedElement ~= nil and self.elementToRow[highlightedElement] ~= nil then
        self:updateInfoForElement(highlightedElement)
        return
    end

    -- If the mouse is not over one of our controls, fall back to the normal
    -- keyboard/controller focus.
    if FocusManager ~= nil and FocusManager.getFocusedElement ~= nil then
        local focusedElement = FocusManager:getFocusedElement()
        if focusedElement ~= nil and self.elementToRow[focusedElement] ~= nil then
            self:updateInfoForElement(focusedElement)
        end
    end
end

function UniversalConveyorSettingsPage:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    -- Let the native FS25 GUI elements and FocusManager handle mouse
    -- highlighting. The update() method reads highlightElement directly.
    return UniversalConveyorSettingsPage:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
end

function UniversalConveyorSettingsPage:onHighlightRemove(element)
    -- Do not immediately overwrite the help text here. When the mouse moves
    -- between controls, FS25 removes the old highlight before setting the new
    -- one. update() will read the new highlightElement on the same frame.
end

function UniversalConveyorSettingsPage:onFocusType(element)
    self.lastInfoElement = nil
    if element ~= nil then
        self.focusedRowIndex = self.elementToRow[element] or self.focusedRowIndex
    end
    self:setInfo(g_i18n:getText("uch_ui_typeInfo"))
end

function UniversalConveyorSettingsPage:onFocusName(element)
    self.lastInfoElement = nil
    if element ~= nil then
        self.focusedRowIndex = self.elementToRow[element] or self.focusedRowIndex
    end
    self:setInfo(g_i18n:getText("uch_ui_nameInfo"))
end

function UniversalConveyorSettingsPage:onFocusAutomation(element)
    self.lastInfoElement = nil
    if element ~= nil then
        self.focusedRowIndex = self.elementToRow[element] or self.focusedRowIndex
    end
    self:setInfo(g_i18n:getText("uch_ui_automationInfo"))
end

function UniversalConveyorSettingsPage:onFocusTeleport(element)
    self.lastInfoElement = nil
    if element ~= nil then
        self.focusedRowIndex = self.elementToRow[element] or self.focusedRowIndex
    end
    self:setInfo(g_i18n:getText("uch_ui_teleportInfo"))
end

function UniversalConveyorSettingsPage:registerInfoElement(element, rowIndex, infoKind)
    if element == nil then
        return
    end

    self.elementToRow[element] = rowIndex
    self.elementToInfo[element] = infoKind

    -- Composite controls such as BinaryOption can highlight one of their
    -- child ButtonElements instead of the BinaryOption parent. Register all
    -- descendants AND attach the native ButtonElement highlight callback to
    -- those descendants. The parent BinaryOption itself does not load an
    -- onHighlight callback (it inherits GuiElement), while its left/right
    -- ButtonElements do. This is the important distinction for mouse hover.
    if element.elements ~= nil then
        for _, child in ipairs(element.elements) do
            self:registerInfoElement(child, rowIndex, infoKind)

            if child.onHighlightCallback ~= nil or child.onClickCallback ~= nil then
                child.target = self
                if infoKind == "type" then
                    child.onHighlightCallback = UniversalConveyorSettingsPage.onFocusType
                elseif infoKind == "name" then
                    child.onHighlightCallback = UniversalConveyorSettingsPage.onFocusName
                elseif infoKind == "automation" then
                    child.onHighlightCallback = UniversalConveyorSettingsPage.onFocusAutomation
                elseif infoKind == "teleport" then
                    child.onHighlightCallback = UniversalConveyorSettingsPage.onFocusTeleport
                end
                child.onHighlightRemoveCallback = UniversalConveyorSettingsPage.onHighlightRemove
            end
        end
    end
end

function UniversalConveyorSettingsPage:onGuiSetupFinished()
    UniversalConveyorSettingsPage:superClass().onGuiSetupFinished(self)

    self.rows = {}
    self.elementToRow = {}
    self.elementToInfo = {}

    for i = 1, 30 do
        local row = self["row" .. i]
        local nameInput = self["name" .. i]
        local enabled = self["enabled" .. i]
        local teleport = self["teleport" .. i]
        local typeText = self["type" .. i]

        self.rows[i] = {
            row = row,
            nameInput = nameInput,
            enabled = enabled,
            teleport = teleport,
            typeText = typeText,
            entry = nil
        }

        if typeText ~= nil then
            self:registerInfoElement(typeText, i, "type")
            typeText.target = self
            typeText.onFocusCallback = UniversalConveyorSettingsPage.onFocusType
            typeText.onHighlightCallback = UniversalConveyorSettingsPage.onFocusType
            typeText.onHighlightRemoveCallback = UniversalConveyorSettingsPage.onHighlightRemove
        end

        if nameInput ~= nil then
            self:registerInfoElement(nameInput, i, "name")

            -- Use both focus and highlight callbacks. Mouse hover in FS25
            -- raises the highlight callback, while controller/keyboard navigation
            -- raises the focus callback. Both must update our custom help panel.
            nameInput.target = self
            nameInput.onFocusCallback = UniversalConveyorSettingsPage.onFocusName
            nameInput.onHighlightCallback = UniversalConveyorSettingsPage.onFocusName
            nameInput.onHighlightRemoveCallback = UniversalConveyorSettingsPage.onHighlightRemove

            -- TextInputElement can use different colors for normal,
            -- highlighted, selected and disabled states. Force a readable
            -- white color for all states so the entered conveyor name stays
            -- visible on the dark FS25 input background.
            if nameInput.setTextColor ~= nil then
                nameInput:setTextColor(1, 1, 1, 1)
            end
            if nameInput.setTextHighlightedColor ~= nil then
                nameInput:setTextHighlightedColor(1, 1, 1, 1)
            end
            if nameInput.setTextSelectedColor ~= nil then
                nameInput:setTextSelectedColor(1, 1, 1, 1)
            end
            if nameInput.setTextDisabledColor ~= nil then
                nameInput:setTextDisabledColor(1, 1, 1, 1)
            end
        end
        if enabled ~= nil then
            self:registerInfoElement(enabled, i, "automation")
            enabled.target = self
            enabled.onClickCallback = function(state)
                self:onClickCheckbox(enabled, state)
            end
            enabled.onFocusCallback = UniversalConveyorSettingsPage.onFocusAutomation
            enabled.onHighlightCallback = UniversalConveyorSettingsPage.onFocusAutomation
            enabled.onHighlightRemoveCallback = UniversalConveyorSettingsPage.onHighlightRemove

            -- BinaryOption is a composite element. Its actual mouse target is
            -- one of the generated left/right ButtonElements. Wire both buttons
            -- explicitly so the help text changes on every mouse transition.
            if enabled.leftButtonElement ~= nil then
                enabled.leftButtonElement.target = self
                enabled.leftButtonElement.onHighlightCallback = UniversalConveyorSettingsPage.onFocusAutomation
                enabled.leftButtonElement.onHighlightRemoveCallback = UniversalConveyorSettingsPage.onHighlightRemove
            end
            if enabled.rightButtonElement ~= nil then
                enabled.rightButtonElement.target = self
                enabled.rightButtonElement.onHighlightCallback = UniversalConveyorSettingsPage.onFocusAutomation
                enabled.rightButtonElement.onHighlightRemoveCallback = UniversalConveyorSettingsPage.onHighlightRemove
            end
        end
        if teleport ~= nil then
            self:registerInfoElement(teleport, i, "teleport")
            teleport.target = self
            -- ButtonElement only creates a mouse highlight when handleFocus is
            -- enabled. The buttonActivate profile used by the teleport action
            -- does not guarantee that, so enable it explicitly.
            teleport.handleFocus = true
            teleport.focusOnHighlight = true
            teleport.onFocusCallback = UniversalConveyorSettingsPage.onFocusTeleport
            teleport.onHighlightCallback = UniversalConveyorSettingsPage.onFocusTeleport
            teleport.onHighlightRemoveCallback = UniversalConveyorSettingsPage.onHighlightRemove
        end
    end
end

function UniversalConveyorSettingsPage:onClickConveyorSettings()
    if g_inGameMenu ~= nil and g_inGameMenu.pageSettings ~= nil
        and g_inGameMenu.pageSettings.subCategoryPaging ~= nil
    then
        g_inGameMenu.pageSettings.subCategoryPaging:setState(
            InGameMenuSettingsFrame.SUB_CATEGORY.UCH_CONVEYORS,
            true
        )
    end
end

function UniversalConveyorSettingsPage:onFrameOpen()
    self.isOpen = true
    self.lastInfoElement = nil
    self:onTabOpen()
end

function UniversalConveyorSettingsPage:onTabOpen()
    if self.controller == nil then
        return
    end

    local entries = self.controller:scanConveyors(true)
    self:updateConveyors(entries)
    if self.uchInfoText ~= nil then
        self:setInfo(g_i18n:getText("uch_ui_pageInfo"))
    end
end

function UniversalConveyorSettingsPage:onFrameClose()
    self:commitAllNameInputs()
    self.isOpen = false
    self.isRefreshing = false
    self.focusedRowIndex = nil
    self.lastInfoElement = nil

    if self.controller ~= nil then
        self.controller:saveSettings()
    end
end

function UniversalConveyorSettingsPage:updateConveyors(entries)
    if self.rows == nil or #self.rows == 0 then
        return
    end

    local count = #entries
    self.isRefreshing = true

    for i = 1, #self.rows do
        local rowData = self.rows[i]
        local entry = entries[i]
        rowData.entry = entry

        if rowData.row ~= nil then
            rowData.row:setVisible(entry ~= nil)
        end

        if entry ~= nil then
            if rowData.nameInput ~= nil then
                rowData.nameInput:setVisible(true)
                local draft = self.nameDrafts[i]
                local desiredText = draft ~= nil and draft or (entry.name or entry.typeName or "Förderband")
                if not rowData.nameInput:getIsFocused() then
                    rowData.nameInput:setText(desiredText)
                end
            end

            if rowData.enabled ~= nil then
                rowData.enabled:setVisible(true)
                rowData.enabled:setIsChecked(entry.enabled ~= false, true)
            end

            if rowData.teleport ~= nil then
                rowData.teleport:setVisible(true)
            end

            if rowData.typeText ~= nil then
                rowData.typeText:setVisible(true)
                rowData.typeText:setText(entry.typeName or "Förderband")
            end
        end
    end

    self.isRefreshing = false

    if self.noConveyorsText ~= nil then
        self.noConveyorsText:setVisible(count == 0)
    end

    if self.conveyorSettingsLayout ~= nil then
        self.conveyorSettingsLayout:invalidateLayout()
        self.conveyorSettingsLayout:updateAbsolutePosition()
    end
end

function UniversalConveyorSettingsPage:onEnterName(element)
    self:commitNameInput(element)
end

function UniversalConveyorSettingsPage:onFocusLeaveName(element)
    self:commitNameInput(element)
end

function UniversalConveyorSettingsPage:commitNameInput(element)
    if self.controller == nil or element == nil then
        return
    end

    local rowIndex = self.elementToRow[element]
    local entry = self:getEntryFromElement(element)
    if rowIndex == nil or entry == nil then
        return
    end

    local text = element.getText ~= nil and element:getText() or (entry.name or entry.typeName or "Förderband")
    self.nameDrafts[rowIndex] = nil
    self.controller:setName(entry.vehicle, text)

    local committedEntry = self.controller:getEntry(entry.vehicle)
    if committedEntry ~= nil and element.setText ~= nil then
        element:setText(committedEntry.name or committedEntry.typeName or "Förderband")
    end
end

function UniversalConveyorSettingsPage:commitAllNameInputs()
    for _, rowData in ipairs(self.rows or {}) do
        if rowData.nameInput ~= nil and rowData.entry ~= nil then
            self:commitNameInput(rowData.nameInput)
        end
    end
end

function UniversalConveyorSettingsPage:getEntryFromElement(element)
    local rowIndex = self.elementToRow[element]
    if rowIndex == nil or self.rows[rowIndex] == nil then
        return nil
    end

    return self.rows[rowIndex].entry
end

function UniversalConveyorSettingsPage:onClickCheckbox(arg1, arg2)
    if self.controller == nil then
        return
    end

    local element = nil
    local state = nil

    -- FS25 GUI callbacks are not consistent across the different element
    -- wrappers. Depending on the callback path the arguments can be
    -- (element, state), (state, element) or just (state).
    if type(arg1) == "table" then
        element = arg1
        state = arg2
    elseif type(arg2) == "table" then
        element = arg2
        state = arg1
    else
        state = arg1
        if self.focusedRowIndex ~= nil and self.rows[self.focusedRowIndex] ~= nil then
            element = self.rows[self.focusedRowIndex].enabled
        end
    end

    if element == nil or self.elementToRow[element] == nil then
        Logging.warning(
            "[UniversalConveyorHelper][SETTINGS] AN/AUS: Kein GUI-Element auflösbar | arg1=%s | arg2=%s | state=%s",
            tostring(arg1), tostring(arg2), tostring(state)
        )
        return
    end

    local rowIndex = self.elementToRow[element]
    self.focusedRowIndex = rowIndex
    local entry = self:getEntryFromElement(element)
    if entry == nil then
        Logging.warning(
            "[UniversalConveyorHelper][SETTINGS] AN/AUS: Kein Förderband gefunden | row=%s | state=%s",
            tostring(rowIndex), tostring(state)
        )
        return
    end

    local enabled = nil
    if element.getIsChecked ~= nil then
        local ok, checked = pcall(element.getIsChecked, element)
        if ok and checked ~= nil then
            enabled = checked == true
        end
    end

    if enabled == nil then
        if type(state) == "number" then
            enabled = state == 2
        else
            enabled = state == true
        end
    end

    Logging.info(
        "[UniversalConveyorHelper][SETTINGS] CLICK | conveyor=%s | state=%s | resolved=%s | row=%d",
        tostring(entry.name or entry.typeName or "Förderband"),
        tostring(state),
        tostring(enabled),
        rowIndex
    )

    self.controller:setEnabled(entry.vehicle, enabled)
    self:updateConveyors(self.controller.currentEntries)
end

function UniversalConveyorSettingsPage:onClickTeleport(arg1)
    local element = arg1

    -- Button callbacks normally provide the clicked element. Keep the same
    -- fallback behaviour as the other settings controls so controller/mouse
    -- callback variants still resolve the focused conveyor row reliably.
    if type(element) ~= "table" or self.elementToRow[element] == nil then
        if self.focusedRowIndex ~= nil and self.rows[self.focusedRowIndex] ~= nil then
            element = self.rows[self.focusedRowIndex].teleport
        end
    end

    local entry = self:getEntryFromElement(element)
    if entry == nil or self.controller == nil then
        Logging.warning("[UniversalConveyorHelper][SETTINGS] Teleport: Kein Förderband für das fokussierte Element gefunden")
        return
    end

    Logging.info(
        "[UniversalConveyorHelper][SETTINGS] TELEPORT CLICK | conveyor=%s | row=%s",
        tostring(entry.name or entry.typeName or "Förderband"),
        tostring(self.elementToRow[element])
    )

    local conveyorName = entry.name or entry.typeName or "Förderband"
    local title = string.format(g_i18n:getText("uch_ui_teleportConfirm"), conveyorName)

    -- Ask for confirmation before changing the player's position. The native
    -- YesNoDialog gives the player an explicit OK/Cancel choice.
    YesNoDialog.show(
        UniversalConveyorSettingsPage.onTeleportConfirmation,
        self,
        title,
        nil, nil, nil, nil, nil, nil,
        entry
    )
end

function UniversalConveyorSettingsPage:onTeleportConfirmation(clickOk, entry)
    if clickOk ~= true or entry == nil or self.controller == nil then
        Logging.info("[UniversalConveyorHelper][SETTINGS] Teleport abgebrochen")
        return
    end

    local conveyorName = entry.name or entry.typeName or "Förderband"
    local teleported = self.controller:teleportToConveyor(entry.vehicle)

    if not teleported then
        Logging.warning("[UniversalConveyorHelper][SETTINGS] Teleport nicht ausgeführt | conveyor=%s", tostring(conveyorName))
        return
    end

    -- The custom page is nested inside the normal settings page. One Back
    -- leaves our sub-page, the second Back closes the settings page itself.
    if g_inGameMenu ~= nil and g_inGameMenu.onButtonBack ~= nil then
        g_inGameMenu:onButtonBack()
        Logging.info("[UniversalConveyorHelper][SETTINGS] Teleport: Förderband-Seite geschlossen")

        if g_inGameMenu.onButtonBack ~= nil then
            g_inGameMenu:onButtonBack()
            Logging.info("[UniversalConveyorHelper][SETTINGS] Teleport: Einstellungen vollständig geschlossen")
        end
    end

    local message = string.format(g_i18n:getText("uch_ui_teleportSuccess"), conveyorName)
    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, message)
    elseif InfoDialog ~= nil and InfoDialog.show ~= nil then
        InfoDialog.show(message, nil, nil, DialogElement.TYPE_INFO)
    end
end

