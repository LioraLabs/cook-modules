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
--
-- Artifact-class filtering (0.7): "over-invalidation is safe"
-- holds for correctness but not for the VALUE of the fold. tsup/esbuild
-- inline `sourcesContent`, so a comment-only edit upstream rewrites
-- `dist/index.mjs.map` while leaving `dist/index.mjs` byte-identical —
-- and a whole-directory fold re-keys every consumer on a sidecar none
-- of them read. That silently cancels the content cutoff this module's
-- headline advantage rests on. So the fold is filtered by artifact
-- class: DEFAULT_NOT_CONSUMED subtracts sourcemaps, and a task's
-- `consumes` replaces the filter outright when its layout is unusual.
-- The filter narrows a FINGERPRINT, never the dep's declared outputs —
-- the map is still built, still stored, still restored on a cache hit.
--
-- The filter below is the BUILD-unit half, applied to the depfile `find`
-- this module writes. A test unit's key folds predecessor outputs
-- engine-side (run.rs compute_ready_test_fingerprint step 1), which no
-- module input declaration can subtract from; CS-0175 added
-- `consumes` on the test unit (cook.add_unit, step_kind = "test" since
-- CS-0185) for it, and units.tasks passes a check's cfg straight through.
--
-- The two halves are not symmetric. This one is a DENYLIST — everything
-- folds except the classes named here — because a default must never
-- drop an artifact class nobody anticipated. The engine's is an
-- ALLOWLIST, matched positively, for the opposite reason: narrowing a
-- test key errs toward replaying a stale pass, so the engine only
-- narrows to what a caller explicitly names. Consequence worth knowing:
-- "everything but sourcemaps" cannot be spelled on the engine surface,
-- so an unconfigured check still re-keys on a dependency's maps while an
-- unconfigured build does not.

local globs = require("cook_pnpm.units.globs")

local M = {}

-- Basename of the per-package depfile a build unit writes after its pnpm
-- script succeeds. Dot-named so it can never enter a default input set
-- (cook_pnpm.units.inputs also excludes it explicitly — a depfile that
-- were its own unit's input would re-key the unit it was recorded by;
-- that exclusion is why units.inputs requires this module).
M.DEPFILE_NAME = ".cook-pnpm.d"

-- Recipe name for a (pkg, task) pair. Keep module-minted names out of the
-- user's recipe namespace, and use the workspace directory instead of the
-- often-scoped npm package name. The root needs no redundant `root` segment.
function M.package_alias(pkg)
    local dir = pkg.dir:gsub("/+$", ""):gsub("^%./", "")
    local alias = dir:match("([^/]+)$")
    return alias ~= "." and alias or nil
end

function M.recipe_name(pkg, task)
    local alias = M.package_alias(pkg)
    return "pnpm:" .. (alias and alias .. ":" or "") .. task
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

-- Artifact classes never folded when a task states no `consumes` (see
-- header). A sourcemap is by construction a debugging sidecar: no build
-- step reads one, and every esbuild-family tool rewrites it on a
-- comment-only edit. Basename globs, matched at any depth.
M.DEFAULT_NOT_CONSUMED = { "*.map" }

-- One `consumes` entry to a `find -name` operand. The accepted shape is
-- a BASENAME glob, optionally written with a leading `**/` for people
-- who think in path globs: "*.mjs", "**/*.d.ts", "index.js". Anything
-- with an interior `/` is rejected rather than silently mis-anchored —
-- `find -name` matches basenames, so a path-shaped entry would match
-- nothing, which is the failure mode this whole issue exists to kill.
local function basename_glob(g, label)
    if type(g) ~= "string" then
        error("[pnpm.task] consumes entry (" .. label .. ") must be a string, "
              .. "got " .. type(g), 5)
    end
    if g:sub(1, 1) == "!" then
        error("[pnpm.task] consumes entry '" .. g .. "' (" .. label .. ") is "
              .. "negated — `consumes` is an allowlist of what the task READS, "
              .. "not a subtraction; list the positive basename globs", 5)
    end
    local pat = g:match("^%*%*/(.+)$") or g
    -- Braces are shell alternation, not glob: `find -name '*.{mjs,cjs}'`
    -- matches the literal string and quietly folds NOTHING, which
    -- under-keys the consumer — a stale-cache bug, strictly worse than
    -- the over-invalidation this surface exists to fix. Loud, because a
    -- filter that silently matches nothing is unobservable.
    if pat:find("[{}]") then
        error("[pnpm.task] consumes entry '" .. g .. "' (" .. label .. ") uses "
              .. "brace alternation, which is shell expansion and not glob — "
              .. "it would match nothing and silently fold no dependency "
              .. "content. Write one entry per extension: "
              .. "consumes = { \"*.mjs\", \"*.cjs\" }", 5)
    end
    if pat == "" or pat:find("/", 1, true) then
        error("[pnpm.task] consumes entry '" .. g .. "' (" .. label .. ") is "
              .. "path-shaped — this surface filters dependency artifacts by "
              .. "BASENAME glob (\"*.mjs\", \"**/*.d.ts\"), matched at any "
              .. "depth under the dep's output dirs. Brace alternation is not "
              .. "glob: write one entry per extension.", 5)
    end
    if pat:find("'", 1, true) then
        error("[pnpm.task] consumes entry '" .. g .. "' (" .. label .. ") "
              .. "contains a single quote, which cannot be carried into the "
              .. "depfile command safely", 5)
    end
    return pat
end

-- The `find` predicate selecting which dependency artifacts land in the
-- depfile. An explicit `consumes` REPLACES the default (turbo-style: an
-- explicit statement of what a task reads is the whole truth about it,
-- not a delta on module policy), so a task that consumes maps can name
-- them back in.
function M.consumes_predicate(consumes, label)
    if consumes and #consumes > 0 then
        local ors = {}
        for _, g in ipairs(consumes) do
            ors[#ors + 1] = "-name '" .. basename_glob(g, label) .. "'"
        end
        return " \\( " .. table.concat(ors, " -o ") .. " \\)"
    end
    local nots = {}
    for _, g in ipairs(M.DEFAULT_NOT_CONSUMED) do
        nots[#nots + 1] = "! -name '" .. g .. "'"
    end
    return (#nots > 0) and (" " .. table.concat(nots, " ")) or ""
end

-- Shell fragment appended to a build command: one make-format rule
-- enumerating every file currently under the dep output dirs, filtered
-- by `predicate` to the artifact classes the task consumes. `sort` pins
-- the line's byte content for a given file set; a missing dir (dep
-- produced nothing yet) contributes nothing rather than failing.
function M.depfile_command(dirs, dpath, predicate)
    local q = {}
    for i, d in ipairs(dirs) do q[i] = "'" .. d .. "'" end
    return "{ printf 'cook-pnpm-deps: '; find " .. table.concat(q, " ")
        .. " -type f" .. (predicate or "") .. " 2>/dev/null | LC_ALL=C sort "
        .. "| tr '\\n' ' '; echo; } > '" .. dpath .. "'"
end

return M
