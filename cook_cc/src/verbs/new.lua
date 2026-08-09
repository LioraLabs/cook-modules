-- cook_cc.verbs.new — `cook cc.new`: scaffold a working C++ project around the Cookfile that is already here
-- domain:  verbs — project-management commands the module registers
-- phase:   register (a verb body is register-phase Lua)
-- effects: cook.chore; writes source files; appends to the Cookfile
-- std:     §22.12, §22.13, §28.3
--
-- The first minute of the milestone's pitch:
--
--     mkdir game && cd game
--     cook modules install cook_cc
--     cook cc.new
--     cook build && cook run
--
-- In-place only. `cook modules install` is what creates the Cookfile and
-- writes the `use` line (CS-0220), because the cc.* chores do not exist until
-- something has loaded cook_cc — a chore can never be the thing that
-- bootstraps a project from nothing. So by the time this verb runs there is
-- always a Cookfile, and its whole job is to fill in what a project needs
-- around it.
local project = require("cook_cc.verbs._project")
local report  = require("cook_cc.verbs._report")

local VERB = "cc.new"

local M = {}

-- The names the template declares, and the list the clash check walks before
-- anything is written.
--
-- It restates what `cookfile_block` below emits rather than generating it: the
-- block is the thing a user reads, and deriving its headers from a list would
-- cost that legibility to save three strings. `new_spec`'s
-- "declares exactly the names it checks for" reads the generated block back
-- and compares, so the restatement cannot drift silently — which is the only
-- property that mattered.
local DECLARES = { "build", "run", "test" }

-- The project's own sources, in the order they are written and reported.
--
-- Three files rather than the two the milestone strictly needs, and `include/`
-- carries a real header rather than being an empty directory. That buys three
-- things at once: `includes = { "include" }` in the generated recipes is
-- load-bearing rather than decoration (which is what COOK-285 learned the hard
-- way), the test has something true to assert instead of `assert(true)`, and
-- an empty directory git will not track never appears.
local SOURCES = {
    { path = "src/main.cpp", content = [[
#include <iostream>

#include "greet.hpp"

int main() {
    std::cout << greet("world") << "\n";
    return 0;
}
]] },
    { path = "include/greet.hpp", content = [[
#pragma once

#include <string>

// Your project's own code, in a header that both the program and its tests
// include. `includes = { "include" }` in the Cookfile is what puts this
// directory on the compiler's search path.
//
// When a header stops being enough, `cook cc.add lib <name>` scaffolds a
// library next to this one.
inline std::string greet(const std::string &name) {
    return "Hello, " + name + "!";
}
]] },
    { path = "tests/main.cpp", content = [[
// Assert-based on purpose: there is no framework to install and nothing to
// learn before the first test runs. Swap in doctest or Catch2 whenever you
// want one — the Cookfile's `test` recipe does not care which you use. It
// compiles this one file by name, so a second test file means adding it to
// that recipe's `sources` list.
//
// The `#undef` is not boilerplate. Asking the toolchain call for
// `optimize = "speed"` (or "size", or "max") adds -DNDEBUG, which compiles
// every assert away — leaving a test that passes without checking anything.
#undef NDEBUG
#include <cassert>
#include <cstdio>

#include "greet.hpp"

int main() {
    assert(greet("world") == "Hello, world!");
    std::printf("ok - greet\n");
    return 0;
}
]] },
}

-- Written when absent, left alone when present: formatting policy belongs to
-- whoever wrote the file that is already there, and cc.new has nothing to add
-- to it. `cc.fmt` (COOK-290) is the consumer.
-- Not a nicety: `cc.fmt` (COOK-290) REFUSES unless the project declares a
-- style at its root, because `clang-format -style=file` with no config
-- anywhere silently falls back to LLVM defaults and exits 0 — reflowing a
-- whole tree to a style nobody chose. This is the file that keeps the first
-- `cook cc.fmt` in a scaffolded project from refusing.
--
-- The settings are COOK-290's, measured against clang-format 22.1.8 and chosen
-- so that what these verbs scaffold is a FIXPOINT of cc.fmt: bare
-- `BasedOnStyle: LLVM` collapses cc.add's `int answer() { return 42; }` onto
-- one line and eats a space before `// namespace math`, so a project would
-- come out of `cc.add` already unformatted. Verified here too, on this verb's
-- own three sources.
local CLANG_FORMAT = { path = ".clang-format", content = [[
# Read by `cook cc.fmt`, and by every editor that speaks clang-format.
BasedOnStyle: LLVM
IndentWidth: 4
ColumnLimit: 100
AllowShortFunctionsOnASingleLine: None
SpacesBeforeTrailingComments: 2
]] }

