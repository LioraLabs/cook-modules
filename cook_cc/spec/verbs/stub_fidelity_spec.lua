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
            assert.same({ { path = "Cookfile", recipe = "game", field = "links",
                entry = '"math"', created = false } }, stub.splices())
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

    -- CS-0221. The stub has to be as strict as the engine here in particular,
    -- because the two policies differ in whether a file is written: a stub
    -- that shrugged at an unknown option would green the one typo whose whole
    -- consequence is that no field gets created.
    describe("cook.cookfile.splice_field with create_if_absent", function()
        local function splice(text, options)
            stub.set_module_call("game", { callee = "cook_cc.bin", text = text })
            return pcall(cook.cookfile.splice_field, "Cookfile", "game", "links", '"math"', options)
        end

        it("still refuses an absent field when not asked to create it", function()
            assert.is_false(splice("cook_cc.bin({ sources = { } })"))
            assert.is_false(splice("cook_cc.bin({ sources = { } })", { create_if_absent = false }))
        end)

        it("creates an absent field when asked, and says which it did", function()
            assert.is_true(splice("cook_cc.bin({ sources = { } })", { create_if_absent = true }))
            assert.is_true(stub.splices()[1].created)
        end)

        it("appends rather than creates when the field is already there", function()
            assert.is_true(splice("cook_cc.bin({ links = { } })", { create_if_absent = true }))
            assert.is_false(stub.splices()[1].created)
        end)

        it("still refuses a field that is there and is not a list", function()
            assert.is_false(splice('cook_cc.bin({ links = "math" })', { create_if_absent = true }))
            assert.same({}, stub.splices())
        end)

        it("refuses an option it does not recognise", function()
            local ok, err = pcall(cook.cookfile.splice_field, "Cookfile", "game", "links", '"m"',
                { create_if_missing = true })
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("unknown option 'create_if_missing'", 1, true))
        end)

        -- The three refusals CS-0221 attached to the create path. A stub that
        -- reported "created" for any of them would green a verb the engine
        -- stops, and two of them are the engine standing between the author
        -- and a Cookfile that no longer loads.
        it("still refuses to create over a bracketed key of the same name", function()
            assert.is_false(splice('cook_cc.bin({ ["links"] = { "a" } })', { create_if_absent = true }))
            assert.is_false(splice("cook_cc.bin({ ['links'] = { 'a' } })", { create_if_absent = true }))
            assert.same({}, stub.splices())
        end)

        it("creates beside a bracketed key of a DIFFERENT name", function()
            assert.is_true(splice('cook_cc.bin({ ["standard"] = "c++20" })', { create_if_absent = true }))
        end)

        it("still refuses a call with no argument table", function()
            assert.is_false(splice('cook_cc.bin("src/main.cpp")', { create_if_absent = true }))
        end)

        it("still refuses a name that cannot be written as a table key", function()
            stub.set_module_call("game", { callee = "cook_cc.bin", text = "cook_cc.bin({ x = 1 })" })
            for _, bad in ipairs({ "", "a.b", "end", "2fast" }) do
                local ok = pcall(cook.cookfile.splice_field, "Cookfile", "game", bad, '"m"',
                    { create_if_absent = true })
                assert.is_false(ok, "field " .. string.format("%q", bad) .. " must be refused")
            end
        end)

        it("refuses a non-boolean option value", function()
            local ok = pcall(cook.cookfile.splice_field, "Cookfile", "game", "links", '"m"',
                { create_if_absent = "yes" })
            assert.is_false(ok)
        end)
    end)

    describe("cook.cookfile.field_entries", function()
        local function entries(text, field)
            stub.set_module_call("game", { callee = "cook_cc.bin", text = text })
            return cook.cookfile.field_entries("Cookfile", "game", field or "links")
        end

        it("reports the entries verbatim and in order", function()
            assert.same({ '"math"', "'sound'", "util" },
                entries("cook_cc.bin({ links = { \"math\", 'sound', util } })"))
        end)

        it("reports an empty list as an empty table, not as absence", function()
            assert.same({}, entries("cook_cc.bin({ links = { } })"))
        end)

        it("is nil for a field that is not there", function()
            assert.is_nil(entries("cook_cc.bin({ sources = { } })"))
        end)

        it("is nil for a recipe the Cookfile does not declare", function()
            assert.is_nil(cook.cookfile.field_entries("Cookfile", "ghost", "links"))
        end)

        it("does not mistake a comma inside an entry for a separator", function()
            assert.same({ '{ "a", "b" }', "f(1, 2)" },
                entries('cook_cc.bin({ links = { { "a", "b" }, f(1, 2) } })'))
        end)

        it("does not mistake a path containing the name for an entry", function()
            assert.same({},
                entries('cook_cc.bin({ sources = { "src/math/main.cpp" }, links = { } })'))
        end)

        it("raises for a field that is there and is not a list", function()
            assert.has_error(function() entries('cook_cc.bin({ links = "math" })') end)
        end)

        -- The lexical spellings §22.13 refuses to exempt. The engine
        -- understands all six; a stub that understood two would answer the
        -- opposite of the engine for each of these, and a spec written
        -- against it would enshrine the inverse behaviour.
        it("does not see a field commented out with a long comment", function()
            assert.is_nil(entries('cook_cc.bin({ sources = { "a.cpp" }, --[[ links = { "m" } ]] })'))
        end)

        it("does not let a brace in a long-bracket string close the list", function()
            assert.same({ "[[a}b]]", '"c"' },
                entries("cook_cc.bin({ links = { [[a}b]], \"c\" } })"))
        end)

        it("does not read two dashes inside a long bracket as a comment", function()
            assert.same({ "[[note -- x]]", '"c"' },
                entries('cook_cc.bin({ links = { [[note -- x]], "c" } })'))
        end)

        it("splits on a semicolon, which Lua admits as a separator", function()
            assert.same({ '"a"', '"b"' }, entries('cook_cc.bin({ links = { "a"; "b" } })'))
        end)

        it("keeps an entry whole when a comment sits beside it", function()
            assert.same({ '"a"', '"b"' },
                entries('cook_cc.bin({ links = { "a", -- why\n "b", -- and\n } })'))
        end)

        it("does not match a field name as a Lua pattern", function()
            -- `field` is caller data. As a pattern, `a.b` would match `axb`.
            assert.is_nil(cook.cookfile.field_entries("Cookfile", "game", "a.b"))
        end)
    end)
end)
