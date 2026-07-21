local stub = require("cook_stub")

local function reload()
    package.loaded["cook_cc.codegen.config_header_renderer"] = nil
    return require("cook_cc.codegen.config_header_renderer")
end

-- Helper for tests: capture render output to a string via a fake file-write hook.
local captured = {}
local function setup_captures()
    captured = {}
    _G.fs = _G.fs or {}
    _G.fs.read  = function(p) return captured["__read:" .. p] or "" end
    _G.fs.write = function(p, content) captured[p] = content end
    _G.fs.mkdir_p = function() end
    _G.fs.exists  = function(p) return captured["__read:" .. p] ~= nil end
end

describe("cook_cc.codegen.config_header_renderer.render", function()
    before_each(function() stub.reset(); stub.install(); setup_captures() end)

    it("substitutes @VAR@ with stringified value", function()
        local r = reload()
        captured["__read:in.h.in"] = "version = @VERSION@\n"
        r.render("in.h.in", "out.h", { VERSION = "1.2.3" })
        assert.equals("version = 1.2.3\n", captured["out.h"])
    end)

    it("substitutes ${VAR} identically to @VAR@", function()
        local r = reload()
        captured["__read:in.h.in"] = "version = ${VERSION}\n"
        r.render("in.h.in", "out.h", { VERSION = "1.2.3" })
        assert.equals("version = 1.2.3\n", captured["out.h"])
    end)

    it("#cmakedefine: truthy yields #define", function()
        local r = reload()
        captured["__read:in.h.in"] = "#cmakedefine HAVE_X\n"
        r.render("in.h.in", "out.h", { HAVE_X = true })
        assert.equals("#define HAVE_X\n", captured["out.h"])
    end)

    it("#cmakedefine: falsy yields /* #undef */", function()
        local r = reload()
        captured["__read:in.h.in"] = "#cmakedefine HAVE_X\n"
        r.render("in.h.in", "out.h", { HAVE_X = false })
        assert.equals("/* #undef HAVE_X */\n", captured["out.h"])
    end)

    it("#cmakedefine with VALUE expands inner @VAR@", function()
        local r = reload()
        captured["__read:in.h.in"] = "#cmakedefine VERSION \"@VERSION@\"\n"
        r.render("in.h.in", "out.h", { VERSION = "1.2.3" })
        assert.equals("#define VERSION \"1.2.3\"\n", captured["out.h"])
    end)

    it("#cmakedefine01: truthy yields #define X 1", function()
        local r = reload()
        captured["__read:in.h.in"] = "#cmakedefine01 HAVE_X\n"
        r.render("in.h.in", "out.h", { HAVE_X = true })
        assert.equals("#define HAVE_X 1\n", captured["out.h"])
    end)

    it("#cmakedefine01: falsy yields #define X 0", function()
        local r = reload()
        captured["__read:in.h.in"] = "#cmakedefine01 HAVE_X\n"
        r.render("in.h.in", "out.h", { HAVE_X = false })
        assert.equals("#define HAVE_X 0\n", captured["out.h"])
    end)

    it("missing @VAR@ substitutes empty (Lua truthiness only false/nil are false)", function()
        local r = reload()
        captured["__read:in.h.in"] = "x = @MISSING@\n"
        r.render("in.h.in", "out.h", {})
        assert.equals("x = \n", captured["out.h"])
    end)

    it("#cmakedefine with 0 (truthy in Lua) yields #define", function()
        local r = reload()
        captured["__read:in.h.in"] = "#cmakedefine HAVE_ZERO\n"
        r.render("in.h.in", "out.h", { HAVE_ZERO = 0 })
        assert.equals("#define HAVE_ZERO\n", captured["out.h"])
    end)
end)
