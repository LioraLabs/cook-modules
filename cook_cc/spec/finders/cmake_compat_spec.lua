local stub = require("cook_stub")

local function reload()
    package.loaded["cook_cc.discovery.finders.cmake_compat"] = nil
    return require("cook_cc.discovery.finders.cmake_compat")
end

describe("cmake_compat driver probe", function()
    before_each(function() stub.reset(); stub.install() end)

    -- Regression (0.7.1): module top-level must NOT register the probe.
    -- The worker VM re-requires this module from `cmake_strategy` inside
    -- execute-phase probe bodies, where `cook.probe` is a register-only
    -- guard. Registration now happens explicitly via
    -- `ensure_probe_registered()` from
    -- `cook_cc.discovery.finder.register_find_probe` during register phase.
    it("require alone does NOT register cc:cmake-driver", function()
        reload()
        local keys = stub.probe_keys()
        for _, k in ipairs(keys) do
            assert.are_not.equal("cc:cmake-driver", k,
                "module top-level must be free of register-only side effects")
        end
    end)

    it("ensure_probe_registered() registers cc:cmake-driver", function()
        local cm = reload()
        cm.ensure_probe_registered()
        local opts = stub.probe_opts("cc:cmake-driver")
        assert.is_not_nil(opts)
        assert.is_string(opts.produce)
    end)

    it("ensure_probe_registered() is idempotent", function()
        local cm = reload()
        cm.ensure_probe_registered()
        cm.ensure_probe_registered()
        local count = 0
        for _, k in ipairs(stub.probe_keys()) do
            if k == "cc:cmake-driver" then count = count + 1 end
        end
        assert.equals(1, count)
    end)

    it("probe inputs declare only the cmake tool", function()
        local cm = reload()
        cm.ensure_probe_registered()
        local opts = stub.probe_opts("cc:cmake-driver")
        assert.same({ "cmake" }, opts.inputs.tools or {})
    end)

    it("probe inputs include CMAKE_PREFIX_PATH env", function()
        local cm = reload()
        cm.ensure_probe_registered()
        local opts = stub.probe_opts("cc:cmake-driver")
        local has_env = false
        for _, e in ipairs(opts.inputs.env or {}) do if e == "CMAKE_PREFIX_PATH" then has_env = true end end
        assert.is_true(has_env)
    end)

    it("driver() reads probe value store, returns nil when no cmake", function()
        stub.set_probe_value("cc:cmake-driver", nil)
        local cm = reload()
        assert.is_nil(cm.driver())
    end)

    it("driver() returns the cached driver record on hit", function()
        stub.set_probe_value("cc:cmake-driver", { binary = "/usr/bin/cmake", version = "3.27.0" })
        local cm = reload()
        assert.same({ binary = "/usr/bin/cmake", version = "3.27.0" }, cm.driver())
    end)
end)
