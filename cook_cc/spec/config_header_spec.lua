local stub = require("cook_stub")

local function reload()
    package.loaded["cook_cc.config_header"]            = nil
    package.loaded["cook_cc.config_header_renderer"]   = nil
    package.loaded["cook_cc.checks"]                   = nil
    package.loaded["cook_cc._check_helpers"]           = nil
    package.loaded["cook_cc.toolchain"]                = nil
    return require("cook_cc.config_header")
end

describe("cook_cc.config_header register-phase behaviour", function()
    before_each(function() stub.reset(); stub.install() end)

    it("registers a cook.add_unit with the template as input and output as output", function()
        local config_header = reload()
        config_header("raylib.h.in", "build/raylib.h", { VERSION = "5.0" })
        local units = stub.added_units()
        assert.equals(1, #units)
        assert.same({ "raylib.h.in" }, units[1].inputs)
        assert.equals("build/raylib.h", units[1].output)
    end)

    it("collects every $<cc:check:...> sigil into the unit's probes list", function()
        local config_header = reload()
        local checks = require("cook_cc.checks")
        local sig1 = checks.has_header("stdint.h")
        local sig2 = checks.has_function("strdup")
        config_header("raylib.h.in", "build/raylib.h", {
            HAVE_STDINT_H = sig1,
            HAVE_STRDUP   = sig2,
            VERSION       = "5.0",
        })
        local units = stub.added_units()
        local probes = {}
        for _, p in ipairs(units[1].probes or {}) do probes[p] = true end
        assert.is_true(probes[sig1:match("^%$<(.+)>$")])
        assert.is_true(probes[sig2:match("^%$<(.+)>$")])
    end)

    it("does not include literal scalars in probes", function()
        local config_header = reload()
        config_header("raylib.h.in", "build/raylib.h", { VERSION = "5.0", N = 42, B = true })
        local units = stub.added_units()
        assert.same({}, units[1].probes or {})
    end)

    it("emits a command invoking the renderer with the vars-literal", function()
        local config_header = reload()
        config_header("raylib.h.in", "build/raylib.h", { VERSION = "5.0", B = true })
        local cmd = stub.added_units()[1].command
        assert.matches("config_header_renderer%.lua", cmd)
        -- The literal scalars are baked into the vars-literal arg.
        assert.matches("VERSION%s*=%s*\"5%.0\"", cmd)
        assert.matches("B%s*=%s*true", cmd)
    end)

    it("emits sigils verbatim inside the vars-literal arg (sigil expansion happens at execute)", function()
        local config_header = reload()
        local checks = require("cook_cc.checks")
        local sig = checks.has_header("stdint.h")
        config_header("raylib.h.in", "build/raylib.h", { HAVE_STDINT_H = sig })
        local cmd = stub.added_units()[1].command
        local probe_key = sig:match("^%$<(.+)>$")
        assert.is_true(cmd:find(sig, 1, true) ~= nil,
                       "expected sigil " .. sig .. " in command, got: " .. cmd)
        assert.is_truthy(probe_key)
    end)
end)
