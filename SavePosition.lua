--[[
    ┌─────────────────────────────────────────────────────────────────────────┐
    │                 SAVE POSITION TOOL v2.6 (Export/Import)                │
    │              MoonLoader Script for SA-MP                               │
    │                                                                        │
    │  Features:                                                             │
    │  • Instant teleport                                                    │
    │  • 10-second teleport cooldown                                         │
    │  • PERMANENT SAVE with export/import                                   │
    │  • Save positions with names                                           │
    │  • List all saved positions                                            │
    │  • Delete positions                                                    │
    │                                                                        │
    │  Hotkey: F10 - Toggle Menu                                            │
    │  Commands: /spos [name], /lpos [index], /poslist                       │
    └─────────────────────────────────────────────────────────────────────────┘
]]

script_name("SavePosition")
script_author("BOJO Dev")
script_version("2.6")

-- Required libraries
require 'lib.moonloader'
local vkeys = require 'vkeys'
local imgui = require 'mimgui'
local ffi = require 'ffi'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- ─────────────────────────────────────────────────────────────────────────────
-- CONFIGURATION
-- ─────────────────────────────────────────────────────────────────────────────

local CONFIG = {
    SAVE_FILE = getWorkingDirectory() .. "\\config\\SavedPositions.json",
    EXPORT_FILE = getWorkingDirectory() .. "\\config\\SavedPositions_Export.txt",
    HOTKEY = vkeys.VK_F10,
    WINDOW_TITLE = "Save Position Manager v2.6",
    MAX_NAME_LENGTH = 64,
    TELEPORT_COOLDOWN = 10, -- 10 seconds cooldown
    
    COLORS = {
        HEADER = imgui.ImVec4(0.2, 0.7, 0.9, 1.0),
        TELEPORT = imgui.ImVec4(0.2, 0.8, 0.2, 1.0),
        SAVE = imgui.ImVec4(0.2, 0.6, 0.9, 1.0),
        DELETE = imgui.ImVec4(0.9, 0.2, 0.2, 1.0),
        EXPORT = imgui.ImVec4(0.8, 0.5, 0.0, 1.0),
        IMPORT = imgui.ImVec4(0.0, 0.8, 0.4, 1.0),
        TEXT_HIGHLIGHT = imgui.ImVec4(1.0, 0.8, 0.0, 1.0),
        WARNING = imgui.ImVec4(1.0, 0.5, 0.0, 1.0)
    }
}

-- ─────────────────────────────────────────────────────────────────────────────
-- STATE VARIABLES
-- ─────────────────────────────────────────────────────────────────────────────

local mainWindow = imgui.new.bool(false)
local savedPositions = {}
local newPositionName = imgui.new.char[CONFIG.MAX_NAME_LENGTH]("")
local searchFilter = imgui.new.char[64]("")
local showConfirmDelete = imgui.new.bool(false)
local deleteIndex = nil
local statusMessage = ""
local statusMessageTime = 0
local lastTeleportTime = 0
local teleportCooldown = imgui.new.int(0)

-- Import/Export variables
local importText = imgui.new.char[10000]("")
local showImportWindow = imgui.new.bool(false)

-- ─────────────────────────────────────────────────────────────────────────────
-- SIMPLE JSON PARSER
-- ─────────────────────────────────────────────────────────────────────────────

local function serializeTable(val, name, skipnewlines, depth)
    skipnewlines = skipnewlines or false
    depth = depth or 0
    
    local tmp = string.rep(" ", depth)
    
    if name then 
        if not skipnewlines then tmp = tmp .. name .. " = " 
        else tmp = tmp .. name .. "=" end
    end
    
    if type(val) == "table" then
        tmp = tmp .. "{" .. (not skipnewlines and "\n" or "")
        
        local first = true
        for k, v in pairs(val) do
            if not first then
                tmp = tmp .. "," .. (not skipnewlines and "\n" or "")
            end
            first = false
            
            if type(k) == "number" then
                tmp = tmp .. serializeTable(v, nil, skipnewlines, depth + 1)
            else
                tmp = tmp .. serializeTable(v, string.format("[%q]", k), skipnewlines, depth + 1)
            end
        end
        
        tmp = tmp .. (not skipnewlines and "\n" .. string.rep(" ", depth) or "") .. "}"
    elseif type(val) == "number" then
        tmp = tmp .. tostring(val)
    elseif type(val) == "string" then
        tmp = tmp .. string.format("%q", val)
    elseif type(val) == "boolean" then
        tmp = tmp .. (val and "true" or "false")
    else
        tmp = tmp .. "\"[inserializeable datatype:" .. type(val) .. "]\""
    end
    
    return tmp
