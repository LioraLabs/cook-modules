local cjson = require("cjson.safe")

local M = {}

local DEFAULT_ENDPOINT = "https://api.anthropic.com/v1/messages"
local API_VERSION = "2023-06-01"

function M._build_payload(opts)
    local body = {
        model      = opts.model,
        system     = opts.system,
        max_tokens = opts.max_tokens or 4096,
        messages   = {
            { role = "user", content = opts.user },
        },
    }
    if opts.temperature ~= nil then body.temperature = opts.temperature end
    if opts.response_format then body.response_format = opts.response_format end
    if opts.tools then body.tools = opts.tools end
    return body
end

local function sh_quote(s)
    return "'" .. s:gsub("'", [['"'"']]) .. "'"
end

function M._curl_cmd(opts)
    local endpoint = opts.endpoint or DEFAULT_ENDPOINT
    return table.concat({
        "curl",
        "--silent",
        "--show-error",
        "--fail-with-body",
        "--max-time", tostring(opts.timeout_s or 120),
        "-H", sh_quote("content-type: application/json"),
        "-H", sh_quote("anthropic-version: " .. API_VERSION),
        "-H", sh_quote("x-api-key: " .. opts.api_key),
        "--data-binary", "@" .. opts.payload_path,
        sh_quote(endpoint),
    }, " ")
end

function M._extract_text(resp)
    if resp.stop_reason and resp.stop_reason ~= "end_turn" and resp.stop_reason ~= "stop_sequence" then
        error(string.format("[cook_ai] anthropic stop_reason=%s — partial/refused response", resp.stop_reason), 2)
    end
    for _, block in ipairs(resp.content or {}) do
        if block.type == "text" then
            return block.text
        end
    end
    error("[cook_ai] anthropic response had no text block", 2)
end

local function write_tmp(path, contents)
    local f, err = io.open(path, "w")
    if not f then error("[cook_ai] open " .. path .. ": " .. err, 2) end
    f:write(contents); f:close()
end

local function read_all(path)
    local f, err = io.open(path, "r")
    if not f then error("[cook_ai] open " .. path .. ": " .. err, 2) end
    local s = f:read("*a"); f:close(); return s
end

function M.call(opts)
    -- opts: api_key, timeout_s, max_retries, model, system, user, max_tokens,
    --       temperature, response_format, tools, payload_path (tmp file path to use),
    --       endpoint (optional override; defaults to https://api.anthropic.com/v1/messages)
    local body = M._build_payload(opts)
    local encoded, jerr = cjson.encode(body)
    if not encoded then error("[cook_ai] json encode: " .. jerr, 2) end
    write_tmp(opts.payload_path, encoded)

    local cmd = M._curl_cmd(opts)
    local response_path = opts.payload_path .. ".response"
    local full = cmd .. " > " .. sh_quote(response_path)

    local attempts = (opts.max_retries or 3) + 1
    local last_err
    for i = 1, attempts do
        local ok = os.execute(full)
        if ok then
            local raw = read_all(response_path)
            local resp, derr = cjson.decode(raw)
            if not resp then error("[cook_ai] json decode: " .. derr .. "\n" .. raw, 2) end
            if resp.type == "error" then
                last_err = resp.error and resp.error.message or "unknown"
                if i == attempts then error("[cook_ai] anthropic error: " .. last_err, 2) end
            else
                return M._extract_text(resp)
            end
        else
            last_err = "curl exited non-zero (attempt " .. i .. "/" .. attempts .. ")"
        end
    end
    error("[cook_ai] anthropic call failed after retries: " .. (last_err or "?"), 2)
end

return M
