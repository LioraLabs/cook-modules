local stub = require("cook_stub")

describe("finders.gl", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.finders.gl"] = nil
        package.loaded["cook_cc.finders.pkg_config"] = nil
        package.loaded["cook_cc.finders.bare_probe"] = nil
        stub.set_sh_handler("cc -print-search-dirs",
            function() return "libraries: =/usr/lib\n" end)
    end)

    it("Linux: pkg-config gl wins", function()
        stub.set_pkg_config_response("gl", {
            exists = true, cflags = "", libs = "-lGL", version = "1.0",
        })
        local f = require("cook_cc.finders.gl")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.same({ "GL" }, a.payload.system_libs)
    end)

    it("Linux: bare probe libGL.so fallback", function()
        stub.set_file_exists("/usr/lib/libGL.so", true)
        local f = require("cook_cc.finders.gl")
        local a = f.find({})
        assert.equals("hit", a.outcome)
    end)

    it("macOS returns frameworks={OpenGL}", function()
        stub.set_platform_os("macos")
        local f = require("cook_cc.finders.gl")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.same({ "OpenGL" }, a.payload.frameworks)
    end)

    it("opengl alias resolves via curated registry to gl", function()
        stub.set_pkg_config_response("gl", {
            exists = true, cflags = "", libs = "-lGL", version = "1.0",
        })
        package.loaded["cook_cc.finders"] = nil
        local curated = require("cook_cc.finders")
        local fn = curated.lookup("opengl")
        assert.is_function(fn)
        local a = fn({})
        assert.equals("curated:gl", a.strategy)
    end)
end)
