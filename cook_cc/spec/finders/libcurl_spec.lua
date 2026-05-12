local stub = require("cook_stub")

describe("finders.libcurl", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.finders.libcurl"] = nil
        package.loaded["cook_cc.finders.pkg_config"] = nil
        stub.set_sh_handler("cc -print-search-dirs",
            function() return "libraries: =/usr/lib\n" end)
    end)

    it("uses curl-config when available", function()
        stub.set_tool_config_response("curl-config --cflags --libs",
            "-I/usr/include/curl -L/usr/lib -lcurl")
        stub.set_tool_config_response("curl-config --version", "libcurl 7.85.0")
        local f = require("cook_cc.finders.libcurl")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.same({ "curl" }, a.payload.system_libs)
        assert.equals("7.85.0", a.payload.version)
    end)

    it("falls back to pkg-config when curl-config absent", function()
        stub.set_pkg_config_response("libcurl", {
            exists = true, cflags = "", libs = "-lcurl", version = "7.85.0",
        })
        local f = require("cook_cc.finders.libcurl")
        local a = f.find({})
        assert.equals("hit", a.outcome)
    end)

    it("miss carries hint", function()
        local f = require("cook_cc.finders.libcurl")
        local a = f.find({})
        assert.equals("miss", a.outcome)
        assert.matches("libcurl4%-openssl%-dev", a.hint)
    end)
end)
