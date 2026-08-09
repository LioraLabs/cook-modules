-- `cook cc.need <dep> <target>` — add a dependency to a target's needs, then
-- probe for it now.
local stub = require("cook_stub")

-- The finder is reloaded alongside the verb because its probe-registration
-- bookkeeping (`_registered`) is per-VM module state, and busted runs every
-- case on one VM: without this the second case's `find` would short-circuit on
-- the first case's registration and the stub would never see the probe.
local function fresh()
    for _, m in ipairs({
        "cook_cc.verbs.need", "cook_cc.verbs._project", "cook_cc.verbs._report",
        "cook_cc.discovery.finder", "cook_cc.toolchain",
        "cook_cc.discovery.finders.bare_probe", "cook_cc.discovery.finders.cmake_compat",
    }) do package.loaded[m] = nil end
    local need = require("cook_cc.verbs.need")
    local report = require("cook_cc.verbs._report")
    return need, report
end

describe("cc.need", function()
    local need, report, said

    local function bin(text) return { callee = "cook_cc.bin", text = text } end
    local function lib(text) return { callee = "cook_cc.lib", text = text } end

    -- The shape `cc.new` + `cc.add bin game` leaves behind: a target with no
    -- `needs` field and no top-level `uses` call, which is the state every
    -- first `cc.need` in a project meets.
    local function scaffolded()
        stub.set_file("Cookfile",
            "use cook_cc\n\ncook_cc.toolchain({ standard = \"c++20\" })\n\nrecipe game\n    x\n\nrecipe math\n    x\n")
        stub.set_module_call("game", bin('cook_cc.bin({ sources = { "src/game/main.cpp" } })'))
        stub.set_module_call("math", lib('cook_cc.lib({ dir = "src/math/" })'))
    end

    -- What the engine hands back for a dependency it located.
    local function found(strategy, version)
        return {
            found = true, version = version, cflags = "", libs = "",
            system_libs = {}, include_dirs = {}, lib_dirs = {}, frameworks = {},
            tried = {
                { strategy = "curated:x", outcome = "skip", reason = "no curated finder" },
                { strategy = strategy, outcome = "hit", reason = "" },
            },
        }
    end

    local function missing()
        return {
            found = false, cflags = "", libs = "",
            system_libs = {}, include_dirs = {}, lib_dirs = {}, frameworks = {},
            tried = {
                { strategy = "curated:ghostlib", outcome = "skip", reason = "no curated finder for 'ghostlib'" },
                { strategy = "pkg-config:ghostlib", outcome = "miss", reason = "pkg-config has no such package" },
                { strategy = "cmake:ghostlib", outcome = "miss", reason = "find_package found nothing" },
                { strategy = "bare:ghostlib", outcome = "miss", reason = "no libghostlib on the linker search path" },
            },
        }
    end

    before_each(function()
        stub.reset(); stub.install()
        need, report = fresh()
        said = {}
        report.emit = function(line) said[#said + 1] = line end
    end)

    local function run(...)
        need.register()
        return stub.invoke_chore("cc.need", { ... })
    end

    local function output()
        return table.concat(said, "\n")
    end

    describe("registration", function()
        it("registers under the module's own namespace", function()
            need.register()
            assert.is_truthy(stub.chore("cc.need"))
        end)

        it("carries an origin so cook menu can attribute it", function()
            need.register()
            assert.equals("cook_cc.verbs.need", stub.chore("cc.need").meta.origin)
        end)

        it("takes the dependency first and requires the target", function()
            -- The ticket asked for `dep [target]`, and the defaults level it
            -- would target does not exist: `cc.defaults` is
            -- `toolchain.merge_defaults`, which has no `needs` key (W8/COOK-5
            -- is still open). An optional param that always refuses would be a
            -- worse interface than a required one, so the target is required —
            -- and `dep` stays first so the day W8 lands, `target` becomes a
            -- trailing defaulted param and every command already written keeps
            -- its meaning.
            need.register()
            assert.same({
                { kind = "required", name = "dep" },
                { kind = "required", name = "target" },
            }, stub.chore("cc.need").meta.__params)
        end)

        it("refuses an invocation naming no target", function()
            need.register()
            assert.has_error(function() stub.invoke_chore("cc.need", { "sdl2" }) end)
        end)
    end)

    describe("creating the field", function()
        before_each(function()
            scaffolded()
            stub.set_probe_value("cc:find:sdl2", found("pkg-config:sdl2", "2.30.10"))
        end)

        it("asks the engine to create a needs field the target does not have", function()
            run("sdl2", "game")
            assert.same({ { path = "Cookfile", recipe = "game", field = "needs",
                entry = '"sdl2"', created = true } }, stub.splices())
        end)

        it("renders the entry as a quoted string, since the caller renders its own", function()
            run("sdl2", "game")
            assert.equals('"sdl2"', stub.splices()[1].entry)
        end)

        it("says what the target now needs", function()
            run("sdl2", "game")
            assert.is_truthy(output():find("game needs += sdl2", 1, true))
        end)

        it("reports the Cookfile as updated", function()
            run("sdl2", "game")
            assert.is_truthy(output():find("updated  Cookfile", 1, true))
        end)
    end)

    describe("appending to an existing field", function()
        before_each(function()
            stub.set_probe_value("cc:find:gl", found("curated:gl"))
        end)

        it("adds to a needs list the target already has", function()
            scaffolded()
            stub.set_module_call("game",
                bin('cook_cc.bin({ sources = { "src/game/main.cpp" }, needs = { "sdl2" } })'))
            run("gl", "game")
            assert.same({ { path = "Cookfile", recipe = "game", field = "needs",
                entry = '"gl"', created = false } }, stub.splices())
        end)
    end)

    describe("declaring the probe at top level", function()
        -- The finding that makes this verb two edits rather than one:
        -- `units/targets.lua`'s `check_needs_declared` refuses a `needs` entry
        -- whose probe nothing declared, so a verb that spliced only the field
        -- would leave a Cookfile that does not build.
        --
        -- "Already declared" is asked of the finder registry rather than of the
        -- Cookfile's text, which is what these cases arrange: a top-level
        -- `cook_cc.uses("sdl2")` HAS run by the time a chore body does, and
        -- what it left behind is a registration.
        local function declared_already(fn, name)
            require("cook_cc.discovery.finder")[fn](name)
        end

        before_each(function()
            stub.set_probe_value("cc:find:sdl2", found("pkg-config:sdl2", "2.30.10"))
            scaffolded()
        end)

        it("appends a uses call for a dependency nothing declared", function()
            run("sdl2", "game")
            assert.is_truthy(stub.file("Cookfile"):find('cook_cc.uses("sdl2")', 1, true))
        end)

        it("says it declared the dependency at top level", function()
            run("sdl2", "game")
            assert.is_truthy(output():find('cook_cc.uses("sdl2")', 1, true))
        end)

        it("writes no second declaration when a uses call already made one", function()
            declared_already("uses", "sdl2")
            run("sdl2", "game")
            assert.is_falsy(stub.file("Cookfile"):find('cook_cc.uses("sdl2")', 1, true))
        end)

        it("leaves a find_or_error declaration alone rather than redeclaring it", function()
            -- The case a text scan gets wrong in the direction that breaks the
            -- project: `find_or_error` declares the same probe key under
            -- raise-on-miss semantics, and `find` refuses to redeclare it. A
            -- verb that appended `uses` here would write a Cookfile whose next
            -- load fails with `duplicate cc.find for 'sdl2' with conflicting
            -- opts` — and the target's `needs` entry was already legal.
            declared_already("find_or_error", "sdl2")
            assert.has_no.errors(function() run("sdl2", "game") end)
            assert.is_falsy(stub.file("Cookfile"):find('cook_cc.uses("sdl2")', 1, true))
            assert.same(1, #stub.splices())
        end)

        it("still splices the needs entry when the declaration was already there", function()
            declared_already("uses", "sdl2")
            run("sdl2", "game")
            assert.same(1, #stub.splices())
        end)

        it("declares with the local this Cookfile binds cook_cc as", function()
            stub.set_file("Cookfile",
                "use mycc ./vendor/cook_cc.lua\n\nrecipe game\n    x\n")
            stub.set_module_call("game", { callee = "mycc.bin", text = 'mycc.bin({ sources = { "a.cpp" } })' })
            run("sdl2", "game")
            assert.is_truthy(stub.file("Cookfile"):find('mycc.uses("sdl2")', 1, true))
        end)
    end)

    describe("idempotence", function()
        before_each(function()
            scaffolded()
            -- The state a first `cc.need sdl2 game` leaves: the probe declared
            -- and the entry in the field.
            require("cook_cc.discovery.finder").uses("sdl2")
            stub.set_module_call("game",
                bin('cook_cc.bin({ sources = { "a.cpp" }, needs = { "sdl2" } })'))
            stub.set_probe_value("cc:find:sdl2", found("pkg-config:sdl2", "2.30.10"))
        end)

        it("does not add a dependency the target already needs", function()
            run("sdl2", "game")
            assert.same({}, stub.splices())
        end)

        it("notes the skip rather than failing", function()
            run("sdl2", "game")
            assert.is_truthy(output():find("skipped  sdl2 (already needed)", 1, true))
        end)

        it("claims no update when it wrote nothing at all", function()
            run("sdl2", "game")
            assert.is_falsy(output():find("updated", 1, true))
        end)

        it("reports what the target needs rather than what was added", function()
            run("sdl2", "game")
            assert.is_truthy(output():find("game needs = sdl2", 1, true))
        end)

        it("still runs the probe, which is the reason to type it twice", function()
            run("sdl2", "game")
            assert.is_truthy(output():find("2.30.10", 1, true))
        end)

        it("does not mistake a source path containing the name for a need", function()
            -- The bug `field_entries` exists to prevent: a Lua search for
            -- `"sdl2"` in the call's text matches inside
            -- `sources = { "src/sdl2/main.cpp" }`.
            stub.set_module_call("game",
                bin('cook_cc.bin({ sources = { "src/sdl2/main.cpp" }, needs = { } })'))
            run("sdl2", "game")
            assert.same(1, #stub.splices())
        end)

        it("recognises an entry the author wrote with single quotes", function()
            stub.set_module_call("game",
                bin("cook_cc.bin({ sources = { 'a.cpp' }, needs = { 'sdl2' } })"))
            run("sdl2", "game")
            assert.same({}, stub.splices())
        end)

        it("treats an entry the author wrote as a variable as unrecognised, and adds", function()
            stub.set_module_call("game",
                bin("cook_cc.bin({ sources = { 'a.cpp' }, needs = { sdl2 } })"))
            run("sdl2", "game")
            assert.same(1, #stub.splices())
        end)
    end)

    describe("verification", function()
        before_each(function() scaffolded() end)

        local function untouched(...)
            local before = stub.file("Cookfile")
            local ok, err = pcall(run, ...)
            assert.is_false(ok)
            assert.equals(before, stub.file("Cookfile"))
            assert.same({}, stub.splices())
            return tostring(err)
        end

        it("names the known targets when the target does not exist", function()
            local err = untouched("sdl2", "ghost")
            assert.is_truthy(err:find("ghost", 1, true))
            assert.is_truthy(err:find("game, math", 1, true))
        end)

        it("refuses a target that is not a cook_cc target, and says so rather than denying it exists", function()
            stub.set_file("Cookfile", "use cook_cc\n\nrecipe web\n    x\n\nrecipe math\n    x\n")
            stub.set_module_call("web", { callee = "cook_pnpm.workspace", text = "cook_pnpm.workspace({})" })
            local err = untouched("sdl2", "web")
            assert.is_truthy(err:find("'web' is a recipe, but it does not build a cook_cc target", 1, true))
            assert.is_falsy(err:find("no target named", 1, true))
        end)

        it("refuses a project with no cook_cc targets at all", function()
            stub.set_file("Cookfile", "use cook_cc\n")
            local err = untouched("sdl2", "game")
            assert.is_truthy(err:find("declares no cook_cc targets", 1, true))
        end)

        it("refuses a dependency name a probe key cannot spell", function()
            local err = untouched("sdl 2", "game")
            assert.is_truthy(err:find("sdl 2", 1, true))
        end)

        it("explains a dotted dependency name in terms of probe references", function()
            -- `.` is member access in `$<cc:find:NAME.cflags>`, which is
            -- exactly what the maker renders from a `needs` entry.
            local err = untouched("gtk.3", "game")
            assert.is_truthy(err:find("member access", 1, true))
        end)

        it("refuses a dependency name this project builds, and points at cc.link", function()
            local err = untouched("math", "game")
            assert.is_truthy(err:find("'math' is a lib this project builds", 1, true))
            assert.is_truthy(err:find("did you mean: cook cc.link game math", 1, true))
        end)

        it("does not suggest linking a target to itself", function()
            local err = untouched("game", "game")
            assert.is_falsy(err:find("cc.link game game", 1, true))
        end)

        it("refuses before it probes, so a refusal registers nothing", function()
            pcall(run, "sdl2", "ghost")
            assert.same({}, stub.probe_keys())
        end)
    end)

    describe("probing it now", function()
        before_each(function() scaffolded() end)

        it("registers the dependency's finder probe", function()
            stub.set_probe_value("cc:find:sdl2", found("pkg-config:sdl2", "2.30.10"))
            run("sdl2", "game")
            assert.is_not_nil(stub.probe_opts("cc:find:sdl2"))
        end)

        it("reports the version and the strategy that found it", function()
            stub.set_probe_value("cc:find:sdl2", found("pkg-config:sdl2", "2.30.10"))
            run("sdl2", "game")
            assert.is_truthy(output():find("sdl2 found: 2.30.10 via pkg-config:sdl2", 1, true))
        end)

        it("reports a hit that carries no version without inventing one", function()
            stub.set_probe_value("cc:find:gl", found("curated:gl"))
            run("gl", "game")
            assert.is_truthy(output():find("gl found via curated:gl", 1, true))
            assert.is_falsy(output():find("nil", 1, true))
        end)

        it("suggests building the target after a hit", function()
            stub.set_probe_value("cc:find:sdl2", found("pkg-config:sdl2", "2.30.10"))
            run("sdl2", "game")
            assert.is_truthy(output():find("try: cook game", 1, true))
        end)

        it("prints every strategy the probe recorded on a miss", function()
            stub.set_probe_value("cc:find:ghostlib", missing())
            run("ghostlib", "game")
            for _, want in ipairs({
                "curated:ghostlib: skip (no curated finder for 'ghostlib')",
                "pkg-config:ghostlib: miss (pkg-config has no such package)",
                "cmake:ghostlib: miss (find_package found nothing)",
                "bare:ghostlib: miss (no libghostlib on the linker search path)",
            }) do
                assert.is_truthy(output():find(want, 1, true))
            end
        end)

        it("hints at installing it on a miss", function()
            stub.set_probe_value("cc:find:ghostlib", missing())
            run("ghostlib", "game")
            assert.is_truthy(output():find("install ghostlib", 1, true))
        end)

        it("suggests re-running itself after a miss, not building a target that cannot link", function()
            stub.set_probe_value("cc:find:ghostlib", missing())
            run("ghostlib", "game")
            assert.is_truthy(output():find("try: cook cc.need ghostlib game", 1, true))
        end)

        it("keeps the edit on a miss, because declaring a dependency you have not installed is legitimate", function()
            stub.set_probe_value("cc:find:ghostlib", missing())
            run("ghostlib", "game")
            assert.same(1, #stub.splices())
        end)

        it("does not raise on a miss", function()
            stub.set_probe_value("cc:find:ghostlib", missing())
            assert.has_no.errors(function() run("ghostlib", "game") end)
        end)

        it("reports the edit before it reports the probe, so a probe failure does not hide it", function()
            -- `cook.probes.get` resolves at register phase (CS-0219) and a
            -- `produce` that raises comes back as an engine message. The edit
            -- has already landed by then and saying so is the difference
            -- between a user who knows what their Cookfile says and one who
            -- has to open it.
            cook.probes.get = function() error("runtime error: probe 'cc:find:sdl2': produce raised", 0) end
            local ok, err = pcall(run, "sdl2", "game")
            assert.is_false(ok)
            assert.is_truthy(output():find("game needs += sdl2", 1, true))
            -- In the verb's voice, keeping the engine's explanation and
            -- dropping the lead-in that names nothing the user typed.
            assert.is_truthy(tostring(err):find("cc.need: could not resolve the cc:find:sdl2 probe", 1, true))
            assert.is_truthy(tostring(err):find("produce raised", 1, true))
            assert.is_falsy(tostring(err):find("runtime error:", 1, true))
        end)

        it("says so plainly when the probe resolves to nothing at all", function()
            cook.probes.get = function() return nil end
            run("sdl2", "game")
            assert.is_truthy(output():find("produced no value", 1, true))
        end)
    end)
end)
