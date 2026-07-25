-- cook_pnpm.units.depfold — depends_on resolution and dependency-output content folding
-- domain:  units — pure edge/path derivation, no engine effects
-- effects: pure
-- std:     §17.1.1, §17.5
--
-- `depends_on` (Turborepo-style, workspace-internal):
--   - `"^build"`  — wait on `build` task in each workspace dependency
--   - `"build"`   — wait on `build` task in the SAME package
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

local globs = require("cook_pnpm.units.globs")

local M = {}

-- Basename of the per-package depfile a build unit writes after its pnpm
-- script succeeds. Dot-named so it can never enter a default input set
-- (cook_pnpm.units.inputs also excludes it explicitly — a depfile that
-- were its own unit's input would re-key the unit it was recorded by;
-- that exclusion is why units.inputs requires this module).
M.DEPFILE_NAME = ".cook-pnpm.d"

-- Recipe name for a (pkg, task) pair. Lives here because resolving a
-- depends_on edge IS producing these names; units.tasks re-exports it.
function M.recipe_name(pkg, task) return pkg.name .. ":" .. task end

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
function M.resolve_depends_on(pkg, depends_on, ctx, strict)
    local requires, dep_units = {}, {}
    local function eligible(dep_pkg, task_name)
        if not dep_pkg.package.scripts[task_name] then return false end
        if strict and not ctx.has_task(dep_pkg, task_name) then return false end
        return true
    end
    local function add(dep_pkg, task_name)
        requires[#requires + 1] = M.recipe_name(dep_pkg, task_name)
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
function M.dep_output_dirs(dep_units, ctx)
    local dirs, seen = {}, {}
    for _, du in ipairs(dep_units) do
        for _, g in ipairs(ctx.pkg_outputs[du.pkg.name] or {}) do
            local sub = globs.claimed_subdir(g)
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

-- Shell fragment appended to a build command: one make-format rule
-- enumerating every file currently under the dep output dirs. `sort`
-- pins the line's byte content for a given file set; a missing dir (dep
-- produced nothing yet) contributes nothing rather than failing.
function M.depfile_command(dirs, dpath)
    local q = {}
    for i, d in ipairs(dirs) do q[i] = "'" .. d .. "'" end
    return "{ printf 'cook-pnpm-deps: '; find " .. table.concat(q, " ")
        .. " -type f 2>/dev/null | LC_ALL=C sort | tr '\\n' ' '; echo; } > '"
        .. dpath .. "'"
end

return M
