local stub = require("cook_stub")

local function reload()
    package.loaded["cook_cc._probe_helpers"] = nil
    return require("cook_cc._probe_helpers")
end

describe("_probe_helpers", function()
    before_each(function() stub.reset(); stub.install() end)

    it("exposes pkg_strategy, cmake_strategy, bare_strategy, curated_strategy, project_strategy, build_result", function()
        local h = reload()
        assert.is_function(h.pkg_strategy)
        assert.is_function(h.cmake_strategy)
        assert.is_function(h.bare_strategy)
        assert.is_function(h.curated_strategy)
        assert.is_function(h.project_strategy)
        assert.is_function(h.build_result)
    end)

    it("pkg_strategy on hit returns hit record", function()
        local h = reload()
        stub.set_pkg_config_response("zlib", { exists = true, cflags = "-I/usr/include", libs = "-lz", version = "1.2.13" })
        local r = h.pkg_strategy("zlib", {})
        assert.equals("hit", r.outcome)
        assert.equals("-lz", r.payload.libs)
    end)

    it("build_result with hit returns found=true record", function()
        local h = reload()
        local hit = { payload = { cflags = "-Ix", libs = "-ly", system_libs = {"y"} } }
        local r = h.build_result(hit, { hit })
        assert.is_true(r.found)
        assert.equals("-Ix", r.cflags)
        assert.equals("-ly", r.libs)
    end)

    it("build_result with no hit returns found=false with tried record", function()
        local h = reload()
        local r = h.build_result(nil, { { strategy = "pkg-config", outcome = "miss" } })
        assert.is_false(r.found)
        assert.equals(1, #r.tried)
    end)

    it("project_strategy returns skip when no registry entry for name", function()
        local h = reload()
        local r = h.project_strategy({}, "nothing", {})
        assert.equals("skip", r.outcome)
    end)

    it("project_strategy returns hit when registry entry returns found=true", function()
        local h = reload()
        local registry = {
            mylib = function(_) return { found = true, cflags = "-I/x", libs = "-lmylib" } end,
        }
        local r = h.project_strategy(registry, "mylib", {})
        assert.equals("hit", r.outcome)
        assert.equals("-lmylib", r.payload.libs)
    end)
end)
