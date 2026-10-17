-- cook_pnpm.units.tasks — pnpm task minting: recipes, build units, check units
-- domain:  units — builds commands and registers work on the engine
-- effects: cook.recipe, cook.add_unit, fs.glob
-- std:     §8.6, §17.4, §17.1.2.1
--
-- Two unit shapes, inferred from declared outputs (override with
-- `kind = "build" | "check"`):
--
--   BUILD  (outputs non-empty) — a cook unit (`cook.add_unit`). Command
--          interpolates the toolchain probe ($<pnpm:toolchain:<pin>.pnpm>),
--          seals the install probe (pnpm-lock.yaml content hash), declares
--          outputs as package-anchored globs resolved post-execute
--          (CS-0085), and restores them from the store on a hit.
--
--   CHECK  (no outputs) — a test unit (`cook.add_unit` with
--          `step_kind = "test"`, CS-0185). This is the
--          engine's sanctioned shape for pass/fail work (Standard §8.6,
--          §17.4): the unit is fingerprinted over the CONTENT of its
--          inputs + consumed predecessor outputs, a pass result is
--          recorded and replayed cross-machine, and `cook test` runs it.
--          A cook unit with `outputs = {}` gets NONE of that (it re-runs
--          every invocation as an engine OneShot) — cook_pnpm ≤0.2
--          minted exactly that, which is why test/lint tasks never
--          cached. Two consequences of the test-unit contract
--          (test commands run verbatim via /bin/sh, no probe
--          substitution — CS-0127): the command uses plain `pnpm` from
--          PATH, and the lockfile determinant rides as a declared INPUT
--          (content-fingerprinted) rather than a seal.
--
-- Both shapes seal toolchain.seals() — the toolchain identity probe
-- (node/pnpm versions), so a toolchain change re-keys every minted unit.
--
-- `requires` (0.2.1, the polyglot escape hatch): extra recipe names
-- appended verbatim to every minted recipe. When a pnpm task reads files
-- produced by a non-pnpm recipe (a wasm-pack step, codegen, a Rust
-- build), path equality alone creates no ordering edge in Cook — the
-- engine rejects the read-after-write unless the producer is named.
-- depends_on cannot express it (it only resolves pnpm task names
-- inside the workspace); requires names any recipe in the graph. Since
-- 0.3 it is also accepted workspace-level (cook_pnpm.workspace{requires}
-- — applied to every minted task).
--
-- Per-package overrides (0.4, Turborepo "<pkg>#<task>"): a tasks-map key
-- of that form REPLACES the base task cfg for that package — no merge,
-- turbo semantics; a key with no base entry mints the task for that
-- package only. Override outputs join the package's default-input
-- exclusion set exactly like base outputs. An override naming a package
-- not in the workspace is a register-time error.
--
-- Negated output globs ("!.next/cache/**") are REJECTED at register
-- time: the engine's outputs[] surface recognises only `*`, `?`, `[`
-- (CS-0085) — `!` exclusion exists for gather (§8.2), not outputs;
-- a "!" entry would resolve as a literal path and silently match
-- nothing. The inputs-side counterpart lives in units.excludes.
--
-- Env (0.4): `env = { "VAR", ... }` on a BUILD task cfg (and/or
-- workspace-level `env`, folded into every build unit) lowers to
-- `consulted_env_keys` — the auto-fold path §17.1.2.1 prescribes for
-- variables the command consumes; no probe needed. Test units have no
-- consulted-env surface (CS-0127), so `env` on a check is a
-- register-time error and workspace-level env skips checks.
--
-- `consumes` (0.7): basename globs naming the dependency artifact
-- classes this task actually reads, filtering the dep-output content
-- fold — see units.depfold for why a whole-directory fold silently
-- cancels the content cutoff. Both unit shapes honour it, by different
-- machinery and with different defaults:
--
--   BUILD  filters the depfile `find` the module writes. Defaults to
--          "everything but sourcemaps": a DENYLIST the module seeds.
--   CHECK  lowers `consumes` onto the test unit (§17.4 rule 1, CS-0175),
--          which narrows the engine's predecessor-output fold. That
--          surface is an ALLOWLIST, so the build side's default is not
--          expressible on it — absent `consumes`, a check still folds
--          every predecessor output, sourcemaps included.
--
-- The asymmetry is a gap, not a design: a check benefits only when its
-- cfg names what it reads. Closing it needs an exclusion spelling on the
-- engine surface.
--
-- The input-set rules live in units.inputs, the subtraction rules in
-- units.excludes, and the depends_on / output-folding rules in
-- units.depfold.

