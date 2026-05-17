local stub = require("cook_stub")

local function reload()
    package.loaded["cook_cc.finders.bare_probe"] = nil
    return require("cook_cc.finders.bare_probe")
end

describe("bare_probe linker-search-dirs probe", function()
    before_each(function() stub.reset(); stub.install() end)

    it("registers cc:linker-search-dirs probe on require", function()
        reload()
        local keys = stub.probe_keys()
        local found = false
        for _, k in ipairs(keys) do if k == "cc:linker-search-dirs" then found = true end end
        assert.is_true(found, "expected cc:linker-search-dirs probe to be registered")
    end)

    it("probe inputs declare only the tools the produce body invokes", function()
        reload()
        local opts = stub.probe_opts("cc:linker-search-dirs")
        local tools = opts.inputs.tools or {}
        -- Probe invokes `cc -print-search-dirs` — only `cc` should be declared.
        assert.same({ "cc" }, tools)
    end)

    it("probe inputs include LIBRARY_PATH env", function()
        reload()
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
