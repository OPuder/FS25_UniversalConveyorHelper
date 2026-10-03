-- Universal Conveyor Helper 1.9.31
-- Native FS25 settings-tab integration, based on the proven FS25 settings-tab pattern.

UniversalConveyorSettingsGui = {}

local UniversalConveyorSettingsGui_mt = Class(UniversalConveyorSettingsGui)

function UniversalConveyorSettingsGui.new(settingsManager)
    local self = setmetatable({}, UniversalConveyorSettingsGui_mt)

    local settingsFrame = g_inGameMenu ~= nil and g_inGameMenu.pageSettings or nil
    if settingsFrame == nil then
        Logging.error("[UniversalConveyorHelper][SETTINGS] pageSettings nicht verfügbar")
        return self
    end

    self.settingsManager = settingsManager
    self.settingsFrame = settingsFrame
    self.screenController = nil

    -- Same hook structure used by working FS25 settings-tab mods.
    local oldOpen = InGameMenuSettingsFrame.onFrameOpen
    InGameMenuSettingsFrame.onFrameOpen = function(frame, ...)
        oldOpen(frame, ...)

        if g_inGameMenu ~= nil and g_inGameMenu.pageSettings == frame then
            frame.isOpening = true
            if self.screenController ~= nil and self.screenController.onFrameOpen ~= nil then
                self.screenController:onFrameOpen()
            end
            frame.isOpening = false
        end
    end

    local oldClose = InGameMenuSettingsFrame.onFrameClose
    InGameMenuSettingsFrame.onFrameClose = function(frame, ...)
        if g_inGameMenu ~= nil and g_inGameMenu.pageSettings == frame then
            if self.screenController ~= nil and self.screenController.onFrameClose ~= nil then
                self.screenController:onFrameClose()
            end
        end
        oldClose(frame, ...)
    end

    local oldClick = settingsFrame.subCategoryPaging.onClickCallback
    settingsFrame.subCategoryPaging.onClickCallback = function(paging, state, ...)
        local retValue = oldClick(paging, state, ...)

        -- BinaryOption/MultiText callbacks do not always pass the paging
        -- element as the first argument. Do not access paging.texts[state]
        -- here; that caused the mouseEvent error in the settings menu.
        local currentState = nil
        if settingsFrame.subCategoryPaging.getState ~= nil then
            currentState = settingsFrame.subCategoryPaging:getState()
        end

        if currentState == InGameMenuSettingsFrame.SUB_CATEGORY.UCH_CONVEYORS then
            if self.screenController ~= nil and self.screenController.onTabOpen ~= nil then
                self.screenController:onTabOpen()
            end

            local page = settingsFrame.uchConveyorSettingsPage
            if settingsFrame.settingsSlider ~= nil and page ~= nil and page.conveyorSettingsLayout ~= nil then
                settingsFrame.settingsSlider:setDataElement(page.conveyorSettingsLayout)
            end

            if page ~= nil and page.conveyorSettingsLayout ~= nil then
                local firstFocusable = page.conveyorSettingsLayout:findFirstFocusable(true)
                local lastContainer = page.conveyorSettingsLayout.elements[#page.conveyorSettingsLayout.elements]
                local lastFocusable = nil
                if lastContainer ~= nil and lastContainer.findFirstFocusable ~= nil then
                    lastFocusable = lastContainer:findFirstFocusable(true)
                end
                FocusManager:linkElements(settingsFrame.subCategoryPaging, FocusManager.TOP, lastFocusable or firstFocusable)
                FocusManager:linkElements(settingsFrame.subCategoryPaging, FocusManager.BOTTOM, firstFocusable)
            end
        end

        return retValue
    end

    return self
end

function UniversalConveyorSettingsGui:addPage(position)
    local settingsFrame = self.settingsFrame
    if settingsFrame == nil then
        return nil
    end

    position = math.min(#settingsFrame.subCategoryPages + 1, position or 3)
    local currentGui = FocusManager.currentGui

    local screenController = UniversalConveyorSettingsPage.register(self.settingsManager)
    if screenController == nil then
        Logging.error("[UniversalConveyorHelper][SETTINGS] GUI-Seite konnte nicht geladen werden")
        return nil
    end

    local additionalPage = screenController.uchConveyorSettingsPage
    local additionalTab = screenController.uchConveyorSettingsTab

    if additionalPage == nil or additionalTab == nil then
        Logging.error("[UniversalConveyorHelper][SETTINGS] Geladene Seite enthält Page/Tab nicht")
        return nil
    end

    self:addElementAtPosition(additionalPage, settingsFrame.subCategoryPages[1].parent, position)
    self:addElementAtPosition(additionalTab, settingsFrame.subCategoryBox, position)
    table.insert(settingsFrame.subCategoryPages, position, additionalPage)
    table.insert(settingsFrame.subCategoryTabs, position, additionalTab)

    for subCategory, id in pairs(InGameMenuSettingsFrame.SUB_CATEGORY) do
        if id >= position then
            InGameMenuSettingsFrame.SUB_CATEGORY[subCategory] = id + 1
        end
    end

    InGameMenuSettingsFrame.SUB_CATEGORY.UCH_CONVEYORS = position
    table.insert(InGameMenuSettingsFrame.HEADER_SLICES, position, "gui.icon_options_device")
    table.insert(InGameMenuSettingsFrame.HEADER_TITLES, position, "uch_ui_folders")

    settingsFrame:updateAbsolutePosition()

    local getDescendants = settingsFrame.getDescendants
    settingsFrame.getDescendants = function()
        return additionalPage:getDescendants()
    end
    settingsFrame:exposeControlsAsFields(settingsFrame.name)
    settingsFrame.getDescendants = getDescendants

    -- Keep the custom page/tab as callback targets. Re-targeting them to
    -- settingsFrame breaks the page controller callbacks (onFocus/onClick).

    FocusManager:setGui(settingsFrame.name)
    FocusManager:removeElement(additionalPage)
    FocusManager:removeElement(additionalTab)
    FocusManager:loadElementFromCustomValues(additionalPage)
    FocusManager:loadElementFromCustomValues(additionalTab)
    FocusManager:setGui(currentGui)

    settingsFrame.uchConveyorSettingsPage = additionalPage
    settingsFrame.uchConveyorSettingsTab = additionalTab
    self.screenController = screenController

    Logging.info("[UniversalConveyorHelper][SETTINGS] Förderband-Menü registriert | Position=%d", position)
    return screenController
end

function UniversalConveyorSettingsGui:addElementAtPosition(element, target, position)
    if element == nil or target == nil then
        return
    end
    if element.parent ~= nil then
        element.parent:removeElement(element)
    end
    table.insert(target.elements, position, element)
    element.parent = target
end
