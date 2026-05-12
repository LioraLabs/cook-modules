local stub = require("cook_stub")

local function reset_all()
    stub.reset(); stub.install()
    package.loaded["cook_cc.finder"] = nil
    package.loaded["cook_cc.finders.pkg_config"] = nil
    package.loaded["cook_cc.finders.bare_probe"] = nil
    package.loaded["cook_cc.finders.cmake_compat"] = nil
    package.loaded["cook_cc.finders.cmake_compat.hints"] = nil
    package.loaded["cook_cc.finders"] = nil
    stub.set_sh_handler("cc -print-search-dirs",
        function() return "libraries: =/usr/lib\n" end)
    -- Default: cmake not on PATH, so cmake-compat skips cleanly.
    -- Individual tests override this when they want cmake-compat to run.
    stub.set_sh_handler("command -v cmake",
        function() return "" end)
end

describe("finder resolver", function()
    before_each(reset_all)

    it("returns blank result + tried list on full miss", function()
        local f = require("cook_cc.finder")
        local r = f.find("nonesuch")
        assert.is_false(r.found)
        assert.is_table(r.tried)
        assert.is_true(#r.tried >= 2)
        assert.same({}, r.system_libs)
    end)

    it("caches result by name+opts", function()
        local f = require("cook_cc.finder")
        local r1 = f.find("nonesuch")
        local r2 = f.find("nonesuch")
        assert.equals(r1, r2)
    end)

    it("project-registered finder runs first and wins", function()
        local f = require("cook_cc.finder")
        f.register("zzz", function(_opts)
            return { found = true, cflags = "", libs = "-lzzz",
                     system_libs = {"zzz"}, include_dirs = {}, lib_dirs = {},
                     frameworks = {}, version = "9.9.9", tried = {} }
        end)
        local r = f.find("zzz")
        assert.is_true(r.found)
        assert.same({ "zzz" }, r.system_libs)
        assert.equals("project:zzz", r.tried[1].strategy)
        assert.equals("hit", r.tried[1].outcome)
    end)

    it("re-registration replaces silently", function()
        local f = require("cook_cc.finder")
        local hits = 0
        f.register("zzz", function(_) hits = hits + 1
            return { found = true, cflags = "", libs = "", system_libs = {},
                     include_dirs = {}, lib_dirs = {}, frameworks = {}, tried = {} } end)
        f.register("zzz", function(_) hits = hits + 100
            return { found = true, cflags = "", libs = "", system_libs = {},
                     include_dirs = {}, lib_dirs = {}, frameworks = {}, tried = {} } end)
        f.find("zzz")
        assert.equals(100, hits)
    end)

    it("falls through to pkg-config when curated/project all miss", function()
        stub.set_pkg_config_response("zlib", {
            exists = true, cflags = "", libs = "-lz", version = "1.2.13",
        })
        local f = require("cook_cc.finder")
        local r = f.find("zlib")
        assert.is_true(r.found)
        assert.equals("1.2.13", r.version)
    end)

    it("cache key distinguishes opts", function()
        local f = require("cook_cc.finder")
        stub.set_pkg_config_response("zlib", {
            exists = true, cflags = "", libs = "-lz", version = "1.2.13",
        })
        local r1 = f.find("zlib")
        local r2 = f.find("zlib", { version = ">=99.0" })
        assert.is_true(r1.found)
        assert.is_false(r2.found)
    end)

    it("consults cmake-compat after pkg-config in the default chain", function()
        stub.set_sh_handler("command -v cmake", function() return "/usr/bin/cmake\n" end)
        stub.set_sh_handler("cmake --find-package -DNAME=ZLIB",
            function() return "ZLIB found.\n" end)  -- driver-detect probe
        stub.set_sh_handler("cmake --find-package -DNAME=Vendor",
            function(cmd)
                if cmd:match("MODE=EXIST")   then return "Vendor found.\n" end
                if cmd:match("MODE=COMPILE") then return "-I/opt/vendor/include\n" end
                if cmd:match("MODE=LINK")    then return "/opt/vendor/lib/libvendor.so\n" end
                error("unhandled")
            end)
        local f = require("cook_cc.finder")
        local r = f.find("Vendor")
        assert.is_true(r.found)
        local strategies = {}
        for _, a in ipairs(r.tried) do strategies[#strategies + 1] = a.strategy end
        -- chain order: project, curated, pkg-config, cmake-compat
        assert.equals("project:Vendor",  strategies[1])
        assert.equals("curated:Vendor",  strategies[2])
        assert.equals("pkg-config",      strategies[3])
        assert.equals("cmake-compat",    strategies[4])
    end)

    it("lifts cmake-compat to position 3 when opts.cmake=true; pkg-config skipped", function()
        stub.set_sh_handler("command -v cmake", function() return "/usr/bin/cmake\n" end)
        stub.set_sh_handler("cmake --find-package -DNAME=ZLIB",
            function() return "ZLIB found.\n" end)
        stub.set_sh_handler("cmake --find-package -DNAME=SDL3",
            function(cmd)
                if cmd:match("MODE=EXIST")   then return "SDL3 found.\n" end
                if cmd:match("MODE=COMPILE") then return "-I/usr/include/SDL3\n" end
                if cmd:match("MODE=LINK")    then return "/usr/lib/libSDL3.so\n" end
                error("unhandled")
            end)
        -- pkg-config would also succeed; assert it is NOT consulted
        stub.set_pkg_config_response("SDL3", { exists = true, libs = "-lSDL3" })

        local f = require("cook_cc.finder")
        local r = f.find("SDL3", { cmake = true })
        assert.is_true(r.found)
        local strategies = {}
        for _, a in ipairs(r.tried) do strategies[#strategies + 1] = a.strategy end
        assert.equals("project:SDL3",   strategies[1])
        assert.equals("curated:SDL3",   strategies[2])
        assert.equals("cmake-compat",   strategies[3])
        assert.is_nil(strategies[4])  -- chain stops at hit
    end)
end)
