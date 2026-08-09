-- cook_cc.verbs.link — `cook cc.link <target> <libs...>`: add dependency edges to an existing target
-- domain:  verbs — project-management commands the module registers
-- phase:   register (a verb body is register-phase Lua)
-- effects: cook.chore; edits the Cookfile
-- std:     §22.12, §22.13 (CS-0221)
--
-- The edge is the part of a C++ project that is tedious to write and easy to
-- get wrong: find the recipe, find its `links`, add a string, keep the commas
-- straight. This is the first verb that reaches INSIDE an existing module call
-- rather than appending a new declaration, which is why it needed CS-0221 —
-- neither `cc.add`'s output nor a hand-written Cookfile carries a `links`
-- field until something needs one.
local project = require("cook_cc.verbs._project")
local report  = require("cook_cc.verbs._report")

local VERB = "cc.link"

local M = {}

-- The field this verb writes. Named once because every message about it should
-- use the same word the Cookfile does.
local FIELD = "links"

-- Which kinds can carry a `links` list, and which kinds can appear in one.
--
-- The overlap is what lets the wrong order self-heal, and the two edges of it
-- are what make the answer decidable: a program links libraries and nothing
-- links a program, so a `bin` in the lib position is always the mistake and
-- never a preference. `headers` is the mirror — it can be linked into things
-- and has no link step of its own — which is why it appears in one table and
-- not the other rather than in neither.
local CAN_LINK  = { bin = true, lib = true, shared = true }
local LINKABLE  = { lib = true, shared = true, headers = true }

