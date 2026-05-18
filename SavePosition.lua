--[[
    ┌─────────────────────────────────────────────────────────────────────────┐
    │                 SAVE POSITION TOOL v3.0 (ENHANCED)                     │
    │              MoonLoader Script for SA-MP                               │
    │                                                                        │
    │  Features:                                                             │
    │  • Instant teleport with cooldown                                      │
    │  • PERMANENT SAVE with export/import/merge                             │
    │  • Categories, Tags, Favorites                                         │
    │  • Distance calculator & sorting                                       │
    │  • ESP markers for all saved positions (HUNT MODE)                     │
    │  • Route system (sequential teleports)                                 │
    │  • Auto-backup & duplicate detection                                   │
    │                                                                        │
    │  Hotkey: F10 - Menu | F9 - Toggle ESP                                 │
    │  Commands: /spos, /lpos, /poslist, /route                              │
    └─────────────────────────────────────────────────────────────────────────┘
]]

script_name("SavePosition")
script_author("BOJO Dev")
script_version("3.0")

-- Required libraries
require 'lib.moonloader'
local vkeys = require 'vkeys'
local imgui = require 'mimgui'
local ffi = require 'ffi'
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
    WINDOW_TITLE = "Save Position Manager v3.0",
    MAX_NAME_LENGTH = 64,
    TELEPORT_COOLDOWN = 2,
    AUTO_BACKUP_INTERVAL = 20, -- Backup every 20 saves
    MAX_ESP_DISTANCE = 20000.0, -- Maximum distance to show ESP markers (entire map)
    
    -- Auto-Teleport Settings
    -- System will automatically extract location from "Hint: (location)" in chat
    -- No hardcoded locations - purely dynamic based on saved positions
    AUTO_TELEPORT_KEYWORDS = {
        "GoldPOT",
        "Hunt begins",
        "Race:",
        -- Add more event keywords here
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
        FAVORITE = imgui.ImVec4(1.0, 0.84, 0.0, 1.0),
        ROUTE = imgui.ImVec4(0.5, 0.0, 0.8, 1.0)
    },
    
    CATEGORIES = {
        "All", "Events", "Spots", "Safe Zones", "Resources", "Custom"
    },
    
    ESP_COLORS = {
        DEFAULT = 0xFFFFFFFF,
        FAVORITE = 0xFFFFD700,
        CATEGORY = {
            Events = 0xFFFF0000,
            Spots = 0xFF00FF00,
            ["Safe Zones"] = 0xFF0000FF,
            Resources = 0xFFFFFF00,
            Custom = 0xFFFF00FF
        }
    }
}

-- ─────────────────────────────────────────────────────────────────────────────
-- STATE VARIABLES
-- ─────────────────────────────────────────────────────────────────────────────

-- Font for ESP rendering (must be global)
local font = nil

local mainWindow = imgui.new.bool(false)
local savedPositions = {}
local savedRoutes = {}
local newPositionName = imgui.new.char[CONFIG.MAX_NAME_LENGTH]("")
local searchFilter = imgui.new.char[64]("")
local showConfirmDelete = imgui.new.bool(false)
local deleteIndex = nil
local statusMessage = ""
local statusMessageTime = 0
local lastTeleportTime = 0
local teleportCooldown = imgui.new.int(0)
local saveCounter = 0

-- New UI state variables
local selectedCategory = imgui.new.int(0) -- 0 = All
local sortMode = imgui.new.int(0) -- 0=None, 1=Name, 2=Date, 3=Distance
local showESP = imgui.new.bool(false)
local espDistance = imgui.new.float(10000.0) -- Default 10km (entire map)
local showDistance = imgui.new.bool(true)
local showFavoritesOnly = imgui.new.bool(false)

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

