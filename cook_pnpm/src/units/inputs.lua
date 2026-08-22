-- cook_pnpm.units.inputs — default input sets and workspace-level input extras
-- domain:  units — computes input sets; reads the tree, registers nothing
-- effects: fs.glob / fs.exists, cook.sh (§25.10 escape hatch, see list_subdirs)
--
-- Default inputs (0.3): omitting `inputs` used to key the task on
-- package.json alone — silently wrong-by-default caching. Now it means
-- "the package's file tree", computed per package as:
--   - every top-level directory of the package EXCEPT node_modules,
--     dot-directories, and any directory claimed by a declared output
--     glob of ANY task in the same mint batch (so `web:test` does not
--     take `pnpm:web:build`'s dist/ as an input and self-invalidate);
--   - plus the package's top-level files, minus those matching a
--     declared output glob.
-- Subtraction runs through cook_pnpm.units.globs' limited matcher, never
-- through cache-key resolution.
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

local globs   = require("cook_pnpm.units.globs")
local depfold = require("cook_pnpm.units.depfold")

local M = {}

-- Top-level directories of `dir`, via the §25.10 shell escape hatch
-- (fs.glob cannot enumerate directories — CS-0064 drops them). Returns
-- BASENAMES. node_modules and dot-directories are excluded at the
-- enumeration itself, so the walk never touches them.
--
-- One process spawn per package, every register phase, cache-hit runs
-- included — an unmeasured register-phase cost that scales with the
-- workspace.
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
function M.defaults(pkg, all_outputs)
    local entries = {}
    for _, base in ipairs(list_subdirs(pkg.dir)) do
        local claimed = false
        for _, g in ipairs(all_outputs) do
            if globs.claimed_subdir(g) == base then claimed = true break end
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
                       or rel == depfold.DEPFILE_NAME
        for _, g in ipairs(all_outputs) do
            if is_output then break end
            if globs.glob_matches(g, rel) then is_output = true end
        end
        if not is_output then entries[#entries + 1] = pkg.dir .. "/" .. rel end
    end
    return entries
end

-- Root-anchor workspace{inputs} extras, dropping missing literals (see
-- header). Globs pass through unexpanded.
function M.workspace_extras(workspace_inputs, root)
    local extra = {}
    for _, g in ipairs(workspace_inputs or {}) do
        local anchored = root .. "/" .. globs.normalize_input_glob(g)
        if anchored:find("[%*%?%[]") or fs.exists(anchored) then
            extra[#extra + 1] = anchored
        end
    end
    return extra
end

return M
