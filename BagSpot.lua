--[[
    ┌─────────────────────────────────────────────────────────────────────────┐
    │                         BAGSPOT v4.0                                    │
    │              MoonLoader Script for SA-MP                                │
    │                                                                         │
    │  Features:                                                              │
    │  • Instant teleport with cooldown                                       │
    │  • Permanent save with export/import/merge                              │
    │  • Distance calculator and sorting                                      │
    │  • ESP markers for all saved positions                                  │
    │  • Route system (sequential teleports)                                  │
    │  • Auto-backup and duplicate detection                                  │
    │  • Moneybag tracker: ESP lines, radar, and Auto-TP on chat hint         │
    │  • Goldpot database matching (NEW tab, smart scoring)                   │
    │  • Sound alerts and proximity pulse for nearby moneybags                │
    │                                                                         │
    │  Hotkey: F10 - Menu | F9 - Toggle ESP                                   │
    │  Commands: /spos, /lpos, /poslist, /uc, /autotp, /clearfocus            │
    └─────────────────────────────────────────────────────────────────────────┘
]]

script_name("BagSpot")
script_author("BOJO Dev")
script_version("4.0")

-- Required libraries
require 'lib.moonloader'
local vkeys = require 'vkeys'
local imgui = require 'mimgui'
local ffi = require 'ffi'
ffi.cdef[[void __stdcall Beep(uint32_t dwFreq, uint32_t dwDuration);]]
local kernel32 = ffi.load('kernel32')
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local sampev = require 'lib.samp.events'

-- ─────────────────────────────────────────────────────────────────────────────
-- CONFIGURATION
-- ─────────────────────────────────────────────────────────────────────────────

local CONFIG = {
    SAVE_FILE = getWorkingDirectory() .. "\\config\\SavedPositions.json",
    EXPORT_FILE = getWorkingDirectory() .. "\\config\\SavedPositions_Export.txt",
    BACKUP_FILE = getWorkingDirectory() .. "\\config\\SavedPositions_Backup.json",
    ROUTES_FILE = getWorkingDirectory() .. "\\config\\SavedRoutes.json",
    HOTKEY = vkeys.VK_F10,
    ESP_HOTKEY = vkeys.VK_F9,
    WINDOW_TITLE = "BagSpot",
    MAX_NAME_LENGTH = 64,
    TELEPORT_COOLDOWN = 2,
    AUTO_BACKUP_INTERVAL = 20, -- Backup every 20 saves
    MAX_ESP_DISTANCE = 20000.0, -- Maximum distance to show ESP markers (entire map)
    MONEYBAG_TP_DISTANCE = 300.0, -- Auto-TP only when within 300m
    
    -- Auto-Teleport Settings
    -- System will automatically extract location from "Hint: (location)" in chat
    -- No hardcoded locations - purely dynamic based on saved positions
    AUTO_TELEPORT_KEYWORDS = {
        "goldpot",
        "hunt begins",
        "race:",
        "moneybag",
        "money bag",
        "bag of money",
        "bag of cash",
        "/find",
    },
    AUTO_TELEPORT_DELAY_MIN = 4, -- Minimum delay (seconds)
    AUTO_TELEPORT_DELAY_MAX = 5, -- Maximum delay (seconds)
    
    COLORS = {
        HEADER = imgui.ImVec4(0.2, 0.7, 0.9, 1.0),
        TELEPORT = imgui.ImVec4(0.2, 0.8, 0.2, 1.0),
        SAVE = imgui.ImVec4(0.2, 0.6, 0.9, 1.0),
        DELETE = imgui.ImVec4(0.9, 0.2, 0.2, 1.0),
        EXPORT = imgui.ImVec4(0.8, 0.5, 0.0, 1.0),
        IMPORT = imgui.ImVec4(0.0, 0.8, 0.4, 1.0),
        TEXT_HIGHLIGHT = imgui.ImVec4(1.0, 0.8, 0.0, 1.0),
        WARNING = imgui.ImVec4(1.0, 0.5, 0.0, 1.0),
        ROUTE = imgui.ImVec4(0.5, 0.0, 0.8, 1.0)
    },
    ESP_COLORS = {
        DEFAULT = 0xFFFFFFFF
    }
}

-- ─────────────────────────────────────────────────────────────────────────────
-- STATE VARIABLES
-- ─────────────────────────────────────────────────────────────────────────────

-- Fonts for ESP rendering
local font = nil
local espFont = nil
local gpsArrowTex = nil

local mainWindow = imgui.new.bool(false)
local savedPositions = {}
local savedRoutes = {}
local newPositionName = imgui.new.char[CONFIG.MAX_NAME_LENGTH]("")
local searchFilter = imgui.new.char[64]("")
local showConfirmDelete = imgui.new.bool(false)
local deleteIndex = nil
local renameIndex = nil
local showRenamePopup = imgui.new.bool(false)
local renameBuffer = imgui.new.char[CONFIG.MAX_NAME_LENGTH]("")
local statusMessage = ""
local statusMessageTime = 0
local lastTeleportTime = 0
local teleportCooldown = imgui.new.int(0)
local saveCounter = 0

-- New UI state variables
local sortMode = imgui.new.int(0) -- 0=None, 1=Name, 2=Date, 3=Distance
local showESP = imgui.new.bool(false)
local espDistance = imgui.new.float(10000.0) -- Default 10km (entire map)

-- Moneybag Tracker (model 1550 pickup ESP)
local showMoneybags = imgui.new.bool(false)
local autoMoneybagTP = imgui.new.bool(false)
local soundAlert = imgui.new.bool(true)
local moneyBags = {}
local moneybagTPPending = false
local moneybagTPTime = 0
local moneybagTPDelay = 1
local moneybagTPCooldown = 0
local moneybagPendingX = 0
local moneybagPendingY = 0
local moneybagPendingZ = 0
local lastProxBeep = 0
local showDistance = imgui.new.bool(true)

-- GPS direction tracking (distance delta per frame)
local prevBagDist = {}
local prevFocusDist = nil

-- Route system
local activeRoute = nil
local currentRouteIndex = 0
local showRouteWindow = imgui.new.bool(false)
local newRouteName = imgui.new.char[64]("")
local routeBuilder = {} -- Temporary array for building routes

-- Performance cache
local distanceCache = {}
local lastCacheUpdate = 0
local cacheUpdateInterval = 0.5 -- Update cache every 500ms

-- Auto-Teleport Variables
local autoTeleportEnabled = imgui.new.bool(false)
local lastDetectedKeyword = ""
local keywordDetectedTime = 0
local autoTeleportPending = false
local pendingSearchTerms = {}
local currentTeleportDelay = 0
local targetPositionName = ""

-- ESP Focus Mode (auto-focus from hints with toggle)
local autoFocusEnabled = imgui.new.bool(true) -- Toggleable auto-focus from chat hints
local espFocusPosition = nil
local espFocusTime = 0
local ESP_FOCUS_DURATION = 60

-- Import/Export variables
local importText = imgui.new.char[10000]("")
local showImportWindow = imgui.new.bool(false)
local mergeOnImport = imgui.new.bool(false)

-- Goldpot Database (from allpositions.txt)
local goldpotDB = {}
local goldpotDBLoaded = false
local goldpotDBPath = getWorkingDirectory() .. "\\config\\allpositions.txt"
local goldpotNEWPath = getWorkingDirectory() .. "\\config\\GoldpotDB_NEW.json"
local showGoldpotDB = imgui.new.bool(false)
local goldpotGroupFilter = imgui.new.int(0)
local GOLD_GROUPS = {"All", "LS", "SF", "LV", "OTHER", "NEW"}
local goldpotSearchFilter = imgui.new.char[64]("")

-- Goldpot Hint Analytics
local hintAnalytics = {}
local hintAnalyticsPath = getWorkingDirectory() .. "\\config\\HintAnalytics.json"
local showAnalytics = imgui.new.bool(false)
local analyticsSortMode = imgui.new.int(0)

-- Last hinted position tracking (for Update Coords feature)
local lastHintedName = nil
local lastHintedSavedIndex = nil
local lastHintedGoldpot = nil

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
-- AUTO-TELEPORT HELPER FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────

local function stripColorCodes(s)
    -- SA-MP inline color codes like {FFFFFF}
    return (s:gsub("{%x%x%x%x%x%x}", ""))
end

local function findBestMatchPosition(searchTerms)
    if #savedPositions == 0 then return nil end
    
    local bestMatch = nil
    local highestScore = 0
    local candidates = {}
    
    -- Score each position
    for i, pos in ipairs(savedPositions) do
        local posName = (pos.name or ""):lower()
        if posName ~= "" then
        local score = 0
        local matchedWords = 0
        local exactMatches = 0
        local totalSearchWords = #searchTerms
        local firstWordFound = false
        local unmatchedCount = 0

        -- Exact phrase match (HIGHEST priority)
        local fullPhrase = table.concat(searchTerms, " ")
        if posName:find(fullPhrase, 1, true) then
            score = 1000
            matchedWords = totalSearchWords
            exactMatches = totalSearchWords
            firstWordFound = true
        else
            for idx, term in ipairs(searchTerms) do
                term = term:lower()
                local termLen = #term
                local found = false

                -- Word boundary match
                if posName:match("%f[%w]" .. term .. "%f[%W]") then
                    score = score + 60
                    matchedWords = matchedWords + 1
                    exactMatches = exactMatches + 1
                    found = true
                -- Word-prefix match
                elseif posName:match("%f[%w]" .. term) then
                    score = score + 35
                    matchedWords = matchedWords + 0.75
                    found = true
                -- Substring match
                elseif posName:find(term, 1, true) then
                    if termLen <= 4 then
                        score = score + 8
                        matchedWords = matchedWords + 0.25
                    else
                        score = score + 20
                        matchedWords = matchedWords + 0.5
                    end
                    found = true
                end

                if found then
                    if idx == 1 and (posName:match("%f[%w]" .. term) or posName:find(term, 1, true) == 1) then
                        firstWordFound = true
                    end
                else
                    unmatchedCount = unmatchedCount + 1
                end
            end

            -- Group match bonus: if a position's group matches a search term
            local posGroup = (pos.group or ""):lower()
            if posGroup ~= "" then
                for _, term in ipairs(searchTerms) do
                    if term == posGroup or posGroup:find(term, 1, true) or term:find(posGroup, 1, true) then
                        score = score + 40
                        break
                    end
                end
            end

            -- Penalty per unmatched word
            if unmatchedCount > 0 then
                score = score - (unmatchedCount * 15)
            end

            -- First-word bonus
            if firstWordFound then
                score = score + 20
            end

            -- Word match ratio bonus
            local matchRatio = matchedWords / totalSearchWords
            if matchRatio >= 0.8 then
                score = score + 100
            elseif matchRatio >= 0.6 then
                score = score + 50
            end

            -- Exact/prefix match bonus
            if exactMatches >= math.max(1, math.floor(totalSearchWords * 0.6)) then
                score = score + 30
            end

            -- Penalty for positions with many extra words
            local posWordCount = 0
            for _ in posName:gmatch("%S+") do
                posWordCount = posWordCount + 1
            end
            if totalSearchWords > 1 and posWordCount > totalSearchWords * 2 then
                score = score - 20
            end

            -- For single-word hints, prefer descriptive names
            if totalSearchWords == 1 and posWordCount > 1 and score > 0 then
                score = score + math.min(30, posWordCount * 6)
            end
        end

            if score > 0 then
                table.insert(candidates, {pos = pos, score = score, matchedWords = matchedWords})
            end

            if score > highestScore then
                highestScore = score
                bestMatch = pos
            end
        end
    end
    
    -- Only return if score is decent (at least 40)
    if highestScore >= 40 then
        local bestMatchRatio = 0
        if bestMatch then
            local posName = (bestMatch.name or ""):lower()
            local totalWords = #searchTerms
            local matched = 0
            for _, term in ipairs(searchTerms) do
                if posName:find(term:lower(), 1, true) then
                    matched = matched + 1
                end
            end
            bestMatchRatio = matched / totalWords
        end
        return bestMatch, bestMatchRatio
    end
    
    return nil, 0
end

