local state = require("cook_ai.state")
local anth  = require("cook_ai.client.anthropic")

local M = {}

function M.call(opts)
    local cfg = state.get_provider()
    if not cfg then
        error("[cook_ai] cook_ai.prompt called before cook_ai.provider — configure provider first", 2)
    end
    assert(type(opts) == "table", "[cook_ai] prompt(opts) requires a table")
    assert(type(opts.system) == "string" and opts.system ~= "",
        "[cook_ai] prompt.system (string) is required")
    assert(type(opts.user) == "string" and opts.user ~= "",
        "[cook_ai] prompt.user (string) is required")

    -- Read model/provider/base-url from cook.env so this read participates
    -- in cook's env-var auto-cache. Falls back to module state if cook.env
    -- isn't reachable (e.g. running outside a cook execute-phase context).
    local function env_or(name, fallback)
        if cook and cook.env and cook.env[name] ~= nil then
            return cook.env[name]
        end
        return fallback
    end
    local model    = opts.model    or env_or("COOK_AI_MODEL",    cfg.model)
    local provider = env_or("COOK_AI_PROVIDER", cfg.provider)
    local base_url = env_or("COOK_AI_BASE_URL", cfg.base_url)

    if provider ~= "anthropic" then
        error("[cook_ai] only anthropic provider is supported in v0.2 (got " .. tostring(provider) .. ")", 2)
    end

    local api_key = cfg.api_key
    if not api_key or api_key == "" then
        error("[cook_ai] api_key not configured — call cook_ai.provider({api_key=...}) first", 2)
    end

    local payload_path = os.tmpname()
    local endpoint
    if base_url and base_url ~= "" then
        endpoint = base_url .. "/v1/messages"
    end

    return anth.call({
        api_key         = api_key,
        timeout_s       = cfg.timeout_s,
        max_retries     = cfg.max_retries,
        model           = model,
        system          = opts.system,
        user            = opts.user,
        max_tokens      = opts.max_tokens,
        temperature     = opts.temperature,
        response_format = opts.response_format,
        tools           = opts.tools,
        endpoint        = endpoint,
        payload_path    = payload_path,
    })
end

return M
