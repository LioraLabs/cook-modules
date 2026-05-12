local stub = require("cook_stub")

describe("finders.sdl2", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.finders.sdl2"] = nil
        package.loaded["cook_cc.finders.pkg_config"] = nil
    end)

    it("sdl2-config preferred", function()
        stub.set_tool_config_response("sdl2-config --cflags --libs",
            "-I/usr/include/SDL2 -L/usr/lib -lSDL2")
        stub.set_tool_config_response("sdl2-config --version", "2.30.1")
        local f = require("cook_cc.finders.sdl2")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.same({ "SDL2" }, a.payload.system_libs)
        assert.equals("2.30.1", a.payload.version)
    end)

    it("falls back to pkg-config sdl2", function()
        stub.set_pkg_config_response("sdl2", {
            exists = true, cflags = "", libs = "-lSDL2", version = "2.30.1",
        })
        local f = require("cook_cc.finders.sdl2")
        local a = f.find({})
        assert.equals("hit", a.outcome)
    end)

    it("miss carries hint", function()
        local f = require("cook_cc.finders.sdl2")
        local a = f.find({})
        assert.equals("miss", a.outcome)
        assert.matches("libsdl2%-dev", a.hint)
    end)
end)
