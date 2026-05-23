local state = require("cook_ai.state")
local anth  = require("cook_ai.client.anthropic")

local M = {}

function M.call(opts)
    -- 0.2.0-2: cook_ai.provider({...}) is optional. If never called, cfg is
    -- nil and the full resolution comes from cook.env. We only error if the
    -- merged result is incomplete.
    local cfg = state.get_provider()
    assert(type(opts) == "table", "[cook_ai] prompt(opts) requires a table")
    assert(type(opts.system) == "string" and opts.system ~= "",
        "[cook_ai] prompt.system (string) is required")
    assert(type(opts.user) == "string" and opts.user ~= "",
        "[cook_ai] prompt.user (string) is required")

    -- Read provider/model/base-url/api_key with this precedence:
    --   opts.<field>  (only for opts.model — explicit per-call override)
    --     > cook.env  (so config-block writes win; participates in auto-cache)
    --     > cfg       (captured at register time via cook_ai.provider)
    -- Falls back to module state if cook.env isn't reachable (e.g. running
    -- outside a cook execute-phase context, like in busted specs).
    local function env_or(name, fallback)
        if cook and cook.env and cook.env[name] ~= nil and cook.env[name] ~= "" then
            return cook.env[name]
        end
        return fallback
    end

    local model    = opts.model or env_or("COOK_AI_MODEL",    cfg and cfg.model    or nil)
    local provider =                env_or("COOK_AI_PROVIDER", cfg and cfg.provider or nil)
    local base_url =                env_or("COOK_AI_BASE_URL", cfg and cfg.base_url or nil)
    local api_key  =                env_or("ANTHROPIC_API_KEY", cfg and cfg.api_key or nil)

    -- Default provider if still nil. (Only anthropic is supported in 0.2; the
    -- check below rejects anything else.)
    if not provider or provider == "" then provider = "anthropic" end

    if provider ~= "anthropic" then
        error("[cook_ai] only anthropic provider is supported in v0.2 (got " .. tostring(provider) .. ")", 2)
    end
    if not model or model == "" then
        error("[cook_ai] model not configured — set env.COOK_AI_MODEL in a config block or pass model= to cook_ai.provider({...})", 2)
    end
    if not api_key or api_key == "" then
        error("[cook_ai] api_key not configured — set env.ANTHROPIC_API_KEY in a config block / shell env or pass api_key= to cook_ai.provider({...})", 2)
    end

    local payload_path = os.tmpname()
    local endpoint
    if base_url and base_url ~= "" then
        endpoint = base_url .. "/v1/messages"
    end

    return anth.call({
        api_key         = api_key,
        timeout_s       = cfg and cfg.timeout_s or 120,
        max_retries     = cfg and cfg.max_retries or 3,
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
