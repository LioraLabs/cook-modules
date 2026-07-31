local stub = require("cook_stub")

local function reload()
    package.loaded["cook_cc.codegen.config_header"]            = nil
    package.loaded["cook_cc.codegen.config_header_renderer"]   = nil
    package.loaded["cook_cc.discovery.checks"]                   = nil
    package.loaded["cook_cc.discovery._check_helpers"]           = nil
    package.loaded["cook_cc.toolchain"]                = nil
    return require("cook_cc.codegen.config_header")
end

describe("cook_cc.codegen.config_header register-phase behaviour", function()
    before_each(function() stub.reset(); stub.install() end)

    it("registers a cook.add_unit with the template as input and output as output", function()
        local config_header = reload()
        config_header({ from = "raylib.h.in", to = "build/raylib.h", vars = { VERSION = "5.0" } })
        local units = stub.added_units()
        assert.equals(1, #units)
        assert.same({ "raylib.h.in" }, units[1].inputs)
        assert.equals("build/raylib.h", units[1].output)
    end)

    it("collects every $<cc:check:...> sigil into the unit's probes list", function()
        local config_header = reload()
        local checks = require("cook_cc.discovery.checks")
        local sig1 = checks.has_header("stdint.h")
        local sig2 = checks.has_function("strdup")
        config_header({
            from = "raylib.h.in",
            to   = "build/raylib.h",
            vars = {
                HAVE_STDINT_H = sig1,
                HAVE_STRDUP   = sig2,
                VERSION       = "5.0",
            },
        })
        local units = stub.added_units()
        local probes = {}
        for _, p in ipairs(units[1].probes or {}) do probes[p] = true end
        assert.is_true(probes[sig1:match("^%$<(.+)>$")])
        assert.is_true(probes[sig2:match("^%$<(.+)>$")])
    end)

    it("does not include literal scalars in probes", function()
        local config_header = reload()
        config_header({ from = "raylib.h.in", to = "build/raylib.h", vars = { VERSION = "5.0", N = 42, B = true } })
        local units = stub.added_units()
        assert.same({}, units[1].probes or {})
    end)

    it("emits a lua_code body that require()s the renderer BY MODULE NAME (no absolute path, no host lua)", function()
        local config_header = reload()
        config_header({ from = "raylib.h.in", to = "build/raylib.h", vars = { VERSION = "5.0", B = true } })
        local unit = stub.added_units()[1]
        assert.is_nil(unit.command)
        local body = unit.lua_code
        assert.matches('require%("cook_cc%.codegen%.config_header_renderer"%)', body)
        -- No filesystem path may appear: an absolute renderer path in the
        -- unit is a cache-key determinant that re-keys when the workspace
        -- directory moves (CS-0196 portable identity).
        assert.is_nil(body:match("config_header_renderer%.lua"))
        -- The literal scalars are baked into the vars table, typed.
        assert.matches("VERSION%s*=%s*\"5%.0\"", body)
        assert.matches("B%s*=%s*true", body)
    end)

    it("emits typed cook.probes.get reads for check sigils (values never round-trip through text)", function()
        local config_header = reload()
        local checks = require("cook_cc.discovery.checks")
        local sig = checks.has_header("stdint.h")
        config_header({ from = "raylib.h.in", to = "build/raylib.h", vars = { HAVE_STDINT_H = sig } })
        local body = stub.added_units()[1].lua_code
        local probe_key = sig:match("^%$<(.+)>$")
        assert.is_truthy(probe_key)
        assert.is_true(body:find('cook.probes.get("' .. probe_key .. '")', 1, true) ~= nil,
                       "expected typed probes.get read for " .. probe_key .. " in body, got: " .. body)
        -- The raw $<...> sigil must NOT appear: this body is Lua, not a
        -- command string, and the sigil pipeline does not run over it.
        assert.is_nil(body:find(sig, 1, true))
    end)

    it("mints the support recipe with origin = cook_cc.codegen.config_header metadata", function()
        local config_header = reload()
        local recipe_name = config_header({ from = "raylib.h.in", to = "build/raylib.h", vars = { VERSION = "5.0" } })
        assert.equals("__cc_config_header__build_raylib_h", recipe_name)
        local meta = stub.recipe_meta(recipe_name)
        assert.is_not_nil(meta)
        assert.equals("cook_cc.codegen.config_header", meta.origin)
    end)

    it("get_headers() reports the output path and outdir", function()
        local config_header = reload()
        config_header({ from = "c.in", to = "build/dhewm3/config.h", vars = {} })
        local headers = config_header.get_headers()
        assert.equals(1, #headers)
        assert.equals("build/dhewm3/config.h", headers[1].output)
        assert.equals("build/dhewm3", headers[1].outdir)
    end)

    it("errors when `from` is missing", function()
        local config_header = reload()
        assert.has_error(function()
            config_header({ to = "build/config.h", vars = {} })
        end, "[cc.config_header] config_header requires both `from` and `to` fields")
    end)

    it("errors when `to` is missing", function()
        local config_header = reload()
        assert.has_error(function()
            config_header({ from = "c.in", vars = {} })
        end, "[cc.config_header] config_header requires both `from` and `to` fields")
    end)

    it("errors when config_header is declared after a cc target has been registered", function()
        local config_header = reload()
        config_header.mark_target_registered()
        assert.has_error(function()
            config_header({ from = "c.in", to = "build/config.h", vars = {} })
        end, "[cc.config_header] config_header declared after a cc target; declare config_header before cc targets")
    end)
end)