end

local function tableToJson(tbl)
    return serializeTable(tbl, nil, true)
end

local function jsonToTable(jsonStr)
    if not jsonStr or jsonStr == "" then return {} end
    
    -- Try to parse as Lua table
    local func, err = loadstring("return " .. jsonStr)
    if func then
        local success, result = pcall(func)
        if success and result then
            return result
        end
    end
    
    -- If that fails, try manual parsing
    local result = {}
    local pos = 1
    
    -- Remove whitespace
    jsonStr = jsonStr:gsub("%s+", " ")
    
    -- Simple array parsing
    if jsonStr:sub(1,1) == "[" then
        local array = {}
        local index = 1
        
        -- Extract objects from array
        for obj in jsonStr:gmatch("{(.-)}") do
            local entry = {}
            
            -- Parse key-value pairs
            for k, v in obj:gmatch('"([^"]+)":([^,}]+)') do
                v = v:gsub('^%s*(.-)%s*$', '%1')
                
                -- Remove quotes if present
                if v:sub(1,1) == '"' and v:sub(-1) == '"' then
                    v = v:sub(2, -2)
                end
                
                -- Convert numbers
                if tonumber(v) then
                    v = tonumber(v)
                elseif v == "true" then
                    v = true
                elseif v == "false" then
                    v = false
                end
                
                entry[k] = v
            end
            
            array[index] = entry
            index = index + 1
        end
        
        return array
    end
    
    return {}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- FILE HANDLING FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────

local function ensureDirectoryExists(filepath)
    local dir = filepath:match("(.+)\\[^\\]+$")
    if dir then
        local path = ""
        for part in dir:gmatch("[^\\]+") do
            if path == "" then
                path = part
            else
                path = path .. "\\" .. part
            end
            if not doesDirectoryExist(path) then
                createDirectory(path)
            end
        end
    end
end

local function savePositionsToFile()
    ensureDirectoryExists(CONFIG.SAVE_FILE)
    
    -- Convert to JSON
    local jsonData = tableToJson(savedPositions)
    
    -- Save to file
    local file = io.open(CONFIG.SAVE_FILE, "w")
    if file then
        file:write(jsonData)
        file:close()
        return true
    end
    return false
end

local function loadPositionsFromFile()
    savedPositions = {}
    
    -- Check if file exists
    if not doesFileExist(CONFIG.SAVE_FILE) then
        return true
    end
    
    -- Read file
    local file = io.open(CONFIG.SAVE_FILE, "r")
    if not file then
        return false
    end
    
    local content = file:read("*all")
    file:close()
    
    if not content or content == "" then
        return true
    end
    
    -- Parse JSON
    local parsedData = jsonToTable(content)
    
    if parsedData and #parsedData > 0 then
        -- It's already an array
        savedPositions = parsedData
    elseif type(parsedData) == "table" then
        -- Convert object to array
        local tempArray = {}
        local index = 1
        for k, v in pairs(parsedData) do
            if type(v) == "table" then
                tempArray[index] = v
                index = index + 1
            end
        end
        savedPositions = tempArray
    end
    
    return true
end

