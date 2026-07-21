-- 0.13.0: the old premise ("target-makers call cook.recipe
-- internally") is GONE. Makers are now STEP CONTRIBUTORS: called INSIDE a
-- user-written `recipe` body with NO name param, they add compile/link/archive
-- units + the export DIRECTLY to the enclosing recipe and mint NO recipe of
-- their own. These specs pin that step-contributor contract.
--
-- We use the DEFAULT stub (inline recipe execution, which sets current_recipe
-- so cook.recipe_name() / recipe.name resolve inside the body).

local stub = require("cook_stub")

local function reset_modules()
    for _, m in ipairs({
        "cook_cc.toolchain", "cook_cc.units.cc", "cook_cc.units.targets", "cook_cc.units.transitive",
        "cook_cc.discovery.finder", "cook_cc.codegen.config_header",
    }) do
        package.loaded[m] = nil
    end
    package.loaded["cook_cc"] = nil
end

local function with_toolchain()
    stub.set_probe_value("cc:compiler:auto", { cxx = "g++", cc = "gcc" })
    require("cook_cc.toolchain").ensure_probe_registered()
end

local function in_recipe(name, fn) cook.recipe(name, {}, fn) end

describe("step-contributor: maker mints NO nested recipe", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        reset_modules()
        with_toolchain()
    end)

    it("cc.bin contributes to the enclosing recipe and registers no extra recipe", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("game", function()
            targets.bin({ sources = { "src/main.c" } })
        end)
        assert.same({ "game" }, stub.recipe_names())
    end)

    it("cc.lib registers no extra recipe", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("mathlib", function()
            targets.lib({ sources = { "src/math.c" } })
        end)
        assert.same({ "mathlib" }, stub.recipe_names())
    end)

    it("cc.shared registers no extra recipe", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("plug", function()
            targets.shared({ sources = { "src/plug.c" } })
        end)
        assert.same({ "plug" }, stub.recipe_names())
    end)

    it("cc.headers registers no extra recipe", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("idlib", function()
            targets.headers({ export_includes = { "include/" } })
        end)
        assert.same({ "idlib" }, stub.recipe_names())
    end)

    it("a bin linking a lib mints exactly the two user recipes, no maker recipes", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("mathlib", function()
            targets.lib({ sources = { "src/math.c" } })
        end)
        in_recipe("game", function()
            targets.bin({ sources = { "src/main.c" }, links = { "mathlib" } })
        end)
        assert.same({ "mathlib", "game" }, stub.recipe_names())
    end)
end)

describe("step-contributor: cc.bin outputs", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        reset_modules()
        with_toolchain()
    end)

    it("produces 2 compiles + 1 link ending at build/bin/<name>", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("game", function()
            targets.bin({ sources = { "src/main.c", "src/util.c" } })
        end)
        local units = stub.added_units()
        assert.equals(3, #units)
        assert.equals("build/obj/game/main.o", units[1].output)
        assert.equals("build/obj/game/util.o", units[2].output)
        assert.equals("build/bin/game", units[3].output)
    end)

    it("registers the bare name in _known", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("game", function()
            targets.bin({ sources = { "src/main.c" } })
        end)
        assert.same({ "game" }, targets._known())
    end)

    it("exports under the recipe identity (cook.import) with compile_info", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("game", function()
            targets.bin({ sources = { "src/main.c" } })
        end)
        local info = cook.import("game")
        assert.is_table(info)
        assert.same({ "src/main.c" }, info.compile_info.sources)
    end)
end)

describe("step-contributor: cc.lib outputs", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        reset_modules()
        with_toolchain()
    end)

    it("produces compile(s) + an archive at build/lib/lib<name>.a", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("mathlib", function()
            targets.lib({ sources = { "src/math.c" } })
        end)
        local units = stub.added_units()
        assert.equals(2, #units)
        assert.equals("build/obj/mathlib/math.o", units[1].output)
        assert.equals("build/lib/libmathlib.a", units[2].output)
        assert.matches("^ar rcs ", units[2].command)
    end)

    it("exports lib_path pointing at the archive", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("mathlib", function()
            targets.lib({ sources = { "src/math.c" } })
        end)
        assert.equals("build/lib/libmathlib.a", cook.import("mathlib").lib_path)
    end)

    it("registers the bare name in _known", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("mathlib", function()
            targets.lib({ sources = { "src/math.c" } })
        end)
        assert.same({ "mathlib" }, targets._known())
    end)
end)

