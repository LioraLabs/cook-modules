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

    it("errors if called before provider was configured", function()
        require("cook_ai.state").reset()
        assert.has_error(function() cook_ai.prompt({ system = "S", user = "U" }) end,
            "[cook_ai] cook_ai.prompt called before cook_ai.provider — configure provider first")
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
end)
