#!/usr/bin/env lua
-- cook_ai_call: execute-phase entry point for cook_ai.prompt units.
-- Reads system/user prompts from files, calls the configured provider, writes
-- the response to --output. Bundled by the cook_ai rockspec as a bin script.

local cli      = require("cook_ai.cli")
local anth     = require("cook_ai.client.anthropic")

local function read_file(p)
    local f, err = io.open(p, "r")
    if not f then error("[cook_ai_call] open " .. p .. ": " .. err, 2) end
    local s = f:read("*a"); f:close(); return s
end

local function write_file(p, s)
    -- ensure parent dir exists
    local dir = p:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then os.execute("mkdir -p " .. ("'%s'"):format(dir:gsub("'", "'\\''"))) end
    local f, err = io.open(p, "w")
    if not f then error("[cook_ai_call] open " .. p .. ": " .. err, 2) end
    f:write(s); f:close()
end

local function main(argv)
    local args = cli.parse_args(argv)
    if args.provider ~= "anthropic" then
        error("[cook_ai_call] v0.1 supports provider=anthropic only", 2)
    end
    local api_key = os.getenv("ANTHROPIC_API_KEY")
    if not api_key or api_key == "" then
        error("[cook_ai_call] ANTHROPIC_API_KEY env var not set", 2)
    end
    local system = read_file(args.system_file)
    local user   = read_file(args.user_file)
    local base_url = os.getenv("ANTHROPIC_BASE_URL")
    local endpoint
    if base_url and base_url ~= "" then
        endpoint = base_url .. "/v1/messages"
    end
    local text = anth.call({
        api_key         = api_key,
        timeout_s       = tonumber(os.getenv("COOK_AI_TIMEOUT_S")) or 120,
        max_retries     = tonumber(os.getenv("COOK_AI_MAX_RETRIES")) or 3,
        model           = args.model,
        system          = system,
        user            = user,
        max_tokens      = args.max_tokens,
        temperature     = args.temperature,
        response_format = args.response_format,
        tools           = args.tools,
        payload_path    = args.payload_tmp,
        endpoint        = endpoint,
    })
    write_file(args.output, text)
end

main(arg)