-- The Cook-managed `.gitignore` section, byte-identical to
-- `COOK_GITIGNORE_SECTION` in cook-cli's `pipeline.rs`, and keyed off the same
-- marker PREFIX. Two implementations of one section is a duplication worth
-- naming: this one is Lua in a module and that one is Rust in the engine, so
-- there is no shared place to put it, and the marker is what keeps them
-- idempotent against each other. Whichever runs second finds the marker and
-- does nothing.
--
-- Why cc.new writes it at all, when `cook modules install` already does: that
-- one merges the section only when it CREATED the Cookfile. A project whose
-- Cookfile was written by hand — or by an older release — reaches cc.new with
-- no ignore rules and a `.cook/` tree its next `git add` would commit.
local GITIGNORE_PATH = ".gitignore"
local GITIGNORE_MARKER = "# Cook artifacts (added by cook"
local GITIGNORE_SECTION = [[
# Cook artifacts (added by cook)
# .cook/ holds caches, per-project state, and the luarocks tree that
# `cook modules install` populates (.cook/modules/). cloud.toml is the one
# tracked file. Everything cook generates is under here, so one rule covers it.
# Your own Lua is not: a module you wrote lives wherever you put it in the
# repo and is reached by path (`use ./lua/helpers.lua`).
.cook/**
**/.cook/**
!**/.cook/
!**/.cook/cloud.toml
]]

-- The C++ half, which the managed section deliberately does not cover: its own
-- comment in the engine says only unambiguously Cook-specific entries belong
-- there, and that language and toolchain ignores are the user's call.
--
-- They are cc.new's call. This IS the toolchain verb, and it has just written
-- a Cookfile whose artifact root is not a matter of opinion — `cook_cc` links
-- into `build/bin/`, archives into `build/lib/` and compiles into
-- `build/obj/`. Without this the second command of the pitch produces a
-- binary, and the `git add -A` after it commits one.
--
-- Its own marker, and appended after the managed section rather than merged
-- into it, so the engine's copy stays byte-identical to the engine's and
-- either half can be recognised on its own.
local CXX_IGNORE_MARKER = "# C++ build artifacts (added by cook cc.new)"
local CXX_IGNORE_SECTION = [[
# C++ build artifacts (added by cook cc.new)
# cook_cc links into build/bin/, archives into build/lib/ and compiles into
# build/obj/. Delete this if you would rather track them.
build/
]]

-- The block appended to the Cookfile. `cc` is the local this Cookfile binds
-- cook_cc as (§27.1.2), not a hardcoded `cook_cc`.
--
-- Three decisions in here that a scratch project settled and a spec cannot:
--
--  * `cook_cc.toolchain(...)` is a column-0 top-level module call (§4.4),
--    first in the block because that is the order it reads in. Its REACH does
--    not depend on that: top-level calls all run during the register pass and
--    recipe bodies are forced after it, so a target declared earlier in the
--    file still sees these settings. Verified against a project where
--    `cc.add lib math` had already appended a recipe above this block: the
--    compile carried `-std=c++20`. What the block must not do is append a
--    SECOND toolchain call, since `toolchain.set` is last-write-wins; `run`
--    refuses rather than write one over a call the author already made.
--  * `chore run: build` — the dependency list is what gates the body, so the
--    binary is current before it is executed (§7.5, §16.2.1).
--  * `test { ./build/bin/test }` names the binary as a literal path. The
--    obvious `test { ./$<in> }` is a codegen ERROR here: `$<in>` needs a
--    preceding surface `cook` step or an `ingredients` declaration, and a
--    module call is neither. `ingredients "build/bin/test"` would not rescue
--    it either — that is a register-phase glob (§16.1.2.2) and matches nothing
--    on a cold tree. The literal path is fine: §15.1 puts the test step's
--    group behind every unit the maker registered above it in the same body,
--    so the binary exists, and it re-runs when the binary changes.
local function cookfile_block(cc)
    return table.concat({
        "# Compiler settings every target below inherits.",
        cc .. '.toolchain({ standard = "c++20", warnings = "strict" })',
        "",
        "# `cook build` — and a bare `cook`, since build is the default target.",
        "recipe build",
        "    " .. cc .. '.bin({ sources = { "src/main.cpp" }, includes = { "include" } })',
        "",
        "# `cook run` — the dependency list builds the binary before running it.",
        "chore run: build",
        "    ./build/bin/build",
        "",
        "# `cook test` — builds the test binary, then runs it.",
        "recipe test",
        "    " .. cc .. '.bin({ sources = { "tests/main.cpp" }, includes = { "include" } })',
        "    test { ./build/bin/test }",
        "",
    }, "\n")
end

-- The line of `cookfile` that already configures the toolchain, or nil.
--
-- A text scan for the same reason `_project.declarations` is one: no
-- register-phase API enumerates a Cookfile's top-level calls, and
-- `cook.cookfile.find_call` answers about a call inside a NAMED recipe, which
-- this is not. Column 0 is exactly what makes a module call top-level (§4.4),
-- so an indented `toolchain` call inside somebody's recipe body is not this
-- and is correctly not matched.
--
-- `cc` is a `use` local, so it is a bare identifier and safe in the pattern.
local function toolchain_line(cookfile, cc)
    local line = 0
    for text in (fs.read(cookfile) .. "\n"):gmatch("([^\n]*)\n") do
        line = line + 1
        if text:find("^" .. cc .. "%.toolchain%s*[({\"']") then return line end
    end
    return nil
