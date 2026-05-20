-- SHI-216 / CS-0072: target-makers must call cook.recipe(...) internally so
-- they can be invoked from a top-level register block in Cookfile v0.9 syntax.
--
-- These specs use a deferred-recipe variant of cook_stub: cook.recipe captures
-- {name, opts, body_fn} without immediately running the body, letting us
-- assert on the recipe header separately from the body effects.

local stub = require("cook_stub")

local function reset_modules()
    for _, m in ipairs({
        "cook_cc.toolchain", "cook_cc.cc", "cook_cc.targets", "cook_cc.transitive",
        "cook_cc.finder",
    }) do
        package.loaded[m] = nil
    end
    package.loaded["cook_cc"] = nil
end

local function with_toolchain()
    stub.set_probe_value("cc:compiler:auto", { cxx = "g++", cc = "gcc" })
    require("cook_cc.toolchain").ensure_probe_registered()
end

-- Install a deferred-recipe variant: cook.recipe captures the registration
-- but does NOT run the body. Returns the captured recipes table.
local function install_deferred()
    local recipes = {}
    stub.install()
    _G.cook.recipe = function(name, opts, body_fn)
        recipes[#recipes + 1] = { name = name, opts = opts, body_fn = body_fn }
    end
    return recipes
end

describe("cook_cc target-makers: cook.recipe header (SHI-216)", function()
    local recipes

    before_each(function()
        stub.reset()
        recipes = install_deferred()
        stub.set_sh_handler("__exists", function() return true end)
        reset_modules()
        with_toolchain()
    end)

    -- cc.bin
    it("cc.bin registers a recipe with the correct name", function()
        local targets = require("cook_cc.targets")
        targets.bin("game", { sources = { "src/main.c" } })
        assert.equals(1, #recipes)
        assert.equals("game", recipes[1].name)
    end)

    it("cc.bin passes opts.links as recipe requires", function()
        local targets = require("cook_cc.targets")
        targets.bin("app", { sources = { "src/a.c" }, links = { "mylib" } })
        assert.equals(1, #recipes)
        assert.same({ "mylib" }, recipes[1].opts.requires)
    end)

    it("cc.bin with no links passes empty requires", function()
        local targets = require("cook_cc.targets")
        targets.bin("app", { sources = { "src/a.c" } })
        assert.same({}, recipes[1].opts.requires)
    end)

    it("cc.bin returns the target name", function()
        local targets = require("cook_cc.targets")
        local result = targets.bin("app", { sources = { "src/a.c" } })
        assert.equals("app", result)
    end)

    -- cc.lib
    it("cc.lib registers a recipe with the correct name", function()
        local targets = require("cook_cc.targets")
        targets.lib("mathlib", { sources = { "src/math.c" } })
        assert.equals(1, #recipes)
        assert.equals("mathlib", recipes[1].name)
    end)

    it("cc.lib passes opts.links as recipe requires", function()
        local targets = require("cook_cc.targets")
        targets.lib("extlib", { sources = { "src/ext.c" }, links = { "base" } })
        assert.same({ "base" }, recipes[1].opts.requires)
    end)

    it("cc.lib returns the target name", function()
        local targets = require("cook_cc.targets")
        local result = targets.lib("mathlib", { sources = { "src/math.c" } })
        assert.equals("mathlib", result)
    end)

    -- cc.shared
    it("cc.shared registers a recipe with the correct name", function()
        local targets = require("cook_cc.targets")
        targets.shared("plug", { sources = { "src/plug.c" } })
        assert.equals(1, #recipes)
        assert.equals("plug", recipes[1].name)
    end)

    it("cc.shared passes opts.links as recipe requires", function()
        local targets = require("cook_cc.targets")
        targets.shared("plug", { sources = { "src/plug.c" }, links = { "iface" } })
        assert.same({ "iface" }, recipes[1].opts.requires)
    end)

    it("cc.shared returns the target name", function()
        local targets = require("cook_cc.targets")
        local result = targets.shared("plug", { sources = { "src/plug.c" } })
        assert.equals("plug", result)
    end)

    -- cc.headers
    it("cc.headers registers a recipe with the correct name", function()
        local targets = require("cook_cc.targets")
        targets.headers("idlib", { export_includes = { "include/" } })
        assert.equals(1, #recipes)
        assert.equals("idlib", recipes[1].name)
    end)

    it("cc.headers passes empty requires (header-only target has no link deps)", function()
        local targets = require("cook_cc.targets")
        targets.headers("idlib", { export_includes = { "include/" } })
        assert.same({}, recipes[1].opts.requires)
    end)

    it("cc.headers returns the target name", function()
        local targets = require("cook_cc.targets")
        local result = targets.headers("idlib", {})
        assert.equals("idlib", result)
    end)
end)

describe("cook_cc target-makers: recipe body effects (SHI-216)", function()
    local recipes

    before_each(function()
        stub.reset()
        recipes = install_deferred()
        stub.set_sh_handler("__exists", function() return true end)
        reset_modules()
        with_toolchain()
    end)

    it("cc.bin body produces compile + link units when invoked", function()
        local targets = require("cook_cc.targets")
        targets.bin("game", { sources = { "src/main.c", "src/util.c" } })
        assert.equals(1, #recipes)
        assert.equals(0, #stub.added_units(), "units should be empty before body runs")

        recipes[1].body_fn()
        local units = stub.added_units()
        -- 2 compiles + 1 link = 3 units minimum
        assert.is_true(#units >= 3,
            "expected >= 3 units (2 compile + 1 link); got " .. tostring(#units))
        assert.equals("build/bin/game", units[#units].output)
    end)

    it("cc.lib body produces compile + archive units when invoked", function()
        local targets = require("cook_cc.targets")
        targets.lib("mathlib", { sources = { "src/math.c" } })
        recipes[1].body_fn()
        local units = stub.added_units()
        assert.is_true(#units >= 2,
            "expected >= 2 units (compile + archive); got " .. tostring(#units))
        assert.equals("build/lib/libmathlib.a", units[#units].output)
    end)

    it("cc.shared body produces compile + shared-link units when invoked", function()
        local targets = require("cook_cc.targets")
        targets.shared("plug", { sources = { "src/plug.c" } })
        recipes[1].body_fn()
        local units = stub.added_units()
        assert.is_true(#units >= 2,
            "expected >= 2 units (compile + link); got " .. tostring(#units))
        assert.equals("build/lib/libplug.so", units[#units].output)
    end)

    it("cc.headers body produces no units (header-only target)", function()
        local targets = require("cook_cc.targets")
        targets.headers("idlib", { export_includes = { "include/" } })
        recipes[1].body_fn()
        assert.equals(0, #stub.added_units())
    end)

    it("cc.headers body calls cook.export with the right includes", function()
        local targets = require("cook_cc.targets")
        targets.headers("idlib", { export_includes = { "include/" } })
        recipes[1].body_fn()
        local info = cook.import("idlib")
        assert.is_table(info)
        assert.same({ "include/" }, info.includes)
    end)

    it("cc.bin body errors when sources list is empty", function()
        local targets = require("cook_cc.targets")
        targets.bin("app", { sources = {} })
        assert.has_error(
            function() recipes[1].body_fn() end,
            "[cc.bin] no sources found for target 'app'"
        )
    end)
end)

describe("cook_cc target-makers: probes register at top level, not in body (CS-0083 Phase 1)", function()
    local recipes

    before_each(function()
        stub.reset()
        recipes = install_deferred()
        stub.set_sh_handler("__exists", function() return true end)
        reset_modules()
        -- NOTE: do NOT call with_toolchain() here — these specs assert that
        -- the target maker itself registers cc:compiler:auto at top-level.
        stub.set_probe_value("cc:compiler:auto", { cxx = "g++", cc = "gcc" })
    end)

    it("cc.bin registers cc:compiler:auto BEFORE body_fn runs", function()
        local targets = require("cook_cc.targets")
        targets.bin("app", { sources = { "src/a.cpp" } })
        local keys_before = stub.probe_keys()
        assert.is_true(#keys_before > 0,
            "expected at least one probe registered before body; got: " .. tostring(#keys_before))
        local has_compiler = false
        for _, k in ipairs(keys_before) do
            if k == "cc:compiler:auto" then has_compiler = true; break end
        end
        assert.is_true(has_compiler,
            "cc:compiler:auto must be registered at top-level before body_fn; got keys: "
            .. table.concat(keys_before, ","))
    end)

    it("cc.bin registers cc:find:<n> for each need BEFORE body_fn runs", function()
        local targets = require("cook_cc.targets")
        targets.bin("app", { sources = { "src/a.cpp" }, needs = { "zlib" } })
        local keys_before = stub.probe_keys()
        local has_zlib = false
        for _, k in ipairs(keys_before) do
            if k == "cc:find:zlib" then has_zlib = true; break end
        end
        assert.is_true(has_zlib,
            "cc:find:zlib must be registered at top-level before body_fn; got keys: "
            .. table.concat(keys_before, ","))
    end)

    it("cc.lib registers cc:find:<n> for each need BEFORE body_fn runs", function()
        local targets = require("cook_cc.targets")
        targets.lib("foolib", { sources = { "src/foo.c" }, needs = { "zlib" } })
        local keys_before = stub.probe_keys()
        local has_zlib = false
        for _, k in ipairs(keys_before) do
            if k == "cc:find:zlib" then has_zlib = true; break end
        end
        assert.is_true(has_zlib,
            "cc:find:zlib must be registered at top-level before body_fn; got keys: "
            .. table.concat(keys_before, ","))
    end)

    it("cc.shared registers cc:find:<n> for each need BEFORE body_fn runs", function()
        local targets = require("cook_cc.targets")
        targets.shared("plug", { sources = { "src/plug.c" }, needs = { "zlib" } })
        local keys_before = stub.probe_keys()
        local has_zlib = false
        for _, k in ipairs(keys_before) do
            if k == "cc:find:zlib" then has_zlib = true; break end
        end
        assert.is_true(has_zlib,
            "cc:find:zlib must be registered at top-level before body_fn; got keys: "
            .. table.concat(keys_before, ","))
    end)

    it("cc.headers registers cc:find:<n> for each need BEFORE body_fn runs", function()
        local targets = require("cook_cc.targets")
        targets.headers("idlib", { export_includes = { "include/" }, needs = { "zlib" } })
        local keys_before = stub.probe_keys()
        local has_zlib = false
        for _, k in ipairs(keys_before) do
            if k == "cc:find:zlib" then has_zlib = true; break end
        end
        assert.is_true(has_zlib,
            "cc:find:zlib must be registered at top-level before body_fn; got keys: "
            .. table.concat(keys_before, ","))
    end)
end)
