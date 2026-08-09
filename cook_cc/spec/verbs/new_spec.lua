-- `cook cc.new` — scaffold a working C++ project around the Cookfile that is
-- already here.
local stub = require("cook_stub")

local function fresh()
    for _, m in ipairs({
        "cook_cc.verbs.new", "cook_cc.verbs._project", "cook_cc.verbs._report",
    }) do package.loaded[m] = nil end
    local new = require("cook_cc.verbs.new")
    local report = require("cook_cc.verbs._report")
    report.emit = function() end
    return new, report
end

describe("cc.new", function()
    local new, report

    before_each(function()
        stub.reset(); stub.install()
        new, report = fresh()
        stub.set_file("Cookfile", "use cook_cc\n")
    end)

    local function run()
        new.register()
        return stub.invoke_chore("cc.new", {})
    end

    describe("registration", function()
        it("registers under the module's own namespace", function()
            new.register()
            assert.is_truthy(stub.chore("cc.new"))
        end)

        it("takes no parameters", function()
            new.register()
            assert.same({}, stub.chore("cc.new").meta.__params)
        end)

        it("carries an origin so cook menu can attribute it", function()
            new.register()
            assert.equals("cook_cc.verbs.new", stub.chore("cc.new").meta.origin)
        end)

        it("does not touch the project just by registering", function()
            new.register()
            assert.equals("use cook_cc\n", stub.file("Cookfile"))
        end)
    end)

    describe("the sources it writes", function()
        before_each(function() run() end)

        it("writes a program with an entry point", function()
            assert.is_truthy(stub.file("src/main.cpp"):find("int main(", 1, true))
        end)

        it("writes a header, so include/ is a real directory and not an empty one", function()
            assert.is_truthy(stub.file("include/greet.hpp"):find("#pragma once", 1, true))
        end)

        it("has the program include that header, so the include path is load-bearing", function()
            assert.is_truthy(stub.file("src/main.cpp"):find('#include "greet.hpp"', 1, true))
        end)

        it("writes a test that asserts something the header actually promises", function()
            local tests = stub.file("tests/main.cpp")
            assert.is_truthy(tests:find("#include <cassert>", 1, true))
            assert.is_truthy(tests:find('#include "greet.hpp"', 1, true))
            assert.is_truthy(tests:find("assert(", 1, true))
        end)

        it("includes nothing but the standard library and the project's own header", function()
            -- The epic's decision: tests are a template convention, not a
            -- framework opinion. Pinning the include list is how that stays
            -- true — a doctest or Catch2 header would show up here.
            local includes = {}
            for header in stub.file("tests/main.cpp"):gmatch('#include%s*[<"]([^>"]+)') do
                includes[#includes + 1] = header
            end
            assert.same({ "cassert", "cstdio", "greet.hpp" }, includes)
        end)

        it("writes the .clang-format cc.fmt refuses to run without", function()
            -- COOK-290: `clang-format -style=file` with no config anywhere
            -- falls back to LLVM defaults and exits 0, so cc.fmt refuses
            -- unless the project declares a style. Every one of these
            -- settings is load-bearing for the fixpoint property — cc.add's
            -- and cc.new's scaffolds must come out of cc.fmt unchanged, and
            -- bare `BasedOnStyle: LLVM` reflows both.
            local fmt = stub.file(".clang-format")
            for _, setting in ipairs({
                "BasedOnStyle: LLVM",
                "IndentWidth: 4",
                "ColumnLimit: 100",
                "AllowShortFunctionsOnASingleLine: None",
                "SpacesBeforeTrailingComments: 2",
            }) do
                assert.is_truthy(fmt:find(setting, 1, true), "missing: " .. setting)
            end
        end)

        it("keeps the assert live under a toolchain that defines NDEBUG", function()
            -- `optimize = "speed"` on the toolchain call adds -DNDEBUG, which
            -- compiles every assert away and leaves a test that passes
            -- without checking anything. The undef must precede the include.
            local tests = stub.file("tests/main.cpp")
            local undef = tests:find("#undef NDEBUG", 1, true)
            assert.is_truthy(undef)
            assert.is_true(undef < tests:find("#include <cassert>", 1, true))
        end)
    end)

    describe("the Cookfile block", function()
        before_each(function() run() end)

        local function cookfile() return stub.file("Cookfile") end

        it("keeps everything that was already there", function()
            assert.equals("use cook_cc\n", cookfile():sub(1, #"use cook_cc\n"))
        end)

        it("declares exactly the names it checks for", function()
            -- The clash check walks a list; the block spells the same names
            -- again in the text it appends. This reads the block back so the
            -- two cannot drift apart in silence — a template that grew a
            -- `bench` recipe without extending the check would append it over
            -- whatever `bench` the project already had.
            local declared = {}
            for keyword, name in cookfile():gmatch("\n(%a+) ([%w_%-]+)") do
                if keyword == "recipe" or keyword == "chore" then
                    declared[#declared + 1] = name
                end
            end
            table.sort(declared)
            assert.same({ "build", "run", "test" }, declared)
        end)

        it("puts the toolchain call first in the block, where it reads", function()
            local toolchain = cookfile():find("cook_cc.toolchain(", 1, true)
            local first_target = cookfile():find("cook_cc.bin(", 1, true)
            assert.is_truthy(toolchain)
            assert.is_truthy(first_target)
            assert.is_true(toolchain < first_target)
        end)

        it("writes exactly one toolchain call", function()
            local count = select(2, cookfile():gsub("%.toolchain%s*%(", ""))
            assert.equals(1, count)
        end)

        it("declares a build recipe over the program's sources", function()
            assert.is_truthy(cookfile():find(
                'recipe build\n    cook_cc.bin({ sources = { "src/main.cpp" }, includes = { "include" } })',
                1, true))
        end)

        it("puts include/ on the search path, so the header it just wrote resolves", function()
            -- The scaffolded main.cpp includes "greet.hpp". Without this the
            -- first `cook build` after cc.new fails to compile, which is the
            -- one thing this verb must never produce.
            for _, target in ipairs({ "build", "test" }) do
                local body = cookfile():match("recipe " .. target .. "\n(.-)\n")
                assert.is_truthy(body:find('includes = { "include" }', 1, true),
                    "recipe " .. target .. " must carry the include path")
            end
        end)

        it("declares run as a chore that depends on build, so the binary is current", function()
            assert.is_truthy(cookfile():find("chore run: build\n    ./build/bin/build", 1, true))
        end)

        it("declares a test recipe that builds the test binary and runs it", function()
            assert.is_truthy(cookfile():find(
                'recipe test\n    cook_cc.bin({ sources = { "tests/main.cpp" }, includes = { "include" } })'
                .. "\n    test { ./build/bin/test }", 1, true))
        end)

        it("names the test binary as a path, not as $<in>", function()
            -- `$<in>` needs a preceding surface `cook` step or an
            -- `ingredients` declaration, and a module call is neither: codegen
            -- rejects the recipe outright with "test step at line N requires a
            -- non-empty source". An `ingredients` glob would not save it —
            -- that resolves at register phase, before the binary exists.
            --
            -- Scoped to the appended block, since the assertion is about what
            -- this verb wrote and not about the rest of somebody's Cookfile.
            local block = cookfile():match("recipe test\n.*$")
            assert.is_truthy(block:find("test { ./build/bin/test }", 1, true))
            assert.is_nil(block:find("$<in>", 1, true))
            assert.is_nil(block:find("ingredients", 1, true))
        end)
    end)

    describe("a project that bound cook_cc under another name", function()
        it("generates calls to the local that Cookfile actually binds", function()
            stub.set_file("Cookfile", "use cc ./vendor/cook_cc.lua\n")
            run()
            assert.is_truthy(stub.file("Cookfile"):find("cc.toolchain(", 1, true))
            assert.is_truthy(stub.file("Cookfile"):find(
                'recipe build\n    cc.bin({ sources = { "src/main.cpp" }', 1, true))
            assert.is_nil(stub.file("Cookfile"):find("cook_cc.bin(", 1, true))
        end)
    end)

    describe(".gitignore", function()
        -- The managed section, byte for byte as cook-cli's
        -- `COOK_GITIGNORE_SECTION` spells it (pipeline.rs). Restated here in
        -- full and not just by its marker line, because the duplication across
        -- two repos is the whole risk: dropping `!**/.cook/cloud.toml` from
        -- the Lua copy would leave every other assertion in this file green.
        local COOK_SECTION = table.concat({
            "# Cook artifacts (added by cook)",
            "# .cook/ holds caches, per-project state, and the luarocks tree that",
            "# `cook modules install` populates (.cook/modules/). cloud.toml is the one",
            "# tracked file. Everything cook generates is under here, so one rule covers it.",
            "# Your own Lua is not: a module you wrote lives wherever you put it in the",
            "# repo and is reached by path (`use ./lua/helpers.lua`).",
            ".cook/**",
            "**/.cook/**",
            "!**/.cook/",
            "!**/.cook/cloud.toml",
            "",
        }, "\n")

        it("creates one carrying the Cook-managed section verbatim", function()
            run()
            assert.is_truthy(stub.file(".gitignore"):find(COOK_SECTION, 1, true))
        end)

        it("also ignores the directory cook_cc builds into", function()
            -- The managed section covers .cook/ only, on purpose: the engine
            -- leaves toolchain ignores to the user. cc.new IS the toolchain
            -- verb, and cook_cc's artifact root is not a matter of opinion —
            -- without this the `git add -A` after the pitch commits a binary.
            run()
            local ignore = stub.file(".gitignore")
            assert.is_truthy(ignore:find("# C++ build artifacts (added by cook cc.new)", 1, true))
            assert.is_truthy(ignore:find("\nbuild/\n", 1, true))
        end)

        it("adds the C++ section below the Cook one, so neither is interleaved", function()
            run()
            local ignore = stub.file(".gitignore")
            assert.is_true(ignore:find(COOK_SECTION, 1, true)
                < ignore:find("# C++ build artifacts", 1, true))
        end)

        it("leaves build/ alone when the project already ignores it", function()
            stub.set_file(".gitignore", "/build/\n")
            run()
            local ignore = stub.file(".gitignore")
            assert.is_nil(ignore:find("# C++ build artifacts", 1, true))
            assert.is_truthy(ignore:find(COOK_SECTION, 1, true))
        end)

        it("writes both sections into an empty file with no leading blank line", function()
            stub.set_file(".gitignore", "")
            run()
            assert.equals("# Cook artifacts", stub.file(".gitignore"):sub(1, 16))
        end)

        -- One blank line between what was there and the section, in both
        -- cases. The Rust half of this merge does the same, and a `.gitignore`
        -- the two of them disagree about is one the user has to hand-edit.
        local function assert_starts_with(prefix, text)
            assert.equals(prefix, text:sub(1, #prefix))
        end

        it("appends the section to one that does not have it, keeping what is there", function()
            stub.set_file(".gitignore", "*.o\n")
            run()
            assert_starts_with("*.o\n\n# Cook artifacts (added by cook)\n", stub.file(".gitignore"))
        end)

        it("gives an unterminated last line its newline back before appending", function()
            stub.set_file(".gitignore", "*.o")
            run()
            assert_starts_with("*.o\n\n# Cook artifacts", stub.file(".gitignore"))
        end)

        it("never writes the Cook section twice", function()
            -- `cook modules install` writes it when it creates the Cookfile,
            -- which is the blessed flow, and an older `cook init` wrote it
            -- with different wording. Both must be recognised by the marker
            -- PREFIX, or the user's file grows a second copy of the block.
            stub.set_file(".gitignore", "# Cook artifacts (added by cook init)\n.cook/**\n")
            run()
            local ignore = stub.file(".gitignore")
            assert.equals(1, select(2, ignore:gsub("# Cook artifacts %(added by cook", "")))
            assert.is_truthy(ignore:find("(added by cook init)", 1, true))
        end)

        it("leaves a file that already carries both sections byte-identical", function()
            local before = "# Cook artifacts (added by cook init)\n.cook/**\n\nbuild/\n"
            stub.set_file(".gitignore", before)
            run()
            assert.equals(before, stub.file(".gitignore"))
        end)
    end)

    describe(".clang-format that is already there", function()
        it("is left alone rather than refused over", function()
            -- Formatting policy belongs to the author, and cc.new has nothing
            -- to add to a file they already wrote. Refusing the whole scaffold
            -- over it would be the wrong trade.
            stub.set_file(".clang-format", "BasedOnStyle: Google\n")
            run()
            assert.equals("BasedOnStyle: Google\n", stub.file(".clang-format"))
            assert.is_truthy(stub.file("src/main.cpp"))
        end)
    end)

    describe("output", function()
        it("names everything it touched and the commands to run next", function()
            local lines = {}
            report.emit = function(l) lines[#lines + 1] = l end
            run()
            assert.same({
                "  created  src/main.cpp",
                "  created  include/greet.hpp",
                "  created  tests/main.cpp",
                "  created  .clang-format",
                "  created  .gitignore",
                "  updated  Cookfile",
                "",
                "  try: cook build && cook run",
            }, lines)
        end)

        it("says what it skipped rather than staying silent about it", function()
            stub.set_file(".clang-format", "BasedOnStyle: Google\n")
            stub.set_file(".gitignore", "# Cook artifacts (added by cook)\nbuild/\n")
            local lines = {}
            report.emit = function(l) lines[#lines + 1] = l end
            run()
            assert.same({
                "  created  src/main.cpp",
                "  created  include/greet.hpp",
                "  created  tests/main.cpp",
                "  skipped  .clang-format",
                "  skipped  .gitignore",
                "  updated  Cookfile",
                "",
                "  try: cook build && cook run",
            }, lines)
        end)
    end)

    describe("refusals", function()
        local function refuse()
            local before = stub.file("Cookfile")
            local ok, err = pcall(run)
            assert.is_false(ok, "expected a refusal")
            assert.equals(before, stub.file("Cookfile"), "the Cookfile must be untouched")
            return err
        end

        it("refuses when there is no Cookfile", function()
            stub.reset(); stub.install()
            new, report = fresh()
            local ok, err = pcall(run)
            assert.is_false(ok)
            assert.is_truthy(err:find("cc.new: no Cookfile in this directory", 1, true))
        end)

        it("refuses a Cookfile that already declares build, naming the line", function()
            -- `cook init`'s hello-world template. The blessed flow never runs
            -- it, but people will.
            stub.set_file("Cookfile", 'use cook_cc\n\nrecipe build\n    cook "out" { : > $<out> }\n')
            local err = refuse()
            assert.equals("cc.new: 'build' is already declared in Cookfile:3\n"
                .. "  cc.new bootstraps a project that has none of build, run, test;"
                .. " add to one that does with cook cc.add", err)
        end)

        it("refuses when a chore owns one of the names, since they share a namespace", function()
            stub.set_file("Cookfile", "use cook_cc\n\nchore run\n    echo hi\n")
            local err = refuse()
            assert.is_truthy(err:find("cc.new: 'run' is already declared in Cookfile:3", 1, true))
        end)

        it("refuses when the test recipe's name is taken", function()
            stub.set_file("Cookfile", "use cook_cc\n\nrecipe test\n    echo hi\n")
            local err = refuse()
            assert.is_truthy(err:find("cc.new: 'test' is already declared in Cookfile:3", 1, true))
        end)

        it("refuses a Cookfile that already configures the toolchain", function()
            -- The fourth thing the block writes, and the one with no name to
            -- clash: toolchain.set is last-write-wins, so appending a second
            -- call would move a project that asked for c++17 to c++20 without
            -- saying so. Nothing else here would have caught it.
            stub.set_file("Cookfile",
                'use cook_cc\n\ncook_cc.toolchain({ standard = "c++17" })\n')
            local err = refuse()
            assert.equals("cc.new: Cookfile:3 already configures the toolchain\n"
                .. "  cc.new writes its own cook_cc.toolchain call, and the later call wins;"
                .. " add targets to a configured project with cook cc.add", err)
        end)

        it("recognises the toolchain call under the local this Cookfile binds", function()
            stub.set_file("Cookfile",
                'use cc ./vendor/cook_cc.lua\n\ncc.toolchain({ standard = "c++17" })\n')
            local err = refuse()
            assert.is_truthy(err:find("Cookfile:3 already configures the toolchain", 1, true))
            assert.is_truthy(err:find("its own cc.toolchain call", 1, true))
        end)

        it("does not mistake an indented toolchain call for a top-level one", function()
            -- Only a column-0 module call is top-level (§4.4). An indented one
            -- is inside somebody's recipe body and is not the register-phase
            -- state this verb would be overriding.
            stub.set_file("Cookfile",
                'use cook_cc\n\nregister\n    cook_cc.toolchain({ standard = "c++17" })\n')
            run()
            assert.is_truthy(stub.file("src/main.cpp"))
        end)

        it("refuses when the program's source is already there", function()
            stub.set_file("src/main.cpp", "// mine\n")
            local err = refuse()
            assert.equals("cc.new: 'src/main.cpp' already exists\n"
                .. "  cc.new lays down a project's first sources;"
                .. " it will not write over anything it did not make", err)
        end)

        it("refuses when only the test's source is already there", function()
            stub.set_file("tests/main.cpp", "// mine\n")
            local err = refuse()
            assert.is_truthy(err:find("cc.new: 'tests/main.cpp' already exists", 1, true))
        end)

        it("refuses when only the header is already there", function()
            stub.set_file("include/greet.hpp", "// mine\n")
            local err = refuse()
            assert.is_truthy(err:find("cc.new: 'include/greet.hpp' already exists", 1, true))
        end)

        it("writes nothing at all when it refuses", function()
            stub.set_file("include/greet.hpp", "// mine\n")
            pcall(run)
            assert.is_nil(stub.file("src/main.cpp"))
            assert.is_nil(stub.file("tests/main.cpp"))
            assert.is_nil(stub.file(".clang-format"))
            assert.is_nil(stub.file(".gitignore"))
        end)

        it("checks the Cookfile's names before it checks the disk", function()
            -- Both are wrong here. The declaration clash is the one that says
            -- "this project is past bootstrapping", which is the more useful
            -- thing to hear first.
            stub.set_file("Cookfile", "use cook_cc\n\nrecipe build\n    echo hi\n")
            stub.set_file("src/main.cpp", "// mine\n")
            local err = refuse()
            assert.is_truthy(err:find("'build' is already declared", 1, true))
        end)
    end)
end)
