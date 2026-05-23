local stub = require("spec.cook_stub")

describe("cook_ai.provider", function()
    local cook_ai
    before_each(function()
        stub.reset()
        package.loaded["cook_ai"] = nil
        package.loaded["cook_ai.provider"] = nil
        package.loaded["cook_ai.state"] = nil
        cook_ai = require("cook_ai")
    end)

    it("captures provider opts", function()
        cook_ai.provider({
            provider = "anthropic",
            model    = "claude-sonnet-4-6",
            api_key  = "test-key",
        })
        local state = require("cook_ai.state")
        local cfg = state.get_provider()
        assert.equals("anthropic", cfg.provider)
        assert.equals("claude-sonnet-4-6", cfg.model)
    end)

    it("registers ai:provider:anthropic:<model> probe", function()
        cook_ai.provider({
            provider = "anthropic",
            model    = "claude-sonnet-4-6",
            api_key  = "test-key",
        })
        assert.is_not_nil(stub.probes["ai:provider:anthropic:claude-sonnet-4-6"])
    end)

    it("rejects unknown provider", function()
        assert.has_error(function()
            cook_ai.provider({ provider = "bogus", model = "x", api_key = "k" })
        end, "[cook_ai] unsupported provider: bogus (v0.1 supports: anthropic)")
    end)

    it("rejects missing api_key", function()
        assert.has_error(function()
            cook_ai.provider({ provider = "anthropic", model = "claude-sonnet-4-6" })
        end)
    end)

    it("applies default max_retries=3 and timeout_s=120", function()
        cook_ai.provider({ provider = "anthropic", model = "m", api_key = "k" })
        local cfg = require("cook_ai.state").get_provider()
        assert.equals(3,   cfg.max_retries)
        assert.equals(120, cfg.timeout_s)
    end)
end)
