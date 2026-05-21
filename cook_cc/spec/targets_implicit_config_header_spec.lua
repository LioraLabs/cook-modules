-- 0.11.0: target-makers (cc.bin / lib / shared / headers) implicitly pick up
-- config_header recipes registered via cook_cc.defaults({ config_header = ... })
-- and thread them into each recipe's `requires` set, so callers don't restate
-- `requires = { cfg }` on every target. Coexists with the existing
-- opts.links / opts.requires propagation (per cook_cc 0.7.0).

local stub = require("cook_stub")

local function reset_modules()
    for _, m in ipairs({
        "cook_cc.toolchain", "cook_cc.cc", "cook_cc.targets", "cook_cc.transitive",
        "cook_cc.finder", "cook_cc.config_header", "cook_cc.config_header_renderer",
        "cook_cc.checks", "cook_cc._check_helpers",
    }) do
        package.loaded[m] = nil
    end
    package.loaded["cook_cc"] = nil
end

-- Deferred-recipe variant: capture cook.recipe registrations without running
-- bodies. Mirrors targets_recipe_creation_spec.lua so we can read
-- recipes[i].opts.requires directly.
local function install_deferred()
    local recipes = {}
    stub.install()
    _G.cook.recipe = function(name, opts, body_fn)
        recipes[#recipes + 1] = { name = name, opts = opts, body_fn = body_fn }
    end
    return recipes
end

local function find_recipe(recipes, name)
    for _, r in ipairs(recipes) do
        if r.name == name then return r end
    end
end

local function requires_contain(opts, target)
    for _, r in ipairs(opts.requires or {}) do
        if r == target then return true end
    end
    return false
end

describe("cc target-makers thread defaults.config_header into recipe requires", function()
    local recipes

    before_each(function()
        stub.reset()
        recipes = install_deferred()
        stub.set_sh_handler("__exists", function() return true end)
        reset_modules()
        stub.set_probe_value("cc:compiler:auto", { cxx = "g++", cc = "gcc" })
        require("cook_cc.toolchain").ensure_probe_registered()
    end)

    local CFG_RECIPE = "__cc_config_header__build_config_h"

    local function with_default_cfg()
        local tc = require("cook_cc.toolchain")
        tc.merge_defaults({
            config_header = { from = "config.h.in", to = "build/config.h", vars = {} },
        })
    end

    it("cc.bin's requires contain the defaults.config_header recipe", function()
        with_default_cfg()
        local targets = require("cook_cc.targets")
        targets.bin("game", { sources = { "src/main.c" } })
        local r = find_recipe(recipes, "game")
        assert.is_not_nil(r, "cc.bin must register a recipe named 'game'")
        assert.is_true(requires_contain(r.opts, CFG_RECIPE),
            "cc.bin requires must contain " .. CFG_RECIPE)
    end)

    it("cc.lib's requires contain the defaults.config_header recipe", function()
        with_default_cfg()
        local targets = require("cook_cc.targets")
        targets.lib("foo", { sources = { "src/foo.c" } })
        local r = find_recipe(recipes, "foo")
        assert.is_not_nil(r)
        assert.is_true(requires_contain(r.opts, CFG_RECIPE))
    end)

    it("cc.shared's requires contain the defaults.config_header recipe", function()
        with_default_cfg()
        local targets = require("cook_cc.targets")
        targets.shared("plugin", { sources = { "src/p.c" } })
        local r = find_recipe(recipes, "plugin")
        assert.is_not_nil(r)
        assert.is_true(requires_contain(r.opts, CFG_RECIPE))
    end)

    it("cc.headers' requires contain the defaults.config_header recipe", function()
        with_default_cfg()
        local targets = require("cook_cc.targets")
        targets.headers("public", {})
        local r = find_recipe(recipes, "public")
        assert.is_not_nil(r)
        assert.is_true(requires_contain(r.opts, CFG_RECIPE))
    end)

    it("coexists with opts.links — both appear in requires", function()
        with_default_cfg()
        local targets = require("cook_cc.targets")
        targets.bin("app", { sources = { "src/a.c" }, links = { "mylib" } })
        local r = find_recipe(recipes, "app")
        assert.is_true(requires_contain(r.opts, CFG_RECIPE), "config_header recipe present")
        assert.is_true(requires_contain(r.opts, "mylib"),   "link target preserved")
    end)

    it("coexists with explicit opts.requires — all three appear", function()
        with_default_cfg()
        local targets = require("cook_cc.targets")
        targets.bin("app", {
            sources  = { "src/a.c" },
            links    = { "mylib" },
            requires = { "explicit-dep" },
        })
        local r = find_recipe(recipes, "app")
        assert.is_true(requires_contain(r.opts, CFG_RECIPE))
        assert.is_true(requires_contain(r.opts, "mylib"))
        assert.is_true(requires_contain(r.opts, "explicit-dep"))
    end)

    it("no defaults.config_header → no implicit requires (pre-0.11 behaviour preserved)", function()
        local targets = require("cook_cc.targets")
        targets.bin("app", { sources = { "src/a.c" }, links = { "x" } })
        local r = find_recipe(recipes, "app")
        assert.same({ "x" }, r.opts.requires)
    end)

    it("multiple defaults.config_header calls → all recipes appear in requires", function()
        local tc = require("cook_cc.toolchain")
        tc.merge_defaults({ config_header = { from = "a.in", to = "build/a.h", vars = {} } })
        tc.merge_defaults({ config_header = { from = "b.in", to = "gen/b.h",   vars = {} } })
        local targets = require("cook_cc.targets")
        targets.lib("foo", { sources = { "src/foo.c" } })
        local r = find_recipe(recipes, "foo")
        assert.is_true(requires_contain(r.opts, "__cc_config_header__build_a_h"))
        assert.is_true(requires_contain(r.opts, "__cc_config_header__gen_b_h"))
    end)
end)
