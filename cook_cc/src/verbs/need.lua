-- cook_cc.verbs.need — `cook cc.need <dep> <target>`: declare an external dependency and probe for it now
-- domain:  verbs — project-management commands the module registers
-- phase:   register (a verb body is register-phase Lua)
-- effects: cook.chore; edits the Cookfile; registers and resolves a cc:find probe
-- std:     §22.12, §22.13 (CS-0221), §22.5 (CS-0219), §28.2
--
-- The verb that answers "do I have sdl2?" without a build. Every other verb in
-- this directory finishes when the Cookfile is written; this one finishes when
-- the machine has been asked, because "declared a dependency" and "the
-- dependency is there" are different facts and only the second one predicts
-- whether the next `cook` will work.
--
-- No fetching and no package manager, deliberately (COOK-281). The finder chain
-- — curated, then pkg-config, then cmake, then a bare link probe — already
-- resolves arbitrary names, so what a miss produces is a list of the places
-- that were looked and a hint about installing it. Conan lands later as a
-- PROVIDER behind that same chain, which is why nothing here knows the name of
-- a package manager: adding one must not need a change to this verb.
local project = require("cook_cc.verbs._project")
local report  = require("cook_cc.verbs._report")
local finder  = require("cook_cc.discovery.finder")

local VERB = "cc.need"

local M = {}

-- The field this verb writes. Named once because every message about it should
-- use the same word the Cookfile does.
local FIELD = "needs"

-- App. A / the probe-key grammar's `PROBE_SEG`, which is what a dependency name
-- becomes: `sdl2` is the key `cc:find:sdl2` and the sigils
-- `$<cc:find:sdl2.cflags>` the maker renders from a `needs` entry.
--
-- It coincides with the declaration-name rule `_project.check_name` enforces,
-- and it is not that rule. That one is a policy about names this layer will
-- turn into directories; this one is a grammar the engine enforces, and the two
-- are free to diverge.
local DEP_PATTERN = "^[A-Za-z_][A-Za-z0-9_%-]*$"