local toolchain = require("cook_pnpm.toolchain")
local workspace = require("cook_pnpm.discovery.workspace")
local globs     = require("cook_pnpm.units.globs")
local inputs    = require("cook_pnpm.units.inputs")
local excludes  = require("cook_pnpm.units.excludes")
local depfold   = require("cook_pnpm.units.depfold")

local M = {}

local recipe_name = depfold.recipe_name

-- Conventional check-script names auto-minted by workspace{checks="auto"}.
M.DEFAULT_CHECKS = { "test", "lint", "typecheck", "check-types" }

-- Re-exported for consumers that name the depfile (specs, docs).
M.DEPFILE_NAME = depfold.DEPFILE_NAME

-- Split "<pkg>#<task>" override keys out of the raw tasks map. `#` never
-- appears in npm package names, so the LAST `#` is the separator.
local function split_overrides(tasks_map, by_name)
    local base, overrides = {}, {}
    for key, cfg in pairs(tasks_map) do
        local pkg_name, task_name = key:match("^(.+)#([^#]+)$")
        if pkg_name then
            if not by_name[pkg_name] then
                error("[pnpm.task] override key '" .. key .. "' names unknown "
                      .. "package '" .. pkg_name .. "' — not in the pnpm "
                      .. "workspace (check pnpm-workspace.yaml / the package's "
                      .. "\"name\" field)", 4)
            end
            overrides[pkg_name] = overrides[pkg_name] or {}
            overrides[pkg_name][task_name] = cfg
        elseif key:find("#", 1, true) then
            error("[pnpm.task] malformed task key '" .. key .. "' — the "
                  .. "per-package form is \"<pkg>#<task>\", both parts "
                  .. "non-empty", 4)
        else
            base[key] = cfg
        end
    end
    return base, overrides
end

-- Engine gap (CS-0085): outputs[] admits only `*`, `?`, `[` — a Turbo
-- "!"-negated entry would be taken as a literal path and match nothing.
local function reject_negated_outputs(cfg, label)
    for _, g in ipairs(cfg.outputs or {}) do
        if g:sub(1, 1) == "!" then
            error("[pnpm.task] output '" .. g .. "' (" .. label .. ") is a "
                  .. "negated glob — the cook engine's outputs[] surface "
                  .. "(CS-0085) supports only *, ?, [ metacharacters; `!` "
                  .. "exclusion exists for gather, not outputs. Declare "
                  .. "the positive globs only.", 4)
        end
    end
end

-- `--filter <pkg>` selects the package inside a workspace; in a solo
-- (single-package) workspace there is nothing to filter and pnpm rejects
-- the flag's premise — run at the root instead.
local function filter_arg(pkg)
    return pkg.solo and "" or ("--filter " .. pkg.name .. " ")
end

local function build_command_for(pkg, task_name)
    toolchain.ensure_probe_registered()
    local key = toolchain.get_probe_key()
    -- $<pnpm:toolchain:....pnpm> is replaced at execute time with the
    -- absolute pnpm binary path resolved by the toolchain probe.
    return "$<" .. key .. ".pnpm> " .. filter_arg(pkg) .. "run " .. task_name
end

