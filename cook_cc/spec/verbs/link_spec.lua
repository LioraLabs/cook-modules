-- `cook cc.link <target> <libs...>` — add dependency edges to an existing target.
local stub = require("cook_stub")

local function fresh()
    for _, m in ipairs({
        "cook_cc.verbs.link", "cook_cc.verbs._project", "cook_cc.verbs._report",
    }) do package.loaded[m] = nil end
    local link = require("cook_cc.verbs.link")
    local report = require("cook_cc.verbs._report")
    return link, report
end

describe("cc.link", function()
    local link, report, said

    -- A project with one bin and three libs, which is the shape the epic's
    -- worked example builds: `cook cc.add bin game` then three `cc.add lib`.
    local function project(cookfile, calls)
        stub.set_file("Cookfile", cookfile)
        for name, call in pairs(calls) do
            stub.set_module_call(name, call)
        end
    end

    local function bin(text) return { callee = "cook_cc.bin", text = text } end
    local function lib(text) return { callee = "cook_cc.lib", text = text } end

    local function scaffolded()
        project(
            "use cook_cc\n\nrecipe game\n    x\n\nrecipe math\n    x\n\nrecipe sound\n    x\n\nrecipe util\n    x\n",
            {
                game  = bin('cook_cc.bin({ sources = { "src/game/main.cpp" } })'),
                math  = lib('cook_cc.lib({ dir = "src/math/", includes = { "include" } })'),
                sound = lib('cook_cc.lib({ dir = "src/sound/", includes = { "include" } })'),
                util  = lib('cook_cc.lib({ dir = "src/util/", includes = { "include" } })'),
            })
    end

    before_each(function()
        stub.reset(); stub.install()
        link, report = fresh()
        said = {}
        report.emit = function(line) said[#said + 1] = line end
    end)

    local function run(...)
        link.register()
        return stub.invoke_chore("cc.link", { ... })
    end

    local function output()
        return table.concat(said, "\n")
    end

    describe("registration", function()
        it("registers under the module's own namespace", function()
            link.register()
            assert.is_truthy(stub.chore("cc.link"))
        end)

        it("takes the target first and one or more libs after it", function()
            link.register()
            assert.same({
                { kind = "required", name = "target" },
                { kind = "variadic_plus", name = "libs" },
            }, stub.chore("cc.link").meta.__params)
        end)

        it("carries an origin so cook menu can attribute it", function()
            link.register()
            assert.equals("cook_cc.verbs.link", stub.chore("cc.link").meta.origin)
        end)

        it("refuses an invocation naming no lib at all", function()
            link.register()
            assert.has_error(function() stub.invoke_chore("cc.link", { "game" }) end)
        end)
    end)

    describe("creating the field", function()
        before_each(function() scaffolded() end)

        it("asks the engine to create a links field the target does not have", function()
            -- The whole reason this verb needed an engine change (CS-0221).
            -- `cc.add` emits no `links`, and neither does a hand-written
            -- Cookfile, so refusing here would leave the verb able to edit
            -- almost nothing.
            run("game", "math")
            assert.same({ { path = "Cookfile", recipe = "game", field = "links",
                entry = '"math"', created = true } }, stub.splices())
        end)

        it("writes one entry per lib, in the order they were typed", function()
            run("game", "math", "sound", "util")
            local entries = {}
            for _, splice in ipairs(stub.splices()) do entries[#entries + 1] = splice.entry end
            assert.same({ '"math"', '"sound"', '"util"' }, entries)
        end)

        it("renders each entry as a quoted string, since the caller renders its own", function()
            run("game", "math")
            assert.equals('"math"', stub.splices()[1].entry)
        end)
    end)

    describe("appending to an existing field", function()
        it("adds to a links list the target already has", function()
            scaffolded()
            stub.set_module_call("game",
                bin('cook_cc.bin({ sources = { "src/game/main.cpp" }, links = { "math" } })'))
            run("game", "sound")
            assert.same({ { path = "Cookfile", recipe = "game", field = "links",
                entry = '"sound"', created = false } }, stub.splices())
        end)
    end)

    describe("idempotence", function()
        before_each(function()
            scaffolded()
            stub.set_module_call("game",
                bin('cook_cc.bin({ sources = { "src/game/main.cpp" }, links = { "math" } })'))
        end)

        it("does not add a lib that is already linked", function()
            run("game", "math")
            assert.same({}, stub.splices())
        end)

        it("notes the skip rather than failing", function()
            run("game", "math")
            assert.is_truthy(output():find("skipped  math (already linked)", 1, true))
        end)

        it("reports an already-linked name once however many times it was typed", function()
            run("game", "math", "math", "math")
            local seen = 0
            for _, line in ipairs(said) do
                if line:find("already linked", 1, true) then seen = seen + 1 end
            end
            assert.same(1, seen)
        end)

        it("says a name was typed twice rather than claiming it was already linked", function()
            -- `sound` was not already linked; THIS invocation linked it. The
            -- two skips are different facts and one of them would be a lie.
            run("game", "sound", "sound")
            assert.is_truthy(output():find("skipped  sound (named twice)", 1, true))
            assert.is_falsy(output():find("sound (already linked)", 1, true))
        end)

        it("treats an entry the author wrote as a variable as unrecognised, and adds", function()
            -- `project.entry_name` answers nil for anything that is not a
            -- string literal, so a comparison never matches: a redundant entry
            -- is a great deal better than silently dropping a wanted edge.
            stub.set_module_call("game",
                bin("cook_cc.bin({ sources = { 'a.cpp' }, links = { math } })"))
            run("game", "math")
            assert.same(1, #stub.splices())
        end)

        it("does not confuse a name that is a prefix of a linked one", function()
            stub.set_module_call("game",
                bin('cook_cc.bin({ sources = { "a.cpp" }, links = { "mathx" } })'))
            run("game", "math")
            assert.same(1, #stub.splices())
        end)

        it("skips the linked one and writes the rest of the batch", function()
            run("game", "math", "sound")
            assert.same(1, #stub.splices())
            assert.equals('"sound"', stub.splices()[1].entry)
        end)

        it("does not write the same lib twice within one invocation", function()
            run("game", "sound", "sound")
            assert.same(1, #stub.splices())
        end)

        it("recognises a lib the author wrote with single quotes", function()
            stub.set_module_call("game",
                bin("cook_cc.bin({ sources = { 'a.cpp' }, links = { 'math' } })"))
            run("game", "math")
            assert.same({}, stub.splices())
        end)

        it("does not mistake a source path containing the name for a link", function()
            -- The bug the engine's `field_entries` exists to prevent: a Lua
            -- search for `"math"` in the call's text matches inside
            -- `sources = { "src/math/main.cpp" }`.
            stub.set_module_call("game",
                bin('cook_cc.bin({ sources = { "src/math/main.cpp" }, links = { } })'))
            run("game", "math")
            assert.same(1, #stub.splices())
        end)
    end)

    describe("verification", function()
        before_each(function() scaffolded() end)

        it("names the known targets when the target does not exist", function()
            local ok, err = pcall(run, "ghost", "math")
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("ghost", 1, true))
            assert.is_truthy(tostring(err):find("game, math, sound, util", 1, true))
        end)

        it("names the known targets when a lib does not exist", function()
            local ok, err = pcall(run, "game", "ghost")
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("ghost", 1, true))
            assert.is_truthy(tostring(err):find("game, math, sound, util", 1, true))
        end)

        it("refuses a target that is not a cook_cc target, and says so rather than denying it exists", function()
            -- A recipe exists under that name, but it builds something else.
            -- Splicing `links` into another module's call would be editing a
            -- table whose keys this verb knows nothing about. "no target named
            -- 'web'" would read as a contradiction to someone looking at
            -- `recipe web` in the file they were told does not have it.
            stub.set_file("Cookfile", "use cook_cc\n\nrecipe web\n    x\n\nrecipe math\n    x\n")
            stub.set_module_call("web", { callee = "cook_pnpm.workspace", text = "cook_pnpm.workspace({})" })
            stub.set_module_call("math", lib("cook_cc.lib({ dir = \"src/math/\" })"))
            local ok, err = pcall(run, "web", "math")
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("'web' is a recipe, but it does not build a cook_cc target", 1, true))
            assert.is_falsy(tostring(err):find("no target named", 1, true))
        end)

        it("refuses a target whose kind links nothing", function()
            stub.set_file("Cookfile",
                "use cook_cc\n\nrecipe hdrs\n    x\n\nrecipe math\n    x\n")
            stub.set_module_call("hdrs",
                { callee = "cook_cc.headers", text = 'cook_cc.headers({ includes = { "include" } })' })
            stub.set_module_call("math", lib('cook_cc.lib({ dir = "src/math/" })'))
            local ok, err = pcall(run, "hdrs", "math")
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("links nothing", 1, true))
        end)

        it("refuses to link a target to itself", function()
            local ok, err = pcall(run, "math", "math")
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("itself", 1, true))
        end)

        it("writes nothing when any name in the batch is refused", function()
            -- Check everything before writing anything: a batch that fails
            -- halfway leaves the author reconciling a partial edit against a
            -- message saying the edit did not happen. Each refusal shape gets
            -- its own case, because each is reached from a different point in
            -- the check order.
            for _, argv in ipairs({
                { "game", "math", "ghost" },   -- unknown, last
                { "game", "ghost", "math" },   -- unknown, first
                { "math", "sound", "game" },   -- a bin in the lib list
                { "game", "math", "game" },    -- the target named as a lib
            }) do
                stub.reset(); stub.install()
                link, report = fresh()
                report.emit = function() end
                scaffolded()
                pcall(run, table.unpack(argv))
                assert.same({}, stub.splices(), table.concat(argv, " "))
            end
        end)
    end)

    describe("the wrong order self-heals", function()
        before_each(function() scaffolded() end)

        it("says which name is the bin and offers the swapped command", function()
            local ok, err = pcall(run, "math", "game")
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("'game' is a bin, cannot be linked into 'math'", 1, true))
            assert.is_truthy(tostring(err):find("cook cc.link game math", 1, true))
        end)

        it("keeps the other libs in the suggested command", function()
            local ok, err = pcall(run, "math", "game", "sound")
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("cook cc.link game math sound", 1, true))
        end)

        it("offers the swap when the target is a headers target", function()
            -- `cc.link app hdrs` is legal, so `cc.link hdrs app` is exactly the
            -- swapped shape and gets the same service. It reaches the check
            -- through the lib position, which is why that position is checked
            -- first.
            stub.set_file("Cookfile", "use cook_cc\n\nrecipe hdrs\n    x\n\nrecipe game\n    x\n")
            stub.set_module_call("hdrs",
                { callee = "cook_cc.headers", text = 'cook_cc.headers({ includes = { "include" } })' })
            local ok, err = pcall(run, "hdrs", "game")
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("cook cc.link game hdrs", 1, true))
        end)

        it("still offers the swap when the one bin is named twice", function()
            local ok, err = pcall(run, "math", "game", "game")
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("cook cc.link game math", 1, true))
            assert.is_falsy(tostring(err):find("math game", 1, true))
        end)

        it("does not suggest a command that would itself be refused", function()
            -- Every name is checked to exist before the swap is offered, so a
            -- typo in the batch is reported as a typo rather than copied into
            -- a suggestion that fails the moment it is run.
            local ok, err = pcall(run, "math", "game", "ghost")
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("ghost", 1, true))
            assert.is_falsy(tostring(err):find("did you mean", 1, true))
        end)

        it("refuses a bin in the lib list without a swap when the target is a bin too", function()
            -- Nothing to swap: two programs, and neither links the other.
            stub.set_module_call("tool", bin('cook_cc.bin({ sources = { "src/tool/main.cpp" } })'))
            stub.set_file("Cookfile",
                "use cook_cc\n\nrecipe game\n    x\n\nrecipe tool\n    x\n\nrecipe math\n    x\n")
            local ok, err = pcall(run, "game", "tool")
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("is a bin", 1, true))
            assert.is_falsy(tostring(err):find("did you mean", 1, true))
        end)

        it("writes nothing when it refuses", function()
            pcall(run, "math", "game")
            assert.same({}, stub.splices())
        end)
    end)

    describe("cycles", function()
        before_each(function() scaffolded() end)

        it("refuses an edge that would close a cycle", function()
            -- The engine catches it at build time, from somewhere that does
            -- not name the command that caused it, and by then the Cookfile
            -- has already been written. "What you scaffold must build
            -- unedited" is the rule this keeps.
            stub.set_module_call("math",
                lib('cook_cc.lib({ dir = "src/math/", links = { "sound" } })'))
            local ok, err = pcall(run, "sound", "math")
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find("already links back to", 1, true))
            assert.same({}, stub.splices())
        end)

        it("refuses a cycle that closes through another target", function()
            stub.set_module_call("math",
                lib('cook_cc.lib({ dir = "src/math/", links = { "sound" } })'))
            stub.set_module_call("sound",
                lib('cook_cc.lib({ dir = "src/sound/", links = { "util" } })'))
            local ok = pcall(run, "util", "math")
            assert.is_false(ok)
            assert.same({}, stub.splices())
        end)

        it("allows a diamond, which is not a cycle", function()
            stub.set_module_call("math",
                lib('cook_cc.lib({ dir = "src/math/", links = { "util" } })'))
            stub.set_module_call("sound",
                lib('cook_cc.lib({ dir = "src/sound/", links = { "util" } })'))
            run("game", "math", "sound")
            assert.same(2, #stub.splices())
        end)
    end)

    describe("what it says", function()
        before_each(function() scaffolded() end)

        it("echoes the resulting state, so the edit is visible without opening the file", function()
            run("game", "math", "sound", "util")
            assert.is_truthy(output():find("game links += math, sound, util", 1, true))
        end)

        it("names the file it edited", function()
            run("game", "math")
            assert.is_truthy(output():find("updated", 1, true))
            assert.is_truthy(output():find("Cookfile", 1, true))
        end)

        it("suggests building the target next", function()
            run("game", "math")
            assert.is_truthy(output():find("try: cook game", 1, true))
        end)

        it("does not claim to have updated the file when it wrote nothing", function()
            stub.set_module_call("game",
                bin('cook_cc.bin({ sources = { "a.cpp" }, links = { "math" } })'))
            run("game", "math")
            assert.is_falsy(output():find("updated", 1, true))
            -- and still says what the target links, since that is the question
            -- the user was asking.
            assert.is_truthy(output():find("game links = math", 1, true))
        end)

        it("shows an entry it cannot name as the author wrote it", function()
            -- Nothing to add, and the existing entry is a variable reference
            -- `entry_name` answers nil for, so the state line has to fall back
            -- to the bytes the author wrote.
            stub.set_module_call("game",
                bin("cook_cc.bin({ sources = { 'a.cpp' }, links = { \"math\", shared_libs } })"))
            run("game", "math")
            assert.is_truthy(output():find("game links = math, shared_libs", 1, true))
        end)
    end)
end)