describe("step-contributor: cc.shared outputs", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        reset_modules()
        with_toolchain()
    end)

    it("produces a -fPIC compile + a -shared link at build/lib/lib<name>.so", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("plug", function()
            targets.shared({ sources = { "src/plug.c" } })
        end)
        local units = stub.added_units()
        assert.equals(2, #units)
        assert.matches(" %-fPIC ", units[1].command)
        assert.matches(" %-shared", units[2].command)
        assert.equals("build/lib/libplug.so", units[2].output)
    end)

    it("exports lib_path pointing at the shared object", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("plug", function()
            targets.shared({ sources = { "src/plug.c" } })
        end)
        assert.equals("build/lib/libplug.so", cook.import("plug").lib_path)
    end)

    it("registers the bare name in _known", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("plug", function()
            targets.shared({ sources = { "src/plug.c" } })
        end)
        assert.same({ "plug" }, targets._known())
    end)
end)

describe("step-contributor: cc.headers outputs", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        reset_modules()
        with_toolchain()
    end)

    it("produces no units", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("idlib", function()
            targets.headers({ export_includes = { "include/" } })
        end)
        assert.equals(0, #stub.added_units())
    end)

    it("exports includes under the recipe identity", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("idlib", function()
            targets.headers({ export_includes = { "include/" } })
        end)
        local info = cook.import("idlib")
        assert.same({ "include/" }, info.includes)
        assert.equals("", info.lib_path)
    end)

    it("registers the bare name in _known", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("idlib", function()
            targets.headers({ export_includes = { "include/" } })
        end)
        assert.same({ "idlib" }, targets._known())
    end)
end)

describe("step-contributor: empty-source errors inside a recipe", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        reset_modules()
        with_toolchain()
    end)

    it("cc.bin errors when sources list is empty", function()
        local targets = require("cook_cc.units.targets")
        assert.has_error(function()
            in_recipe("app", function() targets.bin({ sources = {} }) end)
        end, "[cc.bin] no sources found for target 'app'")
    end)

    it("cc.lib errors when sources list is empty", function()
        local targets = require("cook_cc.units.targets")
        assert.has_error(function()
            in_recipe("app", function() targets.lib({ sources = {} }) end)
        end, "[cc.lib] no sources found for target 'app'")
    end)

    it("cc.shared errors when sources list is empty", function()
        local targets = require("cook_cc.units.targets")
        assert.has_error(function()
            in_recipe("app", function() targets.shared({ sources = {} }) end)
        end, "[cc.shared] no sources found for target 'app'")
    end)
end)

describe("step-contributor: probes register at top level, not in body (CS-0083)", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        reset_modules()
        -- Do NOT call with_toolchain(): assert the maker itself ensures
        -- cc:compiler:auto is registered (idempotently) when it runs.
        stub.set_probe_value("cc:compiler:auto", { cxx = "g++", cc = "gcc" })
    end)

    it("cc.bin ensures cc:compiler:auto is registered", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("app", function()
            targets.bin({ sources = { "src/a.cpp" } })
        end)
        local has_compiler = false
        for _, k in ipairs(stub.probe_keys()) do
            if k == "cc:compiler:auto" then has_compiler = true; break end
        end
        assert.is_true(has_compiler, "cc:compiler:auto must be registered")
    end)

    it("cook_cc.toolchain({...}) registers the compiler probe at top level", function()
        local cc = require("cook_cc")
        cc.toolchain({ compiler = "clang++" })
        local has_probe = false
        for _, k in ipairs(stub.probe_keys()) do
            if k == "cc:compiler:clang++" then has_probe = true; break end
        end
        assert.is_true(has_probe,
            "cook_cc.toolchain() must register cc:compiler:clang++ at top level")
    end)
end)