end

-- Merge the managed sections into `.gitignore`. Returns the action to report:
-- "created", "updated" or "skipped".
--
-- The whitespace rules are the Rust helper's, deliberately: separate an
-- appended section from what precedes it by one blank line, and give an
-- unterminated last line its newline back first, so appending to `*.o` (no
-- trailing newline) does not produce `*.o# Cook artifacts`.
local function append_section(text, section)
    if text == "" then return section end
    local out = text
    if out:sub(-1) ~= "\n" then out = out .. "\n" end
    return out .. "\n" .. section
end

-- Does this file already ignore cook_cc's artifact root? Only the spellings
-- git reads as "that whole directory" count, and a negation (`!build/`) is a
-- deliberate choice this verb has no business overturning — it is not one of
-- these, so it does not match, and the section is appended below it where git
-- gives the later rule precedence anyway.
local function ignores_build(text)
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local rule = line:gsub("%s+$", "")
        if rule == "build" or rule == "build/" or rule == "/build" or rule == "/build/" then
            return true
        end
    end
    return false
end

local function merge_gitignore()
    local existed = fs.exists(GITIGNORE_PATH)
    local out = existed and fs.read(GITIGNORE_PATH) or ""
    local before = out

    if not out:find(GITIGNORE_MARKER, 1, true) then
        out = append_section(out, GITIGNORE_SECTION)
    end
    if not out:find(CXX_IGNORE_MARKER, 1, true) and not ignores_build(out) then
        out = append_section(out, CXX_IGNORE_SECTION)
    end

    if out == before then return "skipped" end
    fs.write(GITIGNORE_PATH, out)
    return existed and "updated" or "created"
end

-- The body. Separated from `register` so a spec can reach it without a
-- dispatch.
--
-- Every refusal happens before the first write, and the Cookfile is asked
-- everything before the disk is. Both orderings matter. The first is the rule
-- this whole directory follows: a verb that wrote two files and then found the
-- third was taken would leave a mess it cannot undo. The second is about which
-- diagnostic is more useful — a project that already declares `build` is past
-- bootstrapping, and hearing that is more use than hearing which file happened
-- to be checked first.
--
-- One qualification on "before the first write", since an unqualified claim
-- here would be a false one: the Cookfile append is last, so a failure THERE
-- leaves the scaffolded files with no recipes to build them. That call is
-- `cook.cookfile.append`, which adds a top-level declaration and so has no
-- recipe, call or field it could fail to find — unlike `splice_field`, its
-- only failure mode is I/O. And an unparseable Cookfile cannot reach here at
-- all: the CLI has to parse the file to find this chore, so `cook cc.new`
-- fails at dispatch, before the verb runs. Verified both.
function M.run()
    local cookfile = project.cookfile(VERB)
    local cc = project.alias(VERB)

    for _, name in ipairs(DECLARES) do
        local clash = project.declared(VERB, name)
        if clash then
            report.fail(VERB,
                "'" .. name .. "' is already declared in " .. cookfile .. ":" .. clash.line,
                "cc.new bootstraps a project that has none of " .. report.list(DECLARES)
                    .. "; add to one that does with cook cc.add")
        end
    end

    -- The fourth thing the block writes, and the one with no name to clash.
    -- `toolchain.set` is last-write-wins, so appending a second call would
    -- move a project that had asked for c++17 to c++20 without saying so.
    local configured = toolchain_line(cookfile, cc)
    if configured then
        report.fail(VERB,
            cookfile .. ":" .. configured .. " already configures the toolchain",
            "cc.new writes its own " .. cc .. ".toolchain call, and the later call wins;"
                .. " add targets to a configured project with cook cc.add")
    end

    for _, file in ipairs(SOURCES) do
        if fs.exists(file.path) then
            report.fail(VERB, "'" .. file.path .. "' already exists",
                "cc.new lays down a project's first sources;"
                    .. " it will not write over anything it did not make")
        end
    end

    for _, file in ipairs(SOURCES) do
        fs.mkdir_p(path.dir(file.path))
        fs.write(file.path, file.content)
        report.did("created", file.path)
    end

    if fs.exists(CLANG_FORMAT.path) then
        report.did("skipped", CLANG_FORMAT.path)
    else
        fs.write(CLANG_FORMAT.path, CLANG_FORMAT.content)
        report.did("created", CLANG_FORMAT.path)
    end

    report.did(merge_gitignore(), GITIGNORE_PATH)

    -- §22.13: the blessed editor. It guarantees one blank line before the
    -- appended block and leaves every other byte of the file alone, which is
    -- what makes appending to a Cookfile somebody else wrote safe.
    project.edit(VERB, "could not append to " .. cookfile,
        cook.cookfile.append, cookfile, cookfile_block(cc))
    report.did("updated", cookfile)
    report.suggest("build && cook run")
end

-- §22.12: called during cook_cc's own chunk evaluation, never later.
function M.register()
    cook.chore(VERB, {
        origin = "cook_cc.verbs.new",
        __params = {},
    }, function()
        M.run()
    end)
end

return M
