-- The stub's job is to be exactly as strict as the engine. A stub that is
-- MORE forgiving greens code the engine rejects, which is the failure mode
-- worth its own spec — four sibling verbs are about to be written against it.
local stub = require("cook_stub")

describe("stub fidelity", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_file("Cookfile", "recipe game\n    x\n")
    end)

    describe("cook.chore", function()
        it("rejects a nil metadata table, as the engine's signature does", function()
            -- The engine takes (String, LuaTable, LuaFunction). A module that
            -- passes nil dies at LOAD, which breaks every build of every
            -- project using it, not just that one verb.
            assert.has_error(function() cook.chore("cc.x", nil, function() end) end,
                "[cook_stub] cook.chore: metadata must be a table, got nil")
        end)

        it("rejects an unnamespaced name", function()
            assert.has_error(function() cook.chore("add", {}, function() end) end,
                "[cook_stub] cook.chore: 'add' must be namespaced (try 'cc.add')")
        end)

        it("rejects another module's namespace", function()
            local ok, err = pcall(cook.chore, "pnpm.add", {}, function() end)
            assert.is_false(ok)
            assert.is_truthy(err:find("may only register under 'cc' or 'cook_cc'", 1, true))
        end)

        it("accepts the module's full name as the prefix", function()
            assert.has_no.errors(function() cook.chore("cook_cc.add", {}, function() end) end)
        end)
    end)

    describe("cook.cookfile.find_call", function()
        it("answers nil for a recipe the Cookfile does not declare", function()
            stub.set_module_call("ghost", { callee = "cook_cc.lib", text = "x" })
            assert.is_nil(cook.cookfile.find_call("Cookfile", "ghost"))
        end)

        it("answers nil for a declared recipe holding no module call", function()
            assert.is_nil(cook.cookfile.find_call("Cookfile", "game"))
        end)
    end)

    describe("cook.cookfile.splice_field", function()
        local function splice(text)
            stub.set_module_call("game", { callee = "cook_cc.bin", text = text })
            return pcall(cook.cookfile.splice_field, "Cookfile", "game", "links", '"math"')
        end

        it("splices into a top-level list", function()
            assert.is_true(splice("cook_cc.bin({ links = { } })"))
            assert.same({ { path = "Cookfile", recipe = "game", field = "links", entry = '"math"' } },
                stub.splices())
        end)

        -- §22.13: "A field is a key, not a substring."
        it("refuses a match inside a comment", function()
            assert.is_false(splice("cook_cc.bin({ sources = { } })  -- links = { }"))
        end)

        it("refuses a match inside a string", function()
            assert.is_false(splice('cook_cc.bin({ sources = { "links = { }" } })'))
        end)

        it("refuses a match that is the key of a NESTED table", function()
            -- The case §22.13 singles out: the result would still parse and
            -- still look like the file the author wrote.
            assert.is_false(splice("cook_cc.bin({ opts = { links = { } } })"))
        end)

        it("refuses a key whose value is not a list", function()
            assert.is_false(splice('cook_cc.bin({ links = "math" })'))
        end)

        it("refuses a longer key that merely ends with the field name", function()
            assert.is_false(splice("cook_cc.bin({ extra_links = { } })"))
        end)

        it("records nothing when it refuses", function()
            splice("cook_cc.bin({ opts = { links = { } } })")
            assert.same({}, stub.splices())
        end)
    end)
end)
