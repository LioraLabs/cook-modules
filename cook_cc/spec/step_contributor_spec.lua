-- Dedicated required-contract spec file for the cook_cc 0.13.0
-- step-contributor rewrite.
--
-- The design for this rewrite enumerates SEVEN behaviors as REQUIRED.
-- Several of them already have coverage
-- scattered across targets_spec.lua / needs_field_spec.lua /
-- config_header_spec.lua — that's fine, this file is not meant to replace
-- those. It exists so the seven required behaviors are gathered in one
-- greppable, canonically-named place. Search this file for "REQUIRED #<n>"
-- to find each one.
--
-- Uses the DEFAULT stub (inline recipe execution): cook.recipe(name, {},
-- body_fn) runs body_fn synchronously and cook.recipe_name()/recipe.name
-- resolve inside it.

local stub = require("cook_stub")

local function in_recipe(name, fn) cook.recipe(name, {}, fn) end

local function with_toolchain()
    stub.set_probe_value("cc:compiler:auto", { cxx = "g++", cc = "gcc" })
    require("cook_cc.toolchain").ensure_probe_registered()
end

-- Superset reload: everything the seven required specs touch, reloaded
-- together so module-local state (targets._known_list, config_header's
-- state.target_registered, finder._registered) starts fresh AND every
-- submodule that `require`s another reloaded submodule sees the SAME
-- instance (critical for REQUIRED #4: targets.lua and this spec must both
-- observe the one reloaded cook_cc.codegen.config_header instance).
local function reset_modules()
    for _, m in ipairs({
        "cook_cc.toolchain", "cook_cc.units.cc", "cook_cc.units.targets", "cook_cc.units.transitive",
        "cook_cc.discovery.finder", "cook_cc.discovery.finders.bare_probe", "cook_cc.discovery.finders.cmake_compat",
        "cook_cc.codegen.config_header",
    }) do
        package.loaded[m] = nil
    end
    package.loaded["cook_cc"] = nil
end

before_each(function()
    stub.reset(); stub.install()
    stub.set_sh_handler("__exists", function() return true end)
    reset_modules()
    stub.set_probe_value("cc:compiler:auto", { cxx = "g++", cc = "gcc" })
    require("cook_cc.toolchain").ensure_probe_registered()
end)

-- ---------------------------------------------------------------------
-- REQUIRED #1: calling a maker OUTSIDE a recipe block errors.
-- ---------------------------------------------------------------------
describe("REQUIRED #1: maker-outside-recipe error", function()
    it("cc.bin errors when called at top level (not inside a recipe)", function()
        local targets = require("cook_cc.units.targets")
        assert.has_error(function()
            targets.bin({ sources = { "a.cpp" } })
        end, "[cc.bin] must be called inside a recipe block; wrap it in a `recipe` block")
    end)

    it("cc.lib errors when called at top level (not inside a recipe)", function()
        local targets = require("cook_cc.units.targets")
        assert.has_error(function()
            targets.lib({ sources = { "a.c" } })
        end, "[cc.lib] must be called inside a recipe block; wrap it in a `recipe` block")
    end)
end)

-- ---------------------------------------------------------------------
-- REQUIRED #2: `needs` entries must be declared via cook_cc.uses() at top
-- level BEFORE a maker references them.
-- ---------------------------------------------------------------------
describe("REQUIRED #2: undeclared-needs error", function()
    it("errors when needs references a probe that was never declared with cook_cc.uses()", function()
        local targets = require("cook_cc.units.targets")
        assert.has_error(function()
            in_recipe("game", function()
                targets.bin({ sources = { "src/main.c" }, needs = { "sdl2" } })
            end)
        end, "[cc.bin] needs \"sdl2\" is not declared; add cook_cc.uses(\"sdl2\") at top level")
    end)

    it("succeeds once cook_cc.uses() has declared the same name at top level", function()
        local cc = require("cook_cc")
        cc.uses("sdl2")
        in_recipe("game", function()
            cc.bin({ sources = { "src/main.c" }, needs = { "sdl2" } })
        end)
        local compile_unit
        for _, u in ipairs(stub.added_units()) do
            if u.output and u.output:match("%.o$") then compile_unit = u; break end
        end
        assert.is_not_nil(compile_unit, "expected a compile unit to be added")
        local probes = {}
        for _, p in ipairs(compile_unit.probes or {}) do probes[p] = true end
        assert.is_true(probes["cc:find:sdl2"],
            "expected cc:find:sdl2 among the compile unit's probes")
    end)
end)

