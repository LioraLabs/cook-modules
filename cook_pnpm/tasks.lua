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
    -- post-hoc), drop output matches.
    for _, m in ipairs(fs.glob(pkg.dir .. "/*")) do
        local rel = m:match("([^/]+)$")
        local is_output = false
        for _, g in ipairs(all_outputs) do
            if glob_matches(g, rel) then is_output = true break end
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

-- A `depends_on` edge only fires if the referenced recipe will actually
-- exist (Turborepo's "no-op on missing script"; prevents dangling edges).
local function resolve_depends_on(pkg, depends_on, by_name)
    local result = {}
    for _, dep in ipairs(depends_on or {}) do
        if dep:sub(1, 1) == "^" then
            local task_name = dep:sub(2)
            for _, dep_pkg_name in ipairs(pkg.workspace_deps) do
                local dep_pkg = by_name[dep_pkg_name]
                if dep_pkg and dep_pkg.package.scripts[task_name] then
                    result[#result + 1] = recipe_name(dep_pkg, task_name)
                end
            end
        else
            if pkg.package.scripts[dep] then
                result[#result + 1] = recipe_name(pkg, dep)
            end
        end
    end
    return result
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
    local requires = resolve_depends_on(pkg, cfg.depends_on, ctx.by_name)
    for _, extra in ipairs(ctx.workspace_requires or {}) do
        requires[#requires + 1] = extra
    end
    for _, extra in ipairs(cfg.requires or {}) do
        requires[#requires + 1] = extra
    end

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

    local input_globs = cfg.inputs
        and anchor_globs(cfg.inputs, pkg.dir, true)
        or  default_inputs(pkg, ctx.pkg_outputs[pkg.name] or {})

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
            cook.add_unit({
                inputs   = inputs,
                outputs  = anchor_globs(outputs, pkg.dir, false),
                command  = build_command_for(pkg, task_name) .. " ",
                -- Toolchain probe is consumed as DATA (the command
                -- interpolates the binary path — §12.7.4); the install
                -- probe is a deterministic, invalidate-only determinant
                -- (lockfile content hash) → carried as a seal (§12.7.5).
                probes   = { toolchain.get_probe_key() },
                seal     = { ctx.install_key },
            })
        else
            local inputs = {}
            for _, g in ipairs(input_globs) do inputs[#inputs + 1] = g end
            inputs[#inputs + 1] = pkg.dir .. "/package.json"
            -- The lockfile is a declared input (content-fingerprinted):
            -- test units take no seal field, and their commands get no
            -- probe substitution (CS-0127) — plain `pnpm` from PATH.
            inputs[#inputs + 1] = ctx.lockfile
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
local function mint_batch(tasks_map, workspace_requires, origin)
    local packages = workspace.list()
    local snap = workspace.snapshot()

    -- Union of declared output globs per package (package-relative).
    local pkg_outputs = {}
    for _, pkg in ipairs(packages) do
        local union = {}
        for task_name, cfg in pairs(tasks_map) do
            if pkg.package.scripts[task_name] then
                for _, g in ipairs(cfg.outputs or {}) do union[#union + 1] = g end
            end
        end
        pkg_outputs[pkg.name] = union
    end

    local ctx = {
        by_name            = snap.by_name,
        install_key        = snap.install_key,
        lockfile           = (snap.root_dir or ".") .. "/pnpm-lock.yaml",
        workspace_requires = workspace_requires,
        pkg_outputs        = pkg_outputs,
    }

    -- Deterministic mint order: sorted task names, packages in topo order.
    local names = {}
    for task_name in pairs(tasks_map) do names[#names + 1] = task_name end
    table.sort(names)
    for _, task_name in ipairs(names) do
        local cfg = tasks_map[task_name]
        for _, pkg in ipairs(packages) do
            -- Skip packages that don't declare the script (Turborepo
            -- no-op-on-missing-script).
            if pkg.package.scripts[task_name] then
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
    mint_batch({ [task_name] = opts or {} }, nil, "cook_pnpm.task")
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
        mint_batch(tasks_map, opts.requires, "cook_pnpm.workspace")
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
