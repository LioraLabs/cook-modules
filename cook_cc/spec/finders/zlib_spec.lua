local stub = require("cook_stub")

describe("finders.zlib", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.finders.zlib"] = nil
        package.loaded["cook_cc.finders.pkg_config"] = nil
        package.loaded["cook_cc.finders.bare_probe"] = nil
        stub.set_sh_handler("cc -print-search-dirs",
            function() return "libraries: =/usr/lib\n" end)
    end)

    it("Linux happy path via pkg-config", function()
        stub.set_pkg_config_response("zlib", {
            exists = true, cflags = "", libs = "-lz", version = "1.2.13",
        })
        local f = require("cook_cc.finders.zlib")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.same({ "z" }, a.payload.system_libs)
        assert.equals("1.2.13", a.payload.version)
    end)

    it("falls back to bare probe when pkg-config misses", function()
        stub.set_file_exists("/usr/lib/libz.so", true)
        local f = require("cook_cc.finders.zlib")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.same({ "z" }, a.payload.system_libs)
    end)

    it("miss emits install hint", function()
        local f = require("cook_cc.finders.zlib")
        local a = f.find({})
        assert.equals("miss", a.outcome)
        assert.matches("zlib1g%-dev", a.hint)
    end)

    it("version-undetectable + constraint → miss", function()
        stub.set_file_exists("/usr/lib/libz.so", true)
        local f = require("cook_cc.finders.zlib")
        local a = f.find({ version = ">=1.0" })
        assert.equals("miss", a.outcome)
    end)
end)