-- Import/Export variables
local importText = imgui.new.char[10000]("")
local showImportWindow = imgui.new.bool(false)
local mergeOnImport = imgui.new.bool(false)

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
    local candidates = {} -- Store all matches with scores
    
    -- Score each position based on how many search terms match
    for i, pos in ipairs(savedPositions) do
        local posName = pos.name:lower()
        local score = 0
        local matchedWords = 0
        local totalSearchWords = #searchTerms
        
        -- Check if all terms combined form an exact phrase match (HIGHEST priority)
        local fullPhrase = table.concat(searchTerms, " ")
        if posName:find(fullPhrase, 1, true) then
            score = score + 1000 -- Extremely high score for exact phrase match
            matchedWords = totalSearchWords
        else
            -- Score individual term matches with better logic
            for _, term in ipairs(searchTerms) do
                term = term:lower()
                
                -- Check for exact word boundary match (higher score)
                if posName:match("%f[%w]" .. term .. "%f[%W]") then
                    score = score + 50 -- Exact word match
                    matchedWords = matchedWords + 1
                elseif posName:find(term, 1, true) then
                    score = score + 20 -- Partial/substring match
                    matchedWords = matchedWords + 0.5
                end
            end
            
            -- Bonus: if most words match, give extra points
            local matchRatio = matchedWords / totalSearchWords
            if matchRatio >= 0.8 then
                score = score + 100 -- 80%+ words match
            elseif matchRatio >= 0.6 then
                score = score + 50 -- 60%+ words match
            end
            
            -- Penalty for positions with too many extra words (less specific)
            local posWordCount = 0
            for _ in posName:gmatch("%S+") do
                posWordCount = posWordCount + 1
            end
            if posWordCount > totalSearchWords * 2 then
                score = score - 20 -- Too many extra words = less likely correct
            end
        end
        
        -- Store candidate if it has any score
        if score > 0 then
            table.insert(candidates, {pos = pos, score = score, matchedWords = matchedWords})
        end
        
        -- Track best match
        if score > highestScore then
            highestScore = score
            bestMatch = pos
        end
    end
    
    -- Debug: show top 3 candidates
    if #candidates > 0 then
        -- Sort by score
        table.sort(candidates, function(a, b) return a.score > b.score end)
        
        sampAddChatMessage("{808080}[Debug] Search: \"" .. table.concat(searchTerms, " ") .. "\"", 0xFFFFFFFF)
        
        for i = 1, math.min(3, #candidates) do
            local c = candidates[i]
            sampAddChatMessage(string.format("{808080}[Debug] #%d: %s (score: %d, matched: %.1f/%d words)", 
                i, c.pos.name, c.score, c.matchedWords, #searchTerms), 0xFFFFFFFF)
        end
    end
    
    -- Only return if score is decent (at least 20 = one term match)
    if highestScore >= 20 then
        return bestMatch
    end
    
    return nil
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
        return nil, nil
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
            if #word > 2 then -- Skip very short words like "to", "at"
                table.insert(searchTerms, word:lower())
            end
        end
        
        if #searchTerms > 0 then
            return detectedKeyword .. " - Hint: " .. hintLocation, searchTerms
        end
    end
    
    -- No hint found = don't auto-teleport
    return nil, nil
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
    local result, handle = sampGetPlayerIdByCharHandle(playerPed)
    if result then
        setCharCoordinates(playerPed, targetPos.x, targetPos.y, targetPos.z)
        if targetPos.angle then
            setCharHeading(playerPed, targetPos.angle)
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
                if pos.favorite == nil then pos.favorite = false end
                if not pos.category then pos.category = "Custom" end
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

-- ─────────────────────────────────────────────────────────────────────────────
-- NEW ENHANCED FEATURES
-- ─────────────────────────────────────────────────────────────────────────────

-- Calculate distance between two 3D points
local function calculateDistance(x1, y1, z1, x2, y2, z2)
    local dx = x2 - x1
    local dy = y2 - y1
    local dz = z2 - z1
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Get cached distance or calculate new one
local function getDistanceToPosition(pos)
    local x, y, z = getCharCoordinates(PLAYER_PED)
    local posKey = string.format("%s_%.0f_%.0f", pos.name, pos.x, pos.y)
    
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

-- Toggle favorite status
local function toggleFavorite(index)
    if savedPositions[index] then
        savedPositions[index].favorite = not savedPositions[index].favorite
        savePositionsToFile()
        return savedPositions[index].favorite
    end
    return false
end

-- Set position category
local function setPositionCategory(index, category)
    if savedPositions[index] then
        savedPositions[index].category = category
        savePositionsToFile()
        return true
    end
    return false
end

-- Sort positions function
local function getSortedPositions()
    local filtered = {}
    local filterText = ffi.string(searchFilter):lower()
    local catIndex = selectedCategory[0]
    local selectedCat = CONFIG.CATEGORIES[catIndex + 1]
    
    -- Apply filters
    for i, pos in ipairs(savedPositions) do
        local nameMatch = filterText == "" or (pos.name and pos.name:lower():find(filterText, 1, true))
        local catMatch = selectedCat == "All" or pos.category == selectedCat
        local favMatch = not showFavoritesOnly[0] or pos.favorite
        
        if nameMatch and catMatch and favMatch then
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
    
    local content = file:read("*all")
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
    if not showESP[0] then return end
    
    local playerX, playerY, playerZ = getCharCoordinates(PLAYER_PED)
    local maxDist = espDistance[0]
    local foundCount = 0
    
    for i, pos in ipairs(savedPositions) do
        local distance = calculateDistance(playerX, playerY, playerZ, pos.x, pos.y, pos.z)
        
        if distance <= maxDist then
            local result, screenX, screenY = convert3DCoordsToScreen(pos.x, pos.y, pos.z)
            
            if result and screenX and screenY then
                local scrW, scrH = getScreenResolution()
                
                -- Check if on screen
                if screenX > 0 and screenX < scrW and screenY > 0 and screenY < scrH then
                    foundCount = foundCount + 1
                    
                    -- Determine color based on category/favorite
                    local colorARGB = 0xFFFFFFFF -- White
                    if pos.favorite then
                        colorARGB = 0xFFFFD700 -- Gold
                    elseif pos.category == "Events" then
                        colorARGB = 0xFFFF0000 -- Red
                    elseif pos.category == "Spots" then
                        colorARGB = 0xFF00FF00 -- Green
                    elseif pos.category == "Safe Zones" then
                        colorARGB = 0xFF0000FF -- Blue
                    end
                    
                    -- Build text to display
                    local displayName = pos.name or ("Pos " .. i)
                    local distText = string.format("[%.0fm]", distance)
                    local fullText = displayName .. "\n" .. distText
                    
                    -- Use renderDrawPolygon to draw a marker box
                    renderDrawPolygon(screenX - 3, screenY - 3, 6, 6, 4, 0, colorARGB)
                    
                    -- Try using regular renderDrawText
                    if font then
                        renderFontDrawText(font, displayName, screenX + 5, screenY - 10, colorARGB)
                        renderFontDrawText(font, distText, screenX + 5, screenY + 5, 0xFFFFFFFF)
                    end
                end
            end
        end
    end
    
    -- Debug: show ESP status on screen
    if foundCount > 0 then
        printStringNow(string.format("~g~ESP: ~w~%d positions visible", foundCount), 100)
    else
        printStringNow("~y~ESP ON ~w~- No positions in range", 100)
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
        
        -- Check for duplicate positions by coordinates
        local isDupe, dupeIndex, dupePos = isDuplicatePosition(x, y, z, 10.0)
        if isDupe then
            sampAddChatMessage(string.format("{FF6600}[SavePos]{FFFFFF} Warning: Position very close to '%s' (%.1fm away)", 
                dupePos.name, calculateDistance(x, y, z, dupePos.x, dupePos.y, dupePos.z)), 0xFFFFFFFF)
        end
        
        -- Check if name already exists
        local exists, existingIndex = isPositionNameExists(name)
        if exists then
            setStatusMessage("✗ Position '" .. name .. "' already exists at #" .. existingIndex)
        else
            local newPos = {
                name = name,
                x = x,
                y = y,
                z = z,
                angle = angle,
                interior = interior,
                inVehicle = inVehicle,
                timestamp = os.time(),
                favorite = false,
                category = "Custom"
            }
            
            table.insert(savedPositions, newPos)
            saveCounter = saveCounter + 1
            
            if savePositionsToFile() then
                setStatusMessage("✓ Saved: " .. name .. " (Total: " .. #savedPositions .. ")")
                
                -- Auto-backup every X saves
                if saveCounter % CONFIG.AUTO_BACKUP_INTERVAL == 0 then
                    if createBackup() then
                        sampAddChatMessage("{00FF00}[SavePos]{FFFFFF} Auto-backup created", 0xFFFFFFFF)
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
    
    imgui.Separator()
    
    -- Category Filter
    imgui.Text("Category:")
    imgui.SameLine()
    local currentCat = CONFIG.CATEGORIES[selectedCategory[0] + 1]
    if imgui.Button(currentCat .. "##CatBtn", imgui.ImVec2(120, 20)) then
        selectedCategory[0] = (selectedCategory[0] + 1) % #CONFIG.CATEGORIES
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Click to cycle through categories")
    end
    
    imgui.SameLine()
    
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
    
    -- Favorites Filter
    if imgui.Checkbox("★ Favorites Only", showFavoritesOnly) then
        -- Filter changed
    end
    
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
        
        -- Add favorite star to header
        local favIcon = pos.favorite and "★ " or ""
        local catIcon = pos.category and ("[" .. pos.category .. "] ") or ""
        local headerText = string.format("%s%s%d. %s", favIcon, catIcon, i, posName)
        
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
            
            -- Category selector
            imgui.Text("Category:")
            imgui.SameLine()
            local currentCat = pos.category or "Custom"
            if imgui.Button(currentCat .. "##CatSel" .. i, imgui.ImVec2(120, 20)) then
                -- Cycle through categories (skip "All")
                local catIndex = 1 -- Start from "Events"
                for idx = 2, #CONFIG.CATEGORIES do
                    if CONFIG.CATEGORIES[idx] == currentCat then
                        catIndex = idx
                        break
                    end
                end
                -- Go to next category
                catIndex = catIndex + 1
                if catIndex > #CONFIG.CATEGORIES then
                    catIndex = 2 -- Skip "All", go to "Events"
                end
                setPositionCategory(i, CONFIG.CATEGORIES[catIndex])
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip("Click to cycle category")
            end
            
            imgui.Spacing()
            
            -- Action buttons
            imgui.PushStyleColor(imgui.Col.Button, CONFIG.COLORS.TELEPORT)
            if imgui.Button("Teleport##" .. i, imgui.ImVec2(100, 25)) then
                teleportToPosition(pos)
            end
            imgui.PopStyleColor()
            
            imgui.SameLine()
            
            -- Favorite button
            local favColor = pos.favorite and CONFIG.COLORS.FAVORITE or imgui.ImVec4(0.5, 0.5, 0.5, 0.6)
            imgui.PushStyleColor(imgui.Col.Button, favColor)
            if imgui.Button((pos.favorite and "★ Fav" or "☆ Fav") .. "##" .. i, imgui.ImVec2(70, 25)) then
                toggleFavorite(i)
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
    
    -- Create font for ESP rendering
    font = renderCreateFont("Arial", 9, 5)
    
    -- Load saved positions from file
    if loadPositionsFromFile() then
        sampAddChatMessage("{00BFFF}[SavePos]{FFFFFF} v3.0 ENHANCED loaded - " .. #savedPositions .. " positions loaded", 0xFFFFFFFF)
    else
        sampAddChatMessage("{FF0000}[SavePos]{FFFFFF} Failed to load save file", 0xFFFFFFFF)
        savedPositions = {}
    end
    
    -- Load routes
    if loadRoutesFromFile() then
        if #savedRoutes > 0 then
            sampAddChatMessage("{00BFFF}[SavePos]{FFFFFF} " .. #savedRoutes .. " routes loaded", 0xFFFFFFFF)
        end
    end
    
    -- Chat commands
    sampRegisterChatCommand("spos", function(params)
        local x, y, z, angle, interior, inVehicle = getPlayerPosition()
        local name = params ~= "" and params or ("Saved #" .. (#savedPositions + 1))
        
        -- Check if name already exists
        local exists, existingIndex = isPositionNameExists(name)
        if exists then
            sampAddChatMessage("{FF0000}[SavePos]{FFFFFF} Position '" .. name .. "' already exists at #" .. existingIndex, 0xFFFFFFFF)
            sampAddChatMessage("{AAAAAA}Use a different name or delete the existing one first", 0xFFFFFFFF)
            return
        end
        
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
        -- Try numeric index first
        local index = tonumber(params)
        if index and savedPositions[index] then
            teleportToPosition(savedPositions[index])
            sampAddChatMessage("{00FF00}[SavePos]{FFFFFF} Teleporting to: " .. savedPositions[index].name, 0xFFFFFFFF)
            return
        end
        
        -- Try fuzzy name matching
        if params ~= "" then
            local pos, idx, score = findPositionByName(params)
            if pos then
                teleportToPosition(pos)
                local matchQuality = score >= 0.9 and "Exact" or score >= 0.7 and "Good" or "Partial"
                sampAddChatMessage(string.format("{00FF00}[SavePos]{FFFFFF} Teleporting to: %s [%s match #%d]", 
                    pos.name, matchQuality, idx), 0xFFFFFFFF)
            else
                sampAddChatMessage("{FF0000}[SavePos]{FFFFFF} No position found matching '" .. params .. "'", 0xFFFFFFFF)
                sampAddChatMessage("{AAAAAA}Use /poslist to see all positions", 0xFFFFFFFF)
            end
        else
            sampAddChatMessage("{FF0000}[SavePos]{FFFFFF} Usage: /lpos [name] or /lpos [index]", 0xFFFFFFFF)
            sampAddChatMessage("{AAAAAA}Example: /lpos cable | /lpos 5", 0xFFFFFFFF)
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
    
    sampRegisterChatCommand("autotp", function()
        autoTeleportEnabled[0] = not autoTeleportEnabled[0]
        local status = autoTeleportEnabled[0] and "ENABLED" or "DISABLED"
        local color = autoTeleportEnabled[0] and "{00FF00}" or "{FF0000}"
        sampAddChatMessage(color .. "[AutoTP]{FFFFFF} Auto-Teleport " .. status, 0xFFFFFFFF)
        sampAddChatMessage("{00BFFF}[Info]{FFFFFF} Detects: GoldPOT, Hunt, Events in chat", 0xFFFFFFFF)
    end)
    
    sampAddChatMessage("{FFFF00}Press F10 for menu | F9 for ESP | Commands: /spos /lpos /poslist /autotp", 0xFFFFFFFF)
    sampAddChatMessage("{00BFFF}[Info]{FFFFFF} NEW: ESP Hunt Mode, Categories, Sorting, Favorites, Routes!", 0xFFFFFFFF)
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
-- CHAT EVENT HANDLER FOR AUTO-TELEPORT
-- ─────────────────────────────────────────────────────────────────────────────

function sampev.onServerMessage(color, text)
    if not autoTeleportEnabled[0] then
        return -- Auto-teleport is disabled
    end
    
    -- Detect keywords in the message
    local keyword, searchTerms = detectKeywordInMessage(text)
    
    if keyword and searchTerms then
        -- Find target position immediately to show in countdown
        local targetPos = findBestMatchPosition(searchTerms)
        
        if not targetPos then
            sampAddChatMessage("{FF6600}[AutoTP]{FFFFFF} Detected keyword but no matching position found", 0xFFFFFFFF)
            return
        end
        
        -- Generate random delay between 5-10 seconds
        currentTeleportDelay = math.random(CONFIG.AUTO_TELEPORT_DELAY_MIN, CONFIG.AUTO_TELEPORT_DELAY_MAX)
        
        lastDetectedKeyword = keyword
        keywordDetectedTime = os.clock()
        autoTeleportPending = true
        pendingSearchTerms = searchTerms
        targetPositionName = targetPos.name
        
        sampAddChatMessage("{00FF00}[AutoTP]{FFFFFF} Detected: {FFFF00}" .. keyword, 0xFFFFFFFF)
        sampAddChatMessage("{00BFFF}[AutoTP]{FFFFFF} Target: {FFFF00}" .. targetPos.name, 0xFFFFFFFF)
        sampAddChatMessage("{00BFFF}[AutoTP]{FFFFFF} Teleporting in " .. currentTeleportDelay .. " seconds...", 0xFFFFFFFF)
        
        printStringNow("~g~EVENT DETECTED!~n~~y~" .. keyword .. "~n~~w~Preparing to teleport...", 3000)
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