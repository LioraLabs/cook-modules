local stub = require("cook_stub")

describe("transitive", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.transitive"] = nil
    end)

    it("returns empty merge when links is empty", function()
        local t = require("cook_cc.transitive")
        local merged = t.resolve_links({})
        assert.same({}, merged.includes)
        assert.same({}, merged.defines)
        assert.same({}, merged.system_libs)
        assert.equals("", merged.extra_ldflags)
    end)

    it("merges single-target export fields", function()
        cook.export("mathlib", {
            includes = { "include/" },
            defines = { "MATHLIB" },
            system_libs = { "m" },
            extra_ldflags = "-Wl,-rpath,/lib",
        })
        local t = require("cook_cc.transitive")
        local merged = t.resolve_links({ "mathlib" })
        assert.same({ "include/" }, merged.includes)
        assert.same({ "MATHLIB" }, merged.defines)
        assert.same({ "m" }, merged.system_libs)
        assert.equals("-Wl,-rpath,/lib", merged.extra_ldflags)
    end)

    it("deduplicates across multiple link targets", function()
        cook.export("a", { includes = { "x" }, system_libs = { "m" } })
        cook.export("b", { includes = { "x" }, system_libs = { "pthread", "m" } })
        local t = require("cook_cc.transitive")
        local merged = t.resolve_links({ "a", "b" })
        assert.same({ "x" }, merged.includes)
        assert.same({ "m", "pthread" }, (function()
            local sorted = {}
            for _, v in ipairs(merged.system_libs) do sorted[#sorted + 1] = v end
            table.sort(sorted); return sorted
        end)())
    end)

    it("transitively follows the `links` chain", function()
        cook.export("a", { includes = { "a_inc" }, links = { "b" } })
        cook.export("b", { includes = { "b_inc" } })
        local t = require("cook_cc.transitive")
        local merged = t.resolve_links({ "a" })
        table.sort(merged.includes)
        assert.same({ "a_inc", "b_inc" }, merged.includes)
    end)

    it("does not infinitely recurse on a cycle", function()
        cook.export("a", { includes = { "ai" }, links = { "b" } })
        cook.export("b", { includes = { "bi" }, links = { "a" } })
        local t = require("cook_cc.transitive")
        local merged = t.resolve_links({ "a" })
        table.sort(merged.includes)
        assert.same({ "ai", "bi" }, merged.includes)
    end)

    it("CS-cook_cc-0.1.1: resolve_links collects lib_path from each link's export", function()
        cook.export("foolib", {
            includes  = {},
            defines   = {},
            system_libs = {},
            extra_ldflags = "",
            links     = {},
            lib_path  = "build/lib/libfoolib.a",
        })
        local t = require("cook_cc.transitive")
        local merged = t.resolve_links({ "foolib" })
        assert.same({ "build/lib/libfoolib.a" }, merged.lib_paths)
    end)

    it("propagates frameworks from a linked target", function()
        cook.export("gfx", {
            includes = {}, system_libs = {}, frameworks = { "OpenGL" },
            extra_ldflags = "", links = {}, lib_path = "",
        })
        local t = require("cook_cc.transitive")
        local merged = t.resolve_links({ "gfx" })
        assert.same({ "OpenGL" }, merged.frameworks)
    end)
end)
