script_name("Auto Math Detector")
script_author("Assistant")
script_version("2.1")

require "lib.moonloader"
local sampev = require 'lib.samp.events'

local DEBUG = false
local ANSWER_CMD = "/ans" -- change to "/ans" if your server uses that

local function stripColorCodes(s)
    -- SA-MP inline color codes like {FFFFFF}
    return (s:gsub("{%x%x%x%x%x%x}", ""))
end

local function normalizeEquation(e)
    -- Normalize common unicode operators and formatting
    e = e:gsub("%s+", "")
    e = e:gsub("[xX×]", "*")
    e = e:gsub("[÷]", "/")
    e = e:gsub("[−–—]", "-")
    e = e:gsub("[＋]", "+")
    e = e:gsub("[／]", "/")
    e = e:gsub("[＊]", "*")
    e = e:gsub("[．]", ".")
    return e
end

local function extractEquationFromMessage(text)
    local msg = stripColorCodes(text)
    local lower = msg:lower()
    local solvePos = lower:find("solve", 1, true)
    if not solvePos then return nil end

    local after = msg:sub(solvePos + #"solve")
    after = after:gsub("^[%s:]+", "")

    -- Capture a contiguous math-looking prefix after "Solve"
    -- Include unicode operator variants so we can normalize them later.
    local candidate = after:match("^([0-9%+%-%*/xX%.%(%)%s×÷−–—＋／＊．]+)")
    if not candidate then return nil end

    candidate = normalizeEquation(candidate)

    -- Safety: only allow characters we expect in arithmetic expressions
    if candidate:find("[^0-9%+%-%*/%.%(%)]+") then
        return nil
    end

    -- Must include at least one digit and one operator
    if not (candidate:find("%d") and candidate:find("[%+%-%*/]")) then
        return nil
    end

    return candidate
end

function main()
    while not isSampAvailable() do wait(100) end
    printStringNow("~g~Math Detector Loaded~n~~w~Will show answers in chat", 3000)
    
    while true do
        wait(0)
        -- Just keep the script running, no key detection needed anymore
    end
end

function sampev.onServerMessage(color, text)
    if DEBUG then
        sampAddChatMessage("{808080}[DEBUG] {FFFFFF}" .. text, 0xFFFFFF)
    end

    -- Only react to server math prompts
    if not (text:find("Math:", 1, true) and text:lower():find("solve", 1, true)) then
        return
    end

    local equation = extractEquationFromMessage(text)
    if not equation then
        if DEBUG then
            sampAddChatMessage("{FF6600}[Info] Could not extract equation from: {FFFFFF}" .. stripColorCodes(text), 0xFFFFFF)
        end
        return
    end

    if DEBUG then
        sampAddChatMessage("{FFFF00}[Found] Equation: {FFFFFF}" .. equation, 0xFFFFFF)
    end

    local func, loadErr = load("return " .. equation)
    if not func then
        if DEBUG then
            sampAddChatMessage("{FF0000}[Error] load() failed: {FFFFFF}" .. tostring(loadErr), 0xFFFFFF)
        end
        return
    end

    local ok, result = pcall(func)
    if not ok then
        if DEBUG then
            sampAddChatMessage("{FF0000}[Error] calc failed: {FFFFFF}" .. tostring(result), 0xFFFFFF)
        end
        return
    end

    local answer = math.floor(tonumber(result) + 0.5)
    
    -- Copy the full command to clipboard for easy pasting
    local clipboardText = ANSWER_CMD .. " " .. answer
    setClipboardText(clipboardText)

    sampAddChatMessage("{00FF00}===========================================", 0xFFFFFF)
    sampAddChatMessage("{FFFF00}Math test = {FFFFFF}" .. equation, 0xFFFFFF)
    sampAddChatMessage("{00FF00}Math Answer : {FFFFFF}" .. answer, 0xFFFFFF)
    sampAddChatMessage("{FF6600}Auto-copied to clipboard: {FFFFFF}" .. clipboardText, 0xFFFFFF)
    sampAddChatMessage("{00FF00}Just press CTRL+V then ENTER!", 0xFFFFFF)
    sampAddChatMessage("{00FF00}===========================================", 0xFFFFFF)

    printStringNow("~y~MATH DETECTED!~n~~g~" .. equation .. " = " .. answer .. "~n~~w~COPIED TO CLIPBOARD!~n~~g~CTRL+V then ENTER", 8000)
end