local stub = require("cook_stub")

describe("cc.find", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.finder"] = nil
    end)

    local function with_pkg(name, cflags, libs)
        stub.set_sh_handler("pkg-config --exists " .. name,
            function() return "" end)
        stub.set_sh_handler("pkg-config --cflags " .. name,
            function() return cflags .. "\n" end)
        stub.set_sh_handler("pkg-config --libs " .. name,
            function() return libs .. "\n" end)
    end

    it("returns the M1 record shape on a hit", function()
        with_pkg("foo", "-I/usr/include/foo -DFOO=1", "-L/usr/lib -lfoo -lpthread")
        local finder = require("cook_cc.finder")
        local r = finder.find("foo")
        assert.is_true(r.found)
        assert.equals("-I/usr/include/foo -DFOO=1", r.cflags)
        assert.equals("-L/usr/lib -lfoo -lpthread", r.libs)
        assert.same({ "/usr/include/foo" }, r.include_dirs)
        assert.same({ "/usr/lib" }, r.lib_dirs)
        assert.same({ "foo", "pthread" }, r.system_libs)
        assert.same({}, r.frameworks)
        assert.is_nil(r.version)
    end)

    it("returns found=false with empty fields on a miss", function()
        stub.set_sh_handler("pkg-config --exists missing",
            function() error("[cook_stub] pkg-config exists missing failed") end)
        local finder = require("cook_cc.finder")
        local r = finder.find("missing")
        assert.is_false(r.found)
        assert.same({}, r.system_libs)
    end)

    it("caches the result keyed by name", function()
        local calls = 0
        local cflags = "-I/a"
        local libs   = "-lfoo"
        stub.set_sh_handler("pkg-config --exists foo", function() return "" end)
        stub.set_sh_handler("pkg-config --cflags foo",
            function() calls = calls + 1; return cflags .. "\n" end)
        stub.set_sh_handler("pkg-config --libs foo",
            function() return libs .. "\n" end)
        local finder = require("cook_cc.finder")
        finder.find("foo"); finder.find("foo")
        assert.equals(1, calls)
    end)

    it("parses framework flags (macOS-style)", function()
        with_pkg("gl", "-I/x", "-lGL -framework OpenGL")
        local finder = require("cook_cc.finder")
        local r = finder.find("gl")
        assert.same({ "OpenGL" }, r.frameworks)
    end)
end)
