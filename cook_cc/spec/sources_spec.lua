-- §28.3.1.1 source selection: literals, globs, `!`-exclusions.
local stub = require("cook_stub")

local function reset_modules()
    for _, m in ipairs({
        "cook_cc.units.sources", "cook_cc.units.object_path",
        "cook_cc.units.cc", "cook_cc.units.targets", "cook_cc.toolchain",
    }) do package.loaded[m] = nil end
end

describe("source selection", function()
    local sources

    before_each(function()
        stub.reset(); stub.install()
        reset_modules()
        stub.set_sh_handler("pwd", function() return "/proj\n" end)
        sources = require("cook_cc.units.sources")
    end)

    it("expands a glob include to workspace-relative paths", function()
        stub.set_glob("src/**/*.cpp", { "/proj/src/a.cpp", "/proj/src/sub/b.cpp" })
        local out = sources.resolve({ sources = { "src/**/*.cpp" } }, "app")
        assert.same({ "src/a.cpp", "src/sub/b.cpp" }, out)
    end)

    it("subtracts a `!` exclusion", function()
        stub.set_glob("src/**/*.cpp", { "/proj/src/a.cpp", "/proj/src/skip.cpp" })
        local out = sources.resolve({
            sources = { "src/**/*.cpp", "!src/skip.cpp" },
        }, "app")
        assert.same({ "src/a.cpp" }, out)
    end)

    it("subtracts a glob exclusion", function()
        stub.set_glob("src/**/*.cpp", { "/proj/src/a.cpp", "/proj/src/x_gen.cpp" })
        stub.set_glob("src/**/*_gen.cpp", { "/proj/src/x_gen.cpp" })
        local out = sources.resolve({
            sources = { "src/**/*.cpp", "!src/**/*_gen.cpp" },
        }, "app")
        assert.same({ "src/a.cpp" }, out)
    end)

    -- §28.3.1.1: "Item order MUST NOT affect the result."
    it("resolves independently of item order", function()
        stub.set_glob("src/**/*.cpp", { "/proj/src/a.cpp", "/proj/src/skip.cpp" })
        local forward = sources.resolve({
            sources = { "src/**/*.cpp", "!src/skip.cpp" },
        }, "app")
        local backward = sources.resolve({
            sources = { "!src/skip.cpp", "src/**/*.cpp" },
        }, "app")
        assert.same(forward, backward)
    end)

    -- Overlapping includes must not register two units with one output —
    -- the ambiguous graph §28.3.5.1 exists to prevent, via another door.
    it("collapses a source contributed by two overlapping globs", function()
        stub.set_glob("src/**/*.cpp", { "/proj/src/a.cpp" })
        stub.set_glob("src/*.cpp", { "/proj/src/a.cpp" })
        local out = sources.resolve({
            sources = { "src/**/*.cpp", "src/*.cpp" },
        }, "app")
        assert.same({ "src/a.cpp" }, out)
    end)

    it("collapses a literal that a glob also matched", function()
        stub.set_glob("src/**/*.cpp", { "/proj/src/a.cpp" })
        stub.set_file_exists("src/a.cpp", true)
        local out = sources.resolve({
            sources = { "src/**/*.cpp", "src/a.cpp" },
        }, "app")
        assert.same({ "src/a.cpp" }, out)
    end)

    -- Source order reaches the ar/link command strings, which are cache-key
    -- determinants. Filesystem order must not leak into the key.
    it("sorts deterministically regardless of glob return order", function()
        stub.set_glob("src/**/*.cpp", { "/proj/src/z.cpp", "/proj/src/a.cpp", "/proj/src/m.cpp" })
        local out = sources.resolve({ sources = { "src/**/*.cpp" } }, "app")
        assert.same({ "src/a.cpp", "src/m.cpp", "src/z.cpp" }, out)
    end)

    -- The rule with the most practical bite: a stale directory in one pattern
    -- silently drops a subtree and resurfaces as an undefined symbol at link.
    it("errors on an include pattern that matches nothing", function()
        local ok, err = pcall(function()
            sources.resolve({ sources = { "src/**/*.cpp" } }, "app")
        end)
        assert.is_false(ok)
        assert.matches("matched no files", err)
        assert.matches("src/%*%*/%*%.cpp", err)
        assert.matches("app", err)
    end)

    it("does NOT error on an exclusion that matches nothing", function()
        stub.set_glob("src/**/*.cpp", { "/proj/src/a.cpp" })
        local out = sources.resolve({
            sources = { "src/**/*.cpp", "!src/never/*.cpp" },
        }, "app")
        assert.same({ "src/a.cpp" }, out)
    end)

    it("errors on a literal source that does not exist", function()
        local ok, err = pcall(function()
            sources.resolve({ sources = { "src/missing.cpp" } }, "app")
        end)
        assert.is_false(ok)
        assert.matches("source not found", err)
        assert.matches("app", err)
    end)

    it("accepts a literal exclusion for a file that is absent", function()
        stub.set_glob("src/**/*.cpp", { "/proj/src/a.cpp" })
        local out = sources.resolve({
            sources = { "src/**/*.cpp", "!src/never_existed.cpp" },
        }, "app")
        assert.same({ "src/a.cpp" }, out)
    end)

    it("normalises absolute and relative spellings to one entry", function()
        stub.set_glob("src/**/*.cpp", { "/proj/src/a.cpp" })
        stub.set_file_exists("/proj/src/a.cpp", true)
        local out = sources.resolve({
            sources = { "src/**/*.cpp", "/proj/src/a.cpp" },
        }, "app")
        assert.same({ "src/a.cpp" }, out)
    end)

    it("still supports the legacy `dir` form without erroring on empty extensions", function()
        stub.set_glob("src/**/*.cpp", { "/proj/src/a.cpp" })
        -- no .c / .cc / .cxx in this tree; that is ordinary, not an error
        local out = sources.resolve({ dir = "src/" }, "app")
        assert.same({ "src/a.cpp" }, out)
    end)
end)