local function detectKeywordInMessage(text)
    local msg = stripColorCodes(text):lower()
    local originalMsg = stripColorCodes(text)
    
    -- First check if message contains any event keyword
    local hasKeyword = false
    local detectedKeyword = ""
    
    for _, keyword in ipairs(CONFIG.AUTO_TELEPORT_KEYWORDS) do
        if msg:find(keyword:lower(), 1, true) then
            hasKeyword = true
            detectedKeyword = keyword
            break
        end
    end
    
    -- Only proceed if we found a keyword AND there's a hint
    if not hasKeyword then
        return nil, nil, nil
    end
    
    -- Check for "Hint: (location)" pattern - REQUIRED
    local hintLocation = originalMsg:match("[Hh]int:%s*(.+)$")
    if hintLocation then
        -- Remove trailing punctuation and clean up
        hintLocation = hintLocation:gsub("[%.!?]+$", "")
        
        -- Extract words from hint for matching
        local searchTerms = {}
        for word in hintLocation:gmatch("%S+") do
            -- Remove punctuation from word
            word = word:gsub("[^%w]+", "")
            if #word >= 2 then -- Keep short prefixes like "SF", "LS", "LV"
                table.insert(searchTerms, word:lower())
            end
        end
        
        if #searchTerms > 0 then
            return detectedKeyword .. " - Hint: " .. hintLocation, searchTerms, hintLocation
        end
    end
    
    -- No hint found = don't auto-teleport
    return nil, nil, nil
end

local function performAutoTeleport(searchTerms)
    if not isSampAvailable() or sampIsDialogActive() or sampIsChatInputActive() then
        return false
    end
    
    -- Check cooldown
    local currentTime = os.clock()
    if currentTime - lastTeleportTime < CONFIG.TELEPORT_COOLDOWN then
        local remaining = math.ceil(CONFIG.TELEPORT_COOLDOWN - (currentTime - lastTeleportTime))
        sampAddChatMessage("{FF6600}[AutoTP]{FFFFFF} Teleport cooldown: " .. remaining .. "s remaining", 0xFFFFFFFF)
        return false
    end
    
    -- Find best matching position
    local targetPos = findBestMatchPosition(searchTerms)
    
    if not targetPos then
        sampAddChatMessage("{FF6600}[AutoTP]{FFFFFF} No matching position found for the detected keyword", 0xFFFFFFFF)
        return false
    end
    
    -- Teleport
    local result, handle = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if result then
        setCharCoordinates(PLAYER_PED, targetPos.x, targetPos.y, targetPos.z)
        if targetPos.angle then
            setCharHeading(PLAYER_PED, targetPos.angle)
        end
        if targetPos.interior and targetPos.interior ~= 0 then
            setActiveInterior(targetPos.interior)
        end
        
        -- Force camera fix
        restoreCameraJumpcut()
        
        lastTeleportTime = currentTime
        
        sampAddChatMessage("{00FF00}[AutoTP]{FFFFFF} Teleported to: {FFFF00}" .. targetPos.name, 0xFFFFFFFF)
        sampAddChatMessage("{00BFFF}Position: {FFFFFF}" .. string.format("%.1f, %.1f, %.1f", targetPos.x, targetPos.y, targetPos.z), 0xFFFFFFFF)
        
        printStringNow("~g~AUTO TELEPORTED!~n~~y~" .. targetPos.name, 3000)
        
        return true
    end
    
    return false
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
    
    local file = io.open(CONFIG.SAVE_FILE, "r")
    if not file then
        return false
    end
    
    local content = file:read("*a")
    file:close()
    
    if not content or content == "" then
        return false
    end
    
    -- Try loading as Lua table (your current format)
    local func, err = loadstring("return " .. content)
    if func then
        local success, data = pcall(func)
        if success and type(data) == "table" then
            -- Handle double nested table { { ... } }
            if #data == 1 and type(data[1]) == "table" then
                savedPositions = data[1]
            else
                savedPositions = data
            end
            
            -- Add missing fields
            for i, pos in ipairs(savedPositions) do
                if not pos.timestamp then pos.timestamp = os.time() end
                if pos.shortcut == nil then pos.shortcut = "" end
                if pos.group == nil then pos.group = "" end
            end
            
            return true
        end
    end
    
    return false
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

local function importFromText(text, merge)
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
                local originalCount = #savedPositions
                
                if merge then
                    -- Merge mode: Add imported positions to existing ones
                    local duplicateCount = 0
                    for _, newPos in ipairs(importedPositions) do
                        -- Check for duplicates by name
                        local exists = false
                        for _, existingPos in ipairs(savedPositions) do
                            if existingPos.name == newPos.name then
                                exists = true
                                duplicateCount = duplicateCount + 1
                                break
                            end
                        end
                        
                        if not exists then
                            table.insert(savedPositions, newPos)
                        end
                    end
                    
                    savePositionsToFile()
                    local addedCount = #savedPositions - originalCount
                    local msg = string.format("Merged: Added %d new positions", addedCount)
                    if duplicateCount > 0 then
                        msg = msg .. string.format(" (Skipped %d duplicates)", duplicateCount)
                    end
                    return true, msg
                else
                    -- Replace mode: Replace all positions
                    savedPositions = importedPositions
                    savePositionsToFile()
                    return true, "Successfully imported " .. #importedPositions .. " positions (replaced all)"
                end
            end
        end
    end
    
    return false, "No valid position data found in text"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- GOLDPOT DATABASE FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────

local function trim(s)
    return (s:match("^%s*(.-)%s*$") or s)
end

local function normalizeNameDB(name)
    return trim(name:lower():gsub("[^%w%s]", ""):gsub("%s+", " "))
end

local function loadGoldpotDatabase()
    goldpotDB = {}
    goldpotDBLoaded = false
    
    local file = io.open(goldpotDBPath, "r")
    if not file then return false end
    
    local content = file:read("*a")
    file:close()
    if not content or content == "" then return false end
    
    local currentGroup = "LS"
    local entries = {}
    
    for line in content:gmatch("[^\r\n]+") do
        local trimmed = trim(line)
        if trimmed == "" then
            -- skip empty lines
        elseif trimmed:match("^LS Goldpots:%s*$") then
            currentGroup = "LS"
        elseif trimmed:match("^SF Goldpots:%s*$") then
            currentGroup = "SF"
        elseif trimmed:match("^LV Goldpots:%s*$") then
            currentGroup = "LV"
        elseif trimmed:match("^OTHER Goldpots:%s*$") then
            currentGroup = "OTHER"
        else
            local lineContent = trimmed:match("^%d+:%s*(.*)")
            if not lineContent then lineContent = trimmed end
            
            -- Extract shortcut: (/xxx) or (/xxx or /yyy)
            local shortcut = ""
            local shortMatch = lineContent:match("%((/[^%)]+)%)%s*$")
            if shortMatch then
                local firstCmd = shortMatch:match("/(%w+)")
                if firstCmd then shortcut = "/" .. firstCmd end
                lineContent = lineContent:gsub("%s*%((/[^%)]+)%)%s*$", "")
            end
            
            -- Remove timestamp " - MM:SS" or " MM:SS" at end
            lineContent = lineContent:gsub("%s*[-–]%s*%d+:%d+%s*$", "")
            lineContent = lineContent:gsub("%s*%d+:%d+%s*$", "")
            -- Remove trailing junk
            lineContent = lineContent:gsub("%s*%*.*$", "")
            
            local name = trim(lineContent)
            if name and name ~= "" then
                table.insert(entries, {
                    name = name,
                    shortcut = shortcut,
                    group = currentGroup,
                    saved = false,
                    savedIndex = nil
                })
            end
        end
    end
    
    goldpotDB = entries
    goldpotDBLoaded = true
    return true
end

local function matchGoldpotDatabase()
    if not goldpotDBLoaded then return end
    
    for _, entry in ipairs(goldpotDB) do
        entry.saved = false
        entry.savedIndex = nil
        
        local entryNorm = normalizeNameDB(entry.name)
        if entryNorm ~= "" then
            for j, pos in ipairs(savedPositions) do
                local posNorm = normalizeNameDB(pos.name or "")
                if posNorm ~= "" and posNorm == entryNorm then
                    entry.saved = true
                    entry.savedIndex = j
                    if not pos.shortcut or pos.shortcut == "" then
                        pos.shortcut = entry.shortcut
                    end
                    if not pos.group or pos.group == "" then
                        pos.group = entry.group
                    end
                    break
                end
            end
        end
    end
end

local function findGoldpotEntry(name)
    if not goldpotDBLoaded then return nil end
    local norm = normalizeNameDB(name)
    if norm == "" then return nil end
    for _, entry in ipairs(goldpotDB) do
        if normalizeNameDB(entry.name) == norm then return entry end
    end
    return nil
end

local function getFilteredGoldpotEntries()
    local results = {}
    local filterText = trim(ffi.string(goldpotSearchFilter):lower())
    local groupIdx = goldpotGroupFilter[0]
    
    for _, entry in ipairs(goldpotDB) do
        local match = true
        
        -- Group filter
        if groupIdx > 0 then
            local groupName = GOLD_GROUPS[groupIdx + 1]
            if entry.group ~= groupName then
                match = false
            elseif groupName == "NEW" and entry.saved then
                match = false
            end
        end
        
        -- Search filter
        if match and filterText ~= "" then
            local nameMatch = entry.name:lower():find(filterText, 1, true)
            local shortMatch = entry.shortcut:lower():find(filterText, 1, true)
            if not nameMatch and not shortMatch then
                match = false
            end
        end
        
        if match then
            table.insert(results, entry)
        end
    end
    
    return results
end

-- ─────────────────────────────────────────────────────────────────────────────
-- GOLDPOT NEW ENTRIES PERSISTENCE
-- ─────────────────────────────────────────────────────────────────────────────

local function saveGoldpotNEW()
    local newEntries = {}
    for _, entry in ipairs(goldpotDB) do
        if entry.group == "NEW" then
            table.insert(newEntries, {name = entry.name, group = "NEW", saved = entry.saved or false})
        end
    end
    if #newEntries == 0 then return true end
    local jsonData = serializeTable(newEntries, nil, true)
    local file = io.open(goldpotNEWPath, "w")
    if file then
        file:write(jsonData)
        file:close()
        return true
    end
    return false
end

local function loadGoldpotNEW()
    if not doesFileExist(goldpotNEWPath) then return true end
    local file = io.open(goldpotNEWPath, "r")
    if not file then return false end
    local content = file:read("*a")
    file:close()
    if not content or content == "" then return true end
    local func, err = loadstring("return " .. content)
    if func then
        local success, data = pcall(func)
        if success and type(data) == "table" then
            for _, entry in ipairs(data) do
                -- Check if already in goldpotDB (might have been added from allpositions.txt)
                local exists = false
                for _, existing in ipairs(goldpotDB) do
                    if normalizeNameDB(existing.name) == normalizeNameDB(entry.name) then
                        exists = true
                        break
                    end
                end
                if not exists then
                    table.insert(goldpotDB, {
                        name = entry.name,
                        shortcut = entry.shortcut or "",
                        group = "NEW",
                        saved = false,
                        savedIndex = nil
                    })
                end
            end
            return true
        end
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HINT ANALYTICS FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────

local function loadHintAnalytics()
    local file = io.open(hintAnalyticsPath, "r")
    if not file then return false end
    local content = file:read("*a")
    file:close()
    if not content or content == "" then return false end
    local func, err = loadstring("return " .. content)
    if func then
        local success, data = pcall(func)
        if success and type(data) == "table" then
            hintAnalytics = data
            return true
        end
    end
    return false
end

local function saveHintAnalytics()
    if not hintAnalytics or next(hintAnalytics) == nil then return end
    local jsonData = serializeTable(hintAnalytics, nil, true)
    local file = io.open(hintAnalyticsPath, "w")
    if file then
        file:write(jsonData)
        file:close()
    end
end

local function trackHint(name, shortcut, group)
    local key = name:lower()
    if not hintAnalytics[key] then
        hintAnalytics[key] = {
            name = name,
            shortcut = shortcut or "",
            group = group or "",
            count = 0,
            firstSeen = os.time(),
            lastSeen = os.time()
        }
    end
    hintAnalytics[key].count = hintAnalytics[key].count + 1
    hintAnalytics[key].lastSeen = os.time()
    hintAnalytics[key].shortcut = shortcut or hintAnalytics[key].shortcut or ""
    hintAnalytics[key].group = group or hintAnalytics[key].group or ""
