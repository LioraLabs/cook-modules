-- What a cc.* verb is allowed to know about the project it is editing.
local stub = require("cook_stub")

local function fresh()
    package.loaded["cook_cc.verbs._project"] = nil
    package.loaded["cook_cc.verbs._report"] = nil
    return require("cook_cc.verbs._project")
end

describe("project", function()
    local project

    before_each(function()
        stub.reset(); stub.install()
        project = fresh()
    end)

    describe("cookfile", function()
        it("finds the Cookfile in the working directory", function()
            stub.set_file("Cookfile", "use cook_cc\n")
            assert.equals("Cookfile", project.cookfile("cc.add"))
        end)

        it("fails naming the verb when there is none", function()
            local ok, err = pcall(project.cookfile, "cc.add")
            assert.is_false(ok)
            assert.equals("cc.add: no Cookfile in this directory", err:match("^[^\n]+"))
        end)

        it("says how to get one", function()
            local _, err = pcall(project.cookfile, "cc.add")
            assert.is_truthy(err:find("cook modules install cook_cc", 1, true))
        end)
    end)

    describe("declarations", function()
        it("lists recipes and chores in file order with their lines", function()
            stub.set_file("Cookfile", table.concat({
                "use cook_cc",
                "",
                "recipe math",
                "    cook_cc.lib({ dir = \"src/math/\" })",
                "",
                "chore clean",
                "    rm -rf build",
            }, "\n") .. "\n")
            assert.same({
                { name = "math", keyword = "recipe", line = 3 },
                { name = "clean", keyword = "chore", line = 6 },
            }, project.declarations("cc.add"))
        end)

        it("reads the quoted declaration spelling", function()
            stub.set_file("Cookfile", 'recipe "my-lib"\n    echo hi\n')
            assert.same({ { name = "my-lib", keyword = "recipe", line = 1 } },
                project.declarations("cc.add"))
        end)

        it("ignores an indented line that looks like a header", function()
            -- Only column 0 introduces a declaration (§3 keyword recognition),
            -- so this is a shell step, not a second recipe.
            stub.set_file("Cookfile", "recipe app\n    echo recipe ghost\n")
            assert.same({ { name = "app", keyword = "recipe", line = 1 } },
                project.declarations("cc.add"))
        end)

        it("ignores a commented-out declaration", function()
            stub.set_file("Cookfile", "# recipe ghost\nrecipe app\n    echo hi\n")
            assert.same({ { name = "app", keyword = "recipe", line = 2 } },
                project.declarations("cc.add"))
        end)

        it("takes a dependency list off the name", function()
            stub.set_file("Cookfile", "chore play: build\n    echo hi\n")
            assert.same({ { name = "play", keyword = "chore", line = 1 } },
                project.declarations("cc.add"))
        end)

        it("takes chore parameters off the name", function()
            stub.set_file("Cookfile", "chore deploy target host=\"prod\"\n    echo hi\n")
            assert.same({ { name = "deploy", keyword = "chore", line = 1 } },
                project.declarations("cc.add"))
        end)

        it("reads a tab as the separator", function()
            stub.set_file("Cookfile", "recipe\tmath\n    echo hi\n")
            assert.same({ { name = "math", keyword = "recipe", line = 1 } },
                project.declarations("cc.add"))
        end)

        it("reads a quote as the separator, with no space", function()
            stub.set_file("Cookfile", 'recipe"my-lib"\n    echo hi\n')
            assert.same({ { name = "my-lib", keyword = "recipe", line = 1 } },
                project.declarations("cc.add"))
        end)

        it("reads a quoted name containing a space or a colon", function()
            stub.set_file("Cookfile", 'recipe "my lib"\n    x\nrecipe "a:b"\n    x\n')
            assert.same({
                { name = "my lib", keyword = "recipe", line = 1 },
                { name = "a:b", keyword = "recipe", line = 3 },
            }, project.declarations("cc.add"))
        end)

        it("reads CRLF line endings", function()
            stub.set_file("Cookfile", "recipe math\r\n    echo hi\r\n")
            assert.same({ { name = "math", keyword = "recipe", line = 1 } },
                project.declarations("cc.add"))
        end)

        it("reads a declaration on an unterminated last line", function()
            stub.set_file("Cookfile", "use cook_cc\nrecipe math")
            assert.same({ { name = "math", keyword = "recipe", line = 2 } },
                project.declarations("cc.add"))
        end)

        it("over-reports a column-0 declaration written inside a heredoc", function()
            -- A known limit, pinned so it stays known. A `cook "out" { }` block
            -- is consumed raw across lines, so this `recipe ghost` is body text
            -- that the column-0 rule cannot distinguish. It over-reports, which
            -- costs a wrong refusal and never a corrupted Cookfile — the safe
            -- direction, and the reason the scan is allowed to be this simple.
            stub.set_file("Cookfile", table.concat({
                "recipe gen",
                '    cook "x.h" {',
                "        cat > x.h <<'EOF'",
                "recipe ghost",
                "EOF",
                "    }",
            }, "\n") .. "\n")
            local names = {}
            for _, d in ipairs(project.declarations("cc.add")) do names[#names + 1] = d.name end
            assert.same({ "gen", "ghost" }, names)
        end)

        it("does not treat the keyword as a prefix match", function()
            stub.set_file("Cookfile", "recipes_are_nice = 1\nrecipe app\n    echo hi\n")
            assert.same({ { name = "app", keyword = "recipe", line = 2 } },
                project.declarations("cc.add"))
        end)
    end)

    describe("declared", function()
        before_each(function()
            stub.set_file("Cookfile", "recipe math\n    echo hi\n")
        end)

        it("reports the declaration that already owns a name", function()
            assert.same({ name = "math", keyword = "recipe", line = 1 },
                project.declared("cc.add", "math"))
        end)

        it("reports nil for a free name", function()
            assert.is_nil(project.declared("cc.add", "game"))
        end)

        it("sees a chore, because recipes and chores share one namespace", function()
            stub.set_file("Cookfile", "recipe math\n    echo hi\nchore clean\n    rm -rf build\n")
            assert.same({ name = "clean", keyword = "chore", line = 3 },
                project.declared("cc.add", "clean"))
        end)
    end)

    describe("targets", function()
        it("maps a declared recipe to the cook_cc maker it calls", function()
            stub.set_file("Cookfile", "recipe math\n    x\nrecipe game\n    x\n")
            stub.set_module_call("math", { callee = "cook_cc.lib", text = "cook_cc.lib({})" })
            stub.set_module_call("game", { callee = "cook_cc.bin", text = "cook_cc.bin({})" })
            local targets = project.targets("cc.link")
            assert.equals("lib", targets.math.kind)
            assert.equals("bin", targets.game.kind)
            assert.equals("cook_cc.lib", targets.math.callee)
        end)

        it("classifies under whatever local this Cookfile binds cook_cc as", function()
            stub.set_file("Cookfile", "use cc ./vendor/cook_cc.lua\n\nrecipe math\n    x\n")
            stub.set_module_call("math", { callee = "cc.lib", text = "cc.lib({})" })
            assert.equals("lib", project.targets("cc.link").math.kind)
        end)

        it("omits a foreign module's maker even when the kind word matches", function()
            stub.set_file("Cookfile", "recipe thing\n    x\n")
            stub.set_module_call("thing", { callee = "cook_other.lib", text = "x" })
            assert.same({}, project.targets("cc.link"))
        end)

        it("omits a recipe holding no module call", function()
            stub.set_file("Cookfile", "recipe docs\n    echo hi\n")
            assert.same({}, project.targets("cc.link"))
        end)

        it("omits a module call that is not a target maker", function()
            stub.set_file("Cookfile", "recipe web\n    x\n")
            stub.set_module_call("web", { callee = "cook_pnpm.workspace", text = "x" })
            assert.same({}, project.targets("cc.link"))
        end)

        it("omits chores", function()
            stub.set_file("Cookfile", "chore clean\n    rm -rf build\n")
            stub.set_module_call("clean", { callee = "cook_cc.lib", text = "x" })
            assert.same({}, project.targets("cc.link"))
        end)
    end)

    describe("alias", function()
        it("answers cook_cc for the ordinary declaration", function()
            stub.set_file("Cookfile", "use cook_cc\n")
            assert.equals("cook_cc", project.alias("cc.add"))
        end)

        it("answers cook_cc for the quoted spelling", function()
            stub.set_file("Cookfile", 'use "cook_cc"\n')
            assert.equals("cook_cc", project.alias("cc.add"))
        end)

        it("answers cook_cc when a path form supplies the file", function()
            -- `use cook_cc ./vendor/cc.lua` still binds the local `cook_cc`.
            stub.set_file("Cookfile", "use cook_cc ./vendor/cc.lua\n")
            assert.equals("cook_cc", project.alias("cc.add"))
        end)

        it("derives the local from a bare path's basename", function()
            stub.set_file("Cookfile", "use ./vendor/cook_cc.lua\n")
            assert.equals("cook_cc", project.alias("cc.add"))
        end)

        it("answers the alias a renaming declaration binds", function()
            stub.set_file("Cookfile", "use cc ./vendor/cook_cc.lua\n")
            assert.equals("cc", project.alias("cc.add"))
        end)

        it("ignores another module's use declaration", function()
            stub.set_file("Cookfile", "use cook_pnpm\nuse cook_cc\n")
            assert.equals("cook_cc", project.alias("cc.add"))
        end)

        it("falls back to cook_cc rather than claiming an unrelated binding", function()
            -- `use mycc ./vendor/patched.lua` is undecidable from the Cookfile:
            -- nothing in the line says which module that file is.
            stub.set_file("Cookfile", "use mycc ./vendor/patched.lua\n")
            assert.equals("cook_cc", project.alias("cc.add"))
        end)
    end)

    describe("check_name", function()
        it("accepts a plain identifier", function()
            assert.has_no.errors(function() project.check_name("cc.add", "math") end)
        end)

        it("accepts internal hyphens and underscores", function()
            assert.has_no.errors(function() project.check_name("cc.add", "my-lib_2") end)
        end)

        it("rejects a dotted name and says why", function()
            local ok, err = pcall(project.check_name, "cc.add", "a.b")
            assert.is_false(ok)
            assert.is_truthy(err:find("cc.add: 'a.b' is not a name cc.add will create", 1, true))
            assert.is_truthy(err:find("import", 1, true))
        end)

        it("rejects a leading digit", function()
            assert.has_error(function() project.check_name("cc.add", "2fast") end,
                "cc.add: '2fast' is not a name cc.add will create\n"
                .. "  a target name starts with a letter or underscore and continues with letters, digits, '_' or '-'")
        end)

        it("rejects a space", function()
            assert.has_error(function() project.check_name("cc.add", "my lib") end,
                "cc.add: 'my lib' is not a name cc.add will create\n"
                .. "  a target name starts with a letter or underscore and continues with letters, digits, '_' or '-'")
        end)

        it("rejects the empty name", function()
            assert.has_error(function() project.check_name("cc.add", "") end,
                "cc.add: '' is not a name cc.add will create\n"
                .. "  a target name starts with a letter or underscore and continues with letters, digits, '_' or '-'")
        end)
    end)
end)