local function known(targets)
    local names = {}
    for name in pairs(targets) do names[#names + 1] = name end
    return report.list(names)
end

-- Refuse a name that is not a target of this project's, naming the ones that
-- are. Shaped as `cc.link`'s is, including the separate sentence for a recipe
-- that exists and builds something else: "no target named 'web'" reads as a
-- contradiction to someone looking at `recipe web` in the file they were just
-- told does not have it, and the real answer is that this verb only edits calls
-- whose fields it understands.
--
-- Unlike `cc.link` there is no kind check after it. All four makers accept
-- `needs` (`units/targets.lua`: bin, lib, shared and headers each call
-- `check_needs_declared`), because a header-only target's headers can include a
-- dependency's headers just as a program's sources can.
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

local function check_dep(dep)
    if type(dep) == "string" and dep:match(DEP_PATTERN) then return end
    local hint = "a dependency name starts with a letter or underscore and continues with"
        .. " letters, digits, '_' or '-'; it becomes the probe key cc:find:<name>"
    if type(dep) == "string" and dep:find(".", 1, true) then
        hint = "'.' is member access in a probe reference, so it cannot appear in a probe"
            .. " key; a finder name spells it '-' or '_'"
    end
    report.fail(VERB, "'" .. tostring(dep) .. "' is not a dependency name " .. VERB .. " can probe", hint)
end

-- The strategy that answered, off the probe's own record. `tried` carries every
-- attempt in order including the one that hit, so this reads the result rather
-- than recomputing it — the probe already decided, and a second opinion here
-- could disagree with the flags the build will actually use.
local function winner(result)
    for _, attempt in ipairs(result.tried or {}) do
        if attempt.outcome == "hit" then return attempt.strategy end
    end
    return nil
end

-- Ask for the dependency now. Returns the probe's value.
--
-- `find`, never `find_or_error`: a miss must come back as a value to report,
-- and `find_or_error` registers a probe whose `produce` raises instead. The two
-- also conflict — `finder` refuses a second declaration of one name under
-- different semantics — so a project whose Cookfile already says
-- `cook_cc.uses("sdl2")` (which is `find`) would fail here if this verb asked
-- for the raising kind.
--
-- The read is what runs it. CS-0219 made a register-phase `cook.probes.get`
-- resolve a declared probe on demand: the same `cook_probe::eval` the executor
-- runs, cached in the same place, so `cc.need` costs nothing the first build
-- would not have cost anyway and a second `cc.need` for the same dependency is
-- a cache hit.
--
-- Wrapped for the reason `_project.edit` is: a resolution failure arrives on
-- the engine's terms — `probe 'cc:find:sdl2': produce raised while resolving it
-- at register phase: …`, prefixed by the Lua host's `runtime error: ` — and
-- reaches the user attributed to nothing they typed. Observed for real: a
-- module tree missing `lpeg` (which `cmake_compat` requires) reported a
-- `package.path` search with no mention of `cc.need` anywhere in it. Not
-- `_project.edit` itself: that one strips a `cook.cookfile.<fn>: <path>: `
-- lead-in this message does not have, and reaching for it here would tie a
-- probe's diagnostics to the Cookfile editor's wording.
local function ask(dep, declared)
    local key = "cc:find:" .. dep
    local ok, value = pcall(function()
        -- Only when nothing declared it. A Cookfile that already says
        -- `cook_cc.find_or_error("sdl2")` declared that name with
        -- raise-on-miss semantics, and `find` refuses to redeclare it under
        -- the other kind — `[cc.find] duplicate cc.find for 'sdl2' with
        -- conflicting opts`, about a call the user never made. Reading the
        -- probe the project already declared is both what it asked for and
        -- what the build will use.
        if not declared then finder.find(dep) end
        return cook.probes.get(key)
    end)
    if not ok then
        -- Strip the Lua chunk position the raising module attached. It names a
        -- file inside the installed module tree, which is `_report`'s reason
        -- for `error(msg, 0)`: the user's position is the command they typed.
        local detail = tostring(value):gsub("^runtime error: ", "")
        detail = detail:gsub("^[^%s:]*%.lua:%d+: ", "")
        report.fail(VERB, "could not resolve the " .. key .. " probe: " .. detail)
    end
    return value
end

-- The body. Separated from `register` so it is reachable from a spec without a
-- dispatch, and so the parameter names are visible in one place.
--
-- Order: every refusal, then both writes, then the report of what was written,
-- then the probe. The report goes before the probe deliberately — resolving a
-- probe runs the author's finder chain, which can raise, and a run that ends
-- with an engine's message about a `produce` body should still have told the
-- user what their Cookfile now says. The alternative leaves them opening the
-- file to find out.
function M.run(dep, target)
    check_dep(dep)

    local cookfile = project.cookfile(VERB)
    local targets = project.targets(VERB)
    if next(targets) == nil then
        report.fail(VERB, "this project declares no cook_cc targets",
            "add one with: cook cc.add bin game")
    end
    require_target(targets, target)

    -- A name this project BUILDS is not an external dependency, and the verb
    -- for it is `cc.link`. Refusing beats probing: `needs` and `links` are
    -- different lists with different meanings, so `cc.need math game` would
    -- otherwise report `math not found` — correctly, since there is no system
    -- library called math — and leave behind a `needs = { "math" }` and a
    -- top-level declaration that will never resolve, both to be undone by
    -- hand. Checked after the target, so the suggestion copies a name that has
    -- already been verified to exist.
    local own = targets[dep]
    if own then
        report.fail(VERB, "'" .. dep .. "' is a " .. own.kind .. " this project builds, not an external dependency",
            dep ~= target
                and ("did you mean: cook cc.link " .. target .. " " .. dep)
                or "needs names libraries the machine provides; links names the ones this project builds")
    end

    local cc = project.alias(VERB)
    local existing = project.entries(VERB, target, FIELD) or {}
    local already = false
    for _, entry in ipairs(existing) do
        if project.entry_name(entry) == dep then already = true end
    end
    -- Is a `cc:find:<dep>` probe already declared for this project?
    --
    -- The authoritative question, not a text scan of the Cookfile, and it is
    -- authoritative because `units/targets.lua`'s `check_needs_declared` — the
    -- check that decides whether the edit this verb is about to make BUILDS —
    -- asks this exact function. A scan would have to recognise `uses`, `find`
    -- and `find_or_error`, in any spelling, across lines, possibly through a
    -- variable, and would be wrong in a different direction for each.
    --
    -- It can answer this early because a chore body runs after the Cookfile's
    -- top level has: the `uses` calls up there have already registered by the
    -- time a dispatch reaches here.
    local declared = finder.is_registered(dep)

    -- The `uses` call goes in FIRST, and the order is the whole safety
    -- argument. A `uses` line with no `needs` entry referring to it is inert:
    -- it registers a probe nothing reads. A `needs` entry with no declaration
    -- is `[cc.bin] needs "sdl2" is not declared`, which is a project that
    -- stopped building. So if only one of the two writes lands, it must be
    -- this one.
    if not declared then
        project.edit(VERB, "could not append to " .. cookfile,
            cook.cookfile.append, cookfile, cc .. '.uses("' .. dep .. '")\n')
    end

    if not already then
        -- CS-0221: create the field where the target has none. Opt-in, because
        -- §22.13's default is that an absent field is a total failure — the
        -- right default for a verb editing a field it expected the author to
        -- have written, and the wrong one for this verb, whose job is to put
        -- the field there. Neither `cc.add`'s output nor a hand-written
        -- Cookfile carries `needs` until something needs one.
        project.edit(VERB, "could not add '" .. dep .. "' to " .. target .. "'s " .. FIELD,
            cook.cookfile.splice_field, cookfile, target, FIELD,
            '"' .. dep .. '"', { create_if_absent = true })
    end

    if already then
        report.did("skipped", dep .. " (already needed)")
    end
    -- Nothing claims to have updated a file it did not touch.
    if not declared or not already then
        report.did("updated", cookfile)
    end

    if not declared then
        report.state(cc .. '.uses("' .. dep .. '") declared at top level')
    end
    if already then
        -- "is sdl2 needed" is the question that was asked, and the answer is
        -- yes; the field's contents say it better than a repeated name.
        local names = {}
        for _, entry in ipairs(existing) do
            names[#names + 1] = project.entry_name(entry) or entry
        end
        report.state(target .. " " .. FIELD .. " = " .. table.concat(names, ", "))
    else
        report.state(target .. " " .. FIELD .. " += " .. dep)
    end

    local result = ask(dep, declared)

    if type(result) ~= "table" then
        -- Not reachable through a normal dispatch: CS-0219 resolves the key or
        -- raises. It IS reachable on a pass with probe resolution switched off
        -- (a discovery pass), and saying which of "not found" and "not asked"
        -- happened is the difference between a user who installs something and
        -- one who installs nothing.
        report.state("cc:find:" .. dep .. " produced no value, so nothing was checked")
        report.suggest(target)
        return
    end

    if result.found then
        local via = winner(result)
        local line = dep .. " found"
        if result.version then line = line .. ": " .. tostring(result.version) end
        if via then line = line .. " via " .. via end
        report.state(line)
        report.suggest(target)
        return
    end

    report.state(dep .. " not found. tried:")
    for _, attempt in ipairs(result.tried or {}) do
        local line = "  - " .. tostring(attempt.strategy) .. ": " .. tostring(attempt.outcome)
        if attempt.reason and attempt.reason ~= "" then
            line = line .. " (" .. attempt.reason .. ")"
        end
        report.state(line)
    end
    -- No package manager is named. Which one is right depends on the machine,
    -- and this module's whole position on external dependencies is that it
    -- finds what is installed rather than installing anything (COOK-281).
    report.state("install " .. dep .. " and its development headers, then re-run to confirm")
    -- Not `try: cook <target>`: the target cannot link until the dependency is
    -- there, so the command worth offering is this one again.
    report.suggest(VERB .. " " .. dep .. " " .. target)
end

-- §22.12: called during cook_cc's own chunk evaluation, never later.
--
-- Two REQUIRED params, where COOK-289 specified `dep [target]`. The optional
-- trailing form targets the defaults level, and there is no defaults level to
-- target: `cc.defaults` is `toolchain.merge_defaults`, which has no `needs` key
-- (W8, COOK-5, still open). An optional parameter that refuses whenever it is
-- omitted is a worse interface than a required one. `dep` still comes first, so
-- when W8 lands `target` becomes a trailing `defaulted_string` and every
-- command written against this release keeps its meaning.
function M.register()
    cook.chore(VERB, {
        origin = "cook_cc.verbs.need",
        __params = {
            { kind = "required", name = "dep" },
            { kind = "required", name = "target" },
        },
    }, function(params)
        M.run(params.dep, params.target)
    end)
end

return M
