local stub = require("cook_stub")

local function reload()
    package.loaded["cook_cc.finder"] = nil
    package.loaded["cook_cc.toolchain"] = nil
    package.loaded["cook_cc.finders.bare_probe"] = nil
    package.loaded["cook_cc.finders.cmake_compat"] = nil
    return require("cook_cc.finder")
end

describe("cc.find probe registration", function()
    before_each(function() stub.reset(); stub.install() end)

    it("find(name) registers cc:find:<name> probe", function()
        local finder = reload()
        finder.find("raylib")
        assert.is_not_nil(stub.probe_opts("cc:find:raylib"))
    end)

    it("find(name) returns a sigil-record", function()
        local finder = reload()
        local r = finder.find("raylib")
        assert.equals("$<cc:find:raylib.cflags>",       r.cflags)
        assert.equals("$<cc:find:raylib.libs>",         r.libs)
        assert.equals("$<cc:find:raylib.include_dirs>", r.include_dirs)
        assert.equals("$<cc:find:raylib.system_libs>",  r.system_libs)
        assert.equals("$<cc:find:raylib.frameworks>",   r.frameworks)
        assert.equals("$<cc:find:raylib.found>",        r.found)
    end)

    it("find(name) is idempotent — duplicate calls do not duplicate probe registration", function()
        local finder = reload()
        finder.find("raylib")
        finder.find("raylib")
        local count = 0
        for _, k in ipairs(stub.probe_keys()) do
            if k == "cc:find:raylib" then count = count + 1 end
        end
        assert.equals(1, count)
    end)

    it("find(name, opts) with conflicting opts on second call raises", function()
        local finder = reload()
        finder.find("raylib", { version = ">=4.0" })
        assert.has_error(function()
            finder.find("raylib", { version = ">=5.0" })
        end)
    end)

    it("find_or_error registers probe and returns sigil-record", function()
        local finder = reload()
        local r = finder.find_or_error("raylib")
        assert.equals("$<cc:find:raylib.cflags>", r.cflags)
    end)

    it("probe inputs include cc:compiler:auto, cc:linker-search-dirs, cc:cmake-driver in requires", function()
        local finder = reload()
        finder.find("raylib")
        local opts = stub.probe_opts("cc:find:raylib")
        local reqs = {}
        for _, k in ipairs(opts.inputs.requires or {}) do reqs[k] = true end
        assert.is_true(reqs["cc:compiler:auto"], "expected cc:compiler:auto in requires")
        assert.is_true(reqs["cc:linker-search-dirs"], "expected cc:linker-search-dirs in requires")
        assert.is_true(reqs["cc:cmake-driver"], "expected cc:cmake-driver in requires")
    end)

    it("register_finder still works for project strategy", function()
        local finder = reload()
        finder.register("raylib", function(_)
            return { found = true, cflags = "-I/from-project", libs = "-lraylib" }
        end)
        -- register() should not raise; it's a function-typecheck only.
    end)

    it("sigil-record cannot be mutated", function()
        local finder = reload()
        local r = finder.find("raylib")
        assert.has_error(function() r.cflags = "spoofed" end)
    end)
end)

describe("cc.uses / is_registered", function()
    before_each(function() stub.reset(); stub.install() end)

    it("uses(...) registers probes for every name passed", function()
        local finder = reload()
        finder.uses("raylib", "sdl2")
        assert.is_not_nil(stub.probe_opts("cc:find:raylib"))
        assert.is_not_nil(stub.probe_opts("cc:find:sdl2"))
    end)

    it("uses(...) is idempotent — calling twice does not duplicate probe registration", function()
        local finder = reload()
        finder.uses("raylib")
        finder.uses("raylib")
        local count = 0
        for _, k in ipairs(stub.probe_keys()) do
            if k == "cc:find:raylib" then count = count + 1 end
        end
        assert.equals(1, count)
    end)

    it("is_registered(name) is false before any find/uses", function()
        local finder = reload()
        assert.is_false(finder.is_registered("raylib"))
    end)

    it("is_registered(name) is true after uses(name)", function()
        local finder = reload()
        finder.uses("raylib")
        assert.is_true(finder.is_registered("raylib"))
    end)

    it("is_registered(name) is false for a name not declared via uses/find", function()
        local finder = reload()
        finder.uses("raylib")
        assert.is_false(finder.is_registered("sdl2"))
    end)
end)
