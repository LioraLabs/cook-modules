-- pnpm task minting.
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
--   CHECK  (no outputs) — a test unit (`cook.add_test`). This is the
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
-- `depends_on` (Turborepo-style, workspace-internal):
--   - `"^build"`  — wait on `build` task in each workspace dependency
--   - `"build"`   — wait on `build` task in the SAME package
--
-- `requires` (0.2.1, the polyglot escape hatch): extra recipe names
-- appended verbatim to every minted recipe. When a pnpm task reads files
-- produced by a non-pnpm recipe (a wasm-pack step, codegen, a Rust
-- build), path equality alone creates no ordering edge in Cook — the
-- engine rejects the read-after-write unless the producer is named.
-- depends_on cannot express it (it only resolves to <pkg>:<task> names
-- inside the workspace); requires names any recipe in the graph. Since
-- 0.3 it is also accepted workspace-level (cook_pnpm.workspace{requires}
-- — applied to every minted task).
--
-- Default inputs (0.3): omitting `inputs` used to key the task on
-- package.json alone — silently wrong-by-default caching. Now it means
-- "the package's file tree", computed per package as:
--   - every top-level directory of the package EXCEPT node_modules,
--     dot-directories, and any directory claimed by a declared output
--     glob of ANY task in the same mint batch (so `web:test` does not
--     take `web:build`'s dist/ as an input and self-invalidate);
--   - plus the package's top-level files, minus those matching a
--     declared output glob.
-- The exclusion matcher (glob_matches below) implements the glob subset
-- output declarations actually use (`dir/**`, `*.ext`, literals); it is
-- used ONLY to subtract build products from default input sets, never
-- for cache-key resolution itself.
--
-- Per-package overrides (0.4, Turborepo "<pkg>#<task>"): a tasks-map key
-- of that form REPLACES the base task cfg for that package — no merge,
-- turbo semantics; a key with no base entry mints the task for that
-- package only. Override outputs join the package's default-input
-- exclusion set exactly like base outputs. An override naming a package
-- not in the workspace is a register-time error.
--
-- Workspace inputs (0.4, turbo globalDependencies): workspace{inputs}
-- entries are WORKSPACE-ROOT-relative (never pkg-anchored) and appended
-- to every minted task's inputs, builds and checks alike. A literal
-- entry that does not exist at register time is DROPPED: the engine
-- treats a missing declared input as never-a-clean-hit, which would
-- silently disable caching for every task; a dropped literal re-enters
-- the moment the file appears, since the register phase re-evaluates on
-- every invocation. Glob entries pass through and resolve to whatever
-- exists.
--
-- Negated output globs ("!.next/cache/**") are REJECTED at register
-- time: the engine's outputs[] surface recognises only `*`, `?`, `[`
-- (CS-0085) — `!` exclusion exists for ingredients (§8.2), not outputs;
-- a "!" entry would resolve as a literal path and silently match
-- nothing.
--
-- Dependency-output folding (0.4): a task's fingerprint must cover the
-- CONTENT of the dependency artifacts it consumes, with the engine's
-- output-content early cutoff (a dep that re-runs to byte-identical
-- output must not re-key the consumer — CS-0138's argument, §17.1.1).
-- The dep file list is unknowable at register time on a cold build, so
-- register-time surfaces (input expansion, file_refs/CS-0101) would
-- fingerprint an empty set once and re-key on the second run. Instead:
--   - BUILD units append a depfile generator to the command and declare
--     it via `discovered_inputs` (§17.5): after the pnpm script runs,
--     one `find | sort` over the dependency packages' claimed output
--     dirs records exactly the files that existed; later runs
--     content-hash that recorded set. Zero settle runs; make-format is
--     whitespace-separated, so dep artifact paths containing spaces are
--     unsupported.
--   - CHECK units get the dep output dirs as plain `<dir>/**/*` inputs —
--     test-unit inputs resolve at READY time (CS-0138), after ordered
--     predecessors materialise, so cold builds fingerprint the real set.
-- The consumed set is the dep package's whole claimed-output union (all
-- its batch tasks), an over-approximation that can only over-invalidate,
-- never go stale. Checks with no explicit depends_on default to
-- {"^build"}: a typecheck reads dep artifacts (tsc -b loads dep .d.ts),
-- so running it unordered against its producers is a race.
--
-- Env (0.4): `env = { "VAR", ... }` on a BUILD task cfg (and/or
-- workspace-level `env`, folded into every build unit) lowers to
-- `consulted_env_keys` — the auto-fold path §17.1.2.1 prescribes for
-- variables the command consumes; no probe needed. Test units have no
-- consulted-env surface (CS-0127), so `env` on a check is a
-- register-time error and workspace-level env skips checks.

local toolchain = require("cook_pnpm.toolchain")
local workspace = require("cook_pnpm.workspace")

local M = {}

local function recipe_name(pkg, task) return pkg.name .. ":" .. task end

-- Conventional check-script names auto-minted by workspace{checks="auto"}.
M.DEFAULT_CHECKS = { "test", "lint", "typecheck", "check-types" }

-- Rewrite a trailing bare "**" to "**/*" so glob resolution matches
-- files, not just directories (the engine's matcher treats a bare "**"
-- as directories-only; tracked upstream). Applied both to register-time
-- fs.glob expansion (build units) and to the glob inputs handed to the
-- engine for ready-time resolution (check units).
local function normalize_input_glob(g)
    if g:sub(-3) == "/**" then return g .. "/*" end
    if g == "**"          then return "**/*"    end
    return g
end

-- Limited glob matcher for OUTPUT-EXCLUSION ONLY (see header). Supports
-- the shapes output declarations use: `dir/**`, `dir/**/*`, `*.ext`,
-- `?`, and literal paths. Paths are package-relative.
local function glob_to_pattern(g)
    local p = g:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%1")
    p = p:gsub("%*%*/%*", "\1")   -- **/* -> any subpath
    p = p:gsub("%*%*", "\1")      -- **   -> any subpath
    p = p:gsub("%*", "[^/]*")     -- *    -> within one segment
    p = p:gsub("%?", "[^/]")
    p = p:gsub("\1", ".*")
    return "^" .. p .. "$"
end

local function glob_matches(g, rel_path)
    return rel_path:match(glob_to_pattern(g)) ~= nil
end

-- First path segment of an output glob whose remainder is a whole-subtree
-- pattern ("dist/**", "dist/**/*", ".next/**") — the directory a default
-- input set must not descend into. Returns nil for root-level patterns
-- ("*.tsbuildinfo") and multi-segment literals.
local function claimed_subdir(g)
    local head, rest = g:match("^([^/]+)/(.+)$")
    if head and (rest == "**" or rest == "**/*") then return head end
    return nil
end

-- Top-level directories of `dir`, via the §25.10 shell escape hatch
-- (fs.glob cannot enumerate directories — CS-0064 drops them). Returns
-- BASENAMES. node_modules and dot-directories are excluded at the
-- enumeration itself, so the walk never touches them.
local function list_subdirs(dir)
    local out = cook.sh("find '" .. dir .. "' -mindepth 1 -maxdepth 1 -type d "
                        .. "! -name node_modules ! -name '.*' 2>/dev/null")
    local dirs = {}
    for line in out:gmatch("[^\r\n]+") do
        local base = line:match("([^/]+)/?$")
        if base then dirs[#dirs + 1] = base end
    end
    table.sort(dirs)
    return dirs
end

-- Default input set for one package: subtree globs for every unclaimed
-- top-level directory + top-level files minus output matches.
-- `all_outputs` is the union of output globs across the mint batch
-- (package-relative). Returns package-anchored globs AND literals, all
-- workspace-relative — suitable both for register-time fs.glob expansion
-- (build) and ready-time engine resolution (check).
local function default_inputs(pkg, all_outputs)
    local entries = {}
    for _, base in ipairs(list_subdirs(pkg.dir)) do
        local claimed = false
        for _, g in ipairs(all_outputs) do
            if claimed_subdir(g) == base then claimed = true break end
        end
        if not claimed then
            entries[#entries + 1] = pkg.dir .. "/" .. base .. "/**/*"
        end
    end
    -- Top-level files: expand now (small, and globs cannot be filtered
    -- post-hoc), drop output matches. `*.tsbuildinfo` is dropped too:
    -- `tsc -b` writes it beside tsconfig on every run, so taking it as an
    -- input self-invalidates the check that produced it (one wasted
    -- re-run before the fingerprint settles).
    for _, m in ipairs(fs.glob(pkg.dir .. "/*")) do
        local rel = m:match("([^/]+)$")
        -- Tool/module state is never an input: *.tsbuildinfo (tsc -b
        -- writes it beside tsconfig every run) and the depfile this
        -- module's own build units write (self-re-keying otherwise).
        local is_output = rel:match("%.tsbuildinfo$") ~= nil
                       or rel == M.DEPFILE_NAME
        for _, g in ipairs(all_outputs) do
            if is_output then break end
            if glob_matches(g, rel) then is_output = true end
        end
        if not is_output then entries[#entries + 1] = pkg.dir .. "/" .. rel end
    end
    return entries
end

local function expand_globs_in_dir(globs, dir)
    if not globs or #globs == 0 then return {} end
    local out = {}
    for _, g in ipairs(globs) do
        local pattern = dir .. "/" .. normalize_input_glob(g)
        for _, m in ipairs(fs.glob(pattern)) do
            out[#out + 1] = m
        end
    end
    return out
end

-- Anchor package-relative globs at the package dir WITHOUT expansion.
local function anchor_globs(globs, dir, normalize)
    local out = {}
    for _, g in ipairs(globs or {}) do
        out[#out + 1] = dir .. "/" .. (normalize and normalize_input_glob(g) or g)
    end
    return out
end

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
                  .. "exclusion exists for ingredients, not outputs. Declare "
                  .. "the positive globs only.", 4)
        end
    end
end

-- A `depends_on` edge fires if the referenced package declares the
-- script (Turborepo's "no-op on missing script") — the recipe may be
-- minted by another task()/workspace() call in the same register phase,
-- so batch-local knowledge cannot veto a user-written edge. When
-- `strict` is set (used only for the MODULE-invented default check edge,
-- which must never dangle), the edge additionally requires the batch to
-- mint the target (ctx.has_task). Returns the resolved recipe names
-- plus the (pkg, task) pairs behind them — the pairs drive
-- dependency-output folding (which is batch-scoped via pkg_outputs
-- regardless: an unminted dep task claims no dirs there).
local function resolve_depends_on(pkg, depends_on, ctx, strict)
    local requires, dep_units = {}, {}
    local function eligible(dep_pkg, task_name)
        if not dep_pkg.package.scripts[task_name] then return false end
        if strict and not ctx.has_task(dep_pkg, task_name) then return false end
        return true
    end
    local function add(dep_pkg, task_name)
        requires[#requires + 1] = recipe_name(dep_pkg, task_name)
        dep_units[#dep_units + 1] = { pkg = dep_pkg, task = task_name }
    end
    for _, dep in ipairs(depends_on or {}) do
        if dep:sub(1, 1) == "^" then
            local task_name = dep:sub(2)
            for _, dep_pkg_name in ipairs(pkg.workspace_deps) do
                local dep_pkg = ctx.by_name[dep_pkg_name]
                if dep_pkg and eligible(dep_pkg, task_name) then
                    add(dep_pkg, task_name)
                end
            end
        else
            if eligible(pkg, dep) then add(pkg, dep) end
        end
    end
    return requires, dep_units
end

-- Workspace-relative directories the given dependency units claim as
-- outputs — the whole per-package union (see header: over-approximation
-- is safe). Sorted for deterministic commands.
local function dep_output_dirs(dep_units, ctx)
    local dirs, seen = {}, {}
    for _, du in ipairs(dep_units) do
        for _, g in ipairs(ctx.pkg_outputs[du.pkg.name] or {}) do
            local sub = claimed_subdir(g)
            if sub then
                local d = du.pkg.dir .. "/" .. sub
                if not seen[d] then
                    seen[d] = true
                    dirs[#dirs + 1] = d
                end
            end
        end
    end
    table.sort(dirs)
    return dirs
end

-- Basename of the per-package depfile a build unit writes after its pnpm
-- script succeeds. Dot-named so it can never enter a default input set
-- (default_inputs also excludes it explicitly — a depfile that were its
-- own unit's input would re-key the unit it was recorded by).
M.DEPFILE_NAME = ".cook-pnpm.d"

-- Working-dir-relative form of a workspace path. The engine requires
-- discovered_inputs.from to be relative (commands run from the
-- workspace root), and relative paths in the depfile body keep the
-- recorded input set machine-portable.
local function workdir_rel(p, root)
    -- Engine paths carry the root marker ("<abs root>/./<rel>"); the
    -- segment after the marker IS the working-dir-relative path.
    local marked = p:match("^.*/%./(.+)$")
    if marked then return marked end
    local prefix = root .. "/"
    if p:sub(1, #prefix) == prefix then return p:sub(#prefix + 1) end
    return p
end

-- Shell fragment appended to a build command: one make-format rule
-- enumerating every file currently under the dep output dirs. `sort`
-- pins the line's byte content for a given file set; a missing dir (dep
-- produced nothing yet) contributes nothing rather than failing.
local function depfile_command(dirs, dpath)
    local q = {}
    for i, d in ipairs(dirs) do q[i] = "'" .. d .. "'" end
    return "{ printf 'cook-pnpm-deps: '; find " .. table.concat(q, " ")
        .. " -type f 2>/dev/null | LC_ALL=C sort | tr '\\n' ' '; echo; } > '"
        .. dpath .. "'"
end

local function build_command_for(pkg, task_name)
    toolchain.ensure_probe_registered()
    local key = toolchain.get_probe_key()
    -- $<pnpm:toolchain:....pnpm> is replaced at execute time with the
    -- absolute pnpm binary path resolved by the toolchain probe.
    return "$<" .. key .. ".pnpm> --filter " .. pkg.name .. " run " .. task_name
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
              .. "check — engine test units (cook.add_test, CS-0127) have no "
              .. "consulted-env surface; make it a build (declare outputs) or "
              .. "drop env", 3)
    end

    -- Checks read dependency artifacts (tsc -b loads dep .d.ts), so an
    -- unordered check is a race; default the edge Turbo leaves implicit.
    -- The defaulted edge resolves strictly (batch-minted targets only —
    -- module-invented edges must never dangle); user-written depends_on
    -- resolves as always.
    local depends_on, strict = cfg.depends_on, false
    if kind == "check" and depends_on == nil then
        depends_on, strict = { "^build" }, true
    end

    local requires, dep_units = resolve_depends_on(pkg, depends_on, ctx, strict)
    for _, extra in ipairs(ctx.workspace_requires or {}) do
        requires[#requires + 1] = extra
    end
    for _, extra in ipairs(cfg.requires or {}) do
        requires[#requires + 1] = extra
    end
    local dep_dirs = dep_output_dirs(dep_units, ctx)

    local input_globs = cfg.inputs
        and anchor_globs(cfg.inputs, pkg.dir, true)
        or  default_inputs(pkg, ctx.pkg_outputs[pkg.name] or {})
    -- Workspace-level extras ride on every task, explicit inputs or not
    -- (already root-anchored + existence-filtered by mint_batch).
    for _, g in ipairs(ctx.extra_inputs or {}) do
        input_globs[#input_globs + 1] = g
    end

    local r_name = recipe_name(pkg, task_name)

    -- Data-driven fan-out carve-out (explicit-recipes contract): minted
    -- names the user never wrote must carry origin metadata so `cook
    -- list` attributes them to the call that created them (CS-0143).
    cook.recipe(r_name, { requires = requires, origin = origin }, function()
        if kind == "build" then
            local inputs = {}
            for _, g in ipairs(input_globs) do
                if g:find("[%*%?%[]") then
                    for _, m in ipairs(fs.glob(g)) do inputs[#inputs + 1] = m end
                else
                    inputs[#inputs + 1] = g
                end
            end
            -- package.json participates so a `scripts` edit invalidates.
            inputs[#inputs + 1] = pkg.dir .. "/package.json"
            -- Dep-output content fold via discovered inputs (see header):
            -- the command records what it consumed; later runs hash that.
            local command = build_command_for(pkg, task_name) .. " "
            local discovered
            if #dep_dirs > 0 then
                local dpath = workdir_rel(pkg.dir, ctx.root) .. "/" .. M.DEPFILE_NAME
                local rel_dirs = {}
                for i, d in ipairs(dep_dirs) do
                    rel_dirs[i] = workdir_rel(d, ctx.root)
                end
                command = command .. "&& " .. depfile_command(rel_dirs, dpath)
                discovered = { from = dpath, format = "make" }
            end
            -- Consulted env: workspace-level keys + per-task keys, in that
            -- order (§17.1.2.1 auto-fold; values fold, dup keys harmless).
            local env_keys = {}
            for _, k in ipairs(ctx.workspace_env or {}) do env_keys[#env_keys + 1] = k end
            for _, k in ipairs(cfg.env or {}) do env_keys[#env_keys + 1] = k end
            cook.add_unit({
                inputs   = inputs,
                outputs  = anchor_globs(outputs, pkg.dir, false),
                command  = command,
                -- Toolchain probe is consumed as DATA (the command
                -- interpolates the binary path — §12.7.4); the install
                -- probe is a deterministic, invalidate-only determinant
                -- (lockfile content hash) → carried as a seal (§12.7.5).
                probes   = { toolchain.get_probe_key() },
                seal     = { ctx.install_key },
                discovered_inputs  = discovered,
                consulted_env_keys = (#env_keys > 0) and env_keys or nil,
            })
        else
            local inputs = {}
            for _, g in ipairs(input_globs) do inputs[#inputs + 1] = g end
            inputs[#inputs + 1] = pkg.dir .. "/package.json"
            -- The lockfile is a declared input (content-fingerprinted):
            -- test units take no seal field, and their commands get no
            -- probe substitution (CS-0127) — plain `pnpm` from PATH.
            inputs[#inputs + 1] = ctx.lockfile
            -- Dep artifacts as ready-time glob inputs (see header): the
            -- ^build edge above guarantees they exist before resolution.
            for _, d in ipairs(dep_dirs) do
                inputs[#inputs + 1] = d .. "/**/*"
            end
            cook.add_test({
                command = "pnpm --filter " .. pkg.name .. " run " .. task_name,
                suite   = pkg.name,
                inputs  = inputs,
                line    = 0,
            })
        end
    end)
end

-- Shared batch minting: `tasks_map` is { task_name -> cfg }. Every task
-- in the batch contributes its outputs to the exclusion set BEFORE any
-- default input set is computed — this is why the workspace{tasks=...}
-- form is preferred over serial cook_pnpm.task() calls.
local function mint_batch(tasks_map, workspace_requires, workspace_inputs, workspace_env, origin)
    local packages = workspace.list()
    local snap = workspace.snapshot()
    local root = snap.root_dir or "."

    local base, overrides = split_overrides(tasks_map, snap.by_name)
    for task_name, cfg in pairs(base) do
        reject_negated_outputs(cfg, "task '" .. task_name .. "'")
    end
    for pkg_name, per_pkg in pairs(overrides) do
        for task_name, cfg in pairs(per_pkg) do
            reject_negated_outputs(cfg, "task '" .. pkg_name .. "#" .. task_name .. "'")
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

    -- Root-anchored workspace extras. A missing literal is dropped (a
    -- declared-but-absent input is never-a-clean-hit engine-side, i.e.
    -- silent cache-off for every task); it re-enters once the file
    -- exists, since register re-evaluates per invocation.
    local extra_inputs = {}
    for _, g in ipairs(workspace_inputs or {}) do
        local anchored = root .. "/" .. normalize_input_glob(g)
        if anchored:find("[%*%?%[]") or fs.exists(anchored) then
            extra_inputs[#extra_inputs + 1] = anchored
        end
    end

    local ctx = {
        by_name            = snap.by_name,
        install_key        = snap.install_key,
        root               = root,
        lockfile           = root .. "/pnpm-lock.yaml",
        workspace_requires = workspace_requires,
        workspace_env      = workspace_env,
        pkg_outputs        = pkg_outputs,
        extra_inputs       = extra_inputs,
        -- True iff this batch mints (dep_pkg, task): script declared AND
        -- an effective cfg covers it — the dangling-edge guard for
        -- resolve_depends_on.
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
                   "cook_pnpm.workspace")
    end
end

-- Escape hatch: register a custom recipe under <pkg>:<name>. The caller
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
