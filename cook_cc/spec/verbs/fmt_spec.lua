-- `cook cc.fmt` — run clang-format in place over the project's C++ sources.
local stub = require("cook_stub")

local function fresh()
    for _, m in ipairs({
        "cook_cc.verbs.fmt", "cook_cc.verbs._report",
    }) do package.loaded[m] = nil end
    local fmt = require("cook_cc.verbs.fmt")
    local report = require("cook_cc.verbs._report")
    report.emit = function() end
    return fmt, report
end

-- The engine hands back ABSOLUTE paths from fs.glob (§25.8), so the fixtures
-- do too: a spec that seeded relative ones would green an implementation that
-- cannot compose a working command line.
local ROOT = "/ws"

-- Seed the working tree a sweep will find. Each path lands in the glob block
-- for its own directory and extension, which is where the real fs.glob would
-- put it.
local function tree(paths)
    local by_pattern = {}
    for _, rel in ipairs(paths) do
        local dir = rel:match("^([^/]+)/")
        local ext = rel:match("%.([^.]+)$")
        local pattern = dir .. "/**/*." .. ext
        by_pattern[pattern] = by_pattern[pattern] or {}
        table.insert(by_pattern[pattern], ROOT .. "/" .. rel)
    end
    for pattern, hits in pairs(by_pattern) do stub.set_glob(pattern, hits) end
end

