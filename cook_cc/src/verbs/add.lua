-- cook_cc.verbs.add — `cook cc.add <kind> <name>`: scaffold a target's files
-- and register it as a recipe
-- domain:  verbs — project-management commands the module registers
-- effects: cook.chore; writes source files; appends to the Cookfile
-- std:     §22.12, §22.13
--
-- The cargo-for-C++ move: adding a library to a project should be one command,
-- not a directory to create, two files to write and a recipe to remember the
-- shape of. What this verb hands back is a target that builds — the whole
-- claim of the milestone is that no editing follows it.
local project = require("cook_cc.verbs._project")
local report  = require("cook_cc.verbs._report")

local VERB = "cc.add"

local M = {}

-- The scaffolds, keyed by the kind the user types. This table is the verb's
-- extension point and its vocabulary at once: `accepted kinds` in the
-- diagnostic is read off it, so a new row is a new accepted kind with no
-- second place to update.
--
-- `cook_cc` also exports `shared` and `headers` makers, and each is one row
-- here when someone decides what its files should look like — a `shared`
-- differs from a `lib` only in the maker it calls, and a `headers` target has
-- no `src/` side at all. Until then an unknown kind is refused rather than
-- guessed at, because a recipe pointing at files nobody wrote is worse than a
-- refusal.
--
-- A row returns `files` (path -> content, written in order via `order`) and
-- the `recipe` text to append.
local SCAFFOLDS = {}

SCAFFOLDS.lib = function(name)
    local guard = name:gsub("[^%w]", "_")
    return {
        order = { "src/" .. name .. "/" .. name .. ".cpp",
                  "include/" .. name .. "/" .. name .. ".hpp" },
        files = {
            ["include/" .. name .. "/" .. name .. ".hpp"] = table.concat({
                "#pragma once",
                "",
                "namespace " .. guard .. " {",
                "",
                "// Returns the answer this library was created to give.",
                "int answer();",
                "",
                "}  // namespace " .. guard,
                "",
            }, "\n"),
            ["src/" .. name .. "/" .. name .. ".cpp"] = table.concat({
                '#include "' .. name .. "/" .. name .. '.hpp"',
                "",
                "namespace " .. guard .. " {",
                "",
                "int answer() {",
                "    return 42;",
                "}",
                "",
                "}  // namespace " .. guard,
                "",
            }, "\n"),
        },
        -- `dir` globs the directory recursively (§28.3.1.1), so every later
        -- file the author adds under it is picked up without a Cookfile edit.
        -- That is the right default for a library: its sources are "this
        -- directory", not a list somebody has to maintain.
        --
        -- `includes` is not decoration. The scaffolded .cpp includes its own
        -- header as `"<name>/<name>.hpp"`, which resolves only with `include/`
        -- on the search path; without this the very first `cook <name>` after
        -- `cc.add` fails to compile. It also carries to consumers: §28.4 falls
        -- `export_includes` back to `includes`, so whatever `cc.link` wires up
        -- later can include this library's header with no further edit.
        recipe = "recipe " .. name .. "\n"
            .. '    cook_cc.lib({ dir = "src/' .. name .. '/", includes = { "include" } })\n',
    }
end

SCAFFOLDS.bin = function(name)
    local main = "src/" .. name .. "/main.cpp"
    return {
        order = { main },
        files = {
            [main] = table.concat({
                "#include <cstdio>",
                "",
                "int main() {",
                '    std::printf("' .. name .. '\\n");',
                "    return 0;",
                "}",
                "",
            }, "\n"),
        },
        -- Named explicitly rather than globbed: a program is one entry point
        -- plus whatever it links, and `cc.link` is the verb that grows it.
        recipe = "recipe " .. name .. "\n"
            .. '    cook_cc.bin({ sources = { "' .. main .. '" } })\n',
    }
end

local function accepted_kinds()
    local kinds = {}
    for k in pairs(SCAFFOLDS) do kinds[#kinds + 1] = k end
    table.sort(kinds)
    return table.concat(kinds, ", ")
end

-- The body. Separated from `register` so it is reachable from a spec without
-- a dispatch, and so the parameter names are visible in one place.
--
-- Every refusal happens before the first write. A verb that scaffolded two
-- files and then discovered the name was taken would leave the project in a
-- state the user did not ask for and this verb cannot undo.
function M.run(kind, name)
    local scaffold = SCAFFOLDS[kind]
    if not scaffold then
        report.fail(VERB, "unknown kind '" .. tostring(kind) .. "'",
            "accepted kinds: " .. accepted_kinds())
    end
    project.check_name(VERB, name)

    local cookfile = project.cookfile(VERB)
    local clash = project.declared(VERB, name)
    if clash then
        report.fail(VERB,
            "'" .. name .. "' is already declared in " .. cookfile .. ":" .. clash.line,
            "pick another name, or edit that declaration yourself")
    end

    local plan = scaffold(name)
    local root = "src/" .. name
    if fs.exists(root) then
        report.fail(VERB, "'" .. root .. "/' already exists",
            "cc.add creates a target's files; it will not write into a directory it did not make")
    end

    for _, path in ipairs(plan.order) do
        fs.mkdir_p(path:match("^(.*)/[^/]+$"))
        fs.write(path, plan.files[path])
        report.did("created", path)
    end

    -- §22.13: the blessed editor, which guarantees one blank line before the
    -- appended block and leaves every other byte of the file alone. Appending
    -- at end of file rather than splicing into a `register` block is
    -- deliberate for now — it cannot mangle what is already there.
    cook.cookfile.append(cookfile, plan.recipe)
    report.did("updated", cookfile)
    report.suggest(name)
end

-- §22.12: called during cook_cc's own chunk evaluation, never later.
function M.register()
    cook.chore(VERB, {
        origin = "cook_cc.verbs.add",
        __params = {
            { kind = "required", name = "kind" },
            { kind = "required", name = "name" },
        },
    }, function(params)
        M.run(params.kind, params.name)
    end)
end

return M
