--[[
    Simple JSON Library for SavePosition Script
    Lightweight JSON encoder/decoder for Lua
]]

local json = {}

-- Encode Lua table to JSON string
function json.encode(value, indent)
    local t = type(value)
    
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "number" then
        if value ~= value then
            return "null"  -- NaN
        elseif value == math.huge or value == -math.huge then
            return "null"  -- Infinity
        else
            return tostring(value)
        end
    elseif t == "string" then
        return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif t == "table" then
        -- Check if array
        local isArray = true
        local maxIndex = 0
        for k, v in pairs(value) do
            if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
                isArray = false
                break
            end
            maxIndex = math.max(maxIndex, k)
        end
        
        if isArray and maxIndex == #value then
            -- Array
            local items = {}
            for i, v in ipairs(value) do
                table.insert(items, json.encode(v, indent))
            end
            return "[" .. table.concat(items, ",") .. "]"
        else
            -- Object
            local items = {}
            for k, v in pairs(value) do
                local key = type(k) == "string" and k or tostring(k)
                table.insert(items, '"' .. key .. '":' .. json.encode(v, indent))
            end
            return "{" .. table.concat(items, ",") .. "}"
        end
    else
        return "null"
    end
end

-- Decode JSON string to Lua table
function json.decode(str)
    if not str or str == "" then
        return nil
    end
    
    local pos = 1
    
    local function skipWhitespace()
        while pos <= #str and str:sub(pos, pos):match("[ \t\n\r]") do
            pos = pos + 1
        end
    end
    
    local function parseValue()
        skipWhitespace()
        local c = str:sub(pos, pos)
        
        if c == '"' then
            return parseString()
        elseif c == '{' then
            return parseObject()
        elseif c == '[' then
            return parseArray()
        elseif c == 't' then
            if str:sub(pos, pos + 3) == "true" then
                pos = pos + 4
                return true
            end
        elseif c == 'f' then
            if str:sub(pos, pos + 4) == "false" then
                pos = pos + 5
                return false
            end
        elseif c == 'n' then
            if str:sub(pos, pos + 3) == "null" then
                pos = pos + 4
                return nil
            end
        elseif c == '-' or c:match("%d") then
            return parseNumber()
        end
        
        error("Invalid JSON at position " .. pos)
    end
    
    function parseString()
        pos = pos + 1  -- Skip opening quote
        local result = ""
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return result
            elseif c == '\\' then
                pos = pos + 1
                local escaped = str:sub(pos, pos)
                if escaped == 'n' then result = result .. '\n'
                elseif escaped == 'r' then result = result .. '\r'
                elseif escaped == 't' then result = result .. '\t'
                elseif escaped == '"' then result = result .. '"'
                elseif escaped == '\\' then result = result .. '\\'
                else result = result .. escaped
                end
            else
                result = result .. c
            end
            pos = pos + 1
        end
        error("Unterminated string")
    end
    
    function parseNumber()
        local startPos = pos
        if str:sub(pos, pos) == '-' then
            pos = pos + 1
        end
        while pos <= #str and str:sub(pos, pos):match("[%d%.eE%+%-]") do
            pos = pos + 1
        end
        return tonumber(str:sub(startPos, pos - 1))
    end
    
    function parseArray()
        pos = pos + 1  -- Skip [
        local result = {}
        skipWhitespace()
        
        if str:sub(pos, pos) == ']' then
            pos = pos + 1
            return result
        end
        
        while true do
            table.insert(result, parseValue())
            skipWhitespace()
            local c = str:sub(pos, pos)
            if c == ']' then
                pos = pos + 1
                return result
            elseif c == ',' then
                pos = pos + 1
            else
                error("Expected ',' or ']' at position " .. pos)
            end
        end
    end
    
    function parseObject()
        pos = pos + 1  -- Skip {
        local result = {}
        skipWhitespace()
        
        if str:sub(pos, pos) == '}' then
            pos = pos + 1
            return result
        end
        
        while true do
            skipWhitespace()
            if str:sub(pos, pos) ~= '"' then
                error("Expected string key at position " .. pos)
            end
            local key = parseString()
            skipWhitespace()
            if str:sub(pos, pos) ~= ':' then
                error("Expected ':' at position " .. pos)
            end
            pos = pos + 1
            result[key] = parseValue()
            skipWhitespace()
            local c = str:sub(pos, pos)
            if c == '}' then
                pos = pos + 1
                return result
            elseif c == ',' then
                pos = pos + 1
            else
                error("Expected ',' or '}' at position " .. pos)
            end
        end
    end
    
    local success, result = pcall(parseValue)
    if success then
        return result
    else
        return nil
    end
end

return json
