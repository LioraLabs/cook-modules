local stub = require("cook_stub")

-- 0.13.0: makers are STEP CONTRIBUTORS — they run INSIDE a user-written
-- recipe body and take NO name param. `in_recipe` mints the enclosing recipe
-- (whose name supplies both the bare artifact-path name and the qualified
-- export identity; in the stub they coincide).
local function in_recipe(name, fn) cook.recipe(name, {}, fn) end

local function with_toolchain()
    stub.set_probe_value("cc:compiler:auto", { cxx = "g++", cc = "gcc" })
    require("cook_cc.toolchain").ensure_probe_registered()
end

local function reset_module(name)
    package.loaded[name] = nil
end

describe("cc.bin", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        for _, m in ipairs({
            "cook_cc.toolchain","cook_cc.cc","cook_cc.targets","cook_cc.transitive",
            "cook_cc.config_header",
        }) do reset_module(m) end
        with_toolchain()
    end)

    it("compiles each source and links to build/bin/<name>", function()
        local targets = require("cook_cc.targets")
        in_recipe("app", function()
            targets.bin({ sources = { "src/a.cpp", "src/b.cpp" } })
        end)
        local units = stub.added_units()
        assert.equals(3, #units)  -- two compiles + one link
        assert.equals("build/obj/app/a.o", units[1].output)
        assert.equals("build/obj/app/b.o", units[2].output)
        assert.equals("build/bin/app",     units[3].output)
    end)

    it("registers the compile fan-out inside one step group; link stays sequential", function()
        local targets = require("cook_cc.targets")
        in_recipe("app", function()
            targets.bin({ sources = { "src/a.cpp", "src/b.cpp" } })
        end)
        local groups = stub.step_groups()
        assert.equals(1, #groups)
        assert.same({ 1, 2 }, groups[1])  -- both compiles grouped, link (unit 3) outside
    end)

    it("registers known_targets in module-local state", function()
        local targets = require("cook_cc.targets")
        in_recipe("app", function()
            targets.bin({ sources = { "src/a.cpp" } })
        end)
        assert.same({ "app" }, targets._known())
    end)

    it("calls cook.export with compile_info for compile_commands", function()
        local targets = require("cook_cc.targets")
        in_recipe("app", function()
            targets.bin({ sources = { "src/a.cpp" }, includes = { "inc/" } })
        end)
        local info = cook.import("app")
        assert.is_table(info.compile_info)
        assert.same({ "src/a.cpp" }, info.compile_info.sources)
        assert.same({ "inc/" }, info.compile_info.includes)
    end)

    it("errors if sources is empty and no dir is given", function()
        local targets = require("cook_cc.targets")
        assert.has_error(function()
            in_recipe("app", function() targets.bin({}) end)
        end, "[cc.bin] no sources found for target 'app'")
    end)

    it("errors when called outside a recipe body", function()
        local targets = require("cook_cc.targets")
        assert.has_error(function()
            targets.bin({ sources = { "src/a.cpp" } })
        end, "[cc.bin] must be called inside a recipe block; wrap it in a `recipe` block")
    end)

    it("CS-cook_cc-0.1.1: bin's link command includes archive paths from cc.lib links", function()
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({ sources = { "src/foo.c" } })
        end)
        -- After lib is registered, cook.import("foolib").lib_path must surface.
        local exported = cook.import("foolib")
        assert.equals("build/lib/libfoolib.a", exported.lib_path)

        in_recipe("app", function()
            targets.bin({
                sources = { "src/main.c" },
                links   = { "foolib" },
            })
        end)
        local units = stub.added_units()
        local link_unit = units[#units]  -- last unit is the link command
        assert.matches("build/lib/libfoolib%.a", link_unit.command,
            "link command must include the foolib archive path")
    end)

    it("CS-cook_cc-0.1.1b: bin's link unit folds dep archive paths into inputs", function()
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({ sources = { "src/foo.c" } })
        end)
        in_recipe("app", function()
            targets.bin({
                sources = { "src/main.c" },
                links   = { "foolib" },
            })
        end)
        local units = stub.added_units()
        local link_unit = units[#units]
        local found = false
        for _, i in ipairs(link_unit.inputs or {}) do
            if i == "build/lib/libfoolib.a" then found = true end
        end
        assert.is_true(found, "link unit inputs must fold in the foolib archive path")
    end)

    it("CS-cook_cc-0.1.2: bin's compile commands include export_includes from cc.lib links", function()
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({
                sources = { "src/foo.c" },
                export_includes = { "foolib/include/" },
            })
        end)
        in_recipe("app", function()
            targets.bin({
                sources = { "src/main.c" },
                links   = { "foolib" },
            })
        end)
        -- All compile units for app must include -Ifoolib/include/
        local units = stub.added_units()
        local app_compiles = {}
        for _, u in ipairs(units) do
            if u.output and u.output:match("^build/obj/app/") then
                app_compiles[#app_compiles + 1] = u
            end
        end
        assert.is_true(#app_compiles > 0, "expected at least one compile for app")
        for _, u in ipairs(app_compiles) do
            assert.matches(" %-Ifoolib/include/ ", u.command,
                "app compile command must include -Ifoolib/include/")
        end
    end)

    it("delegates an unknown-recipe link to require_recipe (no module-side gate)", function()
        -- The module no longer raises its own "links references unknown
        -- recipe" error; a genuine typo surfaces via cook.require_recipe instead.
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({ sources = { "src/foo.c" } })
        end)
        local ok, err = pcall(function()
            in_recipe("app", function()
                targets.bin({ sources = { "src/main.c" }, links = { "foolim" } })
            end)
        end)
        assert.is_false(ok)
        assert.matches("require_recipe", err, 1, true)
        assert.matches("unknown recipe 'foolim'", err, 1, true)
    end)

    it("declares an ordering edge (require_recipe) for each known link", function()
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({ sources = { "src/foo.c" } })
        end)
        in_recipe("app", function()
            targets.bin({ sources = { "src/main.c" }, links = { "foolib" } })
        end)
        assert.same({ "foolib" }, stub.require_recipe_edges())
    end)
end)