local function exportPositions()
    ensureDirectoryExists(CONFIG.EXPORT_FILE)
    
    -- Create a readable text export
    local exportContent = "-- SAVED POSITIONS EXPORT --\n"
    exportContent = exportContent .. "-- Generated on: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n"
    exportContent = exportContent .. "-- Total positions: " .. #savedPositions .. "\n\n"
    exportContent = exportContent .. "JSON DATA:\n"
    exportContent = exportContent .. tableToJson(savedPositions) .. "\n\n"
    
    exportContent = exportContent .. "HUMAN READABLE LIST:\n"
    for i, pos in ipairs(savedPositions) do
        exportContent = exportContent .. string.format("%d. %s\n", i, pos.name or "Unnamed")
        exportContent = exportContent .. string.format("   Coordinates: %.2f, %.2f, %.2f\n", pos.x, pos.y, pos.z)
        exportContent = exportContent .. string.format("   Angle: %.2f | Interior: %d\n", pos.angle or 0, pos.interior or 0)
        if pos.timestamp then
            exportContent = exportContent .. string.format("   Saved: %s\n", os.date("%Y-%m-%d %H:%M", pos.timestamp))
        end
        exportContent = exportContent .. "\n"
    end
    
    -- Save to export file
    local file = io.open(CONFIG.EXPORT_FILE, "w")
    if file then
        file:write(exportContent)
        file:close()
        
        -- Also copy to clipboard if possible
        if string.len(exportContent) < 10000 then
            ffi.copy(importText, exportContent)
        end
        
        return true, "Positions exported to: " .. CONFIG.EXPORT_FILE
    end
    
    return false, "Failed to export positions"
end

local function importFromText(text)
    if not text or text == "" then
        return false, "No text to import"
    end
    
    -- Try to find JSON data in the text
    local jsonStart, jsonEnd = text:find("%[.*%]")
    if not jsonStart then
        jsonStart, jsonEnd = text:find("{.*}")
    end
    
    if jsonStart and jsonEnd then
        local jsonData = text:sub(jsonStart, jsonEnd)
        local parsedData = jsonToTable(jsonData)
        
        if parsedData and (type(parsedData) == "table") then
            -- Convert to array if needed
            local importedPositions = {}
            
            if #parsedData > 0 then
                importedPositions = parsedData
            else
                -- Object with numeric keys
                local index = 1
                while parsedData[tostring(index)] do
                    table.insert(importedPositions, parsedData[tostring(index)])
                    index = index + 1
                end
                
                -- If no numeric keys, try to get all tables
                if #importedPositions == 0 then
                    for _, v in pairs(parsedData) do
                        if type(v) == "table" then
                            table.insert(importedPositions, v)
                        end
                    end
                end
            end
            
            if #importedPositions > 0 then
                -- Replace current positions with imported ones
                savedPositions = importedPositions
                savePositionsToFile()
                return true, "Successfully imported " .. #importedPositions .. " positions"
            end
        end
    end
    
    return false, "No valid position data found in text"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- UTILITY FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────

local function setStatusMessage(msg)
    statusMessage = msg
    statusMessageTime = os.clock()
end

local function getPlayerPosition()
    if not isCharOnFoot(PLAYER_PED) and isCharInAnyCar(PLAYER_PED) then
        local car = storeCarCharIsInNoSave(PLAYER_PED)
        local x, y, z = getCarCoordinates(car)
        local angle = getCarHeading(car)
        local interior = getActiveInterior()
        return x, y, z, angle, interior, true
    else
        local x, y, z = getCharCoordinates(PLAYER_PED)
        local angle = getCharHeading(PLAYER_PED)
        local interior = getActiveInterior()
        return x, y, z, angle, interior, false
    end
end

local function teleportToPosition(pos)
    if not pos then return false end
    
    -- Check cooldown
    local currentTime = os.clock()
    local timeSinceLast = currentTime - lastTeleportTime
    
    if timeSinceLast < CONFIG.TELEPORT_COOLDOWN then
        local remaining = math.ceil(CONFIG.TELEPORT_COOLDOWN - timeSinceLast)
        setStatusMessage(string.format("Please wait %d seconds", remaining))
        return false
    end
    
    -- INSTANT TELEPORT (no smooth movement)
    if isCharInAnyCar(PLAYER_PED) then
        local car = storeCarCharIsInNoSave(PLAYER_PED)
        setCarCoordinates(car, pos.x, pos.y, pos.z)
        setCarHeading(car, pos.angle or 0)
    else
        setCharCoordinates(PLAYER_PED, pos.x, pos.y, pos.z)
        setCharHeading(PLAYER_PED, pos.angle or 0)
    end
    
    -- Set interior if needed
    if pos.interior and pos.interior ~= 0 then
        setActiveInterior(pos.interior)
    end
    
    -- Fix camera
    restoreCameraJumpcut()
    
    -- Force sync with server
    if isSampAvailable() then
        sampForceOnfootSync()
    end
    
    lastTeleportTime = currentTime
    teleportCooldown[0] = CONFIG.TELEPORT_COOLDOWN
    
    setStatusMessage("Teleported to: " .. (pos.name or "Unknown"))
    return true