-- Mint one (pkg, task) recipe. `cfg` is the per-task opts; `ctx` carries
-- the batch-wide knowledge: by_name, install_key, lockfile, workspace
-- requires, and the union of this package's declared outputs.
local function mint_one(pkg, task_name, cfg, ctx, origin)
    local outputs = cfg.outputs or {}
    local kind = cfg.kind or ((#outputs > 0) and "build" or "check")
    if kind ~= "build" and kind ~= "check" then
        error("[pnpm.task] kind must be \"build\" or \"check\", got \""
              .. tostring(kind) .. "\" (task '" .. task_name .. "')", 3)
    end
    if kind == "check" and #outputs > 0 then
        error("[pnpm.task] task '" .. task_name .. "' declares outputs but kind "
              .. "= \"check\"; a check unit produces no artifacts — drop the "
              .. "outputs or use kind = \"build\"", 3)
    end
    if kind == "check" and cfg.env then
        error("[pnpm.task] task '" .. task_name .. "' declares env but is a "
              .. "check — engine test units (step_kind = \"test\", CS-0127/"
              .. "CS-0185) have no "
              .. "consulted-env surface; make it a build (declare outputs) or "
              .. "drop env", 3)
    end
    -- `consumes` on a check lowers onto the test unit (§17.4 rule
    -- 1, CS-0175). It was a register-time error while no engine could
    -- honour it; the engine surface exists now, so it passes through. The
    -- two spellings differ, and deliberately: a build's filter is a
    -- DENYLIST the module seeds with sourcemaps, a check's is an ALLOWLIST
    -- the engine matches positively. See the note in units.depfold.

    -- Checks read dependency artifacts (tsc -b loads dep .d.ts), so an
    -- unordered check is a race; default the edge Turbo leaves implicit.
    -- The defaulted edge resolves strictly (batch-minted targets only —
    -- module-invented edges must never dangle); user-written depends_on
    -- resolves as always.
    local depends_on, strict = cfg.depends_on, false
    if kind == "check" and depends_on == nil then
        depends_on, strict = { "^build" }, true
    end

    local requires, dep_units = depfold.resolve_depends_on(pkg, depends_on, ctx, strict)
    for _, extra in ipairs(ctx.workspace_requires or {}) do
        requires[#requires + 1] = extra
    end
    for _, extra in ipairs(cfg.requires or {}) do
        requires[#requires + 1] = extra
    end
    local dep_dirs = depfold.dep_output_dirs(dep_units, ctx)

    local input_globs = cfg.inputs
        and globs.anchor_globs(cfg.inputs, pkg.dir, true)
        or  inputs.defaults(pkg, ctx.pkg_outputs[pkg.name] or {})
    -- Workspace-level extras ride on every task, explicit inputs or not
    -- (already root-anchored + existence-filtered by mint_batch).
    for _, g in ipairs(ctx.extra_inputs or {}) do
        input_globs[#input_globs + 1] = g
    end

    -- 0.5: subtract exclusions (per-task cfg + workspace level).
    -- Entry-level here — an entry wholly inside an excluded subtree is
    -- dropped for build AND check units; per-file filtering of fs.glob
    -- expansions happens in the build branch below.
    local exclude_pats = excludes.compile(cfg.exclude_inputs, pkg.dir, ctx.root,
                                          "task '" .. task_name .. "'")
    for _, p in ipairs(ctx.exclude_patterns or {}) do
        exclude_pats[#exclude_pats + 1] = p
    end
    if #exclude_pats > 0 then
        local kept = {}
        for _, g in ipairs(input_globs) do
            if not excludes.is_excluded(g, ctx.root, exclude_pats) then
                kept[#kept + 1] = g
            end
        end
        input_globs = kept
    end

    local r_name = recipe_name(pkg, task_name)

    -- Resolved HERE, outside the recipe body: a probe first registered
    -- inside one recipe's body is not scheduled for another recipe's unit
    -- that seals it (`cook test` may never run the registering body), and
    -- the seal then silently keys on nothing.
    local seal = toolchain.seals(kind == "build" and { ctx.install_key } or nil)

    -- Data-driven fan-out carve-out (explicit-recipes contract): minted
    -- names the user never wrote must carry origin metadata so `cook
    -- list` attributes them to the call that created them (CS-0143).
    cook.recipe(r_name, { requires = requires, origin = origin }, function()
        if kind == "build" then
            local unit_inputs = {}
            for _, g in ipairs(input_globs) do
                if g:find("[%*%?%[]") then
                    for _, m in ipairs(fs.glob(g)) do
                        -- 0.5: a tool-written file nested inside a kept
                        -- subtree glob (the manifest.json case) is dropped
                        -- here, at expansion.
                        if not excludes.is_excluded(m, ctx.root, exclude_pats) then
                            unit_inputs[#unit_inputs + 1] = m
                        end
                    end
                else
                    unit_inputs[#unit_inputs + 1] = g
                end
            end
            -- package.json participates so a `scripts` edit invalidates.
            unit_inputs[#unit_inputs + 1] = pkg.dir .. "/package.json"
            -- Dep-output content fold via discovered inputs (units.depfold):
            -- the command records what it consumed; later runs hash that.
            local command = build_command_for(pkg, task_name) .. " "
            local discovered
            if #dep_dirs > 0 then
                local dpath = globs.workdir_rel(pkg.dir, ctx.root)
                              .. "/" .. depfold.DEPFILE_NAME
                local rel_dirs = {}
                for i, d in ipairs(dep_dirs) do
                    rel_dirs[i] = globs.workdir_rel(d, ctx.root)
                end
                -- Fold only the artifact classes this task reads: a
                -- sourcemap rewritten by a comment-only upstream edit
                -- must not re-key a consumer that imports the (identical)
                -- bundle — see units.depfold.
                local predicate = depfold.consumes_predicate(
                    cfg.consumes, "task '" .. task_name .. "'")
                command = command .. "&& "
                          .. depfold.depfile_command(rel_dirs, dpath, predicate)
                discovered = { from = dpath, format = "make" }
            end
            -- Consulted env: workspace-level keys + per-task keys, in that
            -- order (§17.1.2.1 auto-fold; values fold, dup keys harmless).
            local env_keys = {}
            for _, k in ipairs(ctx.workspace_env or {}) do env_keys[#env_keys + 1] = k end
            for _, k in ipairs(cfg.env or {}) do env_keys[#env_keys + 1] = k end
            cook.add_unit({
                inputs   = unit_inputs,
                outputs  = globs.anchor_globs(outputs, pkg.dir, false),
                command  = command,
                -- The toolchain path probe is consumed as DATA (the
                -- command interpolates the binary path — §12.7.4) and
                -- never keys (§22.5.7); its identity and the install
                -- probe (lockfile content hash) key the unit as seals.
                probes   = { toolchain.get_probe_key() },
                seal     = seal,
                discovered_inputs  = discovered,
                consulted_env_keys = (#env_keys > 0) and env_keys or nil,
            })
        else
            local unit_inputs = {}
            for _, g in ipairs(input_globs) do unit_inputs[#unit_inputs + 1] = g end
            unit_inputs[#unit_inputs + 1] = pkg.dir .. "/package.json"
            -- The lockfile is a declared input (content-fingerprinted);
            -- the command runs plain `pnpm` from PATH, keyed on the
            -- toolchain identity through toolchain.seals().
            unit_inputs[#unit_inputs + 1] = ctx.lockfile
            -- Dep artifacts as ready-time glob inputs (units.depfold): the
            -- ^build edge above guarantees they exist before resolution.
            --
            -- These are MOSTLY redundant since CS-0175 — the engine folds
            -- predecessor outputs itself and skips any declared input
            -- already in that set, so a `dist/**` producer's files arrive
            -- either way. Kept because `dep_dirs` is the dep package's
            -- whole claimed-output union, which can include a dir produced
            -- by a sibling task this check does NOT require: those files
            -- are not predecessor outputs, and dropping the glob would
            -- silently stop keying on them. Over-folding is the safe
            -- direction; under-keying replays a stale pass.
            for _, d in ipairs(dep_dirs) do
                unit_inputs[#unit_inputs + 1] = d .. "/**/*"
            end
            -- CS-0185: cook.add_test is gone; a test unit is an ordinary
            -- work unit with step_kind = "test" and no outputs. `suite`
            -- went with it — the ENCLOSING recipe (r_name, minted above)
            -- names and groups the unit, which is strictly better than the
            -- old free-floating suite string.
            cook.add_unit({
                step_kind = "test",
                command = "pnpm " .. filter_arg(pkg) .. "run " .. task_name,
                inputs  = unit_inputs,
                -- Narrows which PREDECESSOR OUTPUTS fold (CS-0175). Absent
                -- folds all of them. Note this cannot carry the build
                -- side's default sourcemap exclusion: the engine surface is
                -- an allowlist, and "everything except *.map" is not
                -- expressible as one. A check only stops re-keying on
                -- sourcemaps if its cfg names what it reads.
                consumes = cfg.consumes,
                seal    = seal,
                line    = 0,
            })
        end
    end)
end

-- Shared batch minting: `tasks_map` is { task_name -> cfg }. Every task
-- in the batch contributes its outputs to the exclusion set BEFORE any
-- default input set is computed — this is why the workspace{tasks=...}
-- form is preferred over serial cook_pnpm.task() calls.
local function mint_batch(tasks_map, workspace_requires, workspace_inputs, workspace_env, origin, workspace_exclude_inputs)
    local packages = workspace.list()
    local snap = workspace.snapshot()
    local root = snap.root_dir or "."

    local aliases = {}
    for _, pkg in ipairs(packages) do
        local alias = depfold.package_alias(pkg)
        if alias then
            if aliases[alias] then
                error("[pnpm.workspace] package directories '" .. aliases[alias]
                      .. "' and '" .. pkg.dir .. "' both map to recipe alias '"
                      .. alias .. "'", 3)
            end
            aliases[alias] = pkg.dir
        end
    end

    local base, overrides = split_overrides(tasks_map, snap.by_name)
    for task_name, cfg in pairs(base) do
        reject_negated_outputs(cfg, "task '" .. task_name .. "'")
        excludes.reject_negated(cfg.inputs, "task '" .. task_name .. "'")
    end
    for pkg_name, per_pkg in pairs(overrides) do
        for task_name, cfg in pairs(per_pkg) do
            reject_negated_outputs(cfg, "task '" .. pkg_name .. "#" .. task_name .. "'")
            excludes.reject_negated(cfg.inputs, "task '" .. pkg_name .. "#" .. task_name .. "'")
        end
    end

    -- Effective cfg for (pkg, task): the override REPLACES the base cfg
    -- entirely (turbo semantics — no merge).
    local function cfg_for(pkg, task_name)
        local per_pkg = overrides[pkg.name]
        if per_pkg and per_pkg[task_name] ~= nil then return per_pkg[task_name] end
        return base[task_name]
    end

    -- Task-name universe: base names plus override-only names.
    local name_set = {}
    for task_name in pairs(base) do name_set[task_name] = true end
    for _, per_pkg in pairs(overrides) do
        for task_name in pairs(per_pkg) do name_set[task_name] = true end
    end

    -- Union of declared output globs per package (package-relative),
    -- through the effective cfg — override outputs claim exclusions for
    -- their package exactly like base outputs.
    local pkg_outputs = {}
    for _, pkg in ipairs(packages) do
        local union = {}
        for task_name in pairs(name_set) do
            local cfg = cfg_for(pkg, task_name)
            if cfg and pkg.package.scripts[task_name] then
                for _, g in ipairs(cfg.outputs or {}) do union[#union + 1] = g end
            end
        end
        pkg_outputs[pkg.name] = union
    end

    -- Root-anchored workspace extras; a missing literal drops (units.inputs).
    excludes.reject_negated(workspace_inputs, "workspace inputs")
    local extra_inputs = inputs.workspace_extras(workspace_inputs, root)

    -- 0.5: workspace-level exclusions (root-relative), subtracted from
    -- every minted task's input set in mint_one.
    local exclude_patterns = excludes.compile(
        workspace_exclude_inputs, root, root, "workspace exclude_inputs")

    local ctx = {
        by_name            = snap.by_name,
        install_key        = snap.install_key,
        root               = root,
        lockfile           = root .. "/pnpm-lock.yaml",
        workspace_requires = workspace_requires,
        workspace_env      = workspace_env,
        pkg_outputs        = pkg_outputs,
        extra_inputs       = extra_inputs,
        exclude_patterns   = exclude_patterns,
        -- True iff this batch mints (dep_pkg, task): script declared AND
        -- an effective cfg covers it — the dangling-edge guard for
        -- depfold.resolve_depends_on.
        has_task           = function(p, t)
            return cfg_for(p, t) ~= nil and p.package.scripts[t] ~= nil
        end,
    }

    -- Deterministic mint order: sorted task names, packages in topo order.
    local names = {}
    for task_name in pairs(name_set) do names[#names + 1] = task_name end
    table.sort(names)
    for _, task_name in ipairs(names) do
        for _, pkg in ipairs(packages) do
            -- Skip packages that don't declare the script (Turborepo
            -- no-op-on-missing-script) or have no cfg for this name
            -- (override-only tasks mint solely for their package).
            local cfg = cfg_for(pkg, task_name)
            if cfg and pkg.package.scripts[task_name] then
                mint_one(pkg, task_name, cfg, ctx, origin)
            end
        end
    end
end

-- Public: single-task form. Mints immediately, so its default-input
-- exclusions see only ITS OWN outputs — a `task("test", {})` called
-- alongside a `task("build", {outputs={"dist/**"}})` will take dist/
-- into test's default inputs. Prefer workspace{tasks = {...}}, which
-- mints the whole batch with the full output picture.
function M.task(task_name, opts)
    mint_batch({ [task_name] = opts or {} }, nil, nil, nil, "cook_pnpm.task")
end

-- Called by cook_pnpm.workspace() (via init.lua) after bootstrap.
-- Mints opts.tasks as one batch, then auto-mints conventional check
-- scripts (opts.checks: "auto" default, a name list, or false).
function M.mint_from_workspace(opts)
    local tasks_map = {}
    for task_name, cfg in pairs(opts.tasks or {}) do
        tasks_map[task_name] = cfg
    end

    local checks = opts.checks
    if checks == nil then checks = "auto" end
    if checks ~= false then
        local names = (checks == "auto") and M.DEFAULT_CHECKS or checks
        for _, task_name in ipairs(names) do
            if tasks_map[task_name] == nil then
                -- Mint only where some package declares the script; the
                -- batch layer already skips non-declaring packages, so an
                -- entry for an undeclared name is simply inert.
                tasks_map[task_name] = { kind = "check" }
            end
        end
    end

    if next(tasks_map) ~= nil then
        mint_batch(tasks_map, opts.requires, opts.inputs, opts.env,
                   "cook_pnpm.discovery.workspace", opts.exclude_inputs)
    end
end

-- Escape hatch: register a custom recipe under the package's pnpm namespace. The caller
-- supplies the body via a function receiving the parsed WorkspaceInfo.
function M.script(pkg_name, name, body_fn)
    local pkg = workspace.lookup(pkg_name)
    if not pkg then
        error("[pnpm.script] unknown package '" .. pkg_name .. "' in workspace", 2)
    end
    cook.recipe(recipe_name(pkg, name), {}, function()
        body_fn(pkg)
    end)
end

return M