describe("cc.lib", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        for _, m in ipairs({
            "cook_cc.toolchain","cook_cc.cc","cook_cc.targets","cook_cc.transitive",
            "cook_cc.config_header",
        }) do reset_module(m) end
        with_toolchain()
    end)

    it("compiles + archives to build/lib/lib<name>.a", function()
        local targets = require("cook_cc.targets")
        in_recipe("mathlib", function()
            targets.lib({ sources = { "math/v.cpp" } })
        end)
        local units = stub.added_units()
        assert.equals(2, #units)
        assert.equals("build/obj/mathlib/v.o", units[1].output)
        assert.equals("build/lib/libmathlib.a", units[2].output)
        assert.matches("^ar rcs ", units[2].command)
    end)

    it("registers the compile fan-out inside one step group; archive stays sequential", function()
        local targets = require("cook_cc.targets")
        in_recipe("mathlib", function()
            targets.lib({ sources = { "math/v.cpp", "math/m.cpp" } })
        end)
        local groups = stub.step_groups()
        assert.equals(1, #groups)
        assert.same({ 1, 2 }, groups[1])  -- both compiles grouped, archive (unit 3) outside
    end)

    it("errors when called outside a recipe body", function()
        local targets = require("cook_cc.targets")
        assert.has_error(function()
            targets.lib({ sources = { "src/a.c" } })
        end, "[cc.lib] must be called inside a recipe block; wrap it in a `recipe` block")
    end)

    it("CS-cook_cc-0.1.2: lib's compile commands include export_includes from cc.lib links", function()
        local targets = require("cook_cc.targets")
        in_recipe("baselib", function()
            targets.lib({
                sources = { "src/base.c" },
                export_includes = { "baselib/include/" },
            })
        end)
        in_recipe("extlib", function()
            targets.lib({
                sources = { "src/ext.c" },
                links   = { "baselib" },
            })
        end)
        local units = stub.added_units()
        local extlib_compiles = {}
        for _, u in ipairs(units) do
            if u.output and u.output:match("^build/obj/extlib/") then
                extlib_compiles[#extlib_compiles + 1] = u
            end
        end
        assert.is_true(#extlib_compiles > 0, "expected at least one compile for extlib")
        for _, u in ipairs(extlib_compiles) do
            assert.matches(" %-Ibaselib/include/ ", u.command,
                "extlib compile command must include -Ibaselib/include/")
        end
    end)
end)

describe("cc.shared", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        for _, m in ipairs({
            "cook_cc.toolchain","cook_cc.cc","cook_cc.targets","cook_cc.transitive",
            "cook_cc.config_header",
        }) do reset_module(m) end
        with_toolchain()
    end)

    it("compiles -fPIC + links -shared to build/lib/lib<name>.so", function()
        local targets = require("cook_cc.targets")
        in_recipe("plug", function()
            targets.shared({ sources = { "p.cpp" } })
        end)
        local units = stub.added_units()
        local compile, link = units[1], units[2]
        assert.matches(" %-fPIC ", compile.command)
        assert.matches(" %-shared", link.command)
        assert.equals("build/lib/libplug.so", link.output)
    end)

    it("CS-0084: opts.output overrides the default link path verbatim", function()
        local targets = require("cook_cc.targets")
        in_recipe("base", function()
            targets.shared({
                sources = { "src/base.cpp" },
                output  = "build/bin/base.so",
            })
        end)
        local units = stub.added_units()
        local link = units[#units]
        assert.equals("build/bin/base.so", link.output)
        assert.matches(" %-shared", link.command)
        local info = cook.import("base")
        assert.equals("build/bin/base.so", info.lib_path)
    end)

    it("errors when called outside a recipe body", function()
        local targets = require("cook_cc.targets")
        assert.has_error(function()
            targets.shared({ sources = { "src/plug.c" } })
        end, "[cc.shared] must be called inside a recipe block; wrap it in a `recipe` block")
    end)

    it("CS-cook_cc-0.1.2: shared's compile commands include export_includes from cc.lib links", function()
        local targets = require("cook_cc.targets")
        in_recipe("iface", function()
            targets.lib({
                sources = { "src/iface.c" },
                export_includes = { "iface/include/" },
            })
        end)
        in_recipe("plug", function()
            targets.shared({
                sources = { "src/plug.c" },
                links   = { "iface" },
            })
        end)
        local units = stub.added_units()
        local plug_compiles = {}
        for _, u in ipairs(units) do
            if u.output and u.output:match("^build/obj/plug/") then
                plug_compiles[#plug_compiles + 1] = u
            end
        end
        assert.is_true(#plug_compiles > 0, "expected at least one compile for plug")
        for _, u in ipairs(plug_compiles) do
            assert.matches(" %-Iiface/include/ ", u.command,
                "plug compile command must include -Iiface/include/")
        end
    end)
end)

describe("targets frameworks", function()
    before_each(function()
        stub.reset(); stub.install()
        for _, m in ipairs({
            "cook_cc.targets","cook_cc.cc","cook_cc.toolchain","cook_cc.transitive",
            "cook_cc.config_header",
        }) do package.loaded[m] = nil end
        stub.set_sh_handler("__exists", function() return true end)
        stub.set_probe_value("cc:compiler:auto", { cxx = "g++", cc = "gcc" })
        require("cook_cc.toolchain").ensure_probe_registered()
        stub.set_platform_os("macos")
    end)

    it("cc.bin passes frameworks through to link command", function()
        local t = require("cook_cc.targets")
        in_recipe("app", function()
            t.bin({ sources = { "src/main.c" }, frameworks = { "OpenGL" } })
        end)
        local link_unit = stub.added_units()[#stub.added_units()]
        assert.matches("%-framework OpenGL", link_unit.command)
    end)

    it("cc.lib exports frameworks via cook.export (CS-0080: export_frameworks)", function()
        local t = require("cook_cc.targets")
        -- Updated for CS-0080: PRIVATE-by-default flips bare `frameworks` to
        -- target-local; explicit propagation is via `export_frameworks`.
        in_recipe("gfx", function()
            t.lib({ sources = { "src/lib.c" }, export_frameworks = { "OpenGL" } })
        end)
        local info = cook.import("gfx")
        assert.same({ "OpenGL" }, info.frameworks)
    end)
end)

describe("cc.headers", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        for _, m in ipairs({
            "cook_cc.toolchain","cook_cc.cc","cook_cc.targets","cook_cc.transitive",
            "cook_cc.config_header",
        }) do reset_module(m) end
        with_toolchain()
    end)

    it("registers exports but emits no units", function()
        local targets = require("cook_cc.targets")
        in_recipe("idlib", function()
            targets.headers({ export_includes = { "include/" } })
        end)
        assert.equals(0, #stub.added_units())
        local info = cook.import("idlib")
        assert.same({ "include/" }, info.includes)
    end)

    it("errors when called outside a recipe body", function()
        local targets = require("cook_cc.targets")
        assert.has_error(function()
            targets.headers({ export_includes = { "include/" } })
        end, "[cc.headers] must be called inside a recipe block; wrap it in a `recipe` block")
    end)
end)

describe("known_targets module-local state (T5)", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.targets"]    = nil
        package.loaded["cook_cc.compile_db"] = nil
    end)

    it("targets._known() exposes a list accessor", function()
        local tg = require("cook_cc.targets")
        local list = tg._known()
        assert.is_table(list)
        assert.equals(0, #list)
    end)

    it("compile_db.write reads from targets._known, not cook.probes.get", function()
        local db = require("cook_cc.compile_db")
        -- No targets registered and no cook.probes entry — write should produce []
        db.write()
        local units = stub.added_units()
        local found = false
        for _, u in ipairs(units) do
            if u.kind == "fs.write" and u.path == "compile_commands.json" then
                assert.equals("[]\n", u.content)
                found = true
            end
        end
        assert.is_true(found, "expected fs.write to compile_commands.json")
    end)
end)

describe("cc PRIVATE/PUBLIC propagation (CS-0080, M4-narrow)", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("__exists", function() return true end)
        for _, m in ipairs({
            "cook_cc.toolchain","cook_cc.cc","cook_cc.targets","cook_cc.transitive",
            "cook_cc.config_header",
        }) do reset_module(m) end
        with_toolchain()
    end)

    -- ----- defines ---------------------------------------------------

    it("bare `defines` on cc.lib does NOT propagate to consumer compile (PRIVATE)", function()
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({
                sources = { "src/foo.c" },
                defines = { "FOO_INTERNAL" },
            })
        end)
        in_recipe("app", function()
            targets.bin({
                sources = { "src/main.c" },
                links   = { "foolib" },
            })
        end)
        for _, u in ipairs(stub.added_units()) do
            if u.output and u.output:match("^build/obj/app/") then
                assert.is_nil(u.command:match("%-DFOO_INTERNAL"),
                    "app compile MUST NOT carry FOO_INTERNAL (bare define is PRIVATE)")
            end
        end
    end)

    it("`export_defines` on cc.lib DOES propagate to consumer compile (PUBLIC)", function()
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({
                sources        = { "src/foo.c" },
                defines        = { "FOO_INTERNAL" },
                export_defines = { "USE_FOO" },
            })
        end)
        in_recipe("app", function()
            targets.bin({
                sources = { "src/main.c" },
                links   = { "foolib" },
            })
        end)
        local app_compiles = {}
        for _, u in ipairs(stub.added_units()) do
            if u.output and u.output:match("^build/obj/app/") then
                app_compiles[#app_compiles + 1] = u
            end
        end
        assert.is_true(#app_compiles > 0, "expected at least one app compile")
        for _, u in ipairs(app_compiles) do
            assert.matches(" %-DUSE_FOO ", u.command,
                "app compile MUST carry USE_FOO (export_defines propagates)")
            assert.is_nil(u.command:match("%-DFOO_INTERNAL"),
                "bare define on lib still leaks (would mean PRIVATE rule broken)")
        end
    end)

    -- ----- system_libs ----------------------------------------------

    it("bare `system_libs` on cc.lib does NOT propagate to consumer link (PRIVATE)", function()
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({
                sources     = { "src/foo.c" },
                system_libs = { "m" },
            })
        end)
        in_recipe("app", function()
            targets.bin({
                sources = { "src/main.c" },
                links   = { "foolib" },
            })
        end)
        local link = stub.added_units()[#stub.added_units()]
        assert.is_nil(link.command:match(" %-lm "),
            "app link MUST NOT carry -lm (bare system_libs on lib is PRIVATE)")
    end)

    it("`export_system_libs` on cc.lib DOES propagate to consumer link (PUBLIC)", function()
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({
                sources            = { "src/foo.c" },
                system_libs        = { "m" },        -- bare: stays PRIVATE
                export_system_libs = { "dl" },       -- PUBLIC
            })
        end)
        in_recipe("app", function()
            targets.bin({
                sources = { "src/main.c" },
                links   = { "foolib" },
            })
        end)
        local link = stub.added_units()[#stub.added_units()]
        assert.matches(" %-ldl ", link.command,
            "app link MUST carry -ldl (export_system_libs propagates)")
        assert.is_nil(link.command:match(" %-lm "),
            "bare system_libs MUST NOT leak alongside the export")
    end)

    -- ----- frameworks ----------------------------------------------

    it("bare `frameworks` on cc.lib does NOT propagate to consumer link (PRIVATE)", function()
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({
                sources    = { "src/foo.c" },
                frameworks = { "Carbon" },
            })
        end)
        in_recipe("app", function()
            targets.bin({
                sources = { "src/main.c" },
                links   = { "foolib" },
            })
        end)
        local link = stub.added_units()[#stub.added_units()]
        assert.is_nil(link.command:match("%-framework Carbon"),
            "app link MUST NOT carry -framework Carbon (PRIVATE)")
    end)

    it("`export_frameworks` on cc.lib DOES propagate to consumer link (PUBLIC)", function()
        stub.set_platform_os("macos")  -- cc.link emits -framework only on macOS
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({
                sources           = { "src/foo.c" },
                export_frameworks = { "OpenGL" },
            })
        end)
        in_recipe("app", function()
            targets.bin({
                sources = { "src/main.c" },
                links   = { "foolib" },
            })
        end)
        local link = stub.added_units()[#stub.added_units()]
        assert.matches("%-framework OpenGL", link.command,
            "app link MUST carry -framework OpenGL (export_frameworks propagates)")
    end)

    -- ----- extra_ldflags --------------------------------------------

    it("bare `extra_ldflags` on cc.lib does NOT propagate to consumer link (PRIVATE)", function()
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({
                sources       = { "src/foo.c" },
                extra_ldflags = "-Wl,--internal-flag",
            })
        end)
        in_recipe("app", function()
            targets.bin({
                sources = { "src/main.c" },
                links   = { "foolib" },
            })
        end)
        local link = stub.added_units()[#stub.added_units()]
        assert.is_nil(link.command:match("%-%-internal%-flag"),
            "app link MUST NOT carry the lib's bare extra_ldflags (PRIVATE)")
    end)

    it("`export_extra_ldflags` on cc.lib DOES propagate to consumer link (PUBLIC)", function()
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({
                sources              = { "src/foo.c" },
                export_extra_ldflags = "-Wl,--public-flag",
            })
        end)
        in_recipe("app", function()
            targets.bin({
                sources = { "src/main.c" },
                links   = { "foolib" },
            })
        end)
        local link = stub.added_units()[#stub.added_units()]
        assert.matches("%-%-public%-flag", link.command,
            "app link MUST carry the lib's export_extra_ldflags")
    end)

    -- ----- backcompat: export_includes fall-back stays green --------

    it("`export_includes` absent → falls back to `includes` (CS-0080 backcompat carve-out)", function()
        local targets = require("cook_cc.targets")
        in_recipe("foolib", function()
            targets.lib({
                sources  = { "src/foo.c" },
                includes = { "foolib/include/" },
            })
        end)
        in_recipe("app", function()
            targets.bin({
                sources = { "src/main.c" },
                links   = { "foolib" },
            })
        end)
        local app_compiles = {}
        for _, u in ipairs(stub.added_units()) do
            if u.output and u.output:match("^build/obj/app/") then
                app_compiles[#app_compiles + 1] = u
            end
        end
        assert.is_true(#app_compiles > 0, "expected at least one app compile")
        for _, u in ipairs(app_compiles) do
            assert.matches(" %-Ifoolib/include/ ", u.command,
                "export_includes fall-back to includes MUST stay (backcompat)")
        end
    end)
end)
