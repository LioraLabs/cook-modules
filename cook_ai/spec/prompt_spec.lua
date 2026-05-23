local stub = require("spec.cook_stub")

describe("cook_ai.prompt", function()
    local cook_ai

    before_each(function()
        stub.reset()
        for _, m in ipairs({"cook_ai", "cook_ai.prompt", "cook_ai.state",
                            "cook_ai.provider", "cook_ai.client.anthropic"}) do
            package.loaded[m] = nil
        end
        cook_ai = require("cook_ai")
        cook_ai.provider({
            provider = "anthropic",
            model    = "claude-sonnet-4-6",
            api_key  = "sk-test",
        })
        -- Stub the actual HTTP call so tests don't fire real requests:
        require("cook_ai.client.anthropic").call = function(opts)
            return "STUB[" .. opts.system .. "|" .. opts.user .. "|" .. opts.model .. "]"
        end
    end)

    it("rejects opts table missing system or user", function()
        assert.has_error(function() cook_ai.prompt({ user = "u" }) end)
        assert.has_error(function() cook_ai.prompt({ system = "s" }) end)
    end)

    it("passes system + user + model from provider config to the client", function()
        local out = cook_ai.prompt({ system = "S", user = "U" })
        assert.equals("STUB[S|U|claude-sonnet-4-6]", out)
    end)

    it("opts.model overrides the provider default", function()
        local out = cook_ai.prompt({ system = "S", user = "U", model = "claude-opus-4-7" })
        assert.equals("STUB[S|U|claude-opus-4-7]", out)
    end)

    it("passes max_tokens / temperature / response_format / tools through", function()
        local captured
        require("cook_ai.client.anthropic").call = function(opts)
            captured = opts
            return ""
        end
        cook_ai.prompt({
            system = "S", user = "U",
            max_tokens = 1024,
            temperature = 0.3,
            response_format = { type = "text" },
            tools = { { name = "calc" } },
        })
        assert.equals(1024, captured.max_tokens)
        assert.equals(0.3, captured.temperature)
        assert.same({ type = "text" }, captured.response_format)
        assert.equals("calc", captured.tools[1].name)
    end)

    -- 0.2.0-2: provider() is optional; everything can come from cook.env.
    describe("cook.env-only resolution (no provider() call)", function()
        before_each(function()
            stub.reset()
            for _, m in ipairs({"cook_ai", "cook_ai.prompt", "cook_ai.state",
                                "cook_ai.provider", "cook_ai.client.anthropic"}) do
                package.loaded[m] = nil
            end
            cook_ai = require("cook_ai")
            -- Intentionally DO NOT call cook_ai.provider({...}). Populate
            -- cook.env as a config block would.
            cook.env.COOK_AI_PROVIDER  = "anthropic"
            cook.env.COOK_AI_MODEL     = "claude-sonnet-4-6"
            cook.env.ANTHROPIC_API_KEY = "sk-from-env"
            require("cook_ai.client.anthropic").call = function(opts)
                return "STUB[" .. opts.system .. "|" .. opts.user
                    .. "|" .. opts.model .. "|" .. opts.api_key .. "]"
            end
        end)

        it("reads provider+model+api_key entirely from cook.env when provider() never ran", function()
            local out = cook_ai.prompt({ system = "S", user = "U" })
            assert.equals("STUB[S|U|claude-sonnet-4-6|sk-from-env]", out)
        end)
    end)

    describe("incomplete config", function()
        before_each(function()
            stub.reset()
            for _, m in ipairs({"cook_ai", "cook_ai.prompt", "cook_ai.state",
                                "cook_ai.provider", "cook_ai.client.anthropic"}) do
                package.loaded[m] = nil
            end
            cook_ai = require("cook_ai")
        end)

        it("errors with a clear message naming the missing model", function()
            cook.env.ANTHROPIC_API_KEY = "sk-test"
            -- no model anywhere
            assert.has_error(function()
                cook_ai.prompt({ system = "S", user = "U" })
            end, "[cook_ai] model not configured — set env.COOK_AI_MODEL in a config block or pass model= to cook_ai.provider({...})")
        end)

        it("errors with a clear message naming the missing api_key", function()
            cook.env.COOK_AI_MODEL = "claude-sonnet-4-6"
            -- no api_key anywhere
            assert.has_error(function()
                cook_ai.prompt({ system = "S", user = "U" })
            end, "[cook_ai] api_key not configured — set env.ANTHROPIC_API_KEY in a config block / shell env or pass api_key= to cook_ai.provider({...})")
        end)
    end)
end)
