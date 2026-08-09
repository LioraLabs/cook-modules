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

-- The names the template declares. Every one of them is checked against the
-- Cookfile before anything is written, and the list is spelled once so the
-- check and the block below cannot drift apart.
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
inline std::string greet(const std::string& name) {
    return "Hello, " + name + "!";
}
]] },
    { path = "tests/main.cpp", content = [[
// Assert-based on purpose: there is no framework to install and nothing to
// learn before the first test runs. Swap in doctest or Catch2 whenever you
// want one — the Cookfile's `test` recipe does not care which you use, it
// just builds this directory and runs the result.
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
local CLANG_FORMAT = { path = ".clang-format", content = [[
# Read by `cook cc.fmt`, and by every editor that speaks clang-format.
BasedOnStyle: LLVM
IndentWidth: 4
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

-- The block appended to the Cookfile. `cc` is the local this Cookfile binds
-- cook_cc as (§27.1.2), not a hardcoded `cook_cc`.
--
-- Three decisions in here that a scratch project settled and a spec cannot:
--
--  * `cook_cc.toolchain(...)` is a column-0 top-level module call (§4.4). It
--    comes first because it is register-phase state every target below reads.
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

-- Merge the managed section into `.gitignore`. Returns the action to report:
-- "created", "updated" or "skipped".
--
-- The three cases and their whitespace are the Rust helper's, deliberately:
-- separate an appended section from what precedes it by one blank line, and
-- give an unterminated last line its newline back first, so appending to
-- `*.o` (no trailing newline) does not produce `*.o# Cook artifacts`.
local function merge_gitignore()
    local path = GITIGNORE_PATH
    if not fs.exists(path) then
        fs.write(path, GITIGNORE_SECTION)
        return "created"
    end
    local existing = fs.read(path)
    if existing:find(GITIGNORE_MARKER, 1, true) then
        return "skipped"
    end
    local out = existing
    if out ~= "" then
        if out:sub(-1) ~= "\n" then out = out .. "\n" end
        out = out .. "\n"
    end
    fs.write(path, out .. GITIGNORE_SECTION)
    return "updated"
end

-- The body. Separated from `register` so a spec can reach it without a
-- dispatch.
--
-- Every refusal happens before the first write, and the Cookfile's names are
-- checked before the disk is. Both orderings matter. The first is the rule
-- this whole directory follows: a verb that wrote two files and then found the
-- third was taken would leave a mess it cannot undo. The second is about which
-- diagnostic is more useful — a project that already declares `build` is past
-- bootstrapping, and hearing that is more use than hearing which file happened
-- to be checked first.
function M.run()
    local cookfile = project.cookfile(VERB)

    for _, name in ipairs(DECLARES) do
        local clash = project.declared(VERB, name)
        if clash then
            report.fail(VERB,
                "'" .. name .. "' is already declared in " .. cookfile .. ":" .. clash.line,
                "cc.new bootstraps a project that has none of " .. report.list(DECLARES)
                    .. "; add to one that does with cook cc.add")
        end
    end

    for _, file in ipairs(SOURCES) do
        if fs.exists(file.path) then
            report.fail(VERB, "'" .. file.path .. "' already exists",
                "cc.new lays down a project's first sources;"
                    .. " it will not write over anything it did not make")
        end
    end

    for _, file in ipairs(SOURCES) do
        fs.mkdir_p(file.path:match("^(.*)/[^/]+$"))
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
        cook.cookfile.append, cookfile, cookfile_block(project.alias(VERB)))
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
