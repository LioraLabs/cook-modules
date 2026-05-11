local stub = require("cook_stub")

local function with_toolchain()
    stub.set_sh_handler("command -v g++", function() return "/usr/bin/g++\n" end)
    stub.set_sh_handler("command -v clang++", function() error("nope") end)
    require("cook_cc.toolchain").rehydrate()
end

local function reset_module(name)
    package.loaded[name] = nil
end

describe("cc.bin", function()
    before_each(function()
        stub.reset(); stub.install()
        for _, m in ipairs({
            "cook_cc.toolchain","cook_cc.cc","cook_cc.targets","cook_cc.transitive",
        }) do reset_module(m) end
        with_toolchain()
    end)

    it("compiles each source and links to build/bin/<name>", function()
        local targets = require("cook_cc.targets")
        targets.bin("app", { sources = { "src/a.cpp", "src/b.cpp" } })
        local units = stub.added_units()
        assert.equals(3, #units)  -- two compiles + one link
        assert.equals("build/obj/app/a.o", units[1].output)
        assert.equals("build/obj/app/b.o", units[2].output)
        assert.equals("build/bin/app",     units[3].output)
    end)

    it("registers known_targets in cook.cache", function()
        local targets = require("cook_cc.targets")
        targets.bin("app", { sources = { "src/a.cpp" } })
        local known = cook.cache.get("known_targets")
        assert.same({ "app" }, known)
    end)

    it("calls cook.export with compile_info for compile_commands", function()
        local targets = require("cook_cc.targets")
        targets.bin("app", { sources = { "src/a.cpp" }, includes = { "inc/" } })
        local info = cook.import("app")
        assert.is_table(info.compile_info)
        assert.same({ "src/a.cpp" }, info.compile_info.sources)
        assert.same({ "inc/" }, info.compile_info.includes)
    end)

    it("errors if sources is empty and no dir is given", function()
        local targets = require("cook_cc.targets")
        assert.has_error(function() targets.bin("app", {}) end,
            "[cc.bin] no sources found for target 'app'")
    end)

    it("CS-cook_cc-0.1.1: bin's link command includes archive paths from cc.lib links", function()
        local targets = require("cook_cc.targets")
        targets.lib("foolib", { sources = { "src/foo.c" } })
        -- After lib is registered, cook.import("foolib").lib_path must surface.
        local exported = cook.import("foolib")
        assert.equals("build/lib/libfoolib.a", exported.lib_path)

        targets.bin("app", {
            sources = { "src/main.c" },
            links   = { "foolib" },
        })
        local units = stub.added_units()
        local link_unit = units[#units]  -- last unit is the link command
        assert.matches("build/lib/libfoolib%.a", link_unit.command,
            "link command must include the foolib archive path")
    end)

    it("CS-cook_cc-0.1.2: bin's compile commands include export_includes from cc.lib links", function()
        local targets = require("cook_cc.targets")
        targets.lib("foolib", {
            sources = { "src/foo.c" },
            export_includes = { "foolib/include/" },
        })
        targets.bin("app", {
            sources = { "src/main.c" },
            links   = { "foolib" },
        })
        -- All compile units for app must include -Ifoolib/include/
        local units = stub.added_units()
        local app_compiles = {}
        for _, u in ipairs(units) do
            if u.output and u.output:match("^build/obj/app/") then
                app_compiles[#app_compiles + 1] = u
            end
        end
        assert.is_true(#app_compiles > 0, "expected at least one compile for app")
        for _, u in ipairs(app_compiles) do
            assert.matches(" %-Ifoolib/include/ ", u.command,
                "app compile command must include -Ifoolib/include/")
        end
    end)
end)

describe("cc.lib", function()
    before_each(function()
        stub.reset(); stub.install()
        for _, m in ipairs({
            "cook_cc.toolchain","cook_cc.cc","cook_cc.targets","cook_cc.transitive",
        }) do reset_module(m) end
        with_toolchain()
    end)

    it("compiles + archives to build/lib/lib<name>.a", function()
        local targets = require("cook_cc.targets")
        targets.lib("mathlib", { sources = { "math/v.cpp" } })
        local units = stub.added_units()
        assert.equals(2, #units)
        assert.equals("build/obj/mathlib/v.o", units[1].output)
        assert.equals("build/lib/libmathlib.a", units[2].output)
        assert.matches("^ar rcs ", units[2].command)
    end)

    it("CS-cook_cc-0.1.2: lib's compile commands include export_includes from cc.lib links", function()
        local targets = require("cook_cc.targets")
        targets.lib("baselib", {
            sources = { "src/base.c" },
            export_includes = { "baselib/include/" },
        })
        targets.lib("extlib", {
            sources = { "src/ext.c" },
            links   = { "baselib" },
        })
        local units = stub.added_units()
        local extlib_compiles = {}
        for _, u in ipairs(units) do
            if u.output and u.output:match("^build/obj/extlib/") then
                extlib_compiles[#extlib_compiles + 1] = u
            end
        end
        assert.is_true(#extlib_compiles > 0, "expected at least one compile for extlib")
        for _, u in ipairs(extlib_compiles) do
            assert.matches(" %-Ibaselib/include/ ", u.command,
                "extlib compile command must include -Ibaselib/include/")
        end
    end)
end)

describe("cc.shared", function()
    before_each(function()
        stub.reset(); stub.install()
        for _, m in ipairs({
            "cook_cc.toolchain","cook_cc.cc","cook_cc.targets","cook_cc.transitive",
        }) do reset_module(m) end
        with_toolchain()
    end)

    it("compiles -fPIC + links -shared to build/lib/lib<name>.so", function()
        local targets = require("cook_cc.targets")
        targets.shared("plug", { sources = { "p.cpp" } })
        local units = stub.added_units()
        local compile, link = units[1], units[2]
        assert.matches(" %-fPIC ", compile.command)
        assert.matches(" %-shared", link.command)
        assert.equals("build/lib/libplug.so", link.output)
    end)

    it("CS-cook_cc-0.1.2: shared's compile commands include export_includes from cc.lib links", function()
        local targets = require("cook_cc.targets")
        targets.lib("iface", {
            sources = { "src/iface.c" },
            export_includes = { "iface/include/" },
        })
        targets.shared("plug", {
            sources = { "src/plug.c" },
            links   = { "iface" },
        })
        local units = stub.added_units()
        local plug_compiles = {}
        for _, u in ipairs(units) do
            if u.output and u.output:match("^build/obj/plug/") then
                plug_compiles[#plug_compiles + 1] = u
            end
        end
        assert.is_true(#plug_compiles > 0, "expected at least one compile for plug")
        for _, u in ipairs(plug_compiles) do
            assert.matches(" %-Iiface/include/ ", u.command,
                "plug compile command must include -Iiface/include/")
        end
    end)
end)

describe("cc.headers", function()
    before_each(function()
        stub.reset(); stub.install()
        for _, m in ipairs({
            "cook_cc.toolchain","cook_cc.cc","cook_cc.targets","cook_cc.transitive",
        }) do reset_module(m) end
        with_toolchain()
    end)

    it("registers exports but emits no units", function()
        local targets = require("cook_cc.targets")
        targets.headers("idlib", { export_includes = { "include/" } })
        assert.equals(0, #stub.added_units())
        local info = cook.import("idlib")
        assert.same({ "include/" }, info.includes)
    end)
end)