end

local function formatCoordinates(x, y, z)
    return string.format("%.2f, %.2f, %.2f", x, y, z)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- IMGUI RENDERING
-- ─────────────────────────────────────────────────────────────────────────────

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    
    local style = imgui.GetStyle()
    style.WindowRounding = 8.0
    style.FrameRounding = 4.0
    style.GrabRounding = 4.0
    style.ScrollbarRounding = 4.0
    style.WindowPadding = imgui.ImVec2(10, 10)
    style.FramePadding = imgui.ImVec2(8, 4)
    style.ItemSpacing = imgui.ImVec2(8, 6)
    
    local colors = style.Colors
    colors[imgui.Col.WindowBg] = imgui.ImVec4(0.08, 0.08, 0.12, 0.95)
    colors[imgui.Col.TitleBg] = imgui.ImVec4(0.1, 0.1, 0.15, 1.0)
    colors[imgui.Col.TitleBgActive] = imgui.ImVec4(0.15, 0.15, 0.22, 1.0)
    colors[imgui.Col.Header] = imgui.ImVec4(0.2, 0.4, 0.6, 0.6)
    colors[imgui.Col.HeaderHovered] = imgui.ImVec4(0.3, 0.5, 0.7, 0.8)
    colors[imgui.Col.HeaderActive] = imgui.ImVec4(0.25, 0.45, 0.65, 1.0)
    colors[imgui.Col.Button] = imgui.ImVec4(0.2, 0.4, 0.6, 0.6)
    colors[imgui.Col.ButtonHovered] = imgui.ImVec4(0.3, 0.5, 0.7, 0.8)
    colors[imgui.Col.ButtonActive] = imgui.ImVec4(0.25, 0.45, 0.65, 1.0)
    colors[imgui.Col.FrameBg] = imgui.ImVec4(0.15, 0.15, 0.2, 0.8)
    colors[imgui.Col.FrameBgHovered] = imgui.ImVec4(0.2, 0.2, 0.28, 0.9)
    colors[imgui.Col.FrameBgActive] = imgui.ImVec4(0.25, 0.25, 0.35, 1.0)
    colors[imgui.Col.ScrollbarBg] = imgui.ImVec4(0.1, 0.1, 0.15, 0.6)
    colors[imgui.Col.ScrollbarGrab] = imgui.ImVec4(0.3, 0.3, 0.4, 0.8)
    colors[imgui.Col.Border] = imgui.ImVec4(0.3, 0.3, 0.4, 0.5)
end)

