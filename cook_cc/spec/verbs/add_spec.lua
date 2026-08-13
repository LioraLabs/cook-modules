-- `cook cc.add <kind> <name>` — scaffold a target and register it.
local stub = require("cook_stub")

local function fresh()
    for _, m in ipairs({
        "cook_cc.verbs.add", "cook_cc.verbs._project", "cook_cc.verbs._report",
    }) do package.loaded[m] = nil end
    local add = require("cook_cc.verbs.add")
    local report = require("cook_cc.verbs._report")
    report.emit = function() end
    return add, report
end

describe("cc.add", function()
    local add, report

    before_each(function()
        stub.reset(); stub.install()
        add, report = fresh()
        stub.set_file("Cookfile", "use cook_cc\n")
    end)

    local function run(...)
        add.register()
        return stub.invoke_chore("cc.add", { ... })
    end

    describe("registration", function()
        it("registers under the module's own namespace", function()
            add.register()
            assert.is_truthy(stub.chore("cc.add"))
        end)

        it("declares kind and name as required positional parameters", function()
            add.register()
            assert.same({
                { kind = "required", name = "kind" },
                { kind = "required", name = "name" },
            }, stub.chore("cc.add").meta.__params)
        end)

        it("carries an origin so cook menu can attribute it", function()
            add.register()
            assert.equals("cook_cc.verbs.add", stub.chore("cc.add").meta.origin)
        end)

        it("does not touch the project just by registering", function()
            add.register()
            assert.equals("use cook_cc\n", stub.file("Cookfile"))
        end)
    end)

    describe("lib", function()
        before_each(function() run("lib", "math") end)

        it("writes an implementation under src/<name>/", function()
            assert.is_truthy(stub.file("src/math/math.cpp"))
        end)

        it("writes a header under include/<name>/", function()
            assert.is_truthy(stub.file("include/math/math.hpp"))
        end)

        it("gives the two files a matching declaration and definition", function()
            assert.is_truthy(stub.file("include/math/math.hpp"):find("namespace math", 1, true))
            assert.is_truthy(stub.file("src/math/math.cpp"):find('#include "math/math.hpp"', 1, true))
        end)

        it("guards the header against double inclusion", function()
            assert.is_truthy(stub.file("include/math/math.hpp"):find("#pragma once", 1, true))
        end)

        it("appends a recipe calling the lib maker over the whole directory", function()
            assert.is_truthy(stub.file("Cookfile"):find(
                'recipe math\n    cook_cc.lib({ dir = "src/math/", includes = { "include" } })',
                1, true))
        end)

        it("puts include/ on the search path, so the header it just wrote resolves", function()
            -- The scaffolded .cpp includes "math/math.hpp". Without this the
            -- first build after cc.add fails to compile, which is the one
            -- thing this verb must never produce.
            local recipe = stub.file("Cookfile"):match("recipe math\n(.-)\n")
            assert.is_truthy(recipe:find('includes = { "include" }', 1, true))
        end)

        it("leaves what was already in the Cookfile alone", function()
            assert.equals("use cook_cc\n", stub.file("Cookfile"):sub(1, 12))
        end)
    end)

    describe("bin", function()
        before_each(function() run("bin", "game") end)

        it("writes a main under src/<name>/", function()
            assert.is_truthy(stub.file("src/game/main.cpp"):find("int main(", 1, true))
        end)

        it("writes no header, because a program exposes nothing", function()
            assert.is_nil(stub.file("include/game/game.hpp"))
        end)

        it("appends a recipe naming the source explicitly", function()
            assert.is_truthy(stub.file("Cookfile"):find(
                'recipe game\n    cook_cc.bin({ sources = { "src/game/main.cpp" } })', 1, true))
        end)
    end)

    describe("a project that bound cook_cc under another name", function()
        it("generates a call to the local that Cookfile actually binds", function()
            -- §27.1.2's sanctioned way to patch a blessed module. Writing
            -- `cook_cc.lib(...)` here would append a call to a global that
            -- does not exist, and the next build would fail on a file this
            -- verb had just written.
            stub.set_file("Cookfile", "use cc ./vendor/cook_cc.lua\n")
            run("lib", "math")
            assert.is_truthy(stub.file("Cookfile"):find(
                'recipe math\n    cc.lib({ dir = "src/math/"', 1, true))
        end)
    end)

    describe("output", function()
        it("names every file it created and the command to build it", function()
            local lines = {}
            report.emit = function(l) lines[#lines + 1] = l end
            run("lib", "math")
            assert.same({
                "  created  src/math/math.cpp",
                "  created  include/math/math.hpp",
                "  updated  Cookfile",
                "",
                "  try: cook math",
            }, lines)
        end)
    end)

    describe("refusals", function()
        local function refuse(...)
            local args = { ... }
            local before = stub.file("Cookfile")
            local ok, err = pcall(function() return run(table.unpack(args)) end)
            assert.is_false(ok, "expected a refusal")
            assert.equals(before, stub.file("Cookfile"), "the Cookfile must be untouched")
            return err
        end

        it("rejects an unknown kind and lists the ones it takes", function()
            local err = refuse("static", "math")
            assert.equals("cc.add: unknown kind 'static'\n  accepted kinds: bin, lib", err)
        end)

        it("rejects a kind cook_cc can make but cc.add cannot yet scaffold", function()
            -- `shared` and `headers` are real makers; until this verb knows how
            -- to lay their files out, silently accepting them would produce a
            -- recipe pointing at nothing.
            local err = refuse("shared", "math")
            assert.equals("cc.add: unknown kind 'shared'\n  accepted kinds: bin, lib", err)
        end)

        it("rejects a name the Cookfile grammar would reject", function()
            local err = refuse("lib", "2fast")
            assert.is_truthy(err:find("cc.add: '2fast' is not a name cc.add will create", 1, true))
        end)

        it("rejects a name that is already declared, naming the line", function()
            stub.set_file("Cookfile", "use cook_cc\n\nrecipe math\n    echo hi\n")
            local err = refuse("lib", "math")
            assert.equals("cc.add: 'math' is already declared in Cookfile:3\n"
                .. "  pick another name, or edit that declaration yourself", err)
        end)

        it("rejects a name a chore already owns, since they share a namespace", function()
            stub.set_file("Cookfile", "chore math\n    echo hi\n")
            local err = refuse("lib", "math")
            assert.is_truthy(err:find("already declared in Cookfile:1", 1, true))
        end)

        it("refuses when there is no Cookfile", function()
            stub.reset(); stub.install()
            add, report = fresh()
            local ok, err = pcall(function() return run("lib", "math") end)
            assert.is_false(ok)
            assert.is_truthy(err:find("cc.add: no Cookfile in this directory", 1, true))
        end)

        it("writes no source files when it refuses", function()
            pcall(function() return run("static", "math") end)
            assert.is_nil(stub.file("src/math/math.cpp"))
        end)

        it("refuses when the source directory is already there", function()
            stub.set_file("src/math/other.cpp", "// mine\n")
            local err = refuse("lib", "math")
            assert.is_truthy(err:find("cc.add: 'src/math' already exists", 1, true))
        end)

        it("refuses when only the include directory is already there", function()
            -- The refusal says it "will not write over anything it did not
            -- make", and a lib writes two trees. Guarding one of them would
            -- silently clobber somebody's header.
            stub.set_file("include/math/math.hpp", "// mine\n")
            local err = refuse("lib", "math")
            assert.is_truthy(err:find("cc.add: 'include/math' already exists", 1, true))
            assert.is_nil(stub.file("src/math/math.cpp"))
        end)
    end)
end)
