local stub = require("cook_stub")

-- 0.13.0: `needs` is REFERENCE-ONLY. The probe is declared at top level by
-- cook_cc.uses(name); the maker (now a step contributor, run inside a recipe
-- body) only references it and wires the sigils. Each test declares the probe
-- with cc.uses(...) FIRST, then calls the maker inside a recipe body.

local function reload_all()
    for _, m in ipairs({
        "cook_cc.toolchain", "cook_cc.finder", "cook_cc.targets",
        "cook_cc.cc", "cook_cc.transitive", "cook_cc.finders.bare_probe",
        "cook_cc.finders.cmake_compat", "cook_cc",
    }) do package.loaded[m] = nil end
    return require("cook_cc")
end

describe("targets.bin with needs={...}", function()
    before_each(function() stub.reset(); stub.install() end)

    it("registers cc:find:<name> probe for each entry in needs", function()
        local cc = reload_all()
        stub.set_file_exists("src/main.c", true)
        cc.uses("raylib")                   -- top-level probe declaration
        cook.recipe("game", {}, function()
            cc.bin({ sources = {"src/main.c"}, needs = { "raylib" } })
        end)
        assert.is_not_nil(stub.probe_opts("cc:find:raylib"))
    end)

    it("registers one probe per needs entry across multiple targets", function()
        local cc = reload_all()
        stub.set_file_exists("src/main.c", true)
        stub.set_file_exists("src/editor.c", true)
        cc.uses("raylib")                   -- idempotent, declared once
        cook.recipe("game", {}, function()
            cc.bin({ sources = {"src/main.c"}, needs = { "raylib" } })
        end)
        cook.recipe("editor", {}, function()
            cc.bin({ sources = {"src/editor.c"}, needs = { "raylib" } })
        end)
        local count = 0
        for _, k in ipairs(stub.probe_keys()) do
            if k == "cc:find:raylib" then count = count + 1 end
        end
        assert.equals(1, count)
    end)

    it("compile units carry probes = {cc:compiler:auto, cc:find:raylib}", function()
        local cc = reload_all()
        stub.set_file_exists("src/main.c", true)
        cc.uses("raylib")
        cook.recipe("game", {}, function()
            cc.bin({ sources = {"src/main.c"}, needs = { "raylib" } })
        end)
        local units = stub.added_units()
        local compile_unit
        for _, u in ipairs(units) do
            if u.output and u.output:match("%.o$") then compile_unit = u; break end
        end
        assert.is_not_nil(compile_unit)
        local p = {}
        for _, k in ipairs(compile_unit.probes or {}) do p[k] = true end
        assert.is_true(p["cc:find:raylib"], "expected cc:find:raylib in compile-unit probes")
        assert.is_true(p["cc:compiler:auto"], "expected cc:compiler:auto in compile-unit probes")
    end)

    it("link unit command embeds $<cc:find:raylib.libs> sigil", function()
        local cc = reload_all()
        stub.set_file_exists("src/main.c", true)
        cc.uses("raylib")
        cook.recipe("game", {}, function()
            cc.bin({ sources = {"src/main.c"}, needs = { "raylib" } })
        end)
        local units = stub.added_units()
        local link_unit
        for _, u in ipairs(units) do
            if u.output and u.output:match("build/bin/game$") then link_unit = u; break end
        end
        assert.is_not_nil(link_unit)
        assert.matches("%$<cc:find:raylib%.libs>", link_unit.command)
    end)

    it("compile unit command embeds $<cc:find:raylib.cflags> sigil", function()
        local cc = reload_all()
        stub.set_file_exists("src/main.c", true)
        cc.uses("raylib")
        cook.recipe("game", {}, function()
            cc.bin({ sources = {"src/main.c"}, needs = { "raylib" } })
        end)
        local units = stub.added_units()
        local compile_unit
        for _, u in ipairs(units) do
            if u.output and u.output:match("%.o$") then compile_unit = u; break end
        end
        assert.matches("%$<cc:find:raylib%.cflags>", compile_unit.command)
    end)

    it("errors when needs references an undeclared probe", function()
        local cc = reload_all()
        stub.set_file_exists("src/main.c", true)
        assert.has_error(function()
            cook.recipe("game", {}, function()
                cc.bin({ sources = {"src/main.c"}, needs = { "raylib" } })
            end)
        end, "[cc.bin] needs \"raylib\" is not declared; add cook_cc.uses(\"raylib\") at top level")
    end)

    it("compile command uses $<cc:compiler:auto.cc> sigil for C sources, not literal compiler", function()
        local cc = reload_all()
        stub.set_file_exists("src/main.c", true)
        cook.recipe("game", {}, function()
            cc.bin({ sources = {"src/main.c"} })   -- .c source -> .cc field
        end)
        local units = stub.added_units()
        local compile_unit
        for _, u in ipairs(units) do
            if u.output and u.output:match("%.o$") then compile_unit = u; break end
        end
        assert.matches("^%$<cc:compiler:auto%.cc>", compile_unit.command)
    end)

    it("compile command uses $<cc:compiler:auto.cxx> sigil for C++ sources", function()
        local cc = reload_all()
        stub.set_file_exists("src/main.cpp", true)
        cook.recipe("game", {}, function()
            cc.bin({ sources = {"src/main.cpp"} })
        end)
        local units = stub.added_units()
        local compile_unit
        for _, u in ipairs(units) do
            if u.output and u.output:match("%.o$") then compile_unit = u; break end
        end
        assert.matches("^%$<cc:compiler:auto%.cxx>", compile_unit.command)
    end)

    it("link command uses $<cc:compiler:auto.cxx> sigil", function()
        local cc = reload_all()
        stub.set_file_exists("src/main.c", true)
        cook.recipe("game", {}, function()
            cc.bin({ sources = {"src/main.c"} })
        end)
        local units = stub.added_units()
        local link_unit
        for _, u in ipairs(units) do
            if u.output and u.output:match("build/bin/game$") then link_unit = u; break end
        end
        assert.matches("^%$<cc:compiler:auto%.cxx>", link_unit.command)
    end)
end)
