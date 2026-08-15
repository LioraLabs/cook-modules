-- cook_cc.units.sources — resolves opts.sources into the compile set (§28.3.1.1)
-- domain:  units — pure set resolution, no engine effects
-- effects: fs.glob / fs.exists
-- std:     §28.3.1.1
--
-- Entries are literals, glob patterns, or `!`-prefixed exclusions, resolved as
-- `(includes) \ (excludes)`. Item order does not affect the result — same
-- grammar and same semantics as the `gather` step (§8.2), deliberately,
-- rather than a second spelling of exclusion.
local object_path = require("cook_cc.units.object_path")

local M = {}

local function is_pattern(s)
    return s:find("[%*%?%[]") ~= nil
end

-- Compare on the workspace-relative form so ordering does not depend on where
-- the workspace happens to live, and so a literal and a glob hit for the same
-- file sort (and dedup) identically.
local function key_of(p)
    return object_path.relative(p)
end

local function glob_or_error(kind, pattern, target)
    local hits = fs.glob(pattern)
    if #hits == 0 and kind == "include" then
        -- §28.3.1.1: a silently-empty include is the failure this catches. In a
        -- target of thousands of sources a stale directory drops a whole
        -- subtree without changing the exit status, and the loss resurfaces as
        -- an undefined symbol at link, far from its cause.
        error("[cc] source pattern matched no files: '" .. pattern
            .. "' (target '" .. target .. "')", 4)
    end
    return hits
end

-- Returns the resolved source list: deduplicated, excludes subtracted, sorted
-- by workspace-relative path.
function M.resolve(opts, target)
    local entries = opts.sources or {}

    -- Back-compat: `dir` recursively globs the four C-family extensions.
    if #entries == 0 and opts.dir then
        entries = {}
        for _, ext in ipairs({ "*.cpp", "*.c", "*.cc", "*.cxx" }) do
            entries[#entries + 1] = opts.dir .. "**/" .. ext
        end
        -- Under `dir` an extension that matches nothing is ordinary, not an
        -- error: a C++-only tree has no .c files and never did.
        local out, seen = {}, {}
        for _, pattern in ipairs(entries) do
            for _, hit in ipairs(fs.glob(pattern)) do
                local k = key_of(hit)
                if not seen[k] then seen[k] = true; out[#out + 1] = k end
            end
        end
        table.sort(out)
        return out
    end

    local included, excluded = {}, {}

    for _, entry in ipairs(entries) do
        local is_exclude = entry:sub(1, 1) == "!"
        local pattern = is_exclude and entry:sub(2) or entry
        local sink = is_exclude and excluded or included

        if is_pattern(pattern) then
            for _, hit in ipairs(glob_or_error(is_exclude and "exclude" or "include", pattern, target)) do
                sink[key_of(hit)] = true
            end
        elseif is_exclude then
            -- A literal exclusion names a file that may legitimately be absent.
            sink[key_of(pattern)] = true
        else
            if not fs.exists(pattern) then
                error("[cc] source not found: '" .. pattern
                    .. "' (target '" .. target .. "')", 4)
            end
            sink[key_of(pattern)] = true
        end
    end

    local out = {}
    for src in pairs(included) do
        if not excluded[src] then out[#out + 1] = src end
    end
    -- Deterministic, host-independent order. Source order reaches the ar and
    -- link command strings, which are cache-key determinants (§17.1.1) — a
    -- directory-order-dependent set would re-key the archive across machines
    -- differing only in filesystem layout.
    table.sort(out)
    return out
end

return M
