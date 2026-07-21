local stub = require("cook_stub")

describe("finders.raylib", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.discovery.finders.raylib"] = nil
        package.loaded["cook_cc.discovery.finders.pkg_config"] = nil
        package.loaded["cook_cc.discovery.finders.bare_probe"] = nil
        stub.set_sh_handler("cc -print-search-dirs",
            function() return "libraries: =/usr/lib\n" end)
    end)

    it("Linux: pkg-config raylib hit", function()
        stub.set_pkg_config_response("raylib", {
            exists = true, cflags = "-I/usr/include",
            libs = "-lraylib -lm -ldl -lpthread", version = "4.5.0",
        })
        local f = require("cook_cc.discovery.finders.raylib")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.equals("4.5.0", a.payload.version)
    end)

    it("macOS: post-processes frameworks when missing", function()
        stub.set_platform_os("macos")
        stub.set_pkg_config_response("raylib", {
            exists = true, cflags = "", libs = "-lraylib", version = "4.5.0",
        })
        local f = require("cook_cc.discovery.finders.raylib")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        local has_opengl = false
        for _, fw in ipairs(a.payload.frameworks) do
            if fw == "OpenGL" then has_opengl = true end
        end
        assert.is_true(has_opengl)
    end)

    it("version constraint enforced", function()
        stub.set_pkg_config_response("raylib", {
            exists = true, cflags = "", libs = "-lraylib", version = "3.0.0",
        })
        local f = require("cook_cc.discovery.finders.raylib")
        local a = f.find({ version = ">=4.0" })
        assert.equals("miss", a.outcome)
        assert.matches("3%.0%.0", a.reason)
    end)

    it("miss carries hint", function()
        local f = require("cook_cc.discovery.finders.raylib")
        local a = f.find({})
        assert.equals("miss", a.outcome)
        assert.matches("libraylib%-dev", a.hint)
    end)
end)
