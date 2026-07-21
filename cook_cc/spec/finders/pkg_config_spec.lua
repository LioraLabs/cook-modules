local stub = require("cook_stub")

describe("finders.pkg_config.try", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.discovery.finders.pkg_config"] = nil
    end)

    it("returns hit Attempt with payload on success", function()
        stub.set_pkg_config_response("zlib", {
            exists = true,
            cflags = "-I/usr/include",
            libs   = "-L/usr/lib -lz",
            version = "1.2.13",
        })
        local pkg = require("cook_cc.discovery.finders.pkg_config")
        local a = pkg.try("zlib")
        assert.equals("hit", a.outcome)
        assert.equals("pkg-config", a.strategy)
        assert.equals("1.2.13", a.payload.version)
        assert.same({ "z" }, a.payload.system_libs)
        assert.same({ "/usr/include" }, a.payload.include_dirs)
        assert.same({ "/usr/lib" }, a.payload.lib_dirs)
        assert.same({}, a.payload.frameworks)
    end)

    it("returns nil on miss", function()
        local pkg = require("cook_cc.discovery.finders.pkg_config")
        local a = pkg.try("nonesuch")
        assert.is_nil(a)
    end)

    it("parses framework tokens", function()
        stub.set_pkg_config_response("gl-macos", {
            exists = true, cflags = "", libs = "-framework OpenGL", version = "1.0",
        })
        local pkg = require("cook_cc.discovery.finders.pkg_config")
        local a = pkg.try("gl-macos")
        assert.same({ "OpenGL" }, a.payload.frameworks)
    end)
end)