local function renderMenu()
    imgui.SetNextWindowSize(imgui.ImVec2(650, 500), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowPos(imgui.ImVec2(100, 100), imgui.Cond.FirstUseEver)
    
    imgui.Begin(CONFIG.WINDOW_TITLE, mainWindow, imgui.WindowFlags.NoCollapse)
    
    -- Header with cooldown indicator
    imgui.PushStyleColor(imgui.Col.Text, CONFIG.COLORS.HEADER)
    imgui.Text(">> POSITION MANAGER v2.6")
    imgui.PopStyleColor()
    
    -- Cooldown display
    local currentTime = os.clock()
    local timeSinceLast = currentTime - lastTeleportTime
    if timeSinceLast < CONFIG.TELEPORT_COOLDOWN then
        local remaining = math.ceil(CONFIG.TELEPORT_COOLDOWN - timeSinceLast)
        imgui.SameLine()
        imgui.TextColored(CONFIG.COLORS.WARNING, string.format(" [Cooldown: %ds]", remaining))
    else
        imgui.SameLine()
        imgui.TextColored(CONFIG.COLORS.TELEPORT, " [Ready to teleport]")
    end
    
    imgui.SameLine()
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), string.format(" [%d saved]", #savedPositions))
    
    imgui.Separator()
    
    -- Current position
    local x, y, z, angle, interior, inVehicle = getPlayerPosition()
    imgui.Text("Current Position:")
    imgui.SameLine()
    imgui.TextColored(CONFIG.COLORS.TEXT_HIGHLIGHT, formatCoordinates(x, y, z))
    
    if inVehicle then
        imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(0.5, 0.8, 1.0, 1.0), " [IN VEHICLE]")
    end
    
    imgui.Separator()
    
    -- ─────────────────────────────────────────────────────────────────────────
    -- SAVE NEW POSITION SECTION
    -- ─────────────────────────────────────────────────────────────────────────
    
    imgui.PushStyleColor(imgui.Col.Text, CONFIG.COLORS.SAVE)
    imgui.Text("[+] SAVE NEW POSITION")
    imgui.PopStyleColor()
    
    -- Name input
    imgui.Text("Name:")
    imgui.SameLine()
    imgui.PushItemWidth(200)
    imgui.InputText("##NewName", newPositionName, CONFIG.MAX_NAME_LENGTH)
    imgui.PopItemWidth()
    
    imgui.SameLine()
    
    -- Save button
    imgui.PushStyleColor(imgui.Col.Button, CONFIG.COLORS.SAVE)
    if imgui.Button("Save Position", imgui.ImVec2(120, 40)) then
        local name = ffi.string(newPositionName)
        if name == "" then name = "Position " .. (#savedPositions + 1) end
        
        local newPos = {
            name = name,
            x = x,
            y = y,
            z = z,
            angle = angle,
            interior = interior,
            inVehicle = inVehicle,
            timestamp = os.time()
        }
        
        table.insert(savedPositions, newPos)
        if savePositionsToFile() then
            setStatusMessage("✓ Saved: " .. name .. " (Total: " .. #savedPositions .. ")")
        else
            setStatusMessage("✗ Failed to save position")
        end
        
        ffi.fill(newPositionName, CONFIG.MAX_NAME_LENGTH)
    end
    imgui.PopStyleColor()
    
    imgui.Separator()
    
    -- ─────────────────────────────────────────────────────────────────────────
    -- IMPORT/EXPORT BUTTONS
    -- ─────────────────────────────────────────────────────────────────────────
    
    imgui.Text("Data Management:")
    
    imgui.PushStyleColor(imgui.Col.Button, CONFIG.COLORS.EXPORT)
    if imgui.Button("EXPORT Positions", imgui.ImVec2(150, 30)) then
        local success, msg = exportPositions()
        setStatusMessage(msg)
        if success then
            sampAddChatMessage("{00FF00}[SavePos]{FFFFFF} " .. msg, 0xFFFFFFFF)
        end
    end
    imgui.PopStyleColor()
    
    imgui.SameLine()
    
    imgui.PushStyleColor(imgui.Col.Button, CONFIG.COLORS.IMPORT)
    if imgui.Button("IMPORT Positions", imgui.ImVec2(150, 30)) then
        showImportWindow[0] = true
    end
    imgui.PopStyleColor()
    
    imgui.SameLine()
    
    if imgui.Button("Reload From File", imgui.ImVec2(150, 30)) then
        if loadPositionsFromFile() then
            setStatusMessage("✓ Reloaded " .. #savedPositions .. " positions from file")
        else
            setStatusMessage("✗ Failed to reload positions")
        end
    end
    
    imgui.Separator()
    
    -- ─────────────────────────────────────────────────────────────────────────
    -- SEARCH AND FILTER
    -- ─────────────────────────────────────────────────────────────────────────
    
    imgui.Text("Search Positions:")
    imgui.SameLine()
    imgui.PushItemWidth(250)
    imgui.InputText("##Search", searchFilter, 64)
    imgui.PopItemWidth()
    
    imgui.SameLine()
    imgui.Text(string.format("Showing: %d/%d", #savedPositions, #savedPositions))
    
    -- Positions list
    imgui.BeginChild("PositionsList", imgui.ImVec2(0, 250), true)
    
    local filterText = ffi.string(searchFilter):lower()
    local displayedCount = 0
    
    for i, pos in ipairs(savedPositions) do
        local posName = pos.name or ("Position " .. i)
        if filterText == "" or posName:lower():find(filterText, 1, true) then
            displayedCount = displayedCount + 1
            
            local headerText = string.format("%d. %s", i, posName)
            
            if imgui.CollapsingHeader(headerText) then
                imgui.Indent()
                
                imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Coordinates:")
                imgui.SameLine()
                imgui.Text(formatCoordinates(pos.x, pos.y, pos.z))
                
                if pos.timestamp then
                    imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Saved: ")
                    imgui.SameLine()
                    imgui.Text(os.date("%Y-%m-%d %H:%M", pos.timestamp))
                end
                
                imgui.Spacing()
                
                -- Action buttons
                imgui.PushStyleColor(imgui.Col.Button, CONFIG.COLORS.TELEPORT)
                if imgui.Button("Teleport##" .. i, imgui.ImVec2(100, 25)) then
                    teleportToPosition(pos)
                end
                imgui.PopStyleColor()
                
                imgui.SameLine()
                
                imgui.PushStyleColor(imgui.Col.Button, CONFIG.COLORS.DELETE)
                if imgui.Button("Delete##" .. i, imgui.ImVec2(80, 25)) then
                    deleteIndex = i
                    showConfirmDelete[0] = true
                end
                imgui.PopStyleColor()
                
                imgui.Unindent()
            end
        end
    end
    
    if displayedCount == 0 and #savedPositions > 0 then
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "No positions match your search.")
    elseif #savedPositions == 0 then
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "No positions saved yet.")
    end
    
    imgui.EndChild()
    
    -- Status message
    if statusMessage ~= "" and (os.clock() - statusMessageTime) < 5 then
        imgui.Separator()
        if statusMessage:sub(1,1) == "✓" then
            imgui.TextColored(imgui.ImVec4(0.2, 0.9, 0.2, 1.0), statusMessage)
        elseif statusMessage:sub(1,1) == "✗" then
            imgui.TextColored(imgui.ImVec4(0.9, 0.2, 0.2, 1.0), statusMessage)
        else
            imgui.TextColored(imgui.ImVec4(0.8, 0.8, 0.2, 1.0), statusMessage)
        end
    end
    
    imgui.End()
    
    -- Delete confirmation
    if showConfirmDelete[0] then
        imgui.SetNextWindowPos(imgui.ImVec2(imgui.GetIO().DisplaySize.x / 2 - 150, imgui.GetIO().DisplaySize.y / 2 - 60))
        imgui.SetNextWindowSize(imgui.ImVec2(300, 120))
        imgui.Begin("Confirm Delete", showConfirmDelete, imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)
        
        if deleteIndex and savedPositions[deleteIndex] then
            local delName = savedPositions[deleteIndex].name or "this position"
            imgui.TextWrapped("Delete '" .. delName .. "'?")
            
            imgui.PushStyleColor(imgui.Col.Button, CONFIG.COLORS.DELETE)
            if imgui.Button("Yes, Delete", imgui.ImVec2(130, 0)) then
                table.remove(savedPositions, deleteIndex)
                savePositionsToFile()
                setStatusMessage("✓ Position deleted")
                showConfirmDelete[0] = false
            end
            imgui.PopStyleColor()
            
            imgui.SameLine()
            if imgui.Button("Cancel", imgui.ImVec2(130, 0)) then
                showConfirmDelete[0] = false
            end
        end
        
        imgui.End()
    end
    
    -- Import window
    if showImportWindow[0] then
        imgui.SetNextWindowSize(imgui.ImVec2(500, 400), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(imgui.GetIO().DisplaySize.x / 2 - 250, imgui.GetIO().DisplaySize.y / 2 - 200))
        imgui.Begin("Import Positions", showImportWindow, imgui.WindowFlags.NoCollapse)
        
        imgui.TextWrapped("Paste your position data below (JSON format):")
        imgui.Spacing()
        
        imgui.InputTextMultiline("##ImportText", importText, 10000, imgui.ImVec2(480, 250))
        
        imgui.Spacing()
        
        if imgui.Button("Import Data", imgui.ImVec2(150, 30)) then
            local text = ffi.string(importText)
            local success, msg = importFromText(text)
            setStatusMessage(msg)
            if success then
                showImportWindow[0] = false
                ffi.fill(importText, 10000)
                sampAddChatMessage("{00FF00}[SavePos]{FFFFFF} " .. msg, 0xFFFFFFFF)
            end
        end
        
        imgui.SameLine()
        
        if imgui.Button("Cancel", imgui.ImVec2(100, 30)) then
            showImportWindow[0] = false
            ffi.fill(importText, 10000)
        end
        
        imgui.SameLine()
        
        imgui.Text("Paste then click Import")
        
        imgui.End()
    end
end

imgui.OnFrame(function() return mainWindow[0] end, renderMenu)

-- ─────────────────────────────────────────────────────────────────────────────
-- MAIN THREAD
-- ─────────────────────────────────────────────────────────────────────────────

function main()
    wait(1000)
    
    -- Wait for SAMP
    if not isSampLoaded() or not isSampAvailable() then
        repeat wait(50) until isSampLoaded() and isSampAvailable()
    end
    
    -- Load saved positions from file
    if loadPositionsFromFile() then
        sampAddChatMessage("{00BFFF}[SavePos]{FFFFFF} v2.6 loaded - " .. #savedPositions .. " positions loaded", 0xFFFFFFFF)
    else
        sampAddChatMessage("{FF0000}[SavePos]{FFFFFF} Failed to load save file", 0xFFFFFFFF)
        savedPositions = {}
    end
    
    -- Chat commands
    sampRegisterChatCommand("spos", function(params)
        local x, y, z, angle, interior, inVehicle = getPlayerPosition()
        local name = params ~= "" and params or ("Saved #" .. (#savedPositions + 1))
        
        local newPos = {
            name = name,
            x = x,
            y = y,
            z = z,
            angle = angle,
            interior = interior,
            inVehicle = inVehicle,
            timestamp = os.time()
        }
        
        table.insert(savedPositions, newPos)
        savePositionsToFile()
        
        sampAddChatMessage("{00FF00}[SavePos]{FFFFFF} Saved: " .. name .. " (Total: " .. #savedPositions .. ")", 0xFFFFFFFF)
    end)
    
    sampRegisterChatCommand("lpos", function(params)
        local index = tonumber(params)
        if index and savedPositions[index] then
            teleportToPosition(savedPositions[index])
        else
            sampAddChatMessage("{FF0000}[SavePos]{FFFFFF} Invalid index. Use /poslist", 0xFFFFFFFF)
        end
    end)
    
    sampRegisterChatCommand("poslist", function()
        sampAddChatMessage("{00BFFF}[SavePos]{FFFFFF} === Saved Positions (" .. #savedPositions .. ") ===", 0xFFFFFFFF)
        if #savedPositions == 0 then
            sampAddChatMessage("{AAAAAA}No positions saved. Use /spos to save one.", 0xFFFFFFFF)
        else
            for i, pos in ipairs(savedPositions) do
                sampAddChatMessage(string.format("{FFFF00}%d.{FFFFFF} %s - %.1f, %.1f, %.1f", 
                    i, pos.name, pos.x, pos.y, pos.z), 0xFFFFFFFF)
            end
        end
    end)
    
    sampAddChatMessage("{FFFF00}Press F10 for menu | Commands: /spos /lpos /poslist", 0xFFFFFFFF)
    
    -- Main loop
    local keyPressed = false
    while true do
        wait(0)
        
        -- Update cooldown counter
        local currentTime = os.clock()
        local timeSinceLast = currentTime - lastTeleportTime
        if timeSinceLast < CONFIG.TELEPORT_COOLDOWN then
            teleportCooldown[0] = math.ceil(CONFIG.TELEPORT_COOLDOWN - timeSinceLast)
        else
            teleportCooldown[0] = 0
        end
        
        -- Toggle menu with F10
        local isHotkeyPressed = isKeyDown(vkeys.VK_F10)
        if isHotkeyPressed and not keyPressed and not sampIsChatInputActive() and not sampIsDialogActive() then
            mainWindow[0] = not mainWindow[0]
            keyPressed = true
        elseif not isHotkeyPressed then
            keyPressed = false
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HOW TO USE EXPORT/IMPORT:
-- 1. Click "EXPORT Positions" to save all positions to a text file
-- 2. File will be saved as: MoonLoader/config/SavedPositions_Export.txt
-- 3. You can copy the JSON data from this file
-- 4. Click "IMPORT Positions" and paste the JSON data
-- 5. This will replace ALL your current positions with the imported ones
-- 6. ALWAYS EXPORT BEFORE IMPORTING to avoid data loss!
-- ─────────────────────────────────────────────────────────────────────────────