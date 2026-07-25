-- §28.3.10.1 code-generation options + CS-0168 `fpic`.
local stub = require("cook_stub")

local function reset_modules()
    for _, m in ipairs({
        "cook_cc.units.sources", "cook_cc.units.object_path",
        "cook_cc.units.cc", "cook_cc.units.targets", "cook_cc.toolchain",
        "cook_cc.units.transitive", "cook_cc.codegen.config_header",
    }) do package.loaded[m] = nil end
end

local function in_recipe(name, fn)
    cook.recipe(name, {}, fn)
end

local function compile_cmds()
    local out = {}
    for _, u in ipairs(stub.added_units()) do
        if u.output and u.output:match("%.o$") then out[#out + 1] = u.command end
    end
    return out
end

local function link_cmd()
    for _, u in ipairs(stub.added_units()) do
        if u.output and (u.output:match("^build/bin/") or u.output:match("%.so$")) then
            return u.command
        end
    end
end

describe("codegen options", function()
    before_each(function()
        stub.reset(); stub.install()
        reset_modules()
        stub.set_sh_handler("__exists", function() return true end)
        stub.set_sh_handler("pwd", function() return "/proj\n" end)
        require("cook_cc.toolchain").set({})
    end)

    describe("optimize", function()
        local cases = {
            { preset = "none",  expect = "%-O0" },
            { preset = "debug", expect = "%-Og" },
            { preset = "size",  expect = "%-Os %-DNDEBUG" },
            { preset = "speed", expect = "%-O2 %-DNDEBUG" },
            { preset = "max",   expect = "%-O3 %-DNDEBUG" },
        }
        for _, c in ipairs(cases) do
            it("maps preset '" .. c.preset .. "'", function()
                local targets = require("cook_cc.units.targets")
                in_recipe("app", function()
                    targets.bin({ sources = { "src/a.cpp" }, optimize = c.preset })
                end)
                assert.matches(c.expect, compile_cmds()[1])
            end)
        end

        it("passes an unrecognised string through as raw flags", function()
            local targets = require("cook_cc.units.targets")
            in_recipe("app", function()
                targets.bin({ sources = { "src/a.cpp" }, optimize = "-Ofast -funroll-loops" })
            end)
            assert.matches("%-Ofast %-funroll%-loops", compile_cmds()[1])
        end)

        it("emits nothing when unset", function()
            local targets = require("cook_cc.units.targets")
            in_recipe("app", function()
                targets.bin({ sources = { "src/a.cpp" } })
            end)
            assert.is_nil(compile_cmds()[1]:match("%-O%w"))
        end)
    end)

    -- Independent of optimize: max + symbols is the ordinary
    -- shippable-with-symbols build; neither option may suppress the other.
    it("emits -g alongside -O3 when both are requested", function()
        local targets = require("cook_cc.units.targets")
        in_recipe("app", function()
            targets.bin({ sources = { "src/a.cpp" }, optimize = "max", debug_symbols = true })
        end)
        local cmd = compile_cmds()[1]
        assert.matches("%-O3", cmd)
        assert.matches("%-g", cmd)
    end)

    describe("gc_sections", function()
        -- The whole point of the option: emitting the compile half alone is
        -- silent and strictly costly. One option, both halves.
        it("emits BOTH the compile flags and the linker's collection flag", function()
            local targets = require("cook_cc.units.targets")
            in_recipe("app", function()
                targets.bin({ sources = { "src/a.cpp" }, gc_sections = true })
            end)
            assert.matches("%-ffunction%-sections", compile_cmds()[1])
            assert.matches("%-fdata%-sections", compile_cmds()[1])
            assert.matches("%-Wl,%-%-gc%-sections", link_cmd())
        end)

        it("uses -dead_strip on macOS", function()
            stub.set_platform_os("macos")
            local targets = require("cook_cc.units.targets")
            in_recipe("app", function()
                targets.bin({ sources = { "src/a.cpp" }, gc_sections = true })
            end)
            assert.matches("%-Wl,%-dead_strip", link_cmd())
        end)

        it("emits neither half when unset", function()
            local targets = require("cook_cc.units.targets")
            in_recipe("app", function()
                targets.bin({ sources = { "src/a.cpp" } })
            end)
            assert.is_nil(compile_cmds()[1]:match("function%-sections"))
            assert.is_nil(link_cmd():match("gc%-sections"))
        end)

        -- A lib emits an archive and never a link, so only the compile half
        -- applies there; the linking target supplies the other half itself.
        it("contributes only the compile half on a lib", function()
            local targets = require("cook_cc.units.targets")
            in_recipe("mathlib", function()
                targets.lib({ sources = { "src/a.cpp" }, gc_sections = true })
            end)
            assert.matches("%-ffunction%-sections", compile_cmds()[1])
        end)
    end)

    describe("toolchain-wide vs per-target", function()
        it("applies a toolchain-wide setting to every target", function()
            require("cook_cc.toolchain").set({ optimize = "max", gc_sections = true })
            local targets = require("cook_cc.units.targets")
            in_recipe("app", function()
                targets.bin({ sources = { "src/a.cpp" } })
            end)
            assert.matches("%-O3", compile_cmds()[1])
            assert.matches("%-Wl,%-%-gc%-sections", link_cmd())
        end)

        it("lets a target override the toolchain-wide value", function()
            require("cook_cc.toolchain").set({ optimize = "max" })
            local targets = require("cook_cc.units.targets")
            in_recipe("app", function()
                targets.bin({ sources = { "src/a.cpp" }, optimize = "none" })
            end)
            local cmd = compile_cmds()[1]
            assert.matches("%-O0", cmd)
            assert.is_nil(cmd:match("%-O3"))
        end)
    end)

    describe("fpic", function()
        it("is off by default on a lib", function()
            local targets = require("cook_cc.units.targets")
            in_recipe("mathlib", function()
                targets.lib({ sources = { "src/a.cpp" } })
            end)
            assert.is_nil(compile_cmds()[1]:match("%-fPIC"))
        end)

        it("can be requested on a lib destined for a shared library", function()
            local targets = require("cook_cc.units.targets")
            in_recipe("mathlib", function()
                targets.lib({ sources = { "src/a.cpp" }, fpic = true })
            end)
            assert.matches("%-fPIC", compile_cmds()[1])
        end)

        it("stays on by default for shared", function()
            local targets = require("cook_cc.units.targets")
            in_recipe("plug", function()
                targets.shared({ sources = { "src/a.cpp" } })
            end)
            assert.matches("%-fPIC", compile_cmds()[1])
        end)

        it("can be turned off explicitly on shared", function()
            local targets = require("cook_cc.units.targets")
            in_recipe("plug", function()
                targets.shared({ sources = { "src/a.cpp" }, fpic = false })
            end)
            assert.is_nil(compile_cmds()[1]:match("%-fPIC"))
        end)
    end)
end)
