-- `cook cc.fmt` — run clang-format in place over the project's C++ sources.
local stub = require("cook_stub")

local function fresh()
    for _, m in ipairs({
        "cook_cc.verbs.fmt", "cook_cc.verbs._project", "cook_cc.verbs._report",
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

-- Seed the working tree a sweep will find. Keys are the directory a file sits
-- under, values the workspace-relative paths; each lands in the glob block for
-- its own extension, which is where the real fs.glob would put it.
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
    local globbed        -- the argument of the last fs.glob call

    before_each(function()
        stub.reset(); stub.install()
        fmt, report = fresh()

        commands = {}
        local inner = cook.sh
        cook.sh = function(cmd)
            commands[#commands + 1] = cmd
            return inner(cmd)
        end
        local inner_glob = fs.glob
        fs.glob = function(pattern)
            globbed = pattern
            return inner_glob(pattern)
        end

        -- clang-format is on PATH unless a test says otherwise.
        stub.set_sh_handler("command -v", function() return "/usr/bin/clang-format\n" end)
        stub.set_sh_handler("'/usr/bin/clang-format'", function() return "" end)
    end)

    -- Every clang-format invocation the verb made, in call order.
    local function formats()
        local out = {}
        for _, cmd in ipairs(commands) do
            if cmd:find("clang%-format'") then out[#out + 1] = cmd end
        end
        return out
    end

    -- Every path a clang-format invocation was handed, in call order.
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
        it("sweeps src, include and tests for every C-family extension", function()
            tree({ "src/a.cpp" })
            fmt.run()
            assert.same({
                "src/**/*.c", "src/**/*.cc", "src/**/*.cpp", "src/**/*.cxx",
                "src/**/*.h", "src/**/*.hpp", "src/**/*.cppm", "src/**/*.ixx",
                "include/**/*.c", "include/**/*.cc", "include/**/*.cpp", "include/**/*.cxx",
                "include/**/*.h", "include/**/*.hpp", "include/**/*.cppm", "include/**/*.ixx",
                "tests/**/*.c", "tests/**/*.cc", "tests/**/*.cpp", "tests/**/*.cxx",
                "tests/**/*.h", "tests/**/*.hpp", "tests/**/*.cppm", "tests/**/*.ixx",
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

        it("does not mind a directory the project does not have", function()
            -- §25.8: a pattern matching nothing contributes an empty block. A
            -- header-only library has no tests/ and never did.
            tree({ "include/a.hpp" })
            assert.has_no.errors(function() fmt.run() end)
        end)
    end)

    describe("the invocation", function()
        it("resolves the binary before running it, honouring CLANG_FORMAT", function()
            tree({ "src/a.cpp" })
            fmt.run()
            assert.equals('command -v "${CLANG_FORMAT:-clang-format}" 2>/dev/null', commands[1])
        end)

        it("edits in place, under the style the project declared", function()
            -- -style=file is passed rather than assumed: it is what makes
            -- "respects the project's .clang-format" a property of the call
            -- and not of which clang-format the user happens to have.
            --
            -- The tail is how the verb gets to keep what clang-format said. A
            -- non-zero exit reaches Lua as a raise whose captured output is
            -- carried in the engine's own transport encoding (§24.1, CS-0215),
            -- which is not a module's to parse; folding stderr into stdout and
            -- swallowing the status brings the same words back through the
            -- documented channel, the return value.
            tree({ "src/a.cpp" })
            fmt.run()
            assert.same({ "'/usr/bin/clang-format' -style=file -i '" .. ROOT
                .. "/src/a.cpp' 2>&1 || echo __cc_fmt_failed__" }, formats())
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

        it("keeps every command line well short of ARG_MAX, and formats every file anyway", function()
            local paths = {}
            for i = 1, 4000 do
                paths[i] = ("src/a-directory-with-a-long-enough-name/file-%04d.cpp"):format(i)
            end
            tree(paths)
            fmt.run()
            assert.is_true(#formats() > 1, "expected the sweep to be split across invocations")
            for _, cmd in ipairs(formats()) do
                assert.is_true(#cmd < 200000, "a command line grew to " .. #cmd .. " bytes")
            end
            assert.equals(4000, #formatted())
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
            assert.same({ "  ran      clang-format over 1 file in src/, include/, tests/" }, lines)
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

        it("takes success at its word when the sentinel is absent", function()
            stub.set_sh_handler("'/usr/bin/clang-format'", function() return "" end)
            tree({ "src/a.cpp" })
            assert.has_no.errors(function() fmt.run() end)
        end)
    end)
end)
