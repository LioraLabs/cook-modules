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
