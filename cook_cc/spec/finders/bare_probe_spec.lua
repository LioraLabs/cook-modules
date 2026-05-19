local stub = require("cook_stub")

local function reload()
    package.loaded["cook_cc.finders.bare_probe"] = nil
    return require("cook_cc.finders.bare_probe")
end

describe("bare_probe linker-search-dirs probe", function()
    before_each(function() stub.reset(); stub.install() end)

    -- Regression (0.7.1): module top-level must NOT register the probe.
    -- The worker VM re-requires this module from `bare_strategy` /
    -- `cmake_strategy` / curated finders inside execute-phase probe
    -- bodies, where `cook.probe` is a register-only guard. Registration
    -- now happens explicitly via `ensure_probe_registered()` from
    -- `cook_cc.finder.register_find_probe` during register phase.
    it("require alone does NOT register cc:linker-search-dirs", function()
        reload()
        local keys = stub.probe_keys()
        for _, k in ipairs(keys) do
            assert.are_not.equal("cc:linker-search-dirs", k,
                "module top-level must be free of register-only side effects")
        end
    end)

    it("ensure_probe_registered() registers cc:linker-search-dirs", function()
        local bare = reload()
        bare.ensure_probe_registered()
        local keys = stub.probe_keys()
        local found = false
        for _, k in ipairs(keys) do if k == "cc:linker-search-dirs" then found = true end end
        assert.is_true(found, "expected cc:linker-search-dirs probe to be registered")
    end)

    it("ensure_probe_registered() is idempotent", function()
        local bare = reload()
        bare.ensure_probe_registered()
        bare.ensure_probe_registered()
        local count = 0
        for _, k in ipairs(stub.probe_keys()) do
            if k == "cc:linker-search-dirs" then count = count + 1 end
        end
        assert.equals(1, count)
    end)

    it("probe inputs declare only the tools the produce body invokes", function()
        local bare = reload()
        bare.ensure_probe_registered()
        local opts = stub.probe_opts("cc:linker-search-dirs")
        local tools = opts.inputs.tools or {}
        -- Probe invokes `cc -print-search-dirs` — only `cc` should be declared.
        assert.same({ "cc" }, tools)
    end)

    it("probe inputs include LIBRARY_PATH env", function()
        local bare = reload()
        bare.ensure_probe_registered()
        local opts = stub.probe_opts("cc:linker-search-dirs")
        local has_libpath = false
        for _, e in ipairs(opts.inputs.env or {}) do if e == "LIBRARY_PATH" then has_libpath = true end end
        assert.is_true(has_libpath, "expected LIBRARY_PATH in probe inputs.env")
    end)

    it("try() consults probe value store for search dirs", function()
        stub.set_probe_value("cc:linker-search-dirs", { "/opt/raylib/lib", "/usr/lib" })
        stub.set_file_exists("/opt/raylib/lib/libraylib.so", true)
        local bare = reload()
        local r = bare.try("raylib")
        assert.is_not_nil(r)
        assert.equals("bare-probe", r.strategy)
        assert.equals("hit", r.outcome)
    end)

    it("try() falls back to /usr/lib + /usr/local/lib when probe value unset", function()
        stub.set_file_exists("/usr/lib/libfoo.so", true)
        local bare = reload()
        local r = bare.try("foo")
        assert.is_not_nil(r)
        assert.equals("hit", r.outcome)
    end)
end)