end

local function getAnalyticsStats()
    local totalHints = 0
    local uniqueCount = 0
    local lastHint = nil
    local lastHintTime = 0
    local hotList = {}
    
    for key, data in pairs(hintAnalytics) do
        totalHints = totalHints + data.count
        if data.count > 0 then uniqueCount = uniqueCount + 1 end
        if data.lastSeen > lastHintTime then
            lastHintTime = data.lastSeen
            lastHint = data
        end
        if data.count >= 3 then
            table.insert(hotList, data)
        end
    end
    
    table.sort(hotList, function(a, b) return a.count > b.count end)
    
    local topHot = {}
    for i = 1, math.min(3, #hotList) do
        table.insert(topHot, hotList[i])
    end
    
    return totalHints, uniqueCount, lastHint, lastHintTime, topHot
end

local function getSortedAnalytics(sortMode)
    local results = {}
    local seenKeys = {}
    
    -- First, add all goldpot DB entries with analytics data merged in
    for _, entry in ipairs(goldpotDB) do
        local key = entry.name:lower()
        local analyticsData = hintAnalytics[key]
        if analyticsData then
            seenKeys[key] = true
            table.insert(results, {
                name = entry.name,
                shortcut = entry.shortcut or "",
                group = entry.group or "",
                count = analyticsData.count,
                firstSeen = analyticsData.firstSeen,
                lastSeen = analyticsData.lastSeen
            })
        else
            table.insert(results, {
                name = entry.name,
                shortcut = entry.shortcut or "",
                group = entry.group or "",
                count = 0,
                firstSeen = 0,
                lastSeen = 0
            })
        end
    end
    
    -- Add any orphaned analytics entries (not in goldpot DB, e.g. unknown hints)
    for key, data in pairs(hintAnalytics) do
        if not seenKeys[key] then
            table.insert(results, {
                name = data.name,
                shortcut = data.shortcut or "",
                group = data.group or "",
                count = data.count,
                firstSeen = data.firstSeen,
                lastSeen = data.lastSeen
            })
        end
    end
    
    if sortMode == 0 then -- Most frequent
        table.sort(results, function(a, b) return a.count > b.count end)
    elseif sortMode == 1 then -- Least frequent (seen at least once)
        table.sort(results, function(a, b)
            if a.count == 0 and b.count > 0 then return false end
            if b.count == 0 and a.count > 0 then return true end
            return a.count < b.count
        end)
    elseif sortMode == 2 then -- Never seen
        table.sort(results, function(a, b)
            if a.count == 0 and b.count > 0 then return true end
            if b.count == 0 and a.count > 0 then return false end
            return a.name < b.name
        end)
    end
    
    return results
end

-- ─────────────────────────────────────────────────────────────────────────────
-- UTILITY FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────

local function setStatusMessage(msg)
    statusMessage = msg
    statusMessageTime = os.clock()
end

-- Fuzzy string matching - returns similarity score (0-1)
local function calculateSimilarity(str1, str2)
    str1 = str1:lower()
    str2 = str2:lower()
    
    -- Exact match
    if str1 == str2 then return 1.0 end
    
    -- Contains match (higher score)
    if str2:find(str1, 1, true) or str1:find(str2, 1, true) then
        return 0.9
    end
    
    -- Calculate Levenshtein-like similarity
    local len1, len2 = #str1, #str2
    local matches = 0
    
    -- Count matching characters
    for i = 1, math.min(len1, len2) do
        if str1:sub(i,i) == str2:sub(i,i) then
            matches = matches + 1
        end
    end
    
    -- Word matching - split by spaces and check if words match
    local words1 = {}
    for word in str1:gmatch("%S+") do
        table.insert(words1, word)
    end
    
    local wordMatches = 0
    for _, word1 in ipairs(words1) do
        if str2:find(word1, 1, true) then
            wordMatches = wordMatches + 1
        end
    end
    
    local wordScore = wordMatches / math.max(#words1, 1)
    local charScore = matches / math.max(len1, len2)
    
    -- Combine scores
    return math.max(wordScore * 0.8, charScore * 0.6)
end

-- Find best matching position by name
local function findPositionByName(searchName)
    if not searchName or searchName == "" then return nil end
    
    local bestMatch = nil
    local bestScore = 0
    local bestIndex = nil
    
    for i, pos in ipairs(savedPositions) do
        local posName = pos.name or ""
        local score = calculateSimilarity(searchName, posName)
        
        if score > bestScore then
            bestScore = score
            bestMatch = pos
            bestIndex = i
        end
    end
    
    -- Require at least 30% similarity to avoid random matches
    if bestScore >= 0.3 then
        return bestMatch, bestIndex, bestScore
    end
    
    return nil, nil, 0
end

-- Check if position name already exists (exact match)
local function isPositionNameExists(name)
    if not name or name == "" then return false end
    
    local nameLower = name:lower()
    for i, pos in ipairs(savedPositions) do
        if pos.name and pos.name:lower() == nameLower then
            return true, i
        end
    end
    
    return false, nil
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

local function doUpdateCoords()
    if lastHintedSavedIndex and savedPositions[lastHintedSavedIndex] then
        local px, py, pz = getPlayerPosition()
        savedPositions[lastHintedSavedIndex].x = px
        savedPositions[lastHintedSavedIndex].y = py
        savedPositions[lastHintedSavedIndex].z = pz
        savedPositions[lastHintedSavedIndex].timestamp = os.time()
        savePositionsToFile()
        local msg = "{00FF00}[BagSpot]{FFFFFF} Updated coords for: {FFFF00}" .. lastHintedName
        sampAddChatMessage(msg, 0xFFFFFFFF)
        setStatusMessage("✓ Updated coords: " .. lastHintedName)
        return true
    elseif lastHintedGoldpot then
        local x, y, z, angle, interior, inVehicle = getPlayerPosition()
        local newPos = {
            name = lastHintedGoldpot.name,
            x = x,
            y = y,
            z = z,
            angle = angle or 0,
            interior = interior or 0,
            shortcut = lastHintedGoldpot.shortcut or "",
            group = lastHintedGoldpot.group or "",
            timestamp = os.time()
        }
        table.insert(savedPositions, newPos)
        savePositionsToFile()
        if goldpotDBLoaded then
            matchGoldpotDatabase()
            saveGoldpotNEW()
        end
        local msg = "{00FF00}[BagSpot]{FFFFFF} Saved exact location: {FFFF00}" .. lastHintedGoldpot.name
        sampAddChatMessage(msg, 0xFFFFFFFF)
        setStatusMessage("✓ Saved exact location: " .. lastHintedGoldpot.name)
        lastHintedSavedIndex = #savedPositions
        lastHintedGoldpot = nil
        return true
    else
        sampAddChatMessage("{FF6600}[BagSpot]{FFFFFF} No hint detected yet. Wait for a hint first.", 0xFFFFFFFF)
        return false
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- NEW ENHANCED FEATURES
-- ─────────────────────────────────────────────────────────────────────────────

-- Sound alert helper
function playBeep(freq, duration)
    if not soundAlert[0] then return end
    xpcall(function() kernel32.Beep(freq or 800, duration or 150) end, function() end)
end

-- Calculate distance between two 3D points
local function calculateDistance(x1, y1, z1, x2, y2, z2)
    local dx = x2 - x1
    local dy = y2 - y1
    local dz = z2 - z1
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- GPS arrow rotation: returns degrees, 0 = target ahead, >0 = right, <0 = left
local function getDirectionArrowDeg(playerX, playerY, playerHeading, targetX, targetY)
    local headingRad = math.rad(playerHeading)
    local fwdX = math.sin(headingRad)
    local fwdY = math.cos(headingRad)
    local dx = targetX - playerX
    local dy = targetY - playerY
    local len = math.sqrt(dx*dx + dy*dy)
    if len < 0.01 then return 0 end
    local dirX = dx / len
    local dirY = dy / len
    local dot = fwdX * dirX + fwdY * dirY
    local cross = fwdX * dirY - fwdY * dirX
    return math.deg(math.atan2(cross, dot))
end

-- Render a rotated arrow at screen position (PNG or polygon fallback)
local function renderRotatedArrow(sx, sy, angleDeg, size, color, glowColor)
    if gpsArrowTex then
        local w = math.min(size * 1.8, 24)
        local h = math.min(size * 2.4, 32)
        if glowColor then
            renderDrawTexture(gpsArrowTex, sx - w/2 - 2, sy - h/2 - 2, w + 4, h + 4, angleDeg)
        end
        renderDrawTexture(gpsArrowTex, sx - w/2, sy - h/2, w, h, angleDeg)
    else
        if glowColor then
            renderDrawPolygon(sx - size - 1, sy - size - 1, (size + 1) * 2, (size + 1) * 2, 3, angleDeg, glowColor)
        end
        renderDrawPolygon(sx - size, sy - size, size * 2, size * 2, 3, angleDeg, color)
    end
end

-- Direction label: FRONT or BACK
local function getDirectionLabel(angleDeg)
    if type(angleDeg) ~= "number" then return "FRONT" end
    if math.abs(angleDeg) < 90 then return "FRONT"
    else return "BACK" end
end

-- Render GPS guide ring at bottom-center of screen
local function renderGPSRing(cx, cy, radius, angleDeg, targetName, distance, deltaDist, textColor)
    for dy = -radius, radius do
        local hw = math.sqrt(radius * radius - dy * dy)
        renderDrawLine(cx - hw, cy + dy, cx + hw, cy + dy, 1.0, 0x88000000)
    end
    local steps = 24
    for i = 1, steps do
        local a1 = (i-1) / steps * math.pi * 2
        local a2 = i / steps * math.pi * 2
        renderDrawLine(
            cx + math.cos(a1) * radius, cy + math.sin(a1) * radius,
            cx + math.cos(a2) * radius, cy + math.sin(a2) * radius,
            1.5, 0xCCFFFFFF
        )
    end
    local arrowSize = radius - 6
    local arrowColor, arrowGlow
    if deltaDist == nil then
        arrowColor = 0xFFFFFFFF
        arrowGlow = 0x44FFFFFF
    elseif deltaDist > 0 then
        arrowColor = 0xFF00FF00
        arrowGlow = 0x4400FF00
    else
        arrowColor = 0xFFFF4444
        arrowGlow = 0x44FF4444
    end
    renderRotatedArrow(cx, cy, angleDeg, arrowSize, arrowColor, arrowGlow)
    if espFont then
        local deltaStr = ""
        local deltaClr = 0xFFFFFFFF
        if deltaDist then
            if deltaDist > 0 then
                deltaStr = string.format(" -%.0fm", deltaDist)
                deltaClr = 0xFF00FF00
            elseif deltaDist < 0 then
                deltaStr = string.format(" +%.0fm", math.abs(deltaDist))
                deltaClr = 0xFFFF4444
            end
        end
        local info = string.format("%s  %.0fm%s", targetName or "", distance or 0, deltaStr)
        renderFontDrawText(espFont, info, cx - radius - 10, cy + radius + 5, 0x80000000)
        renderFontDrawText(espFont, info, cx - radius - 11, cy + radius + 4, deltaClr)
    end
end

-- Get cached distance or calculate new one
local function getDistanceToPosition(pos)
    local x, y, z = getCharCoordinates(PLAYER_PED)
    local posName = pos.name or ""
    local posKey = string.format("%s_%.0f_%.0f", posName, pos.x, pos.y)
    
    -- Check cache
    if distanceCache[posKey] then
        return distanceCache[posKey]
    end
    
    -- Calculate and cache
    local distance = calculateDistance(x, y, z, pos.x, pos.y, pos.z)
    distanceCache[posKey] = distance
    return distance
end

-- Update distance cache periodically
local function updateDistanceCache()
    local currentTime = os.clock()
    if currentTime - lastCacheUpdate >= cacheUpdateInterval then
        distanceCache = {} -- Clear old cache
        lastCacheUpdate = currentTime
    end
end

-- Check if position is duplicate
local function isDuplicatePosition(x, y, z, threshold)
    threshold = threshold or 5.0 -- 5 meter threshold
    
    for i, pos in ipairs(savedPositions) do
        local distance = calculateDistance(x, y, z, pos.x, pos.y, pos.z)
        if distance < threshold then
            return true, i, pos
        end
    end
    
    return false, nil, nil
end

-- Auto-backup system
local function createBackup()
    ensureDirectoryExists(CONFIG.BACKUP_FILE)
    
    local jsonData = tableToJson(savedPositions)
    local file = io.open(CONFIG.BACKUP_FILE, "w")
    if file then
        file:write(jsonData)
        file:close()
        return true
    end
    return false
end

-- Sort positions function
local function getSortedPositions()
    local filtered = {}
    local filterText = ffi.string(searchFilter):lower()
    
    -- Apply filters
    for i, pos in ipairs(savedPositions) do
        local nameMatch = filterText == "" or (pos.name and pos.name:lower():find(filterText, 1, true))
        
        if nameMatch then
            table.insert(filtered, {index = i, pos = pos})
        end
    end
    
    -- Sort
    if sortMode[0] == 1 then -- By Name
        table.sort(filtered, function(a, b) 
            return (a.pos.name or ""):lower() < (b.pos.name or ""):lower()
        end)
    elseif sortMode[0] == 2 then -- By Date
        table.sort(filtered, function(a, b) 
            return (a.pos.timestamp or 0) > (b.pos.timestamp or 0)
        end)
    elseif sortMode[0] == 3 then -- By Distance
        table.sort(filtered, function(a, b) 
            local distA = getDistanceToPosition(a.pos)
            local distB = getDistanceToPosition(b.pos)
            return distA < distB
        end)
    end
    
    return filtered
end

-- ─────────────────────────────────────────────────────────────────────────────
-- ROUTE SYSTEM
-- ─────────────────────────────────────────────────────────────────────────────

local function saveRoutesToFile()
    ensureDirectoryExists(CONFIG.ROUTES_FILE)
    local jsonData = tableToJson(savedRoutes)
    local file = io.open(CONFIG.ROUTES_FILE, "w")
    if file then
        file:write(jsonData)
        file:close()
        return true
    end
    return false
end

local function loadRoutesFromFile()
    if not doesFileExist(CONFIG.ROUTES_FILE) then
        return true
    end
    
    local file = io.open(CONFIG.ROUTES_FILE, "r")
    if not file then return false end
    
    local content = file:read("*a")
    file:close()
    
    if content and content ~= "" then
        savedRoutes = jsonToTable(content) or {}
    end
    
    return true
end

local function createRoute(name, positionIndices)
    local route = {
        name = name,
        positions = {},
        created = os.time()
    }
    
    for _, idx in ipairs(positionIndices) do
        if savedPositions[idx] then
            table.insert(route.positions, {
                name = savedPositions[idx].name,
                x = savedPositions[idx].x,
                y = savedPositions[idx].y,
                z = savedPositions[idx].z,
                angle = savedPositions[idx].angle,
                interior = savedPositions[idx].interior
            })
        end
    end
    
    table.insert(savedRoutes, route)
    saveRoutesToFile()
    return route
end

local function startRoute(routeIndex)
    if savedRoutes[routeIndex] then
        activeRoute = savedRoutes[routeIndex]
        currentRouteIndex = 1
        return true
    end
    return false
end

local function nextRoutePosition()
    if not activeRoute or currentRouteIndex > #activeRoute.positions then
        activeRoute = nil
        return false
    end
    
    local pos = activeRoute.positions[currentRouteIndex]
    if teleportToPosition(pos) then
        currentRouteIndex = currentRouteIndex + 1
        return true
    end
    
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- ESP RENDERING SYSTEM
-- ─────────────────────────────────────────────────────────────────────────────

local function worldToScreen(posX, posY, posZ)
    local result, screenX, screenY = convert3DCoordsToScreen(posX, posY, posZ)
    if result then
        local behindPlayer = false
        local camX, camY, camZ = getActiveCameraCoordinates()
        local angleX = posX - camX
        local angleY = posY - camY
        local angleZ = posZ - camZ
        
        -- Check if behind camera
        local camPointX, camPointY, camPointZ = getActiveCameraPointAt()
        local dotProduct = angleX * (camPointX - camX) + angleY * (camPointY - camY) + angleZ * (camPointZ - camZ)
        
        if dotProduct < 0 then
            behindPlayer = true
        end
        
        return true, screenX, screenY, behindPlayer
    end
    return false, 0, 0, false
end

local function renderPositionESP()
    if #savedPositions == 0 then return end
    local playerX, playerY, playerZ = getCharCoordinates(PLAYER_PED)
    local scrW, scrH = getScreenResolution()

    -- Draw focus overlay if a position is currently focused (orange pulsing line)
    if espFocusPosition then
        local dist = calculateDistance(playerX, playerY, playerZ, espFocusPosition.x, espFocusPosition.y, espFocusPosition.z)
        repeat
        local a, b, c = convert3DCoordsToScreen(espFocusPosition.x, espFocusPosition.y, espFocusPosition.z)
        local sx, sy
        if type(a) == "boolean" then
            if not a then break end
            sx, sy = b, c
        else
            sx, sy = a, b
        end
        if not (sx and sy) then break end

        if sx > 0 and sx < scrW and sy > 0 and sy < scrH then
            local pulse = (math.sin(os.clock() * 3) + 1) / 2
            local alpha = math.floor(0xF0 * (0.6 + pulse * 0.4))
            local color = (alpha * 0x1000000) + 0xFF8800
            renderDrawLine(scrW / 2, scrH, sx, sy, 2.0 + pulse, color)
            renderDrawPolygon(sx - 4, sy - 4, 8, 8, 4, 0, color)
            if espFont then
                local label = string.format(">> %s - %.0fm <<", espFocusPosition.name or "#?", dist)
                renderFontDrawText(espFont, label, sx - 60, sy - 20, 0x80000000)
                renderFontDrawText(espFont, label, sx - 61, sy - 21, color)
            end
        end
        until true

        if espFont then
            local heading = getCharHeading(PLAYER_PED)
            local focusAngle = getDirectionArrowDeg(playerX, playerY, heading, espFocusPosition.x, espFocusPosition.y)
            local focusDelta = prevFocusDist and (prevFocusDist - dist) or nil
            prevFocusDist = dist
            local gpsCx = scrW / 2
            local gpsCy = scrH - 60
            renderGPSRing(gpsCx, gpsCy, 28, focusAngle, espFocusPosition.name, dist, focusDelta, 0xFFFF8800)
        end

        -- Auto-clear when within 10m
        if dist < 10 then
            espFocusPosition = nil
        end
    end

    -- Regular ESP (all positions, only if showESP is ON)
    if not showESP[0] then return end
    local maxDist = espDistance[0]

    for i, pos in ipairs(savedPositions) do
        local dist = calculateDistance(playerX, playerY, playerZ, pos.x, pos.y, pos.z)
        if dist <= maxDist then
            repeat
            local a, b, c = convert3DCoordsToScreen(pos.x, pos.y, pos.z)
            local sx, sy
            if type(a) == "boolean" then
                if not a then break end
                sx, sy = b, c
            else
                sx, sy = a, b
            end
            if not (sx and sy) then break end

            if sx > 0 and sx < scrW and sy > 0 and sy < scrH then
                local grad = math.min(1, dist / 5000)
                local alpha = math.floor(0xCC * (1 - grad * 0.5))
                local color = (alpha * 0x1000000) + 0x00BFFF
                renderDrawLine(scrW / 2, scrH, sx, sy, 1.0, color)
                renderDrawPolygon(sx - 3, sy - 3, 6, 6, 4, 0, color)
                if espFont then
                    renderFontDrawText(espFont, pos.name or ("#" .. i), sx + 6, sy - 8, 0x80000000)
                    renderFontDrawText(espFont, pos.name or ("#" .. i), sx + 5, sy - 9, color)
                end
            end
            until true
        end
    end
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
    imgui.Text(">> BagSpot")
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
    
    imgui.SameLine()
    local goldButtonColor = showGoldpotDB[0] and imgui.ImVec4(0.8, 0.5, 0.0, 1.0) or imgui.ImVec4(0.3, 0.3, 0.4, 0.6)
    imgui.PushStyleColor(imgui.Col.Button, goldButtonColor)
    if imgui.Button(showGoldpotDB[0] and "DB: ON" or "Goldpot DB", imgui.ImVec2(90, 0)) then
        showGoldpotDB[0] = not showGoldpotDB[0]
    end
    imgui.PopStyleColor()
    
    imgui.SameLine()
    local hasHint = lastHintedName ~= nil
    local ucColor = hasHint and imgui.ImVec4(0.1, 0.7, 0.3, 1.0) or imgui.ImVec4(0.3, 0.3, 0.4, 0.4)
    imgui.PushStyleColor(imgui.Col.Button, ucColor)
    imgui.PushStyleColor(imgui.Col.Text, hasHint and imgui.ImVec4(1.0, 1.0, 1.0, 1.0) or imgui.ImVec4(0.5, 0.5, 0.5, 0.5))
    if imgui.Button("📍 Update Coords", imgui.ImVec2(130, 0)) then
        doUpdateCoords()
    end
    imgui.PopStyleColor()
    imgui.PopStyleColor()
    
    imgui.Separator()
    
    if not showGoldpotDB[0] then
        -- NORMAL VIEW ---
    
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
        
        -- Check for duplicate positions by coordinates
        local isDupe, dupeIndex, dupePos = isDuplicatePosition(x, y, z, 10.0)
        if isDupe then
            sampAddChatMessage(string.format("{FF6600}[BagSpot]{FFFFFF} Warning: Position very close to '%s' (%.1fm away)", 
                dupePos.name, calculateDistance(x, y, z, dupePos.x, dupePos.y, dupePos.z)), 0xFFFFFFFF)
        end
        
        -- Check if name already exists
        local exists, existingIndex = isPositionNameExists(name)
        if exists then
            setStatusMessage("✗ Position '" .. name .. "' already exists at #" .. existingIndex)
        else
            local goldMatch = findGoldpotEntry(name)
            local newPos = {
                name = name,
                x = x,
                y = y,
                z = z,
                angle = angle,
                interior = interior,
                inVehicle = inVehicle,
                timestamp = os.time(),
                shortcut = goldMatch and goldMatch.shortcut or "",
                group = goldMatch and goldMatch.group or ""
            }
            
            table.insert(savedPositions, newPos)
            saveCounter = saveCounter + 1
            
            if savePositionsToFile() then
                if goldpotDBLoaded then
                    matchGoldpotDatabase()
                    saveGoldpotNEW()
                end
                setStatusMessage("✓ Saved: " .. name .. " (Total: " .. #savedPositions .. ")")
                
                -- Auto-backup every X saves
                if saveCounter % CONFIG.AUTO_BACKUP_INTERVAL == 0 then
                    if createBackup() then
                        sampAddChatMessage("{00FF00}[BagSpot]{FFFFFF} Auto-backup created", 0xFFFFFFFF)
                    end
                end
            else
                setStatusMessage("✗ Failed to save position")
            end
            
            ffi.fill(newPositionName, CONFIG.MAX_NAME_LENGTH)
        end
    end
    imgui.PopStyleColor()
    
    imgui.SameLine()
    
    -- ─────────────────────────────────────────────────────────────────────────
    -- AUTO-TELEPORT TOGGLE SECTION
    -- ─────────────────────────────────────────────────────────────────────────
    
    local buttonColor = autoTeleportEnabled[0] and imgui.ImVec4(0.2, 0.8, 0.2, 1.0) or imgui.ImVec4(0.8, 0.2, 0.2, 1.0)
    local buttonText = autoTeleportEnabled[0] and "Auto-TP: ON" or "Auto-TP: OFF"
    
    imgui.PushStyleColor(imgui.Col.Button, buttonColor)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(buttonColor.x + 0.1, buttonColor.y + 0.1, buttonColor.z + 0.1, 1.0))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(buttonColor.x - 0.1, buttonColor.y - 0.1, buttonColor.z - 0.1, 1.0))
    
    if imgui.Button(buttonText, imgui.ImVec2(120, 40)) then
        autoTeleportEnabled[0] = not autoTeleportEnabled[0]
        local status = autoTeleportEnabled[0] and "ENABLED" or "DISABLED"
        local color = autoTeleportEnabled[0] and "{00FF00}" or "{FF0000}"
        sampAddChatMessage(color .. "[AutoTP]{FFFFFF} Auto-Teleport " .. status, 0xFFFFFFFF)
        setStatusMessage("✓ Auto-Teleport " .. status)
    end
    
    imgui.PopStyleColor(3)
    
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Toggle auto-teleport on chat events (GoldPOT, Hunt, etc.)\\nHelps avoid bans by enabling/disabling quickly")
    end
    
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
            sampAddChatMessage("{00FF00}[BagSpot]{FFFFFF} " .. msg, 0xFFFFFFFF)
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
            if goldpotDBLoaded then
                matchGoldpotDatabase()
                saveGoldpotNEW()
            end
            setStatusMessage("✓ Reloaded " .. #savedPositions .. " positions from file")
        else
            setStatusMessage("✗ Failed to reload positions")
        end
    end
    
    imgui.Separator()
    
    -- ─────────────────────────────────────────────────────────────────────────
    -- SEARCH AND FILTER
    -- ─────────────────────────────────────────────────────────────────────────
    
    -- ESP Controls
    imgui.Text("ESP Hunt Mode:")
    imgui.SameLine()
    
    local espButtonColor = showESP[0] and imgui.ImVec4(0.2, 0.8, 0.2, 1.0) or imgui.ImVec4(0.5, 0.5, 0.5, 0.6)
    imgui.PushStyleColor(imgui.Col.Button, espButtonColor)
    if imgui.Button(showESP[0] and "ESP: ON (F9)" or "ESP: OFF (F9)", imgui.ImVec2(130, 25)) then
        showESP[0] = not showESP[0]
    end
    imgui.PopStyleColor()
    
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Show all saved positions on screen (perfect for manual hunting!)")
    end
    
    imgui.SameLine()
    imgui.Text("Distance:")
    imgui.SameLine()
    imgui.PushItemWidth(100)
    imgui.SliderFloat("##ESPDist", espDistance, 100, 20000, "%.0fm")
    imgui.PopItemWidth()
    
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Set to 10000+ to see entire map")
    end
    
    -- Auto Focus toggle (auto-focus on hint detection)
    imgui.SameLine()
    local afColor = autoFocusEnabled[0] and imgui.ImVec4(0.9, 0.5, 0.0, 1.0) or imgui.ImVec4(0.5, 0.5, 0.5, 0.6)
    imgui.PushStyleColor(imgui.Col.Button, afColor)
    if imgui.Button(autoFocusEnabled[0] and "AutoFocus: ON" or "AutoFocus: OFF", imgui.ImVec2(120, 25)) then
        autoFocusEnabled[0] = not autoFocusEnabled[0]
        setStatusMessage(autoFocusEnabled[0] and "Auto-focus enabled (hints set focus)" or "Auto-focus disabled")
    end
    imgui.PopStyleColor()
    if imgui.IsItemHovered() then
        if autoFocusEnabled[0] then
            imgui.SetTooltip("Auto-focus from hints is ON. Toggle OFF to disable.")
        else
            imgui.SetTooltip("Auto-focus from hints is OFF. Use Set Focus button to manually focus.")
        end
    end

    -- Manual "Set Focus" button (works even when auto-focus is OFF)
    imgui.SameLine()
    local hasHint = lastHintedSavedIndex ~= nil
    local sfColor = hasHint and imgui.ImVec4(0.2, 0.6, 0.8, 1.0) or imgui.ImVec4(0.3, 0.3, 0.4, 0.4)
    imgui.PushStyleColor(imgui.Col.Button, sfColor)
    if imgui.Button("Set Focus", imgui.ImVec2(80, 25)) then
        if lastHintedSavedIndex and savedPositions[lastHintedSavedIndex] then
            espFocusPosition = {
                x = savedPositions[lastHintedSavedIndex].x,
                y = savedPositions[lastHintedSavedIndex].y,
                z = savedPositions[lastHintedSavedIndex].z,
                name = savedPositions[lastHintedSavedIndex].name or ("#" .. lastHintedSavedIndex)
            }
            espFocusTime = os.clock()
            setStatusMessage("Manual focus set: " .. (savedPositions[lastHintedSavedIndex].name or "#" .. lastHintedSavedIndex))
        else
            setStatusMessage("No hint detected yet! Wait for a chat hint first.")
        end
    end
    imgui.PopStyleColor()
    if imgui.IsItemHovered() then
        if hasHint then
            imgui.SetTooltip("Manually focus on the last detected hint position")
        else
            imgui.SetTooltip("No hint detected yet")
        end
    end
    
    -- Moneybag Tracker toggle
    local mbColor = showMoneybags[0] and imgui.ImVec4(0.9, 0.7, 0.0, 1.0) or imgui.ImVec4(0.5, 0.5, 0.5, 0.6)
    imgui.PushStyleColor(imgui.Col.Button, mbColor)
    if imgui.Button(showMoneybags[0] and "Moneybags: ON ($)" or "Moneybags: OFF", imgui.ImVec2(150, 25)) then
        showMoneybags[0] = not showMoneybags[0]
    end
    imgui.PopStyleColor()
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Track active moneybag pickups (model 1550) within ~300m")
    end
    imgui.SameLine()
    local atpColor = autoMoneybagTP[0] and imgui.ImVec4(0.2, 0.8, 0.2, 1.0) or imgui.ImVec4(0.5, 0.5, 0.5, 0.6)
    imgui.PushStyleColor(imgui.Col.Button, atpColor)
    if imgui.Button(autoMoneybagTP[0] and "AutoTP: ON" or "AutoTP: OFF", imgui.ImVec2(100, 25)) then
        autoMoneybagTP[0] = not autoMoneybagTP[0]
    end
    imgui.PopStyleColor()
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Auto-teleport to nearest moneybag every few seconds")
    end
    imgui.SameLine()
    local soundColor = soundAlert[0] and imgui.ImVec4(0.2, 0.6, 0.8, 1.0) or imgui.ImVec4(0.5, 0.5, 0.5, 0.6)
    imgui.PushStyleColor(imgui.Col.Button, soundColor)
    if imgui.Button(soundAlert[0] and "Sound: ON" or "Sound: OFF", imgui.ImVec2(90, 25)) then
        soundAlert[0] = not soundAlert[0]
    end
    imgui.PopStyleColor()
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Beep on hint detection and moneybag spawn")
    end

    
    imgui.Separator()
    
    -- Sort Mode
    imgui.Text("Sort:")
    imgui.SameLine()
    local sortModes = {"None", "Name", "Date", "Distance"}
    local currentSort = sortModes[sortMode[0] + 1]
    if imgui.Button(currentSort .. "##SortBtn", imgui.ImVec2(120, 20)) then
        sortMode[0] = (sortMode[0] + 1) % 4
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Click to cycle through sort modes")
    end
    
    imgui.SameLine()
    
    -- Search Box
    imgui.Text("Search:")
    imgui.SameLine()
    imgui.PushItemWidth(200)
    imgui.InputText("##Search", searchFilter, 64)
    imgui.PopItemWidth()
    
    local sortedPositions = getSortedPositions()
    
    imgui.SameLine()
    imgui.Text(string.format("Showing: %d/%d", #sortedPositions, #savedPositions))
    
    
    -- Positions list
    imgui.BeginChild("PositionsList", imgui.ImVec2(0, 250), true)
    
    for _, entry in ipairs(sortedPositions) do
        local i = entry.index
        local pos = entry.pos
        local posName = pos.name or ("Position " .. i)
        
        local headerText = string.format("%d. %s", i, posName)
        
        -- Calculate distance
        local distance = getDistanceToPosition(pos)
        local distText = string.format(" (%.0fm)", distance)
        
        if imgui.CollapsingHeader(headerText .. distText) then
            imgui.Indent()
            
            imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Coordinates:")
            imgui.SameLine()
            imgui.Text(formatCoordinates(pos.x, pos.y, pos.z))
            
            imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Distance:")
            imgui.SameLine()
            imgui.TextColored(CONFIG.COLORS.TEXT_HIGHLIGHT, string.format("%.1f meters", distance))
            
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
            
            imgui.PushStyleColor(imgui.Col.Button, CONFIG.COLORS.IMPORT)
            if imgui.Button("Rename##" .. i, imgui.ImVec2(70, 25)) then
                renameIndex = i
                ffi.copy(renameBuffer, pos.name or "")
                showRenamePopup[0] = true
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
    
    if #sortedPositions == 0 and #savedPositions > 0 then
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "No positions match your search/filter.")
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

    else
        -- GOLDPOT DATABASE VIEW ---
        renderGoldpotDBView()
    end

    imgui.End()
    
    -- Rename popup
    if showRenamePopup[0] and renameIndex and savedPositions[renameIndex] then
        imgui.SetNextWindowPos(imgui.ImVec2(imgui.GetIO().DisplaySize.x / 2 - 150, imgui.GetIO().DisplaySize.y / 2 - 60))
        imgui.SetNextWindowSize(imgui.ImVec2(300, 120))
        if imgui.Begin("Rename Position", showRenamePopup, imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse) then
            local oldName = savedPositions[renameIndex].name or ""
            
            imgui.Text("New name:")
            imgui.PushItemWidth(260)
            imgui.InputText("##RenameInput", renameBuffer, CONFIG.MAX_NAME_LENGTH)
            imgui.PopItemWidth()
            
            imgui.Spacing()
            
            if imgui.Button("Save", imgui.ImVec2(130, 0)) then
                local newName = ffi.string(renameBuffer)
                if newName ~= "" then
                    savedPositions[renameIndex].name = newName
                    savedPositions[renameIndex].timestamp = os.time()
                    savePositionsToFile()
                    setStatusMessage("✓ Renamed: " .. oldName .. " → " .. newName)
                    showRenamePopup[0] = false
                end
            end
            
            imgui.SameLine()
            if imgui.Button("Cancel", imgui.ImVec2(130, 0)) then
                showRenamePopup[0] = false
            end
        end
        imgui.End()
    end
    
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
                if goldpotDBLoaded then
                    matchGoldpotDatabase()
                    saveGoldpotNEW()
                end
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
        
        imgui.Checkbox("Merge with existing (don't replace)", mergeOnImport)
        if imgui.IsItemHovered() then
            imgui.SetTooltip("If checked, will add new positions instead of replacing all")
        end
        
        imgui.Spacing()
        
        imgui.InputTextMultiline("##ImportText", importText, 10000, imgui.ImVec2(480, 220))
        
        imgui.Spacing()
        
        if imgui.Button("Import Data", imgui.ImVec2(150, 30)) then
            local text = ffi.string(importText)
            local success, msg = importFromText(text, mergeOnImport[0])
            setStatusMessage(msg)
            if success then
                showImportWindow[0] = false
                ffi.fill(importText, 10000)
                sampAddChatMessage("{00FF00}[BagSpot]{FFFFFF} " .. msg, 0xFFFFFFFF)
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

-- ─────────────────────────────────────────────────────────────────────────────
-- GOLDPOT DATABASE UI
-- ─────────────────────────────────────────────────────────────────────────────

function renderGoldpotDBView()
    -- Tab buttons
    local dbActive = not showAnalytics[0]
    local anActive = showAnalytics[0]
    
    imgui.PushStyleColor(imgui.Col.Button, dbActive and imgui.ImVec4(0.8, 0.5, 0.0, 1.0) or imgui.ImVec4(0.3, 0.3, 0.4, 0.6))
    if imgui.Button("Database##gptab", imgui.ImVec2(80, 22)) then showAnalytics[0] = false end
    imgui.PopStyleColor()
    imgui.SameLine()
    imgui.PushStyleColor(imgui.Col.Button, anActive and imgui.ImVec4(0.8, 0.5, 0.0, 1.0) or imgui.ImVec4(0.3, 0.3, 0.4, 0.6))
    if imgui.Button("Analytics##gptab", imgui.ImVec2(80, 22)) then showAnalytics[0] = true end
    imgui.PopStyleColor()
    
    imgui.Separator()
    
    if not showAnalytics[0] then
        -- DATABASE VIEW ---
        
    -- Group filter tabs
    imgui.Text("Filter Group:")
    imgui.SameLine()
    for idx, groupName in ipairs(GOLD_GROUPS) do
        if idx > 1 then imgui.SameLine() end
        local isActive = (idx - 1) == goldpotGroupFilter[0]
        if isActive then
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.5, 0.0, 1.0))
        end
        if imgui.Button(groupName .. "##GP" .. idx, imgui.ImVec2(55, 22)) then
            goldpotGroupFilter[0] = idx - 1
        end
        if isActive then
            imgui.PopStyleColor()
        end
    end
    
    -- Search filter
    imgui.SameLine()
    imgui.Text("Search:")
    imgui.SameLine()
    imgui.PushItemWidth(150)
    imgui.InputText("##GPSearch", goldpotSearchFilter, 64)
    imgui.PopItemWidth()
    
    local filtered = getFilteredGoldpotEntries()
    
    imgui.Text(string.format("Showing: %d/%d goldpots", #filtered, #goldpotDB))
    imgui.Separator()
    
    -- Database list
    imgui.BeginChild("GoldpotDBList", imgui.ImVec2(0, 260), true)
    
    for idx, entry in ipairs(filtered) do
        local icon = entry.saved and "✓" or "□"
        local statusColor = entry.saved and imgui.ImVec4(0.2, 0.8, 0.2, 1.0) or imgui.ImVec4(0.8, 0.3, 0.1, 1.0)
        local shortcutColor = entry.shortcut ~= "" and imgui.ImVec4(0.2, 0.7, 0.9, 1.0) or imgui.ImVec4(0.5, 0.5, 0.5, 0.5)
        local groupColor = imgui.ImVec4(0.5, 0.5, 0.5, 1.0)
        
        if entry.group == "LS" then groupColor = imgui.ImVec4(0.2, 0.8, 0.2, 1.0)
        elseif entry.group == "SF" then groupColor = imgui.ImVec4(0.2, 0.6, 0.9, 1.0)
        elseif entry.group == "LV" then groupColor = imgui.ImVec4(0.9, 0.7, 0.0, 1.0)
        elseif entry.group == "OTHER" then groupColor = imgui.ImVec4(0.8, 0.4, 0.8, 1.0)
        elseif entry.group == "NEW" then groupColor = imgui.ImVec4(0.0, 0.9, 0.9, 1.0)
        end
        
        -- Header text
        local headerText = string.format("%s %s", icon, entry.name)
        if not entry.saved and entry.shortcut ~= "" then
            headerText = headerText .. "  [" .. entry.shortcut .. "]"
        end
        
        if imgui.CollapsingHeader(headerText .. "##gpe" .. idx) then
            imgui.Indent()
            
            imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Group: ")
            imgui.SameLine()
            imgui.TextColored(groupColor, entry.group)
            
            imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Shortcut: ")
            imgui.SameLine()
            imgui.TextColored(shortcutColor, entry.shortcut ~= "" and entry.shortcut or "none")
            
            imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Status: ")
            imgui.SameLine()
            if entry.saved then
                imgui.TextColored(imgui.ImVec4(0.2, 0.8, 0.2, 1.0), "SAVED ✓")
            else
                imgui.TextColored(imgui.ImVec4(0.8, 0.3, 0.1, 1.0), "NOT SAVED YET ⚠")
            end
            
            if not entry.saved then
                imgui.Spacing()
                imgui.TextColored(imgui.ImVec4(0.8, 0.8, 0.2, 1.0), 
                    entry.shortcut ~= "" and string.format("Go to location via %s, then use /spos %s", entry.shortcut, entry.name) or "")
            end
            
            -- Action button: teleport if saved, hint if not
            imgui.Spacing()
            if entry.saved and entry.savedIndex then
                imgui.PushStyleColor(imgui.Col.Button, CONFIG.COLORS.TELEPORT)
                if imgui.Button("Teleport##gpt" .. idx, imgui.ImVec2(100, 25)) then
                    if savedPositions[entry.savedIndex] then
                        teleportToPosition(savedPositions[entry.savedIndex])
                    end
                end
                imgui.PopStyleColor()
            elseif entry.shortcut ~= "" then
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.5, 0.0, 1.0))
                if imgui.Button("Copy Shortcut##gpc" .. idx, imgui.ImVec2(120, 25)) then
                    sampAddChatMessage(string.format("{FFA500}[GoldpotDB]{FFFFFF} Use %s to reach: {FFFF00}%s", entry.shortcut, entry.name), 0xFFFFFFFF)
                    setStatusMessage(string.format("Shortcut: %s for %s", entry.shortcut, entry.name))
                end
                imgui.PopStyleColor()
            end
            
            imgui.Unindent()
        end
    end
    
    if #goldpotDB == 0 then
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "Goldpot database not loaded.")
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "Check that config/allpositions.txt exists.")
    elseif #filtered == 0 then
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "No entries match your filter/search.")
    end
    
    imgui.EndChild()
    
    -- Legend
    imgui.Separator()
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "□ = Unsaved  |  ✓ = Saved in your positions")
    imgui.SameLine()
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), string.format(" | Total: %d goldpots", #goldpotDB))
    
    else
        -- ANALYTICS VIEW ---
        renderAnalyticsView()
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HINT ANALYTICS UI
-- ─────────────────────────────────────────────────────────────────────────────

function renderAnalyticsView()
    local totalHints, uniqueCount, lastHint, lastHintTime, topHot = getAnalyticsStats()
    
    -- Stats header
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.2, 0.8, 0.9, 1.0))
    imgui.Text("HINT ANALYTICS")
    imgui.PopStyleColor()
    
    local hasData = totalHints > 0
    if hasData then
        local now = os.time()
        local lastHintAgo = math.floor((now - lastHintTime) / 60)
        local agoText = lastHintAgo < 1 and "just now" or lastHintAgo < 60 and tostring(lastHintAgo) .. "m ago" or tostring(math.floor(lastHintAgo / 60)) .. "h ago"
        
        imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Total hints detected: ")
        imgui.SameLine()
        imgui.TextColored(CONFIG.COLORS.TEXT_HIGHLIGHT, tostring(totalHints))
        imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), " | Unique: ")
        imgui.SameLine()
        imgui.TextColored(CONFIG.COLORS.TEXT_HIGHLIGHT, string.format("%d/%d", uniqueCount, #goldpotDB))
        
        imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Last hint: ")
        imgui.SameLine()
        if lastHint then
            local hintName = lastHint.name or "Unknown"
            imgui.TextColored(CONFIG.COLORS.TEXT_HIGHLIGHT, hintName .. " (" .. agoText .. ")")
        end
        
        if #topHot > 0 then
            local hotNames = {}
            for _, h in ipairs(topHot) do
                table.insert(hotNames, h.name .. " (" .. h.count .. "x)")
            end
            imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Hot: ")
            imgui.SameLine()
            imgui.TextColored(CONFIG.COLORS.TEXT_HIGHLIGHT, table.concat(hotNames, ", "))
        end
    else
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "No hint data collected yet.")
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "Hint analytics will populate as goldpot hints appear in chat.")
    end
    
    imgui.Separator()
    
    -- Reset Analytics button
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.7, 0.2, 0.2, 1.0))
    if imgui.Button("Reset Analytics", imgui.ImVec2(120, 22)) then
        hintAnalytics = {}
        saveHintAnalytics()
        setStatusMessage("✓ Hint analytics reset")
    end
    imgui.PopStyleColor()
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Clear all hint analytics data")
    end
    
    imgui.SameLine()
    
    -- Sort buttons
    imgui.Text("Sort:")
    imgui.SameLine()
    local sorts = {"Most Frequent", "Least Frequent", "Never Seen"}
    local currentSort = sorts[analyticsSortMode[0] + 1]
    if imgui.Button(currentSort .. "##ansort", imgui.ImVec2(120, 22)) then
        analyticsSortMode[0] = (analyticsSortMode[0] + 1) % 3
    end
    
    local sortedData = getSortedAnalytics(analyticsSortMode[0])
    
    imgui.Text(string.format("Showing: %d goldpot entries (%d unseen)", #sortedData, #sortedData - uniqueCount))
    imgui.Separator()
    
    -- List
    imgui.BeginChild("AnalyticsList", imgui.ImVec2(0, 260), true)
    
    for idx, data in ipairs(sortedData) do
        local name = data.name or "Unknown"
        local shortcutText = data.shortcut ~= "" and " [" .. data.shortcut .. "]" or ""
        local headerText = name .. shortcutText
        
        if imgui.CollapsingHeader(headerText .. "##an" .. idx) then
            imgui.Indent()
            
            local countColor = data.count >= 10 and imgui.ImVec4(0.9, 0.2, 0.2, 1.0) or data.count >= 3 and imgui.ImVec4(0.9, 0.7, 0.0, 1.0) or data.count >= 1 and imgui.ImVec4(0.2, 0.8, 0.2, 1.0) or imgui.ImVec4(0.5, 0.5, 0.5, 1.0)
            
            imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Count: ")
            imgui.SameLine()
            imgui.TextColored(countColor, data.count == 0 and "0x never" or tostring(data.count) .. "x")
            
            if data.count > 0 then
                imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "First seen: ")
                imgui.SameLine()
                imgui.Text(os.date("%Y-%m-%d %H:%M", data.firstSeen))
                
                local now = os.time()
                local secsAgo = now - data.lastSeen
                local agoStr = secsAgo < 60 and tostring(secsAgo) .. "s ago" or secsAgo < 3600 and tostring(math.floor(secsAgo/60)) .. "m ago" or secsAgo < 86400 and tostring(math.floor(secsAgo/3600)) .. "h ago" or tostring(math.floor(secsAgo/86400)) .. "d ago"
                imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Last seen: ")
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.2, 0.7, 0.9, 1.0), os.date("%Y-%m-%d %H:%M", data.lastSeen) .. " (" .. agoStr .. ")")
            end
            
            if data.group and data.group ~= "" then
                local grpColor = data.group == "LS" and imgui.ImVec4(0.2, 0.8, 0.2, 1.0) or data.group == "SF" and imgui.ImVec4(0.2, 0.6, 0.9, 1.0) or data.group == "LV" and imgui.ImVec4(0.9, 0.7, 0.0, 1.0) or data.group == "OTHER" and imgui.ImVec4(0.8, 0.4, 0.8, 1.0) or data.group == "NEW" and imgui.ImVec4(0.0, 0.9, 0.9, 1.0) or imgui.ImVec4(0.5, 0.5, 0.5, 1.0)
                imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "Group: ")
                imgui.SameLine()
                imgui.TextColored(grpColor, data.group)
            end
            
            imgui.Unindent()
        end
    end
    
    if #goldpotDB == 0 then
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "Goldpot database not loaded.")
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "Check that config/allpositions.txt exists.")
    end
    
    imgui.EndChild()
    
    -- Legend
    imgui.Separator()
    imgui.TextColored(imgui.ImVec4(0.2, 0.8, 0.2, 1.0), "[1-2x]")
    imgui.SameLine()
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), " | ")
    imgui.SameLine()
    imgui.TextColored(imgui.ImVec4(0.9, 0.7, 0.0, 1.0), "[3-9x]")
    imgui.SameLine()
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), " | ")
    imgui.SameLine()
    imgui.TextColored(imgui.ImVec4(0.9, 0.2, 0.2, 1.0), "[10x+]")
    imgui.SameLine()
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), " | ")
    imgui.SameLine()
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "[Never seen]")
    imgui.SameLine()
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), string.format(" | Total: %d hints", totalHints))
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
    
    -- Create fonts for ESP rendering
    font = renderCreateFont("Arial", 10, 5)
    espFont = renderCreateFont("Arial", 12, 5)
    -- Load GPS arrow texture
    xpcall(function() gpsArrowTex = renderLoadTexture(getWorkingDirectory() .. "\\config\\gps-arrow.png") end, function() end)
    
    -- Load saved positions from file
    if loadPositionsFromFile() then
        sampAddChatMessage("{00BFFF}[BagSpot]{FFFFFF} loaded - " .. #savedPositions .. " positions loaded", 0xFFFFFFFF)
    else
        sampAddChatMessage("{FF0000}[BagSpot]{FFFFFF} Failed to load save file", 0xFFFFFFFF)
        savedPositions = {}
    end
    
    -- Load routes
    if loadRoutesFromFile() then
        if #savedRoutes > 0 then
            sampAddChatMessage("{00BFFF}[BagSpot]{FFFFFF} " .. #savedRoutes .. " routes loaded", 0xFFFFFFFF)
        end
    end
    
    -- Load goldpot database and match with saved positions
    if loadGoldpotDatabase() then
        -- Load persisted NEW entries from previous sessions
        loadGoldpotNEW()
        matchGoldpotDatabase()
        -- Save any newly-matched shortcuts/groups to file
        savePositionsToFile()
        if #goldpotDB > 0 then
            sampAddChatMessage("{00BFFF}[GoldpotDB]{FFFFFF} " .. #goldpotDB .. " goldpot entries loaded", 0xFFFFFFFF)
        end
    end
    
    -- Load hint analytics
    loadHintAnalytics()
    
    -- Chat commands
    sampRegisterChatCommand("spos", function(params)
        local x, y, z, angle, interior, inVehicle = getPlayerPosition()
        local name = params ~= "" and params or ("Saved #" .. (#savedPositions + 1))
        
        -- Check if name already exists
        local exists, existingIndex = isPositionNameExists(name)
        if exists then
            sampAddChatMessage("{FF0000}[BagSpot]{FFFFFF} Position '" .. name .. "' already exists at #" .. existingIndex, 0xFFFFFFFF)
            sampAddChatMessage("{AAAAAA}Use a different name or delete the existing one first", 0xFFFFFFFF)
            return
        end
        
        local goldMatch = findGoldpotEntry(name)
        local newPos = {
            name = name,
            x = x,
            y = y,
            z = z,
            angle = angle,
            interior = interior,
            inVehicle = inVehicle,
            timestamp = os.time(),
            shortcut = goldMatch and goldMatch.shortcut or "",
            group = goldMatch and goldMatch.group or ""
        }
        
        table.insert(savedPositions, newPos)
        savePositionsToFile()
        if goldpotDBLoaded then
            matchGoldpotDatabase()
            saveGoldpotNEW()
        end
        
        sampAddChatMessage("{00FF00}[BagSpot]{FFFFFF} Saved: " .. name .. " (Total: " .. #savedPositions .. ")", 0xFFFFFFFF)
    end)
    
    sampRegisterChatCommand("lpos", function(params)
        -- Try numeric index first
        local index = tonumber(params)
        if index and savedPositions[index] then
            teleportToPosition(savedPositions[index])
            sampAddChatMessage("{00FF00}[BagSpot]{FFFFFF} Teleporting to: " .. savedPositions[index].name, 0xFFFFFFFF)
            return
        end
        
        -- Try fuzzy name matching
        if params ~= "" then
            local pos, idx, score = findPositionByName(params)
            if pos then
                teleportToPosition(pos)
                local matchQuality = score >= 0.9 and "Exact" or score >= 0.7 and "Good" or "Partial"
                sampAddChatMessage(string.format("{00FF00}[BagSpot]{FFFFFF} Teleporting to: %s [%s match #%d]", 
                    pos.name, matchQuality, idx), 0xFFFFFFFF)
            else
                sampAddChatMessage("{FF0000}[BagSpot]{FFFFFF} No position found matching '" .. params .. "'", 0xFFFFFFFF)
                sampAddChatMessage("{AAAAAA}Use /poslist to see all positions", 0xFFFFFFFF)
            end
        else
            sampAddChatMessage("{FF0000}[BagSpot]{FFFFFF} Usage: /lpos [name] or /lpos [index]", 0xFFFFFFFF)
            sampAddChatMessage("{AAAAAA}Example: /lpos cable | /lpos 5", 0xFFFFFFFF)
        end
    end)
    
    sampRegisterChatCommand("poslist", function()
        sampAddChatMessage("{00BFFF}[BagSpot]{FFFFFF} === Saved Positions (" .. #savedPositions .. ") ===", 0xFFFFFFFF)
        if #savedPositions == 0 then
            sampAddChatMessage("{AAAAAA}No positions saved. Use /spos to save one.", 0xFFFFFFFF)
        else
            for i, pos in ipairs(savedPositions) do
                sampAddChatMessage(string.format("{FFFF00}%d.{FFFFFF} %s - %.1f, %.1f, %.1f", 
                    i, pos.name, pos.x, pos.y, pos.z), 0xFFFFFFFF)
            end
        end
    end)
    
    sampRegisterChatCommand("autotp", function()
        autoTeleportEnabled[0] = not autoTeleportEnabled[0]
        local status = autoTeleportEnabled[0] and "ENABLED" or "DISABLED"
        local color = autoTeleportEnabled[0] and "{00FF00}" or "{FF0000}"
        sampAddChatMessage(color .. "[AutoTP]{FFFFFF} Auto-Teleport " .. status, 0xFFFFFFFF)
        sampAddChatMessage("{00BFFF}[Info]{FFFFFF} Detects: GoldPOT, Hunt, Events in chat", 0xFFFFFFFF)
    end)
    
    sampRegisterChatCommand("clearfocus", function()
        if espFocusPosition then
            espFocusPosition = nil
            espFocusTime = 0
            sampAddChatMessage("{00FF00}[Focus]{FFFFFF} ESP focus cleared", 0xFFFFFFFF)
        else
            sampAddChatMessage("{FFFF00}[Focus]{FFFFFF} No active ESP focus", 0xFFFFFFFF)
        end
    end)
    
    sampRegisterChatCommand("uc", function()
        doUpdateCoords()
    end)
    
    sampAddChatMessage("{FFFF00}F10 menu | F9 ESP | /uc /spos /lpos /poslist /autotp /clearfocus", 0xFFFFFFFF)
    sampAddChatMessage("{00BFFF}[Info]{FFFFFF} F10 > Moneybags: ON to track $ pickups (model 1550)", 0xFFFFFFFF)
    if autoTeleportEnabled[0] then
        sampAddChatMessage("{00FF00}[AutoTP]{FFFFFF} Auto-Teleport is ENABLED", 0xFFFFFFFF)
    end
    
    -- Main loop
    local keyPressed = false
    local espKeyPressed = false
    while true do
        wait(0)
        
        -- Update distance cache periodically for performance
        updateDistanceCache()
        
        -- Render ESP markers
        renderPositionESP()
        
        -- Render moneybag pickups (model 1550)
        renderMoneybagESP()


        -- Proximity beep (every 2s when within 30m)
        if showMoneybags[0] and soundAlert[0] then
            local mbPx, mbPy, mbPz = getCharCoordinates(PLAYER_PED)
            local nearBag = false
            for id, pos in pairs(moneyBags) do
                if calculateDistance(mbPx, mbPy, mbPz, pos.x, pos.y, pos.z) < 30 then
                    nearBag = true
                    break
                end
            end
            if nearBag then
                if os.clock() - (lastProxBeep or 0) > 2 then
                    playBeep(1000, 80)
                    lastProxBeep = os.clock()
                end
            end
        end
        
        -- Moneybag auto-teleport with countdown + cooldown
        if autoMoneybagTP[0] and not moneybagTPPending then
            local now = os.clock()
            if now >= moneybagTPCooldown then
                local mbPx, mbPy, mbPz = getCharCoordinates(PLAYER_PED)
                local nearestDist, nearestPos
                for id, pos in pairs(moneyBags) do
                    local d = calculateDistance(mbPx, mbPy, mbPz, pos.x, pos.y, pos.z)
                    if not nearestDist or d < nearestDist then
                        nearestDist = d
                        nearestPos = pos
                    end
                end
                if nearestPos and nearestDist and nearestDist <= CONFIG.MONEYBAG_TP_DISTANCE then
                    moneybagPendingX = nearestPos.x
                    moneybagPendingY = nearestPos.y
                    moneybagPendingZ = nearestPos.z
                    moneybagTPPending = true
                    moneybagTPTime = os.clock()
                    sampAddChatMessage(string.format("{FFD700}[MB]{FFFFFF} TP to moneybag in %ds...", moneybagTPDelay), -1)
                end
            end
        end
        if moneybagTPPending then
            local remaining = moneybagTPDelay - (os.clock() - moneybagTPTime)
            if remaining > 0 then
                printStringNow(string.format("~y~MB TP in ~w~%d~y~s~w~!", math.ceil(remaining)), 500)
            else
                playBeep(800, 100)
                setCharCoordinates(PLAYER_PED, moneybagPendingX, moneybagPendingY, moneybagPendingZ)
                restoreCameraJumpcut()
                moneybagTPPending = false
                moneybagTPCooldown = os.clock() + 5
                sampAddChatMessage("{FFD700}[MB]{FFFFFF} Teleported to moneybag!", -1)
            end
        end
        
        -- Check for pending auto-teleport
        if autoTeleportPending and autoTeleportEnabled[0] then
            local currentTime = os.clock()
            local elapsed = currentTime - keywordDetectedTime
            local remaining = math.ceil(currentTeleportDelay - elapsed)
            
            -- Show countdown on screen
            if remaining > 0 then
                printStringNow(string.format("~g~AUTO-TELEPORT ACTIVE~n~~y~Target: ~w~%s~n~~b~Teleporting in: ~w~%ds", 
                    targetPositionName, remaining), 1000)
            end
            
            if elapsed >= currentTeleportDelay then
                autoTeleportPending = false
                performAutoTeleport(pendingSearchTerms)
            end
        end
        
        -- Update cooldown counter
        local currentTime = os.clock()
        local timeSinceLast = currentTime - lastTeleportTime
        if timeSinceLast < CONFIG.TELEPORT_COOLDOWN then
            teleportCooldown[0] = math.ceil(CONFIG.TELEPORT_COOLDOWN - timeSinceLast)
        else
            teleportCooldown[0] = 0
        end
        
        -- Toggle ESP with F9
        local isEspKeyPressed = isKeyDown(vkeys.VK_F9)
        if isEspKeyPressed and not espKeyPressed and not sampIsChatInputActive() and not sampIsDialogActive() then
            showESP[0] = not showESP[0]
            local status = showESP[0] and "ENABLED" or "DISABLED"
            sampAddChatMessage("{00FF00}[ESP]{FFFFFF} Hunt Mode " .. status, 0xFFFFFFFF)
            espKeyPressed = true
        elseif not isEspKeyPressed then
            espKeyPressed = false
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
-- MONEYBAG PICKUP TRACKING (model 1550)
-- ─────────────────────────────────────────────────────────────────────────────

function sampev.onCreatePickup(id, model, pickupType, position)
    if model == 1550 then
        moneyBags[id] = {x = position.x, y = position.y, z = position.z}
        playBeep(440, 100)
    end
end

function sampev.onDestroyPickup(id)
    moneyBags[id] = nil
end

function sampev.onSendPickedUpPickup(pickupId)
    if moneyBags[pickupId] and espFocusPosition then
        local px, py, pz = moneyBags[pickupId].x, moneyBags[pickupId].y, moneyBags[pickupId].z
        local dist = calculateDistance(px, py, pz, espFocusPosition.x, espFocusPosition.y, espFocusPosition.z)
        if dist < 10 then
            espFocusPosition = nil
        end
    end
    moneyBags[pickupId] = nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- MONEYBAG ESP RENDERING
-- ─────────────────────────────────────────────────────────────────────────────

function renderMoneybagESP()
    if not showMoneybags[0] then return end
    if not next(moneyBags) then prevBagDist = {}; return end

    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local scrW, scrH = getScreenResolution()
    local bagCount = 0
    local nearestDist = 999999.0
    local nearestBagId = nil
    local nearestBagAngle = 0
    local now = os.clock()
    local playerHeading = getCharHeading(PLAYER_PED)

    -- Clean up stale distance entries
    for id in pairs(prevBagDist) do
        if not moneyBags[id] then prevBagDist[id] = nil end
    end

    for id, pos in pairs(moneyBags) do
        repeat
        local dist = calculateDistance(px, py, pz, pos.x, pos.y, pos.z)
        if dist < nearestDist then
            nearestDist = dist
            nearestBagId = id
            nearestBagAngle = getDirectionArrowDeg(px, py, playerHeading, pos.x, pos.y)
        end
        bagCount = bagCount + 1

        local a, b, c = convert3DCoordsToScreen(pos.x, pos.y, pos.z)
        local sx, sy
        if type(a) == "boolean" then
            if not a then break end
            sx, sy = b, c
        else
            sx, sy = a, b
        end
        if not (sx and sy) then break end

        -- Proximity pulse
        local pulse = 0
        local pulseSpeed = 0
        if dist < 30 then
            pulseSpeed = 8
            pulse = 0.3 + 0.7 * math.abs(math.sin(now * pulseSpeed))
        elseif dist < 60 then
            pulseSpeed = 5
            pulse = 0.5 + 0.5 * math.abs(math.sin(now * pulseSpeed))
        end

        -- Smooth color: green < 80 → yellow < 300 → red > 800
        local r, g, b
        if dist < 80 then
            r, g, b = 0, 255, 0
        elseif dist < 300 then
            local t = (dist - 80) / 220
            r, g, b = math.floor(255 * t), 255, math.floor(255 * (1 - t))
        elseif dist < 800 then
            local t = (dist - 300) / 500
            r, g, b = 255, math.floor(255 * (1 - t)), 0
        else
            r, g, b = 255, 50, 50
        end
        local baseAlpha = dist > 1000 and 0xAA or 0xFF
        local alpha = pulse > 0 and math.floor(baseAlpha * (0.5 + 0.5 * pulse)) or baseAlpha
        local color = (alpha * 0x1000000) + (r * 0x10000) + (g * 0x100) + b
        local glowColor = ((math.floor(alpha * 0.3) % 256) * 0x1000000) + (r * 0x10000) + (g * 0x100) + b
        local textColor = (0xFF * 0x1000000) + (r * 0x10000) + (g * 0x100) + b

        -- Pulsing size and line width
        local markerSize = pulse > 0 and 4 + math.floor(6 * pulse) or 4
        local lineWidth = pulse > 0 and 1.5 + 3.0 * pulse or 1.5

        if sx > 0 and sx < scrW and sy > 0 and sy < scrH then
            -- Glow line
            renderDrawLine(scrW / 2, scrH, sx, sy, lineWidth + 2.5, glowColor)
            renderDrawLine(scrW / 2, scrH, sx, sy, lineWidth, color)
            -- Marker
            renderDrawPolygon(sx - markerSize, sy - markerSize, markerSize * 2, markerSize * 2, 4, 0, color)
            local label = dist < 30 and string.format("$ %.0fm!", dist) or string.format("$ %.0fm", dist)
            if espFont then
                renderFontDrawText(espFont, label, sx + 7, sy - 9, 0x80000000)
                renderFontDrawText(espFont, label, sx + 6, sy - 10, textColor)
            end
            -- Direction arrow at bag (white = direction only)
            local arrowDeg = getDirectionArrowDeg(px, py, playerHeading, pos.x, pos.y)
            local arrSize = pulse > 0 and 10 or 7
            renderRotatedArrow(sx, sy - 18, arrowDeg, arrSize, 0xCCFFFFFF, 0x44FFFFFF)
            -- Track distance for GPS ring delta (no text rendered per-bag)
            prevBagDist[id] = dist
        else
            local ex = math.max(15, math.min(scrW - 15, sx))
            local ey = math.max(55, math.min(scrH - 55, sy))
            renderDrawLine(scrW / 2, scrH, ex, ey, 1.5 + pulse, 0x44FFFF00)
            renderDrawLine(scrW / 2, scrH, ex, ey, 0.5 + pulse, 0x88FFFF00)
            if espFont then
                renderFontDrawText(espFont, string.format("$ %.0fm", dist), ex + 9, ey - 7, 0x80000000)
                renderFontDrawText(espFont, string.format("$ %.0fm", dist), ex + 8, ey - 8, 0xAAFFFF00)
            end
            -- Off-screen direction chevron
            local offAngle = math.deg(math.atan2(sy - scrH/2, sx - scrW/2))
            renderRotatedArrow(ex, ey - 16, offAngle, 6, 0xAAFFFF00)
        end
        until true
    end

    -- Top-right HUD
    if espFont then
        local hudX, hudY = scrW - 15, 25
        if bagCount > 0 then
            renderFontDrawText(espFont, string.format("$ BAGS: %d", bagCount), hudX - 95, hudY - 1, 0x80000000)
            renderFontDrawText(espFont, string.format("$ BAGS: %d", bagCount), hudX - 96, hudY - 2, 0xFFFFFF00)
            local nearText = string.format("Nearest: %dm", math.floor(nearestDist))
            if nearestDist < 30 then
                renderFontDrawText(espFont, nearText .. " !", hudX - 125, hudY + 13, 0x80000000)
                renderFontDrawText(espFont, nearText .. " !", hudX - 126, hudY + 12, 0xFFFF4444)
            else
                renderFontDrawText(espFont, nearText, hudX - 110, hudY + 13, 0x80000000)
                renderFontDrawText(espFont, nearText, hudX - 111, hudY + 12, 0xFFFFFFFF)
            end
        end
    end

    -- Bottom-center GPS guide ring for nearest moneybag (skip if focus active)
    if not espFocusPosition and nearestBagId and moneyBags[nearestBagId] then
        local gpsCx = scrW / 2
        local gpsCy = scrH - 60
        local gpsDelta = prevBagDist[nearestBagId] and (prevBagDist[nearestBagId] - nearestDist) or nil
        renderGPSRing(gpsCx, gpsCy, 28, nearestBagAngle, "$ BAG", nearestDist, gpsDelta, 0xFFFFFF00)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- MONEYBAG MINI-RADAR
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- CHAT EVENT HANDLER FOR AUTO-TELEPORT
-- ─────────────────────────────────────────────────────────────────────────────

function sampev.onServerMessage(color, text)
    -- Detect keywords in the message
    local keyword, searchTerms, hintLocation = detectKeywordInMessage(text)
    
    if keyword and searchTerms and hintLocation then
        -- Track analytics: build search hint text
        local hintText = ""
        for _, word in ipairs(searchTerms) do
            hintText = hintText .. " " .. word
        end
        hintText = trim(hintText)
        
        -- Find target position
        local targetPos, matchRatio = findBestMatchPosition(searchTerms)
        
        if not targetPos then
            -- Check goldpot database for unsaved entries
            local goldMatch = nil
            if goldpotDBLoaded then
                for _, entry in ipairs(goldpotDB) do
                    local entryNorm = normalizeNameDB(entry.name)
                    if entryNorm:find(hintText:lower(), 1, true) or hintText:lower():find(entryNorm, 1, true) then
                        goldMatch = entry
                        break
                    end
                end
            end
            
            if goldMatch then
                trackHint(goldMatch.name, goldMatch.shortcut, goldMatch.group)
                lastHintedName = goldMatch.name
                lastHintedSavedIndex = goldMatch.saved and goldMatch.savedIndex or nil
                lastHintedGoldpot = goldMatch.saved and nil or goldMatch
                if goldMatch.saved then
                    sampAddChatMessage("{FF6600}[BagSpot]{FFFFFF} Detected keyword but no position data loaded", 0xFFFFFFFF)
                    printStringNow("~y~" .. goldMatch.name .. "~n~~w~Detected but no data loaded", 3000)
                else
                    local shortcutLine = goldMatch.shortcut ~= "" and "~g~" .. goldMatch.shortcut .. "~w~ to go there" or ""
                    printStringNow("~y~" .. goldMatch.name .. "~n~~w~NOT SAVED!~n~" .. shortcutLine, 4000)
                    sampAddChatMessage("{FFA500}[GoldpotDB]{FFFFFF} Detected: {FFFF00}" .. goldMatch.name, 0xFFFFFFFF)
                    sampAddChatMessage("{FFA500}⚠ Not saved yet! {FFFFFF}Use " .. (goldMatch.shortcut ~= "" and goldMatch.shortcut .. " to get there, then " or "") .. "/spos " .. goldMatch.name, 0xFFFFFFFF)
                    playBeep(660, 150)
                    playBeep(880, 200)
                end
            else
                trackHint(hintLocation, "", "")
                -- Add as NEW goldpot DB entry if not already in DB
                local newEntry = nil
                local hintNorm = normalizeNameDB(hintLocation)
                if hintNorm ~= "" then
                    for _, entry in ipairs(goldpotDB) do
                        if normalizeNameDB(entry.name) == hintNorm then
                            newEntry = entry
                            break
                        end
                    end
                    if not newEntry then
                        newEntry = {
                            name = hintLocation,
                            shortcut = "",
                            group = "NEW",
                            saved = false,
                            savedIndex = nil
                        }
                        table.insert(goldpotDB, newEntry)
                        saveGoldpotNEW()
                    end
                end
                lastHintedName = hintLocation
                lastHintedSavedIndex = nil
                lastHintedGoldpot = newEntry
                sampAddChatMessage("{FF6600}[BagSpot]{FFFFFF} Unknown hint added to DB as NEW: {FFFF00}" .. hintLocation, 0xFFFFFFFF)
                printStringNow("~y~" .. hintLocation .. "~n~~c~NEW~w~: Check Goldpot DB", 3000)
            end
            saveHintAnalytics()
            return
        end
        
        -- 60% confidence threshold
        if matchRatio < 0.6 then
            sampAddChatMessage(string.format("{FFFF00}[Focus]{FFFFFF} Low confidence (%.0f%%) — adding to NEW tab", matchRatio * 100), 0xFFFFFFFF)
            
            -- Also add to NEW goldpot DB since weak match = likely different location
            local hintNorm = normalizeNameDB(hintLocation)
            if hintNorm ~= "" then
                local foundInDB = false
                for _, entry in ipairs(goldpotDB) do
                    if normalizeNameDB(entry.name) == hintNorm then
                        foundInDB = true
                        lastHintedGoldpot = entry
                        lastHintedName = entry.name
                        entry.saved = false
                        entry.savedIndex = nil
                        break
                    end
                end
                if not foundInDB then
                    local newEntry = {
                        name = hintLocation,
                        shortcut = "",
                        group = "NEW",
                        saved = false,
                        savedIndex = nil
                    }
                    table.insert(goldpotDB, newEntry)
                    saveGoldpotNEW()
                    lastHintedGoldpot = newEntry
                    lastHintedName = hintLocation
                end
            end
            trackHint(lastHintedName, "", "")
            saveHintAnalytics()
            lastHintedSavedIndex = nil
            printStringNow("~y~" .. hintLocation .. "~n~~c~NEW~w~: Added to Goldpot DB", 3000)
            sampAddChatMessage("{FF6600}[BagSpot]{FFFFFF} Added to NEW tab: {FFFF00}" .. hintLocation, 0xFFFFFFFF)
            return
        end
        
        -- Track analytics for matched position
        trackHint(targetPos.name, targetPos.shortcut or "", targetPos.group or "")
        saveHintAnalytics()
        
        -- Track last hinted for Update Coords
        lastHintedName = targetPos.name
        lastHintedGoldpot = nil
        for idx, pos in ipairs(savedPositions) do
            if pos == targetPos then
                lastHintedSavedIndex = idx
                break
            end
        end
        
        -- Show detected position
        playBeep(660, 150)
        playBeep(880, 200)
        
        sampAddChatMessage("{FFA500}[Detected]{FFFFFF} Position: {FFFF00}" .. targetPos.name, 0xFFFFFFFF)
        local px2, py2, pz2 = getCharCoordinates(PLAYER_PED)
        if px2 then
            sampAddChatMessage("{AAAAAA}Distance: {FFFF00}" .. string.format("%.0fm", 
                calculateDistance(px2, py2, pz2, targetPos.x, targetPos.y, targetPos.z)), 0xFFFFFFFF)
        end
        
        -- Auto-focus (only if enabled in menu)
        if autoFocusEnabled[0] then
            espFocusPosition = {
                x = targetPos.x,
                y = targetPos.y,
                z = targetPos.z,
                name = targetPos.name
            }
            espFocusTime = os.clock()
        end
        
        -- Auto-teleport (only if enabled)
        if autoTeleportEnabled[0] then
            currentTeleportDelay = math.random(CONFIG.AUTO_TELEPORT_DELAY_MIN, CONFIG.AUTO_TELEPORT_DELAY_MAX)
            
            lastDetectedKeyword = keyword
            keywordDetectedTime = os.clock()
            autoTeleportPending = true
            pendingSearchTerms = searchTerms
            targetPositionName = targetPos.name
            
            sampAddChatMessage("{00FF00}[AutoTP]{FFFFFF} Detected: {FFFF00}" .. keyword, 0xFFFFFFFF)
            sampAddChatMessage("{00BFFF}[AutoTP]{FFFFFF} Teleporting in " .. currentTeleportDelay .. " seconds...", 0xFFFFFFFF)
            printStringNow("~g~EVENT DETECTED!~n~~y~" .. keyword .. "~n~~w~Preparing to teleport...", 3000)
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