-- ---------------------------------------------------------------------
-- REQUIRED #3: `links` delegates ordering + unknown-recipe validation to
-- cook.dep_order (CS-0161; was cook.require_recipe before 0.17.0). The module MUST NOT impose its own hard is_known()
-- gate: M._known_list is a per-VM accumulator and cannot see a
-- recipe whose maker body ran in a different worker VM (e.g. `shared`), so
-- a module-side fatal gate spuriously rejects valid cross-recipe links and
-- blocked every dhewm3 build. The engine's dep_order owns both concerns.
-- ---------------------------------------------------------------------
describe("REQUIRED #3: links delegates ordering + validation to dep_order", function()
    it("records a dep_order edge for each link and does NOT raise a module-side gate", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("foolib", function()
            targets.lib({ sources = { "src/foo.c" } })
        end)
        in_recipe("app", function()
            targets.bin({ sources = { "m.cpp" }, links = { "foolib" } })
        end)
        -- The ordering edge is the dep_order call, not a module error.
        -- (before_each resets stub state, so foolib is the only name recorded.)
        assert.same({}, stub.require_recipe_edges())
        assert.same("foolib", stub.dep_order_edges()[1])
    end)

    it("surfaces the engine's unknown-recipe error for a genuine typo (via cook.import, not a module gate)", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("foolib", function()
            targets.lib({ sources = { "src/foo.c" } })
        end)
        local ok, err = pcall(function()
            in_recipe("app", function()
                targets.bin({ sources = { "m.cpp" }, links = { "foolim" } })
            end)
        end)
        assert.is_false(ok)
        assert.is_string(err)
        -- The error originates in cook.import's forcing (the engine's concern),
        -- NOT a cc-module "links references unknown recipe" gate.
        assert.matches("unknown recipe 'foolim'", err, 1, true)
        assert.matches("cook.import", err, 1, true)
    end)
end)

-- ---------------------------------------------------------------------
-- REQUIRED #4: cook_cc.codegen.config_header() must be declared BEFORE any cc
-- target; calling it after one has registered errors.
-- ---------------------------------------------------------------------
describe("REQUIRED #4: config_header-after-target error", function()
    it("errors when config_header() is called after a cc target has already registered", function()
        local targets = require("cook_cc.units.targets")
        local cc      = require("cook_cc")
        in_recipe("app", function()
            targets.bin({ sources = { "src/main.c" } })
        end)
        assert.has_error(function()
            cc.config_header({ from = "c.in", to = "build/config.h", vars = {} })
        end, "[cc.config_header] config_header declared after a cc target; declare config_header before cc targets")
    end)
end)

-- ---------------------------------------------------------------------
-- REQUIRED #5: a linked lib's archive is a declared INPUT on the
-- link unit (not just command-line text).
-- ---------------------------------------------------------------------
describe("REQUIRED #5: dep archive present in link-unit inputs", function()
    it("build/lib/libfoolib.a is in app's link-unit inputs when app links foolib", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("foolib", function()
            targets.lib({ sources = { "foo.c" } })
        end)
        in_recipe("app", function()
            targets.bin({ sources = { "main.c" }, links = { "foolib" } })
        end)
        local units = stub.added_units()
        local link_unit
        for _, u in ipairs(units) do
            if u.output == "build/bin/app" then link_unit = u; break end
        end
        assert.is_not_nil(link_unit, "expected a link unit outputting build/bin/app")
        local found = false
        for _, i in ipairs(link_unit.inputs or {}) do
            if i == "build/lib/libfoolib.a" then found = true end
        end
        assert.is_true(found, "link unit inputs must contain build/lib/libfoolib.a")
    end)
end)

