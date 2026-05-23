local state = require("cook_ai.state")

local SUPPORTED_PROVIDERS = { anthropic = true }

local M = {}

local function require_field(opts, name)
    if opts[name] == nil or opts[name] == "" then
        error(string.format("[cook_ai] provider.%s is required", name), 3)
    end
end

function M.configure(opts)
    if type(opts) ~= "table" then
        error("[cook_ai] provider(opts) requires a table", 2)
    end
    require_field(opts, "provider")
    if not SUPPORTED_PROVIDERS[opts.provider] then
        error(string.format(
            "[cook_ai] unsupported provider: %s (v0.1 supports: anthropic)",
            opts.provider), 2)
    end
    require_field(opts, "model")
    require_field(opts, "api_key")

    local cfg = {
        provider    = opts.provider,
        model       = opts.model,
        api_key     = opts.api_key,
        base_url    = opts.base_url or os.getenv("ANTHROPIC_BASE_URL"),
        max_retries = opts.max_retries or 3,
        timeout_s   = opts.timeout_s   or 120,
    }
    state.set_provider(cfg)

    -- Side-effect: surface provider id + model id as env vars so they participate
    -- in cook's env-var auto-cache (Standard §17.1). Reads from these inside
    -- cook_ai.prompt(...) at execute time invalidate the unit when the
    -- Cookfile author bumps env.COOK_AI_MODEL in a config block.
    if cook and cook.env then
        cook.env.COOK_AI_PROVIDER = cfg.provider
        cook.env.COOK_AI_MODEL    = cfg.model
        if cfg.base_url and cfg.base_url ~= "" then
            cook.env.COOK_AI_BASE_URL = cfg.base_url
        end
    end
end

return M
