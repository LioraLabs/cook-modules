local stub = require("spec.cook_stub")

describe("cook_ai.prompt emit()", function()
    local cook_ai

    before_each(function()
        stub.reset()
        for _, m in ipairs({ "cook_ai", "cook_ai.prompt", "cook_ai.state",
                             "cook_ai.provider", "cook_ai.probes.model" }) do
            package.loaded[m] = nil
        end
        stub.fs_files = {
            ["docs/en/intro.md"]  = "Hello world.",
            ["docs/en/install.md"] = "Run `cook install`.",
            ["docs/en/skip.md"]   = "---\nnotranslate: true\n---\nDo not.",
        }
        cook_ai = require("cook_ai")
        cook_ai.provider({
            provider = "anthropic",
            model    = "claude-sonnet-4-6",
            api_key  = "k",
        })
    end)

    it("emits one recipe + one unit per matched input", function()
        cook_ai.prompt({
            name   = "translate-fr",
            inputs = { "docs/en/**/*.md" },
            output = function(p) return (p:gsub("/en/", "/fr/")) end,
            system = "Translate to French.",
            user   = function(_, content) return content end,
        })
        assert.equals(3, #stub.recipes_by_name_prefix("translate-fr/"))
        assert.equals(3, #stub.units)
    end)

    it("unit has input file in inputs[] and resolved output in outputs[]", function()
        cook_ai.prompt({
            name   = "translate-fr",
            inputs = { "docs/en/intro.md" },
            output = "docs/fr/{stem}.{ext}",
            system = "S", user = "U",
        })
        local u = stub.units[1]
        assert.is_true(stub.list_contains(u.inputs, "docs/en/intro.md"))
        assert.is_true(stub.list_contains(u.outputs, "docs/fr/intro.md"))
    end)

    it("unit requires ai:provider:anthropic:<model>", function()
        cook_ai.prompt({
            name = "x", inputs = {"docs/en/intro.md"},
            output = "out/{stem}.md", system = "S", user = "U",
        })
        assert.is_true(stub.list_contains(stub.units[1].requires,
            "ai:provider:anthropic:claude-sonnet-4-6"))
    end)

    it("unit command interpolates model id + invokes cook_ai_call", function()
        cook_ai.prompt({
            name = "x", inputs = {"docs/en/intro.md"},
            output = "out/{stem}.md", system = "S", user = "U",
        })
        local cmd = stub.units[1].command
        assert.matches("cook_ai_call", cmd)
        assert.matches("--model claude%-sonnet%-4%-6", cmd)
        assert.matches("--output out/intro%.md", cmd)
    end)

    it("system + user content live in inputs[] (cache-key contribution)", function()
        cook_ai.prompt({
            name = "x", inputs = {"docs/en/intro.md"},
            output = "out/{stem}.md",
            system = "SYSTEM-V1", user = function(_, c) return "USER-V1:" .. c end,
        })
        local u = stub.units[1]
        local sys_in = stub.find_input_with_content(u, "SYSTEM-V1")
        local usr_in = stub.find_input_with_content(u, "USER-V1:Hello world.")
        assert.is_not_nil(sys_in, "system content must live in a file listed in inputs[]")
        assert.is_not_nil(usr_in, "resolved user content must live in a file listed in inputs[]")
    end)

    it("model bump (via second prompt with override) produces a different probe key in requires[]", function()
        cook_ai.prompt({
            name = "x", inputs = {"docs/en/intro.md"},
            output = "out/{stem}.md", system = "S", user = "U",
            model = "claude-opus-4-7",
        })
        assert.is_true(stub.list_contains(stub.units[1].requires,
            "ai:provider:anthropic:claude-opus-4-7"))
    end)

    it("nil user/system skips emission for that input", function()
        cook_ai.prompt({
            name   = "x",
            inputs = { "docs/en/**/*.md" },
            output = "out/{stem}.md",
            system = "S",
            user   = function(p, _)
                if p:match("skip%.md$") then return nil end
                return "U"
            end,
        })
        assert.equals(2, #stub.units, "skip.md must not emit a unit")
    end)

    it("response_format value is folded into the command (cache-key sensitivity)", function()
        cook_ai.prompt({
            name = "x", inputs = {"docs/en/intro.md"},
            output = "out/{stem}.md", system = "S", user = "U",
            response_format = { type = "json_schema", schema = { type = "object" } },
        })
        assert.matches('--response%-format%-json', stub.units[1].command)
        assert.matches('json_schema',              stub.units[1].command)
    end)
end)
