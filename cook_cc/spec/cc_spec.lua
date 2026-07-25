local stub = require("cook_stub")

local function with_toolchain()
    stub.set_probe_value("cc:compiler:auto", { cxx = "g++", cc = "gcc" })
    require("cook_cc.toolchain").ensure_probe_registered()
end

describe("cc.compile", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        package.loaded["cook_cc.units.cc"] = nil
        package.loaded["cook_cc.toolchain"] = nil
        with_toolchain()
    end)

    it("emits a $<cc:compiler:auto.cxx> sigil command for a .cpp source", function()
        local cc = require("cook_cc.units.cc")
        local obj = cc.compile("src/main.cpp", { target_name = "app" })
        local units = stub.added_units()
        assert.equals(1, #units)
        assert.equals("build/obj/app/src/main.cpp.o", units[1].output)
        assert.matches("^%$<cc:compiler:auto%.cxx> ", units[1].command)
        assert.matches(" %-c ", units[1].command)
        assert.matches(" src/main%.cpp ", units[1].command)
        assert.equals(obj, "build/obj/app/src/main.cpp.o")
    end)

    it("emits a $<cc:compiler:auto.cc> sigil command for a .c source", function()
        local cc = require("cook_cc.units.cc")
        cc.compile("src/main.c", { target_name = "app" })
        assert.matches("^%$<cc:compiler:auto%.cc> ", stub.added_units()[1].command)
    end)

    it("includes -std flag for C++ sources when standard is set", function()
        local cc = require("cook_cc.units.cc")
        cc.compile("src/main.cpp", { target_name = "app", standard = "c++17" })
        assert.matches(" %-std=c%+%+17 ", stub.added_units()[1].command)
    end)

    it("does not pass -std to C sources", function()
        local cc = require("cook_cc.units.cc")
        cc.compile("src/main.c", { target_name = "app", standard = "c++17" })
        assert.is_falsy(stub.added_units()[1].command:match("%-std="))
    end)

    it("appends -I and -D from opts", function()
        local cc = require("cook_cc.units.cc")
        cc.compile("src/main.cpp", {
            target_name = "app",
            includes = { "include/" },
            defines = { "FOO=1" },
        })
        local cmd = stub.added_units()[1].command
        assert.matches(" %-Iinclude/ ", cmd)
        assert.matches(" %-DFOO=1 ", cmd)
    end)

    it("emits -MMD -MF <dep_file> for header dep tracking", function()
        local cc = require("cook_cc.units.cc")
        cc.compile("src/main.cpp", { target_name = "app" })
        local u = stub.added_units()[1]
        assert.matches(" %-MMD ", u.command)
        assert.matches(" %-MF ", u.command)
        assert.equals("make", u.discovered_inputs.format)
        -- The depfile mirrors the object path, so translation units sharing a
        -- basename get distinct depfiles.
        assert.matches("%.cook/deps/build/obj/app/src/main%.cpp%.o%.d$", u.discovered_inputs.from)
    end)

    it("gives same-basename sources distinct objects and depfiles", function()
        local cc = require("cook_cc.units.cc")
        cc.compile("src/a/util.cpp", { target_name = "app" })
        cc.compile("src/b/util.cpp", { target_name = "app" })
        local units = stub.added_units()
        assert.equals("build/obj/app/src/a/util.cpp.o", units[1].output)
        assert.equals("build/obj/app/src/b/util.cpp.o", units[2].output)
        assert.are_not.equals(units[1].output, units[2].output)
        assert.are_not.equals(
            units[1].discovered_inputs.from,
            units[2].discovered_inputs.from
        )
    end)

    -- §28.3.5.1 forbids deriving the object path by folding separators into a
    -- flat name, because that transform is not injective either. This is the
    -- pair that proves it: both spellings fold to `dictionary_compression`.
    it("keeps a/b.cpp distinct from a_b.cpp (sanitisation would alias them)", function()
        local cc = require("cook_cc.units.cc")
        cc.compile("src/dictionary_compression.cpp", { target_name = "app" })
        cc.compile("src/dictionary/compression.cpp", { target_name = "app" })
        local units = stub.added_units()
        assert.are_not.equals(units[1].output, units[2].output)
    end)

    -- The extension is retained rather than replaced: one target may legally
    -- compile both, and they dispatch to different drivers.
    it("keeps foo.c distinct from foo.cpp", function()
        local cc = require("cook_cc.units.cc")
        cc.compile("src/foo.c", { target_name = "app" })
        cc.compile("src/foo.cpp", { target_name = "app" })
        local units = stub.added_units()
        assert.equals("build/obj/app/src/foo.c.o", units[1].output)
        assert.equals("build/obj/app/src/foo.cpp.o", units[2].output)
    end)

    -- fs.glob hands back ABSOLUTE paths; an author writes the relative form.
    -- Both spellings of one source must derive one object, or a globbed target
    -- and a listed target disagree about what they already built.
    it("derives one object from either spelling of the same source", function()
        local cc = require("cook_cc.units.cc")
        stub.set_sh_handler("pwd", function() return "/proj\n" end)
        cc.compile("/proj/src/main.cpp", { target_name = "app" })
        assert.equals("build/obj/app/src/main.cpp.o", stub.added_units()[1].output)
    end)

    it("still honours an explicit opts.output verbatim", function()
        local cc = require("cook_cc.units.cc")
        local obj = cc.compile("src/main.cpp", { target_name = "app", output = "custom/x.o" })
        assert.equals("custom/x.o", obj)
        assert.equals("custom/x.o", stub.added_units()[1].output)
    end)

    it("seals the resolved toolchain probe as an auditable determinant (§12.7.5)", function()
        local cc = require("cook_cc.units.cc")
        cc.compile("src/main.cpp", { target_name = "app" })
        local u = stub.added_units()[1]
        assert.same({ "cc:compiler:auto" }, u.probes)
        assert.same(u.probes, u.seal)
    end)
end)

