local stub = require("cook_stub")

local function reload()
    package.loaded["cook_cc.discovery.checks"]        = nil
    package.loaded["cook_cc.toolchain"]     = nil
    package.loaded["cook_cc.discovery._check_helpers"] = nil
    return require("cook_cc.discovery.checks")
end

describe("cook_cc.discovery.checks.has_header", function()
    before_each(function() stub.reset(); stub.install() end)

    it("returns a sigil string with kind=has-header and the header name", function()
        local checks = reload()
        local s = checks.has_header("stdint.h")
        assert.matches("^%$<cc:check:has%-header:stdint_h:[0-9a-f]+>$", s)
    end)

    it("registers a cc:check:has-header:<name>:<fp> probe", function()
        local checks = reload()
        checks.has_header("stdint.h")
        local found = false
        for _, k in ipairs(stub.probe_keys()) do
            if k:match("^cc:check:has%-header:stdint_h:[0-9a-f]+$") then found = true end
        end
        assert.is_true(found)
    end)

    it("requires cc:compiler:<override-or-auto>", function()
        local checks = reload()
        checks.has_header("stdint.h")
        local key
        for _, k in ipairs(stub.probe_keys()) do
            if k:match("^cc:check:has%-header:") then key = k end
        end
        local opts = stub.probe_opts(key)
        local reqs = {}
        for _, r in ipairs(opts.inputs.requires or {}) do reqs[r] = true end
        assert.is_true(reqs["cc:compiler:auto"])
    end)

    it("is idempotent (same opts → same probe, no duplicate registration)", function()
        local checks = reload()
        local s1 = checks.has_header("stdint.h")
        local s2 = checks.has_header("stdint.h")
        assert.equals(s1, s2)
        local count = 0
        for _, k in ipairs(stub.probe_keys()) do
            if k:match("^cc:check:has%-header:stdint_h:") then count = count + 1 end
        end
        assert.equals(1, count)
    end)

    it("different opts yield different fingerprints (and different keys)", function()
        local checks = reload()
        local s1 = checks.has_header("stdint.h", { standard = "c11" })
        local s2 = checks.has_header("stdint.h", { standard = "c99" })
        assert.is_not.equals(s1, s2)
    end)

    it("same opts produce the same sigil across reloads", function()
        local checks = reload()
        local s = checks.has_header("stdint.h", { standard = "c11" })
        assert.equals(s, checks.has_header("stdint.h", { standard = "c11" }))
    end)
end)

describe("cook_cc.discovery.checks.has_function", function()
    before_each(function() stub.reset(); stub.install() end)

    it("returns a sigil string with kind=has-function and the function name", function()
        local checks = reload()
        local s = checks.has_function("strdup", { includes = { "string.h" } })
        assert.matches("^%$<cc:check:has%-function:strdup:[0-9a-f]+>$", s)
    end)

    it("registers a cc:check:has-function:<name>:<fp> probe", function()
        local checks = reload()
        checks.has_function("strdup", { includes = { "string.h" } })
        local found = false
        for _, k in ipairs(stub.probe_keys()) do
            if k:match("^cc:check:has%-function:strdup:[0-9a-f]+$") then found = true end
        end
        assert.is_true(found)
    end)

    it("is idempotent", function()
        local checks = reload()
        local a = checks.has_function("strdup")
        local b = checks.has_function("strdup")
        assert.equals(a, b)
    end)
end)

describe("cook_cc.discovery.checks.has_define", function()
    before_each(function() stub.reset(); stub.install() end)

    it("returns a sigil string with kind=has-define and the macro name", function()
        local checks = reload()
        local s = checks.has_define("__GNUC__")
        assert.matches("^%$<cc:check:has%-define:__GNUC__:[0-9a-f]+>$", s)
    end)

    it("registers a cc:check:has-define:<name>:<fp> probe", function()
        local checks = reload()
        checks.has_define("__GNUC__")
        local found = false
        for _, k in ipairs(stub.probe_keys()) do
            if k:match("^cc:check:has%-define:__GNUC__:[0-9a-f]+$") then found = true end
        end
        assert.is_true(found)
    end)
end)

describe("cook_cc.discovery.checks.sizeof", function()
    before_each(function() stub.reset(); stub.install() end)

    it("returns a sigil string with kind=sizeof and the type name", function()
        local checks = reload()
        local s = checks.sizeof("long")
        assert.matches("^%$<cc:check:sizeof:long:[0-9a-f]+>$", s)
    end)

    it("registers a cc:check:sizeof:<name>:<fp> probe", function()
        local checks = reload()
        checks.sizeof("long")
        local found = false
        for _, k in ipairs(stub.probe_keys()) do
            if k:match("^cc:check:sizeof:long:[0-9a-f]+$") then found = true end
        end
        assert.is_true(found)
    end)

    it("idempotent across repeat calls", function()
        local checks = reload()
        local a = checks.sizeof("int")
        local b = checks.sizeof("int")
        assert.equals(a, b)
    end)
end)

describe("cook_cc.discovery.checks.endian", function()
    before_each(function() stub.reset(); stub.install() end)

    it("returns a sigil string with kind=endian", function()
        local checks = reload()
        local s = checks.endian()
        assert.matches("^%$<cc:check:endian:_:[0-9a-f]+>$", s)
    end)

    it("registers a cc:check:endian:_:<fp> probe", function()
        local checks = reload()
        checks.endian()
        local found = false
        for _, k in ipairs(stub.probe_keys()) do
            if k:match("^cc:check:endian:_:[0-9a-f]+$") then found = true end
        end
        assert.is_true(found)
    end)
end)

describe("cook_cc.discovery.checks.has_compile_flag", function()
    before_each(function() stub.reset(); stub.install() end)

    it("returns a sigil string with kind=has-compile-flag and the sanitised flag name", function()
        local checks = reload()
        local s = checks.has_compile_flag("-Wno-unused")
        assert.matches("^%$<cc:check:has%-compile%-flag:%-Wno%-unused:[0-9a-f]+>$", s)
    end)

    it("sanitises characters not valid in probe keys", function()
        local checks = reload()
        local s = checks.has_compile_flag("-Wl,--as-needed")
        -- ',' becomes '_'
        assert.matches("^%$<cc:check:has%-compile%-flag:%-Wl_%-%-as%-needed:[0-9a-f]+>$", s)
    end)
end)

describe("cook_cc.discovery.checks.has_link_flag", function()
    before_each(function() stub.reset(); stub.install() end)

    it("returns a sigil string with kind=has-link-flag", function()
        local checks = reload()
        local s = checks.has_link_flag("-Wl,-no-undefined")
        assert.matches("^%$<cc:check:has%-link%-flag:[^>]+:[0-9a-f]+>$", s)
    end)
end)
