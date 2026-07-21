local stub = require("cook_stub")

describe("finders.openal", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.discovery.finders.openal"] = nil
        package.loaded["cook_cc.discovery.finders.pkg_config"] = nil
        package.loaded["cook_cc.discovery.finders.bare_probe"] = nil
        stub.set_sh_handler("cc -print-search-dirs",
            function() return "libraries: =/usr/lib\n" end)
    end)

    it("Linux: pkg-config openal hit", function()
        stub.set_pkg_config_response("openal", {
            exists = true, cflags = "", libs = "-lopenal", version = "1.21",
        })
        local f = require("cook_cc.discovery.finders.openal")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.same({ "openal" }, a.payload.system_libs)
    end)

    it("Linux: bare probe libopenal.so fallback", function()
        stub.set_file_exists("/usr/lib/libopenal.so", true)
        local f = require("cook_cc.discovery.finders.openal")
        local a = f.find({})
        assert.equals("hit", a.outcome)
    end)

    it("macOS returns frameworks={OpenAL}", function()
        stub.set_platform_os("macos")
        local f = require("cook_cc.discovery.finders.openal")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.same({ "OpenAL" }, a.payload.frameworks)
    end)

    it("Linux miss carries install hint", function()
        local f = require("cook_cc.discovery.finders.openal")
        local a = f.find({})
        assert.equals("miss", a.outcome)
        assert.matches("libopenal%-dev", a.hint)
    end)
end)