describe("cc.archive", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        package.loaded["cook_cc.units.cc"] = nil
        package.loaded["cook_cc.toolchain"] = nil
        with_toolchain()
    end)

    it("emits an `ar rcs` command with the given objects + output", function()
        local cc = require("cook_cc.units.cc")
        cc.archive({ "build/obj/a/x.o", "build/obj/a/y.o" }, "build/lib/liba.a")
        local u = stub.added_units()[1]
        assert.matches("^ar rcs build/lib/liba%.a ", u.command)
        assert.matches("build/obj/a/x%.o", u.command)
        assert.matches("build/obj/a/y%.o", u.command)
        assert.equals("build/lib/liba.a", u.output)
    end)
end)

describe("cc.link", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        package.loaded["cook_cc.units.cc"] = nil
        package.loaded["cook_cc.toolchain"] = nil
        with_toolchain()
    end)

    it("emits a $<cc:compiler:auto.cxx> link with -l<name> per system_lib", function()
        local cc = require("cook_cc.units.cc")
        cc.link(
            { "build/obj/app/main.o" },
            "build/bin/app",
            { system_libs = { "m", "pthread" } }
        )
        local cmd = stub.added_units()[1].command
        assert.matches("^%$<cc:compiler:auto%.cxx> ", cmd)
        assert.matches(" %-o build/bin/app ", cmd)
        assert.matches(" %-lm ", cmd)
        assert.matches(" %-lpthread ", cmd)
    end)

    it("seals the resolved compiler + finder probes as auditable determinants (§12.7.5)", function()
        local cc = require("cook_cc.units.cc")
        cc.link(
            { "build/obj/app/main.o" },
            "build/bin/app",
            { needs = { "sdl2" } }
        )
        local u = stub.added_units()[1]
        local sealed = {}
        for _, k in ipairs(u.seal or {}) do sealed[k] = true end
        assert.is_true(sealed["cc:compiler:auto"], "expected cc:compiler:auto in seal")
        assert.is_true(sealed["cc:find:sdl2"], "expected cc:find:sdl2 in seal")
    end)
end)

describe("cc.link frameworks", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.units.cc"] = nil
        package.loaded["cook_cc.toolchain"] = nil
        with_toolchain()
    end)

    it("emits -framework <name> on macOS", function()
        stub.set_platform_os("macos")
        local cc = require("cook_cc.units.cc")
        cc.link({ "a.o" }, "build/bin/x", { frameworks = { "OpenGL", "Cocoa" } })
        local cmd = stub.added_units()[1].command
        assert.matches("%-framework OpenGL", cmd)
        assert.matches("%-framework Cocoa", cmd)
    end)

    it("ignores frameworks on Linux", function()
        local cc = require("cook_cc.units.cc")
        cc.link({ "a.o" }, "build/bin/x", { frameworks = { "OpenGL" } })
        local cmd = stub.added_units()[1].command
        assert.is_nil(cmd:find("%-framework"))
    end)
end)
