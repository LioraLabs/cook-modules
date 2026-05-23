local cjson = require("cjson.safe")
local M = {}

local REQUIRED = { "provider", "model", "system_file", "user_file", "output", "payload_tmp" }

local function flag_to_key(flag)
    return (flag:gsub("^%-%-", ""):gsub("%-", "_"))
end

function M.parse_args(argv)
    local out = {}
    local i = 1
    while i <= #argv do
        local flag = argv[i]
        local val  = argv[i + 1]
        if not flag:match("^%-%-") then
            error("[cook_ai_call] unexpected positional: " .. flag, 2)
        end
        local key = flag_to_key(flag)
        if key == "max_tokens" or key == "temperature" then
            out[key] = tonumber(val) or error("[cook_ai_call] --" .. key .. " needs a number")
        elseif key == "response_format_json" then
            local rf, err = cjson.decode(val)
            if not rf then error("[cook_ai_call] bad --response-format-json: " .. err, 2) end
            out.response_format = rf
        elseif key == "tools_json" then
            local t, err = cjson.decode(val)
            if not t then error("[cook_ai_call] bad --tools-json: " .. err, 2) end
            out.tools = t
        else
            out[key] = val
        end
        i = i + 2
    end
    for _, name in ipairs(REQUIRED) do
        if out[name] == nil then
            error("[cook_ai_call] missing required --" .. name:gsub("_","-"), 2)
        end
    end
    return out
end

return M
