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

    it("emits package-specific hint for known catalogue entries", function()
        install_cmake_present()
        -- Make SDL3 EXIST fail without being unhandled
        stub.set_sh_handler("cmake --find-package -DNAME=SDL3",
            function() return "SDL3 not found.\n" end)
        local mod = require("cook_cc.finders.cmake_compat")
        local a = mod.main_chain("SDL3")
        assert.equals("miss", a.outcome)
        assert.matches("libsdl3%-dev", a.hint)
        assert.matches("brew: sdl3", a.hint)
    end)

    it("parses COMPILE output into include_dirs and cflags", function()
        install_cmake_present()
        stub.set_sh_handler("cmake --find-package -DNAME=ZLIB",
            function(cmd)
                if cmd:match("MODE=EXIST")   then return "ZLIB found.\n" end
                if cmd:match("MODE=COMPILE") then return "-I/usr/include\n" end
                if cmd:match("MODE=LINK")    then return "/usr/lib/libz.so\n" end
                error("[stub] unexpected mode: " .. cmd)
            end)
        local mod = require("cook_cc.finders.cmake_compat")
        local a = mod.main_chain("ZLIB")
        assert.equals("hit", a.outcome)
        assert.equals("/usr/include", a.payload.include_dirs[1])
        assert.matches("-I/usr/include", a.payload.cflags)
    end)

    it("classifies -framework / -l / -L tokens in LINK output", function()
        install_cmake_present()
        stub.set_sh_handler("cmake --find-package -DNAME=Mixed",
            function(cmd)
                if cmd:match("MODE=EXIST")   then return "Mixed found.\n" end
                if cmd:match("MODE=COMPILE") then return "-I/opt/mixed/include\n" end
                if cmd:match("MODE=LINK")    then
                    return "/opt/mixed/lib/libmixed.dylib -framework Foundation "
                        .. "-L/opt/mixed/lib -lextra\n"
                end
                error("[stub] unexpected mode: " .. cmd)
            end)
        local mod = require("cook_cc.finders.cmake_compat")
        local a = mod.main_chain("Mixed")
        assert.equals("hit", a.outcome)
        assert.same({"Foundation"}, a.payload.frameworks)
        assert.same({"extra"}, a.payload.system_libs)
        assert.same({"/opt/mixed/lib"}, a.payload.lib_dirs)
        assert.matches("/opt/mixed/lib/libmixed%.dylib", a.payload.libs)
    end)

    it("rejects LINK output containing *Config.cmake (imported-target chain)", function()
        install_cmake_present()
        stub.set_sh_handler("cmake --find-package -DNAME=ChainedFoo",
            function(cmd)
                if cmd:match("MODE=EXIST")   then return "ChainedFoo found.\n" end
                if cmd:match("MODE=COMPILE") then return "-I/usr/include\n" end
                if cmd:match("MODE=LINK")    then
                    return "/usr/lib/libFoo.so /usr/lib/cmake/Bar/BarConfig.cmake\n"
                end
                error("unhandled")
            end)
        local mod = require("cook_cc.finders.cmake_compat")
        local a = mod.main_chain("ChainedFoo")
        assert.equals("miss", a.outcome)
        assert.matches("imported%-target chain too complex", a.reason)
        assert.matches("cc%.register_finder", a.hint)
    end)

    it("also rejects *Targets.cmake references", function()
        install_cmake_present()
        stub.set_sh_handler("cmake --find-package -DNAME=ChainedBar",
            function(cmd)
                if cmd:match("MODE=EXIST")   then return "ChainedBar found.\n" end
                if cmd:match("MODE=COMPILE") then return "\n" end
                if cmd:match("MODE=LINK")    then return "/usr/lib/cmake/Baz/BazTargets.cmake\n" end
                error("unhandled")
            end)
        local mod = require("cook_cc.finders.cmake_compat")
        local a = mod.main_chain("ChainedBar")
        assert.equals("miss", a.outcome)
        assert.matches("imported%-target", a.reason)
    end)
end)
