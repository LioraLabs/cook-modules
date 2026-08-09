-- cook_cc.verbs._project — the project as a cc.* verb sees it: where the
-- Cookfile is, what it already declares, and which targets are which kind
-- domain:  verbs — project-management commands the module registers
-- effects: reads the Cookfile; raises
-- std:     §22.12, §22.13, App. A.5
--
-- Every verb needs the same three answers before it can act, and each of the
-- three has a wrong version that looks right. Answering them once, here, is
-- what keeps five verbs from acquiring five subtly different ideas of what
-- counts as an existing target.
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

-- The root Cookfile, as a path the sandbox accepts (§22.13 resolves relative
-- to the project root, and chore dispatch only ever binds to the root member,
-- so this is the file the verbs edit).
--
-- Returned rather than assumed by each caller so that the "there is no
-- project here" diagnostic is written once and reads the same from every verb.
function M.cookfile(verb)
    if not fs.exists("Cookfile") then
        report.fail(verb, "no Cookfile in this directory",
            "run this from your project root, or start one with: cook modules install cook_cc")
    end
    return "Cookfile"
end

-- Every top-level `recipe` / `chore` declaration, in file order, as
-- `{ name, keyword, line }`.
--
-- Scanning text rather than asking the engine is not a shortcut: no
-- register-phase API enumerates the registered names, and `cook.cookfile`
-- answers about one named recipe at a time. The scan is a faithful reading of
-- the language's own rule and not a heuristic — a declaration keyword is
-- recognised only at column 0 (§3), and a body therefore cannot contain one,
-- because a column-0 line is precisely what terminates the body (§4).
function M.declarations(verb)
    local path = M.cookfile(verb)
    local out = {}
    local line = 0
    for text in (fs.read(path) .. "\n"):gmatch("([^\n]*)\n") do
        line = line + 1
        -- The separator after the keyword is required (§7.1), which is what
        -- keeps `recipes_are_nice = 1` from reading as a declaration.
        local keyword, rest = text:match("^(recipe)[ \t\"](.*)$")
        if not keyword then
            keyword, rest = text:match("^(chore)[ \t\"](.*)$")
        end
        if keyword then
            -- The quote consumed by the class above is put back, so both
            -- spellings reach one name matcher.
            if text:sub(#keyword + 1, #keyword + 1) == '"' then rest = '"' .. rest end
            local name = rest:match('^%s*"([^"]*)"') or rest:match("^%s*([^%s:]+)")
            if name then
                out[#out + 1] = { name = name, keyword = keyword, line = line }
            end
        end
    end
    return out
end

-- The declaration that already owns `name`, or nil.
--
-- This is the collision check, and `cook.cookfile.find_call` cannot serve it:
-- that call answers nil both for a recipe that does not exist and for one that
-- exists without a module call, so a verb keying off it would happily append a
-- second `recipe math` and leave the author with a Cookfile that no longer
-- parses (App. A duplicate-declaration rule).
function M.declared(verb, name)
    for _, decl in ipairs(M.declarations(verb)) do
        if decl.name == name then return decl end
    end
    return nil
end

-- Every declared recipe that calls a cook_cc target maker, as
-- `name -> { kind, callee }`.
--
-- The kind is the callee's last dotted segment, so a project that renamed the
-- module (`use cc cook_cc`) classifies the same as one that did not: the
-- alias is the author's business and the maker is what carries the meaning.
-- A recipe whose call is some other module's is left out rather than
-- misfiled — `cook_pnpm.workspace` is not a C++ target.
function M.targets(verb)
    local path = M.cookfile(verb)
    local out = {}
    for _, decl in ipairs(M.declarations(verb)) do
        if decl.keyword == "recipe" then
            local call = cook.cookfile.find_call(path, decl.name)
            if call then
                local kind = call.callee:match("([^.]+)$")
                if kind and M.KINDS[kind] then
                    out[decl.name] = { kind = kind, callee = call.callee }
                end
            end
        end
    end
    return out
end

-- Refuse a name the Cookfile grammar would refuse, before anything is written.
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
    report.fail(verb, "'" .. tostring(name) .. "' is not a valid target name", hint)
end

return M
