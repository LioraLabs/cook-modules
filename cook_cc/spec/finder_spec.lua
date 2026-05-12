local stub = require("cook_stub")

describe("cc.find integration", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc"] = nil
        package.loaded["cook_cc.finder"] = nil
        package.loaded["cook_cc.finders"] = nil
        package.loaded["cook_cc.finders.pkg_config"] = nil
        package.loaded["cook_cc.finders.bare_probe"] = nil
        stub.set_sh_handler("cc -print-search-dirs",
            function() return "libraries: =/usr/lib\n" end)
    end)

    it("pkg-config hit populates v0.2 fields", function()
        stub.set_pkg_config_response("foo", {
            exists = true, cflags = "-I/usr/include/foo -DFOO=1",
            libs = "-L/usr/lib -lfoo -lpthread", version = "1.0",
        })
        local cc = require("cook_cc")
        local r = cc.find("foo")
        assert.is_true(r.found)
        assert.equals("-I/usr/include/foo -DFOO=1", r.cflags)
        assert.same({ "foo", "pthread" }, r.system_libs)
        assert.is_table(r.tried)
    end)

    it("miss returns blank result with tried list", function()
        local cc = require("cook_cc")
        local r = cc.find("definitely_no_such_package_xyz_42")
        assert.is_false(r.found)
        assert.same({}, r.system_libs)
        assert.is_table(r.tried)
    end)
end)

describe("cc.find_or_error", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc"] = nil
        package.loaded["cook_cc.finder"] = nil
        package.loaded["cook_cc.finders"] = nil
        package.loaded["cook_cc.finders.pkg_config"] = nil
        package.loaded["cook_cc.finders.bare_probe"] = nil
        stub.set_sh_handler("cc -print-search-dirs",
            function() return "libraries: =/usr/lib\n" end)
    end)

    it("returns the result on hit", function()
        stub.set_pkg_config_response("zlib", {
            exists = true, cflags = "", libs = "-lz", version = "1.2.13",
        })
        local cc = require("cook_cc")
        local r = cc.find_or_error("zlib")
        assert.is_true(r.found)
    end)

    it("raises on miss with formatted tried list", function()
        local cc = require("cook_cc")
        assert.error_matches(function() cc.find_or_error("nonesuch") end,
            "%[cc%.find_or_error%].*nonesuch")
    end)
end)

describe("cc.register_finder", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc"] = nil
        package.loaded["cook_cc.finder"] = nil
    end)

    it("raises when finder is not a function", function()
        local cc = require("cook_cc")
        assert.has_error(function() cc.register_finder("bad", "not a fn") end)
    end)
end)