-- ---------------------------------------------------------------------
-- REQUIRED #6 (THE COVERAGE GAP): a generated config header, declared at
-- top level via cook_cc.codegen.config_header(), must show up end-to-end as a
-- declared input on every compile unit for a target declared AFTER it,
-- AND that target's compile commands must auto-gain -I<outdir>.
-- ---------------------------------------------------------------------
describe("REQUIRED #6: generated config header present in compile-unit inputs (end-to-end)", function()
    it("app's compile units declare the config header as an input and gain -I<outdir>", function()
        local cc = require("cook_cc")
        cc.config_header({ from = "config.h.in", to = "build/dhewm3/config.h", vars = {} })

        local targets = require("cook_cc.units.targets")
        in_recipe("app", function()
            targets.bin({ sources = { "src/main.cpp" } })
        end)

        local app_compiles = {}
        for _, u in ipairs(stub.added_units()) do
            if u.output and u.output:match("^build/obj/app/") then
                app_compiles[#app_compiles + 1] = u
            end
        end
        assert.is_true(#app_compiles > 0, "expected at least one compile unit for app")

        for _, u in ipairs(app_compiles) do
            local has_header_input = false
            for _, i in ipairs(u.inputs or {}) do
                if i == "build/dhewm3/config.h" then has_header_input = true end
            end
            assert.is_true(has_header_input,
                "compile unit " .. u.output .. " must declare build/dhewm3/config.h as an input")
            assert.matches("%-Ibuild/dhewm3", u.command,
                "compile unit " .. u.output .. " command must include -Ibuild/dhewm3 (auto-joined outdir)")
        end
    end)
end)

-- ---------------------------------------------------------------------
-- REQUIRED #7: a cook.dep_order ordering edge is declared for each
-- entry in `links`.
-- ---------------------------------------------------------------------
describe("REQUIRED #7: cook.dep_order edge declared for each links entry", function()
    it("declares an edge for every linked recipe, in links order", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("a", function()
            targets.lib({ sources = { "a.c" } })
        end)
        in_recipe("b", function()
            targets.lib({ sources = { "b.c" } })
        end)
        in_recipe("app", function()
            targets.bin({ sources = { "main.c" }, links = { "a", "b" } })
        end)
        -- links order preserved; declare_link_deps forces in order, then
        -- cc.link mints the link unit's own edges in closure walk order.
        assert.same({}, stub.require_recipe_edges())
        assert.same({ "a", "b" }, { stub.dep_order_edges()[1], stub.dep_order_edges()[2] })
    end)
end)

-- ---------------------------------------------------------------------
-- REQUIRED #8: a target declared after cook_cc.codegen.config_header()
-- must declare a cook.require_recipe ORDERING edge to the config_header
-- support recipe — not merely the file-input edge. cook only schedules
-- recipes inside the requested target's require_recipe closure, so without
-- this edge a targeted build (`cook app`) never runs the generator and the
-- compile fails on a missing config.h. The file-input edge (REQUIRED #6)
-- folds the header into the cache key but does NOT pull the recipe in.
-- ---------------------------------------------------------------------
describe("REQUIRED #8: config_header support recipe is an ordering edge on later targets", function()
    it("app declares a require_recipe edge to the config_header support recipe", function()
        local cc = require("cook_cc")
        -- Capture the support-recipe name the module mints.
        local support = cc.config_header({ from = "config.h.in", to = "build/dhewm3/config.h", vars = {} })
        assert.is_string(support)

        local targets = require("cook_cc.units.targets")
        in_recipe("app", function()
            targets.bin({ sources = { "src/main.cpp" } })
        end)

        local found = false
        for _, e in ipairs(stub.require_recipe_edges()) do
            if e == support then found = true end
        end
        assert.is_true(found,
            "a target after config_header() must declare cook.require_recipe('" ..
            support .. "') so the generator is scheduled for a targeted build")
    end)
end)
