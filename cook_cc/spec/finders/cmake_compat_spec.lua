local stub = require("cook_stub")

local function reload()
    package.loaded["cook_cc.finders.cmake_compat"] = nil
    return require("cook_cc.finders.cmake_compat")
end

describe("cmake_compat driver probe", function()
    before_each(function() stub.reset(); stub.install() end)

    it("registers cc:cmake-driver probe on require", function()
        reload()
        local opts = stub.probe_opts("cc:cmake-driver")
        assert.is_not_nil(opts)
        assert.is_string(opts.produce)
    end)

    it("probe inputs declare only the cmake tool", function()
        reload()
        local opts = stub.probe_opts("cc:cmake-driver")
        assert.same({ "cmake" }, opts.inputs.tools or {})
    end)

    it("probe inputs include CMAKE_PREFIX_PATH env", function()
        reload()
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
