-- cook_cc.verbs._project — the project as a cc.* verb sees it: where the Cookfile is, what it declares, what cook_cc is bound as, and which targets are which kind
-- domain:  verbs — project-management commands the module registers
-- phase:   register (a verb body is register-phase Lua)
-- effects: reads the Cookfile; raises
-- std:     §22.12, §22.13, App. A.5
--
-- Every verb needs the same answers before it can act, and each of them has a
-- wrong version that looks right. Answering them once, here, is what keeps
-- five verbs from acquiring five subtly different ideas of what counts as an
-- existing target.
--
-- This module only READS. Writing back is `cook.cookfile.*` (§22.13) and
-- nothing here duplicates it: a second Cookfile editor is exactly what that
-- section exists to prevent.
local report = require("cook_cc.verbs._report")

local M = {}

-- The target makers cook_cc exports (§28). A verb classifies a recipe by the
-- maker it calls, so this is the whole vocabulary of "kind" in the verb layer.
-- `cc.add` scaffolds a subset of it; see `verbs/add.lua`.
M.KINDS = { bin = true, lib = true, shared = true, headers = true }

-- App. A.5 BARE_IDENTIFIER, minus the dot that App. A bans at a declaration
-- site. Spelled once so the diagnostic and the check cannot disagree.
local NAME_PATTERN = "^[A-Za-z_][A-Za-z0-9_%-]*$"
local NAME_RULE =
    "a target name starts with a letter or underscore and continues with letters, digits, '_' or '-'"

