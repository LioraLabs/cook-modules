-- 0.11.0: cook_cc.defaults({ config_header = { from, to, vars } }) — the
-- caller declares the generated config header once on the toolchain and
-- every cc target picks it up transitively. The toolchain side of the
-- contract:
--   * synthesize the config_header recipe (same shape as a standalone
--     cook_cc.config_header(from, to, vars) call),
--   * append the output's directory to defaults.includes so consumers
--     can `#include "config.h"` without restating the path,
--   * expose the recipe name via toolchain.get_config_header_recipes()
--     so targets.lua can thread it into every cc target's requires.
-- The targets side (implicit requires propagation) lives in
-- targets_implicit_config_header_spec.lua.

local stub = require("cook_stub")

local function reset_modules()
    for _, m in ipairs({
        "cook_cc.toolchain",
        "cook_cc.config_header",
        "cook_cc.config_header_renderer",
        "cook_cc.checks",
        "cook_cc._check_helpers",
    }) do
        package.loaded[m] = nil
    end
end

describe("cook_cc.toolchain.merge_defaults({ config_header = ... })", function()
    before_each(function()
        stub.reset()
        stub.install()
        reset_modules()
    end)

    it("registers a synthetic recipe whose unit matches the standalone config_header behaviour", function()
        local tc = require("cook_cc.toolchain")
        tc.merge_defaults({
            config_header = {
                from = "neo/config.h.in",
                to   = "build/dhewm3/config.h",
                vars = { os = "linux", cpu = "x86_64", FOO = true },
            },
        })
        local units = stub.added_units()
        assert.equals(1, #units)
        assert.same({ "neo/config.h.in" }, units[1].inputs)
        assert.equals("build/dhewm3/config.h", units[1].output)
    end)

    it("appends path.dir(to) to defaults.includes", function()
        local tc = require("cook_cc.toolchain")
        tc.merge_defaults({
            includes      = { "neo/libs/imgui" },
            config_header = {
                from = "neo/config.h.in",
                to   = "build/dhewm3/config.h",
                vars = {},
            },
        })
        local includes = tc.get_defaults().includes
        local seen = {}
        for _, v in ipairs(includes) do seen[v] = true end
        assert.is_true(seen["neo/libs/imgui"], "explicit include preserved")
        assert.is_true(seen["build/dhewm3"], "config_header output dir auto-joined to includes")
    end)

    it("exposes the synthesized recipe name via get_config_header_recipes()", function()
        local tc = require("cook_cc.toolchain")
        tc.merge_defaults({
            config_header = {
                from = "neo/config.h.in",
                to   = "build/dhewm3/config.h",
                vars = {},
            },
        })
        local names = tc.get_config_header_recipes()
        assert.equals(1, #names)
        -- Recipe-name shape per config_header.lua's recipe_name_for():
        --   "__cc_config_header__" .. output:gsub("[/.]", "_")
        assert.equals("__cc_config_header__build_dhewm3_config_h", names[1])
    end)

    it("supports multiple calls — recipes and include dirs both accumulate", function()
        local tc = require("cook_cc.toolchain")
        tc.merge_defaults({
            config_header = { from = "a.in", to = "build/a.h", vars = {} },
        })
        tc.merge_defaults({
            config_header = { from = "b.in", to = "gen/b.h", vars = {} },
        })
        local names = tc.get_config_header_recipes()
        assert.equals(2, #names)
        assert.equals("__cc_config_header__build_a_h", names[1])
        assert.equals("__cc_config_header__gen_b_h", names[2])

        local includes = tc.get_defaults().includes
        local seen = {}
        for _, v in ipairs(includes) do seen[v] = true end
        assert.is_true(seen["build"])
        assert.is_true(seen["gen"])
    end)

    it("merge_defaults without config_header leaves the recipe list and includes untouched", function()
        local tc = require("cook_cc.toolchain")
        tc.merge_defaults({ includes = { "src" }, defines = { "X" } })
        assert.same({}, tc.get_config_header_recipes())
        local includes = tc.get_defaults().includes
        local seen = {}
        for _, v in ipairs(includes) do seen[v] = true end
        assert.is_true(seen["src"])
    end)
end)