describe("cc.fmt", function()
    local fmt, report
    local commands       -- every cook.sh the verb ran, in call order
    local globbed        -- the argument of every fs.glob call, in call order

    before_each(function()
        stub.reset(); stub.install()
        fmt, report = fresh()

        commands = {}
        local inner = cook.sh
        cook.sh = function(cmd)
            commands[#commands + 1] = cmd
            return inner(cmd)
        end
        globbed = {}
        local inner_glob = fs.glob
        fs.glob = function(pattern)
            globbed[#globbed + 1] = pattern
            return inner_glob(pattern)
        end

        -- clang-format is on PATH and the project declares a style, unless a
        -- test says otherwise.
        stub.set_sh_handler("command -v", function() return "/usr/bin/clang-format\n" end)
        stub.set_sh_handler("'/usr/bin/clang-format'", function() return "" end)
        stub.set_file(".clang-format", "BasedOnStyle: LLVM\n")
    end)

    -- Every clang-format invocation the verb made, in call order.
    local function formats()
        local out = {}
        for _, cmd in ipairs(commands) do
            if cmd:find("clang%-format'") then out[#out + 1] = cmd end
        end
        return out
    end

    -- Every path a clang-format invocation was handed, in call order. Reads the
    -- quoting back off the command, so it only speaks for paths that contain no
    -- quote of their own; the escaping case asserts the command text directly.
    local function formatted()
        local out = {}
        for _, cmd in ipairs(formats()) do
            for quoted in cmd:gmatch("'([^']*)'") do
                if quoted ~= "/usr/bin/clang-format" then out[#out + 1] = quoted end
            end
        end
        return out
    end

    describe("registration", function()
        it("registers under the module's own namespace", function()
            fmt.register()
            assert.is_truthy(stub.chore("cc.fmt"))
        end)

        it("takes no parameters", function()
            -- Deliberate, and the reason §7.6 had to land first: a paramless
            -- verb is only safe once a chore body runs solely when asked for.
            fmt.register()
            assert.same({}, stub.chore("cc.fmt").meta.__params)
        end)

        it("carries an origin so cook menu can attribute it", function()
            fmt.register()
            assert.equals("cook_cc.verbs.fmt", stub.chore("cc.fmt").meta.origin)
        end)

        it("runs nothing just by registering", function()
            fmt.register()
            assert.same({}, commands)
        end)

        it("sweeps when dispatched with no arguments", function()
            tree({ "src/a.cpp" })
            fmt.register()
            stub.invoke_chore("cc.fmt", {})
            assert.same({ ROOT .. "/src/a.cpp" }, formatted())
        end)
    end)

    describe("the source set", function()
        it("sweeps each of src, include and tests for every C-family extension", function()
            tree({ "src/a.cpp" })
            fmt.run()
            assert.same({
                { "src/**/*.c", "src/**/*.cc", "src/**/*.cpp", "src/**/*.cxx",
                  "src/**/*.h", "src/**/*.hpp", "src/**/*.cppm", "src/**/*.ixx" },
                { "include/**/*.c", "include/**/*.cc", "include/**/*.cpp", "include/**/*.cxx",
                  "include/**/*.h", "include/**/*.hpp", "include/**/*.cppm", "include/**/*.ixx" },
                { "tests/**/*.c", "tests/**/*.cc", "tests/**/*.cpp", "tests/**/*.cxx",
                  "tests/**/*.h", "tests/**/*.hpp", "tests/**/*.cppm", "tests/**/*.ixx" },
            }, globbed)
        end)

        it("formats headers and module units, not just translation units", function()
            tree({ "src/a.cpp", "include/a.hpp", "src/legacy/b.c", "src/mod.cppm" })
            fmt.run()
            assert.same({
                ROOT .. "/include/a.hpp",
                ROOT .. "/src/a.cpp",
                ROOT .. "/src/legacy/b.c",
                ROOT .. "/src/mod.cppm",
            }, formatted())
        end)

        it("orders the set, so the command a run composes does not depend on the filesystem", function()
            tree({ "src/z.cpp", "src/a.cpp", "src/m.cpp" })
            fmt.run()
            assert.same({
                ROOT .. "/src/a.cpp", ROOT .. "/src/m.cpp", ROOT .. "/src/z.cpp",
            }, formatted())
        end)

        it("sweeps what a project has when it does not have all three directories", function()
            -- A header-only library has no tests/ and never did. The stub
            -- cannot tell an absent directory from an empty one — that half is
            -- §25.8's guarantee about fs.glob, and the end-to-end run is what
            -- exercises it; what this pins is that the verb formats the files
            -- it did find rather than refusing over the ones it did not.
            tree({ "include/a.hpp" })
            fmt.run()
            assert.same({ ROOT .. "/include/a.hpp" }, formatted())
        end)
    end)

    describe("the invocation", function()
        it("resolves the binary before running it, honouring CLANG_FORMAT", function()
            tree({ "src/a.cpp" })
            fmt.run()
            assert.equals('command -v "${CLANG_FORMAT:-clang-format}" 2>/dev/null', commands[1])
        end)

        it("edits in place, under the project's style and no other", function()
            -- The requirement, kept apart from how failure is detected so that
            -- changing the latter cannot break this. -style=file is passed
            -- rather than assumed: it is what makes "respects the project's
            -- .clang-format" a property of the call and not of which
            -- clang-format the user happens to have. -fallback-style=none is
            -- the guarantee behind it: with no style to find, clang-format
            -- leaves every file exactly as it was rather than reflowing the
            -- tree to LLVM's defaults.
            tree({ "src/a.cpp" })
            fmt.run()
            assert.equals(1, #formats())
            assert.is_truthy(formats()[1]:find(
                "-style=file -fallback-style=none -i '" .. ROOT .. "/src/a.cpp'", 1, true))
        end)

        it("keeps what clang-format printed, by taking its exit status out of the shell's hands", function()
            -- A non-zero exit reaches Lua as a raise whose captured output is
            -- carried in the engine's own transport encoding (§24.1, CS-0215),
            -- which is not a module's to parse; folding stderr into stdout and
            -- swallowing the status brings the same words back through the
            -- documented channel, the return value.
            tree({ "src/a.cpp" })
            fmt.run()
            assert.is_truthy(formats()[1]:find("2>&1 || echo __cc_fmt_failed__", 1, true))
        end)

        it("runs the binary the resolution found, not the name it looked for", function()
            stub.set_sh_handler("command -v", function() return "/opt/llvm/bin/clang-format\n" end)
            stub.set_sh_handler("'/opt/llvm/bin/clang-format'", function() return "" end)
            tree({ "src/a.cpp" })
            fmt.run()
            assert.is_truthy(formats()[1]:find("^'/opt/llvm/bin/clang%-format' "))
        end)

        it("quotes paths, so a directory with a space in it is one argument", function()
            tree({ "src/my sources/a.cpp" })
            fmt.run()
            assert.same({ ROOT .. "/src/my sources/a.cpp" }, formatted())
        end)

        it("escapes a quote in a path rather than closing the argument on it", function()
            -- The whole reason the quoting is hand-rolled. A path is whatever
            -- the user named their directories, and one that ends the quoted
            -- argument early hands the rest of the path to sh as words.
            tree({ "src/o'brien/a.cpp" })
            fmt.run()
            assert.is_truthy(formats()[1]:find(
                "-i '" .. ROOT .. "/src/o'\\''brien/a.cpp' 2>&1", 1, true))
        end)

        it("splits a sweep too large for one command line, and formats every file anyway", function()
            local paths = {}
            for i = 1, 4000 do
                paths[i] = ("src/a-directory-with-a-long-enough-name/file-%04d.cpp"):format(i)
            end
            tree(paths)
            fmt.run()
            assert.is_true(#formats() > 1, "expected the sweep to be split across invocations")
            for _, cmd in ipairs(formats()) do
                -- The budget, exactly, and not a comfortable multiple of it: a
                -- slack bound only catches "no batching at all", and would pass
                -- an accounting that left the command's own prefix and tail out
                -- of the sum.
                assert.is_true(#cmd <= 64 * 1024,
                    "a command line grew to " .. #cmd .. " bytes")
            end
            assert.equals(4000, #formatted())
        end)

        it("sends a path longer than the whole budget on its own", function()
            -- It cannot be split, and declining to format it would be the verb
            -- skipping a file for a reason of its own.
            local long = "src/" .. string.rep("d", 70 * 1024) .. "/a.cpp"
            tree({ long, "src/b.cpp" })
            fmt.run()
            assert.equals(2, #formats())
            assert.equals(2, #formatted())
        end)
    end)

    describe("output", function()
        it("says what it swept and how much of it", function()
            local lines = {}
            report.emit = function(l) lines[#lines + 1] = l end
            tree({ "src/a.cpp", "include/a.hpp", "tests/a_test.cpp" })
            fmt.run()
            assert.same({ "  ran      clang-format over 3 files in src/, include/, tests/" }, lines)
        end)

        it("counts one file as one file", function()
            local lines = {}
            report.emit = function(l) lines[#lines + 1] = l end
            tree({ "src/a.cpp" })
            fmt.run()
            assert.same({ "  ran      clang-format over 1 file in src/" }, lines)
        end)

        it("names the directories it formatted, not the ones it looked in", function()
            -- A header-only library reading "in src/, include/, tests/" is
            -- being told about two directories it does not have.
            local lines = {}
            report.emit = function(l) lines[#lines + 1] = l end
            tree({ "include/a.hpp", "tests/a_test.cpp" })
            fmt.run()
            assert.same({ "  ran      clang-format over 2 files in include/, tests/" }, lines)
        end)

        it("passes on anything clang-format said while succeeding", function()
            -- §24.1 (CS-0188) has the engine attribute a command's stderr to
            -- the unit that ran it; folding stderr into stdout takes that job
            -- over, so dropping the output would re-introduce exactly the
            -- vanished-warnings bug that section was written to fix.
            local lines = {}
            report.emit = function(l) lines[#lines + 1] = l end
            stub.set_sh_handler("'/usr/bin/clang-format'",
                function() return "warning: unknown key 'Wombat'\n" end)
            tree({ "src/a.cpp" })
            fmt.run()
            assert.same({
                "warning: unknown key 'Wombat'",
                "  ran      clang-format over 1 file in src/",
            }, lines)
        end)
    end)

    describe("refusals", function()
        local function refuse()
            local ok, err = pcall(fmt.run)
            assert.is_false(ok, "expected a refusal")
            return err
        end

        it("names the binary and how to get it when clang-format is missing", function()
            stub.set_sh_handler("command -v", function() return "\n" end)
            tree({ "src/a.cpp" })
            local err = refuse()
            assert.is_truthy(err:find("cc.fmt: clang-format is not on PATH", 1, true))
            assert.is_truthy(err:find("apt install clang-format", 1, true))
            assert.is_truthy(err:find("CLANG_FORMAT", 1, true))
        end)

        it("treats a failing resolution as a missing binary", function()
            -- `command -v` exits non-zero when it finds nothing, which cook.sh
            -- reports as a Lua error rather than as empty output (§24.1).
            stub.set_sh_handler("command -v", function() error("exit status 1") end)
            tree({ "src/a.cpp" })
            assert.is_truthy(refuse():find("cc.fmt: clang-format is not on PATH", 1, true))
        end)

        it("formats nothing when the binary is missing", function()
            stub.set_sh_handler("command -v", function() return "\n" end)
            tree({ "src/a.cpp" })
            pcall(fmt.run)
            assert.same({}, formats())
        end)

        it("refuses when there is nothing to format, naming where it looked", function()
            -- Reporting success over an empty sweep is the failure this
            -- catches: a project whose sources live somewhere else gets a run
            -- that formats nothing and says nothing about it.
            local err = refuse()
            assert.is_truthy(err:find("cc.fmt: no C or C++ sources found", 1, true))
            assert.is_truthy(err:find("src/, include/, tests/", 1, true))
        end)

        it("refuses when the project declares no style at all", function()
            -- The first-contact case, and the destructive one: an existing
            -- project that never opted into clang-format would otherwise have
            -- its whole tree reflowed to LLVM's defaults, successfully and
            -- silently. This verb formats to the style a project declares; it
            -- does not pick one for it.
            stub.reset(); stub.install()
            stub.set_sh_handler("command -v", function() return "/usr/bin/clang-format\n" end)
            tree({ "src/a.cpp" })
            local err = refuse()
            assert.is_truthy(err:find("cc.fmt: no .clang-format in this project", 1, true))
            assert.is_truthy(err:find("InheritParentConfig", 1, true))
        end)

        it("formats nothing when the project declares no style", function()
            stub.reset(); stub.install()
            stub.set_sh_handler("command -v", function() return "/usr/bin/clang-format\n" end)
            tree({ "src/a.cpp" })
            pcall(fmt.run)
            assert.same({}, formats())
        end)

        it("takes _clang-format as the declaration too", function()
            -- clang-format reads either spelling; refusing the second would be
            -- this verb inventing a rule the tool does not have.
            stub.reset(); stub.install()
            stub.set_sh_handler("command -v", function() return "/usr/bin/clang-format\n" end)
            stub.set_sh_handler("'/usr/bin/clang-format'", function() return "" end)
            stub.set_file("_clang-format", "BasedOnStyle: LLVM\n")
            tree({ "src/a.cpp" })
            assert.has_no.errors(function() fmt.run() end)
        end)

        it("hands back what clang-format said, not what cook ran", function()
            -- The raw failure quotes the command, which for a whole-project
            -- sweep is every path in the project. What the user needs is the
            -- one line the tool wrote, and it must survive: without it a
            -- malformed .clang-format is a refusal with no way to act on it.
            stub.set_sh_handler("'/usr/bin/clang-format'", function()
                return "/ws/.clang-format:2:18: error: Could not find closing ]!\n"
                    .. "IndentWidth: [1,2\n__cc_fmt_failed__\n"
            end)
            tree({ "src/a.cpp" })
            local err = refuse()
            assert.equals("cc.fmt: clang-format failed\n"
                .. "  /ws/.clang-format:2:18: error: Could not find closing ]!", err)
        end)

        it("falls back to the usual cause when clang-format said nothing", function()
            stub.set_sh_handler("'/usr/bin/clang-format'", function() return "__cc_fmt_failed__\n" end)
            tree({ "src/a.cpp" })
            assert.equals("cc.fmt: clang-format failed\n"
                .. "  a malformed .clang-format is the usual cause", refuse())
        end)

        it("treats a raise from the shell itself as the same failure", function()
            -- The composed command swallows clang-format's exit status, so a
            -- raise here is the engine's or the shell's, not the formatter's —
            -- and re-raising it verbatim would put every path in the project
            -- into the diagnostic.
            stub.set_sh_handler("'/usr/bin/clang-format'", function() error("could not spawn") end)
            tree({ "src/a.cpp" })
            local err = refuse()
            assert.is_truthy(err:find("cc.fmt: clang-format failed", 1, true))
            assert.is_falsy(err:find("src/a.cpp", 1, true))
        end)

        it("survives a command that returns no output at all", function()
            stub.set_sh_handler("'/usr/bin/clang-format'", function() return nil end)
            tree({ "src/a.cpp" })
            assert.has_no.errors(function() fmt.run() end)
        end)
    end)

    describe("what it does not touch", function()
        it("never reaches for the Cookfile editor", function()
            -- The one verb whose job needs nothing but the chore API. A rule
            -- stated only in prose is one a later edit quietly breaks, and
            -- `cook.cookfile.*` is the surface that rewrites the user's own
            -- program.
            local handle = assert(io.open("src/verbs/fmt.lua", "r"))
            local source = handle:read("a"); handle:close()
            local offenders = {}
            for line in source:gmatch("[^\n]+") do
                if not line:match("^%s*%-%-") and line:find("cook%.cookfile") then
                    offenders[#offenders + 1] = line
                end
            end
            assert.same({}, offenders)
        end)

        it("leaves the Cookfile byte-identical", function()
            stub.set_file("Cookfile", "use cook_cc\n\nrecipe app\n    cook_cc.bin({})\n")
            tree({ "src/a.cpp" })
            fmt.run()
            assert.equals("use cook_cc\n\nrecipe app\n    cook_cc.bin({})\n", stub.file("Cookfile"))
            assert.same({}, stub.splices())
        end)
    end)
end)