-- Run a `cook.cookfile.*` call and re-raise any failure in this module's voice.
--
-- Those calls raise on their own terms — an unparseable Cookfile comes back as
-- `cook.cookfile.find_call: /abs/path/Cookfile: …`, with an absolute path and
-- no verb name. That is a perfectly good message from the engine and the wrong
-- shape from a verb, and it is the one way a verb can bypass `_report` without
-- meaning to. Every verb's `cook.cookfile.*` call goes through here, including
-- the write side, which is why it is exported.
function M.edit(verb, what, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        -- The engine prefixes its own API name and an absolute path, and the
        -- Lua host prefixes `runtime error: ` in front of both; keep the
        -- explanation, drop the lead-in that names a function the user never
        -- called and a path they are standing in.
        --
        -- Two patterns because the second is the fallback: an error raised
        -- before the file was resolved carries no path to strip, and an
        -- anchored pattern expecting one would leave the whole lead-in in
        -- place. That is how the original single pattern failed — it anchored
        -- `^[^:]*` at a string beginning `runtime error: `, whose colon it
        -- could not cross, so it matched nothing and every engine message
        -- reached the user raw.
        local text = tostring(result)
        local detail, hit = text:gsub("^.-cook%.cookfile%.[%w_]+: [^:]*: ", "", 1)
        if hit == 0 then detail = text:gsub("^.-cook%.cookfile%.[%w_]+: ", "", 1) end
        report.fail(verb, what .. ": " .. detail)
    end
    return result
end

-- The root Cookfile, as a path the sandbox accepts (§22.13 resolves relative
-- to the project root, and chore dispatch only ever binds to the root member,
-- so this is the file the verbs edit).
--
-- The CLI reaches a chore only after finding a Cookfile — it searches upward
-- from the invocation directory and runs from where it found one, so a verb
-- invoked from `src/` still sees the project root and writes root-relative
-- paths. This check therefore rarely fires from a normal dispatch; it is here
-- so that "there is no project here" has one diagnostic rather than five
-- different nil-index errors.
function M.cookfile(verb)
    if not fs.exists("Cookfile") then
        report.fail(verb, "no Cookfile in this directory",
            "start one with: cook modules install cook_cc, which writes the `use` line these verbs need")
    end
    return "Cookfile"
end

-- Every top-level `recipe` / `chore` declaration, in file order, as
-- `{ name, keyword, line }`.
--
-- Scanning text rather than asking the engine is not a shortcut: no
-- register-phase API enumerates the registered names, and `cook.cookfile`
-- answers about one named recipe at a time.
--
-- What the scan is: the declaration keywords are recognised only at column 0
-- (§3), so a column-0 `recipe`/`chore` line is a declaration and an indented
-- one is body text. Two known limits, both of which over-report rather than
-- under-report — a wrong refusal, never a corrupted Cookfile:
--
--  1. A `cook "out" { … }` step's block is consumed raw, carrying quote and
--     heredoc state across lines, so a column-0 `recipe ghost` written inside
--     a heredoc is body text that this scan reads as a declaration.
--  2. It sees only SURFACE declarations. A name minted at register time — by a
--     `register` block calling `cook.recipe`, or by another module's top-level
--     call — occupies the same callable namespace and is invisible here. This
--     one under-reports, and the engine catches it: appending a colliding name
--     produces a register-phase collision diagnostic rather than a silent
--     wrong build. cook_cc's own makers stopped minting recipes at 0.13.0, so
--     the vector is other modules, not this one.
function M.declarations(verb)
    local path = M.cookfile(verb)
    local out = {}
    local line = 0
    for text in (fs.read(path) .. "\n"):gmatch("([^\n]*)\n") do
        line = line + 1
        for _, keyword in ipairs({ "recipe", "chore" }) do
            -- The separator after the keyword is required and is a space, a
            -- tab or a `"` (§7.1) — which is what keeps `recipes_are_nice = 1`
            -- from reading as a declaration.
            local rest = text:match("^" .. keyword .. "[ \t\"](.*)$")
            if rest then
                -- The quote consumed by the class above is put back, so both
                -- spellings reach one name matcher.
                if text:sub(#keyword + 1, #keyword + 1) == '"' then rest = '"' .. rest end
                local name = rest:match('^%s*"([^"]*)"') or rest:match("^%s*([^%s:]+)")
                if name then
                    out[#out + 1] = { name = name, keyword = keyword, line = line }
                end
                break
            end
        end
    end
    return out
end

-- The declaration that already owns `name`, or nil.
--
-- This is the collision check as far as the Cookfile's TEXT goes; limit 2 on
-- `declarations` above is the part it cannot see, and the engine catches that
-- part. `cook.cookfile.find_call` cannot serve even this much:
-- that call answers nil both for a recipe that does not exist and for one that
-- exists without a module call, so a verb keying off it would happily append a
-- second `recipe math` and leave the author with a Cookfile that no longer
-- parses (App. A duplicate-declaration rule). Recipes and chores share one
-- callable namespace, so both count.
function M.declared(verb, name)
    for _, decl in ipairs(M.declarations(verb)) do
        if decl.name == name then return decl end
    end
    return nil
end

-- What this Cookfile binds cook_cc as — the name a generated call must use.
--
-- Almost always `cook_cc`, and the answer matters exactly when it is not: a
-- project that patched the module with the path form (`use ./vendor/cc.lua`,
-- §27.1.2) binds a different local, and a verb that wrote `cook_cc.lib(...)`
-- there would append a call to a global that does not exist. Reading the
-- Cookfile tolerantly and then writing to it assumptively is the worst of the
-- two, so both ends use this.
--
-- The three spellings and what each binds (§12.1): `use cook_cc` and
-- `use cook_cc ./vendor/cc.lua` both bind `cook_cc`; `use ./cook_cc.lua` binds
-- the basename without its extension.
--
-- Which `use` line is ours is a separate question from what it binds, and only
-- the recognisable cases are answered: the local is already `cook_cc`, or the
-- line mentions cook_cc somewhere. `use mycc ./vendor/patched.lua` is genuinely
-- undecidable from the Cookfile alone, and falls back to `cook_cc` rather than
-- guessing that some unrelated module is this one.
function M.alias(verb)
    local path = M.cookfile(verb)
    for text in (fs.read(path) .. "\n"):gmatch("([^\n]*)\n") do
        local rest = text:match("^use[ \t\"](.*)$")
        if rest then
            if text:sub(4, 4) == '"' then rest = '"' .. rest end
            local first = rest:match('^%s*"([^"]*)"') or rest:match("^%s*(%S+)")
            local has_second = (rest:match('^%s*"[^"]*"%s+%S') or rest:match("^%s*%S+%s+%S")) ~= nil
            local bound = first
            if first and not has_second and first:match("%.lua$") then
                bound = first:match("([^/]+)%.lua$")
            end
            if bound == "cook_cc" then return bound end
            if bound and rest:find("cook_cc", 1, true) then return bound end
        end
    end
    return "cook_cc"
end

-- Every declared recipe that calls a cook_cc target maker, as
-- `name -> { kind, callee }`.
--
-- Both halves of the callee are checked. The module half must be the local
-- this Cookfile binds cook_cc as, so a project that renamed it classifies the
-- same as one that did not, and another module's maker is left out rather than
-- misfiled — `cook_pnpm.workspace` is not a C++ target, and neither is a
-- `cook_pnpm.lib` if one ever exists. The maker half must name a kind cook_cc
-- actually exports.
--
-- No verb in this directory calls it yet. It is here because COOK-281's
-- decomposition puts the wrong-order self-heal in `cc.link` ("the chore knows
-- which names are bins and which are libs") and the optional trailing target
-- in `cc.need`, and both read exactly this.
--
-- Costs one full parse of the Cookfile per declared recipe, because
-- `find_call` takes a path and re-reads. Fine at the scale a hand-written
-- Cookfile reaches; do not build a loop on top of it.
function M.targets(verb)
    local path = M.cookfile(verb)
    local cc = M.alias(verb)
    local out = {}
    for _, decl in ipairs(M.declarations(verb)) do
        if decl.keyword == "recipe" then
            local call = M.edit(verb, "could not read " .. path,
                cook.cookfile.find_call, path, decl.name)
            if call then
                local module, kind = call.callee:match("^(.+)%.([^.]+)$")
                if module == cc and M.KINDS[kind] then
                    out[decl.name] = { kind = kind, callee = call.callee }
                end
            end
        end
    end
    return out
end

-- Refuse a name this verb layer will not create, before anything is written.
--
-- Narrower than the grammar on purpose. App. A.5 admits a quoted `recipe "my
-- lib"`, and `declarations` above will happily read one — but these verbs turn
-- a name into directories and filenames as well as a declaration, and a name
-- that needs quoting makes a poor one of those. So this is a policy of the
-- verbs, and the message says so rather than claiming the Cookfile would
-- reject it.
--
-- Catching it here rather than letting the appended declaration fail to parse
-- is the difference between a message about the name the user typed and a
-- parse error in a file the verb just edited.
function M.check_name(verb, name)
    if type(name) == "string" and name:match(NAME_PATTERN) then return end
    local hint = NAME_RULE
    if type(name) == "string" and name:find(".", 1, true) then
        hint = "dotted names are not permitted at a declaration site; namespacing across Cookfiles uses `import`"
    end
    report.fail(verb, "'" .. tostring(name) .. "' is not a name " .. verb .. " will create", hint)
end

-- The entries of `field`'s list in `name`'s module call, as written, or nil
-- when there is no such field (§22.13, CS-0221).
--
-- A verb asks this to be idempotent, and it asks the ENGINE rather than
-- scanning `find_call`'s text itself. The obvious Lua answer to "is `math`
-- already in `links`" is to search the call text for `"math"`, and that
-- matches inside `sources = { "src/math/main.cpp" }` — a skip that silently
-- drops the edge the user asked for. Locating a top-level key and splitting a
-- list without tripping over a comma inside a nested table, a call, a string
-- or a comment is the same work §22.13 already specifies for the write side.
function M.entries(verb, name, field)
    local path = M.cookfile(verb)
    return M.edit(verb, "could not read " .. field .. " in " .. name,
        cook.cookfile.field_entries, path, name, field)
end

-- The name a list entry spells, or nil when it does not spell one.
--
-- Entries come back verbatim, so `"math"` and `'math'` both name math and both
-- have to be recognised — an author's Cookfile is not obliged to use the
-- quoting these verbs generate. Anything else (an identifier, a table, a call)
-- is a value this layer cannot resolve, and answering nil rather than guessing
-- means a comparison against it never matches: the verb then adds an entry
-- that may be redundant, which is a great deal better than silently skipping
-- one the user asked for.
function M.entry_name(entry)
    return entry:match('^"([^"]*)"$') or entry:match("^'([^']*)'$")
end

return M
