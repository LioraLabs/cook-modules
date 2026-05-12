local stub = require("cook_stub")

local function reset_all()
    stub.reset(); stub.install()
    package.loaded["cook_cc.finders.cmake_compat"] = nil
    package.loaded["cook_cc.finders.cmake_compat.hints"] = nil
end

local function install_cmake_present()
    stub.set_sh_handler("command -v cmake", function() return "/usr/bin/cmake\n" end)
    stub.set_sh_handler("cmake --find-package -DNAME=ZLIB",
        function() return "ZLIB found.\n" end)
end

describe("cmake_compat strategy", function()
    before_each(reset_all)

    it("module loads cleanly", function()
        local mod = require("cook_cc.finders.cmake_compat")
        assert.is_function(mod.main_chain)
    end)

    it("skips when opts.version is set, without touching cmake", function()
        local sh_called = false
        stub.set_sh_handler("cmake ", function() sh_called = true; return "" end)
        local mod = require("cook_cc.finders.cmake_compat")
        local a = mod.main_chain("Anything", { version = ">=1.0" })
        assert.equals("cmake-compat", a.strategy)
        assert.equals("skip", a.outcome)
        assert.matches("version detection unsupported", a.reason)
        assert.is_false(sh_called)
    end)

    it("skips when cmake is not on PATH", function()
        stub.set_sh_handler("command -v cmake", function() return "" end)
        local mod = require("cook_cc.finders.cmake_compat")
        local a = mod.main_chain("SDL3")
        assert.equals("skip", a.outcome)
        assert.matches("cmake binary not on PATH", a.reason)
        assert.matches("install cmake", a.hint)
    end)

    it("skips when --find-package legacy mode is unsupported", function()
        stub.set_sh_handler("command -v cmake", function() return "/usr/bin/cmake" end)
        stub.set_sh_handler("cmake --find-package -DNAME=ZLIB",
            function() return "Unknown option: --find-package" end)
        local mod = require("cook_cc.finders.cmake_compat")
        local a = mod.main_chain("SDL3")
        assert.equals("skip", a.outcome)
        assert.matches("legacy mode", a.reason)
    end)

    it("returns miss when EXIST reports not found", function()
        install_cmake_present()
        stub.set_sh_handler("cmake --find-package -DNAME=DoesNotExist",
            function() error("[stub] cmake exit 1: DoesNotExist not found.") end)
        local mod = require("cook_cc.finders.cmake_compat")
        local a = mod.main_chain("DoesNotExist")
        assert.equals("miss", a.outcome)
        assert.matches("cmake found no Config or Find module", a.reason)
        -- Generic hint fallback because DoesNotExist not in catalog
        assert.matches("cmake %-%-find%-package %-DNAME=DoesNotExist", a.hint)
    end)
end)
