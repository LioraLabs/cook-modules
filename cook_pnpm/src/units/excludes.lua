-- cook_pnpm.units.excludes — exclude_inputs compilation and subtree matching
-- domain:  units — pure set subtraction, no engine effects
-- effects: pure
--
-- Input exclusions (0.5, `exclude_inputs`): tools that write derived
-- state INTO source dirs (next build rewriting app/.well-known/...
-- manifests) must not re-key their own task. Task-cfg entries are
-- package-relative, workspace-level entries root-relative; both are
-- subtracted from every affected task's inputs — per-file at build-unit
-- fs.glob expansion, entry-level (whole glob inside an excluded subtree)
-- for check units, whose globs resolve engine-side. The `!` is implied.
--
-- `!`-prefixed entries on any INPUTS surface are a loud register-time
-- error (see reject_negated). Anchoring (`dir .. "/" .. g`) would corrupt
-- the `!` into a mid-path literal (`apps/web/!foo/**`) that silently
-- matches nothing — the exact failure mode that hid a tool-written file
-- re-keying a 29s build, and the origin bug this whole surface exists to
-- prevent. The declared subtraction surface is `exclude_inputs`; `!` on
-- `inputs` is never a shorthand for it.

local globs = require("cook_pnpm.units.globs")

local M = {}

-- `!`-prefixed entries on an *inputs* surface are rejected loudly (see
-- header). The error names exclude_inputs as the replacement.
function M.reject_negated(input_globs, label)
    for _, g in ipairs(input_globs or {}) do
        if g:sub(1, 1) == "!" then
            error("[pnpm.task] input '" .. g .. "' (" .. label .. ") is a "
                  .. "negated glob — anchoring would corrupt the `!` into a "
                  .. "mid-path literal that silently matches nothing. Use "
                  .. "exclude_inputs = { \"" .. g:sub(2) .. "\" } instead.", 4)
        end
    end
end

-- Compile `exclude_inputs` globs into match patterns over
-- workspace-relative paths. `dir` anchors the entries: the package dir
-- for task-cfg exclusions, the workspace root for workspace-level ones.
-- The `!` is implied; a `!`-prefixed entry here is an error, not a
-- double negation.
function M.compile(exclude_globs, dir, root, label)
    local pats = {}
    for _, g in ipairs(exclude_globs or {}) do
        if g:sub(1, 1) == "!" then
            error("[pnpm.task] exclude_inputs entry '" .. g .. "' (" .. label
                  .. ") — the `!` is implied on this surface; write the glob "
                  .. "without it", 4)
        end
        local anchored = dir .. "/" .. globs.normalize_input_glob(g)
        pats[#pats + 1] = globs.glob_to_pattern(globs.workdir_rel(anchored, root))
    end
    return pats
end

-- True when `path` (workspace path, any anchoring form) falls inside one
-- of the compiled exclude patterns. Also true for a GLOB entry that lies
-- wholly inside an excluded subtree — `apps/web/app/**/*` matches the
-- compiled `^apps/web/app/.*$` textually — which is what lets exclusion
-- drop whole default-input entries for check units, whose globs the
-- engine resolves ready-time and the module never expands.
function M.is_excluded(path, root, pats)
    if #pats == 0 then return false end
    local rel = globs.workdir_rel(path, root)
    for _, p in ipairs(pats) do
        if rel:match(p) then return true end
    end
    return false
end

return M
