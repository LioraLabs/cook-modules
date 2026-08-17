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

    -- CS-0244 removed `opts.inputs.env`, and cook rejects it at register
    -- phase, so this asserts the absence where it used to assert presence.
    -- CMAKE_PREFIX_PATH does not move this probe's value anyway: the binary,
    -- its version and legacy support are the same whatever the prefix path.
    it("probe declares no env inputs (CS-0244)", function()
        local cm = reload()
        cm.ensure_probe_registered()
        local opts = stub.probe_opts("cc:cmake-driver")
        assert.is_nil(opts.inputs.env)
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
