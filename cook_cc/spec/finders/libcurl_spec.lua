local stub = require("cook_stub")

describe("finders.libcurl", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.discovery.finders.libcurl"] = nil
        package.loaded["cook_cc.discovery.finders.pkg_config"] = nil
        stub.set_sh_handler("cc -print-search-dirs",
            function() return "libraries: =/usr/lib\n" end)
    end)

    it("uses curl-config when available", function()
        stub.set_tool_config_response("curl-config --cflags", "-I/usr/include/curl")
        stub.set_tool_config_response("curl-config --libs", "-L/usr/lib -lcurl")
        stub.set_tool_config_response("curl-config --version", "libcurl 7.85.0")
        local f = require("cook_cc.discovery.finders.libcurl")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.same({ "curl" }, a.payload.system_libs)
        assert.equals("7.85.0", a.payload.version)
    end)

    it("0.10.2 follow-up: cflags + libs are split, no leading newline in libs", function()
        -- Pre-0.10.2 bug: the curated libcurl finder called
        -- `curl-config --cflags --libs` in one shot. On systems where
        -- --cflags is empty (Arch/Debian default), the combined output is
        -- `\n-lcurl\n`. After trailing-whitespace strip the libs field
        -- retained a LEADING newline, which split the link command across
        -- /bin/sh -c lines and broke the build.
        stub.set_tool_config_response("curl-config --cflags", "")
        stub.set_tool_config_response("curl-config --libs", "-lcurl")
        stub.set_tool_config_response("curl-config --version", "libcurl 7.85.0")
        local f = require("cook_cc.discovery.finders.libcurl")
        local a = f.find({})
        assert.equals("hit", a.outcome)
        assert.equals("",       a.payload.cflags)
        assert.equals("-lcurl", a.payload.libs)
        assert.same({ "curl" }, a.payload.system_libs)
    end)

    it("falls back to pkg-config when curl-config absent", function()
        stub.set_pkg_config_response("libcurl", {
            exists = true, cflags = "", libs = "-lcurl", version = "7.85.0",
        })
        local f = require("cook_cc.discovery.finders.libcurl")
        local a = f.find({})
        assert.equals("hit", a.outcome)
    end)

    it("miss carries hint", function()
        local f = require("cook_cc.discovery.finders.libcurl")
        local a = f.find({})
        assert.equals("miss", a.outcome)
        assert.matches("libcurl4%-openssl%-dev", a.hint)
    end)
end)