local function known(targets)
    local names = {}
    for name in pairs(targets) do names[#names + 1] = name end
    return report.list(names)
end

-- Refuse a name that is not a target of this project's, naming the ones that
-- are. Both positions ask it, and both want the same answer: a typo and a
-- forgotten `cc.add` look identical from here, and the target list tells the
-- two apart better than either guess would.
--
-- A recipe that exists and is not a cook_cc target gets its own sentence. It
-- is the one case where "no target named 'web'" would be read as a
-- contradiction — the user is looking at `recipe web` in the file they were
-- told does not have it — and the real answer is that this verb only edits
-- calls whose fields it understands.
local function require_target(targets, name)
    if targets[name] then return targets[name] end
    local declared = project.declared(VERB, name)
    if declared then
        report.fail(VERB, "'" .. name .. "' is a " .. declared.keyword
            .. ", but it does not build a cook_cc target",
            "known targets: " .. known(targets))
    end
    report.fail(VERB, "no target named '" .. tostring(name) .. "' in this project",
        "known targets: " .. known(targets))
end

-- The command the user probably meant, when they put the bin last.
--
-- Only offered when swapping would actually be right: the batch names exactly
-- one bin, and the target they gave is something that can be linked into it.
-- Two bins have no valid order, and a suggestion that would itself be refused
-- sends them round the loop a second time — which is also why this runs after
-- every name has been checked to exist, so the rest of the batch it copies
-- into the suggestion is known-good.
local function swapped(target, libs, targets, bin_name)
    local bins, count = {}, 0
    for _, lib in ipairs(libs) do
        if targets[lib].kind == "bin" and not bins[lib] then
            bins[lib] = true
            count = count + 1
        end
    end
    if count ~= 1 or not LINKABLE[targets[target].kind] then return nil end

    -- The old target leads the new lib list, and a name already in it is not
    -- repeated: the suggestion should be a command worth running verbatim.
    local rest, seen = { target }, { [target] = true, [bin_name] = true }
    for _, lib in ipairs(libs) do
        if not seen[lib] then
            seen[lib] = true
            rest[#rest + 1] = lib
        end
    end
    return "did you mean: cook " .. VERB .. " " .. bin_name .. " " .. table.concat(rest, " ")
end

-- Does `from` already reach `goal` through the links this Cookfile declares?
--
-- Asked before writing, because `cook cc.link util math` after
-- `cook cc.link math util` produces a Cookfile that parses, looks right, and
-- cannot build: the engine reports `dependency cycle: math -> util -> math`
-- from somewhere that does not name the command that caused it. This verb is
-- holding the whole graph already, and "what you scaffold must build unedited"
-- is the rule the directory is written to.
local function reaches(targets, from, goal, seen)
    if from == goal then return true end
    if seen[from] then return false end
    seen[from] = true
    for _, entry in ipairs(project.entries(VERB, from, FIELD) or {}) do
        local name = project.entry_name(entry)
        if name and targets[name] and reaches(targets, name, goal, seen) then return true end
    end
    return false
end

-- The body. Separated from `register` so it is reachable from a spec without a
-- dispatch, and so the parameter names are visible in one place.
--
-- Every argument is checked before the first entry is written. The checks are
-- ordered so that each one's diagnostic is about a fact the checks before it
-- have already established: existence first, so the swap suggestion can copy
-- the rest of the batch into a command that will actually run; then the kinds,
-- which is the question existence makes answerable; then the cycle, which
-- needs both.
function M.run(target, libs)
    libs = libs or {}
    if #libs == 0 then
        -- Unreachable through a dispatch — `variadic_plus` refuses an empty
        -- list before the body runs — and reachable through `M.run`, which is
        -- the seam the specs and any future caller use.
        report.fail(VERB, "name at least one lib to link into '" .. tostring(target) .. "'",
            "the target comes first: cook " .. VERB .. " <target> <libs...>")
    end

    local cookfile = project.cookfile(VERB)
    local targets = project.targets(VERB)
    if next(targets) == nil then
        report.fail(VERB, "this project declares no cook_cc targets",
            "add one with: cook cc.add lib math")
    end

    require_target(targets, target)
    for _, lib in ipairs(libs) do
        if lib == target then
            report.fail(VERB, "'" .. target .. "' cannot link to itself")
        end
        require_target(targets, lib)
    end

    -- The lib position is checked first, and that ordering is the self-heal.
    -- A swapped `cc.link math game` is wrong in both positions at once, and
    -- only the lib-position complaint can name the bin and offer the command
    -- that fixes it; reporting the target's kind first would answer the same
    -- mistake with a message that has nowhere to point.
    for _, lib in ipairs(libs) do
        local lib_kind = targets[lib].kind
        if not LINKABLE[lib_kind] then
            report.fail(VERB,
                "'" .. lib .. "' is a " .. lib_kind .. ", cannot be linked into '" .. target .. "'",
                swapped(target, libs, targets, lib)
                    or "a bin is a program; link libraries into it, not the other way round")
        end
    end

    local kind = targets[target].kind
    if not CAN_LINK[kind] then
        report.fail(VERB, "'" .. target .. "' is a " .. kind .. " target, so it links nothing",
            swapped(target, libs, targets, libs[1])
                or ("the target comes first: cook " .. VERB .. " <target> <libs...>"))
    end

    for _, lib in ipairs(libs) do
        if reaches(targets, lib, target, {}) then
            report.fail(VERB, "'" .. lib .. "' already links back to '" .. target .. "'",
                "linking it would close a cycle, and a cycle does not build")
        end
    end

    -- One read, before the first write. Re-reading between splices would be
    -- the obvious alternative and it answers a question nobody asked: what
    -- matters is what the target linked when the user typed the command, and
    -- deciding the whole batch against that also catches `cc.link game a a`.
    local existing = project.entries(VERB, target, FIELD) or {}
    local linked = {}
    for _, entry in ipairs(existing) do
        local name = project.entry_name(entry)
        if name then linked[name] = true end
    end

    -- The two reasons to skip are reported apart. "already linked" is a fact
    -- about the file the user has; a name they typed twice in one command is a
    -- fact about the command, and telling them it was already linked when this
    -- invocation is what linked it is simply untrue.
    local adding, skipping, queued, noted = {}, {}, {}, {}
    for _, lib in ipairs(libs) do
        if linked[lib] then
            -- Reported once however many times it was typed: a name the file
            -- already carries has one thing to say about it, and saying it
            -- twice is noise about the command rather than news about the
            -- project.
            if not noted[lib] then
                noted[lib] = true
                skipping[#skipping + 1] = { name = lib, why = "already linked" }
            end
        elseif queued[lib] then
            if not noted[lib] then
                noted[lib] = true
                skipping[#skipping + 1] = { name = lib, why = "named twice" }
            end
        else
            queued[lib] = true
            adding[#adding + 1] = lib
        end
    end

    for _, skip in ipairs(skipping) do
        report.did("skipped", skip.name .. " (" .. skip.why .. ")")
    end

    for _, lib in ipairs(adding) do
        -- CS-0221: create the field where the target has none. Opt-in, because
        -- §22.13's default is that an absent field is a total failure — which
        -- is the right default for a verb editing a field it expected the
        -- author to have written, and the wrong one for this verb, whose whole
        -- job is to put the field there.
        project.edit(VERB, "could not add '" .. lib .. "' to " .. target .. "'s " .. FIELD,
            cook.cookfile.splice_field, cookfile, target, FIELD,
            '"' .. lib .. '"', { create_if_absent = true })
    end

    if #adding > 0 then
        report.did("updated", cookfile)
        report.state(target .. " " .. FIELD .. " += " .. table.concat(adding, ", "))
    else
        -- Nothing was written, so nothing claims to have been. The state line
        -- still goes out: "is math linked" is the question that was asked, and
        -- the answer is yes.
        local names = {}
        for _, entry in ipairs(existing) do
            names[#names + 1] = project.entry_name(entry) or entry
        end
        report.state(target .. " " .. FIELD .. " = " .. table.concat(names, ", "))
    end
    report.suggest(target)
end

-- §22.12: called during cook_cc's own chunk evaluation, never later.
function M.register()
    cook.chore(VERB, {
        origin = "cook_cc.verbs.link",
        __params = {
            { kind = "required", name = "target" },
            { kind = "variadic_plus", name = "libs" },
        },
    }, function(params)
        M.run(params.target, params.libs)
    end)
end

return M
