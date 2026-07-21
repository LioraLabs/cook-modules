local stub = require("cook_stub")

describe("finders.sdl2", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.discovery.finders.sdl2"] = nil
        package.loaded["cook_cc.discovery.finders.pkg_config"] = nil
    end)

    it("sdl2-config preferred", function()
        stub.set_tool_config_response("sdl2-config --cflags",
            "-I/usr/include/SDL2 -D_GNU_SOURCE=1 -D_REENTRANT")
        stub.set_tool_config_response("sdl2-config --libs", "-L/usr/lib -lSDL2")
        stub.set_tool_config_response("sdl2-config --version", "2.30.1")
        local f = require("cook_cc.discovery.finders.sdl2")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.same({ "SDL2" }, a.payload.system_libs)
        assert.equals("2.30.1", a.payload.version)
    end)

    it("CS-0084 follow-up: cflags + libs are split, not merged into libs", function()
        -- Pre-0.10.1 bug: the curated sdl2 finder called
        -- `sdl2-config --cflags --libs` and stuffed the combined output
        -- into `libs`, leaving `cflags = ""`. Downstream compiles that
        -- depended on the sigil-resolved cflags ($<cc:find:sdl2.cflags>)
        -- saw an empty string and missed SDL2's include path. The fix
        -- queries the two endpoints separately and stores them split.
        stub.set_tool_config_response("sdl2-config --cflags",
            "-I/usr/include/SDL2 -D_GNU_SOURCE=1 -D_REENTRANT")
        stub.set_tool_config_response("sdl2-config --libs", "-L/usr/lib -lSDL2")
        stub.set_tool_config_response("sdl2-config --version", "2.30.1")
        local f = require("cook_cc.discovery.finders.sdl2")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.equals("-I/usr/include/SDL2 -D_GNU_SOURCE=1 -D_REENTRANT", a.payload.cflags)
        assert.equals("-L/usr/lib -lSDL2", a.payload.libs)
        assert.same({ "/usr/include/SDL2" }, a.payload.include_dirs)
        assert.same({ "/usr/lib" }, a.payload.lib_dirs)
        assert.same({ "SDL2" }, a.payload.system_libs)
    end)

    it("falls back to pkg-config sdl2", function()
        stub.set_pkg_config_response("sdl2", {
            exists = true, cflags = "", libs = "-lSDL2", version = "2.30.1",
        })
        local f = require("cook_cc.discovery.finders.sdl2")
        local a = f.find({})
        assert.equals("hit", a.outcome)
    end)

    it("miss carries hint", function()
        local f = require("cook_cc.discovery.finders.sdl2")
        local a = f.find({})
        assert.equals("miss", a.outcome)
        assert.matches("libsdl2%-dev", a.hint)
    end)
end)
