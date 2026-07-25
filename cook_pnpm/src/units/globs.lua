-- cook_pnpm.units.globs — glob normalisation, the subtraction-only matcher, and path anchoring
-- domain:  units — pure path/glob primitives, no engine effects
-- effects: pure
--
-- Every path this module hands the engine passes through here. Three
-- concerns, all pure string work:
--
--   normalisation  — the trailing bare `**` rewrite (see normalize_input_glob)
--   matching       — a LIMITED glob matcher used ONLY for subtraction
--   anchoring      — package-relative globs to workspace-relative ones
--
-- The matcher (glob_to_pattern / glob_matches) implements the glob subset
-- that output declarations and `exclude_inputs` actually use — `dir/**`,
-- `dir/**/*`, `*.ext`, `?`, and literal paths. It exists to SUBTRACT build
-- products and tool-written files from default input sets. It is never used
-- for cache-key resolution: that stays engine-side, where the real matcher
-- lives. Do not grow this into a general glob implementation — if a surface
-- needs shapes this cannot express, that surface belongs engine-side.

local M = {}

-- Rewrite a trailing bare "**" to "**/*" so glob resolution matches
-- files, not just directories (the engine's matcher treats a bare "**"
-- as directories-only; tracked upstream). Applied both to register-time
-- fs.glob expansion (build units) and to the glob inputs handed to the
-- engine for ready-time resolution (check units).
function M.normalize_input_glob(g)
    if g:sub(-3) == "/**" then return g .. "/*" end
    if g == "**"          then return "**/*"    end
    return g
end

function M.glob_to_pattern(g)
    local p = g:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%1")
    p = p:gsub("%*%*/%*", "\1")   -- **/* -> any subpath
    p = p:gsub("%*%*", "\1")      -- **   -> any subpath
    p = p:gsub("%*", "[^/]*")     -- *    -> within one segment
    p = p:gsub("%?", "[^/]")
    p = p:gsub("\1", ".*")
    return "^" .. p .. "$"
end

function M.glob_matches(g, rel_path)
    return rel_path:match(M.glob_to_pattern(g)) ~= nil
end

-- First path segment of an output glob whose remainder is a whole-subtree
-- pattern ("dist/**", "dist/**/*", ".next/**") — the directory a default
-- input set must not descend into. Returns nil for root-level patterns
-- ("*.tsbuildinfo") and multi-segment literals.
function M.claimed_subdir(g)
    local head, rest = g:match("^([^/]+)/(.+)$")
    if head and (rest == "**" or rest == "**/*") then return head end
    return nil
end

-- Anchor package-relative globs at the package dir WITHOUT expansion.
function M.anchor_globs(globs, dir, normalize)
    local out = {}
    for _, g in ipairs(globs or {}) do
        out[#out + 1] = dir .. "/" .. (normalize and M.normalize_input_glob(g) or g)
    end
    return out
end

-- Working-dir-relative form of a workspace path. The engine requires
-- discovered_inputs.from to be relative (commands run from the
-- workspace root), and relative paths in the depfile body keep the
-- recorded input set machine-portable.
function M.workdir_rel(p, root)
    -- Engine paths carry the root marker ("<abs root>/./<rel>"); the
    -- segment after the marker IS the working-dir-relative path.
    local marked = p:match("^.*/%./(.+)$")
    if marked then return marked end
    local prefix = root .. "/"
    if p:sub(1, #prefix) == prefix then return p:sub(#prefix + 1) end
    return p
end

return M
