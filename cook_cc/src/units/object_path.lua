-- cook_cc.units.object_path — the ONE object/depfile path derivation (§28.3.5.1)
-- domain:  units — pure path derivation, no engine effects
-- effects: pure (cook.sh only to recover the workspace root, and only for
--          absolute sources; cached per VM)
-- std:     §28.3.5.1
--
-- §28.3.11 forbids re-deriving object paths independently of cc.compile: the
-- compile database and the compiler must agree BY CONSTRUCTION, not by two
-- copies kept in lockstep. This module is that construction. `units/cc.lua`
-- and `codegen/compile_db.lua` are its only callers, and neither may compute
-- an object path any other way.
local M = {}

-- Workspace root, recovered once per VM. fs.glob returns ABSOLUTE paths while
-- authors write workspace-relative ones, so the derivation has to agree on a
-- single form or two spellings of one source derive two objects. The Cook Lua
-- API exposes no path.relative and no workspace-root accessor (§26 is
-- stem/dir/ext/join/name/replace_ext), so we recover it from the register
-- VM's cwd, which IS the workspace root. Resolved lazily: a relative source
-- never needs it, which is both the common path and what keeps this pure for
-- most callers.
local root_cache = nil

local function workspace_root()
    if not root_cache then
        root_cache = (cook.sh("pwd") or ""):gsub("%s+$", "")
    end
    return root_cache
end

-- FNV-1a over the path, rendered hex. Only used to key sources that live
-- outside the workspace, where there is no relative path to carry through.
local function fnv1a(s)
    local h = 2166136261
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = (h * 16777619) & 0xFFFFFFFF
    end
    return string.format("%08x", h)
end

-- Workspace-relative form of `source`, carried through UNALTERED: directory
-- components and file extension both survive. Injectivity is a property of
-- that construction. Do not "sanitise" this into a flat name — separator
-- folding is not injective either (a/b.o collides with a.b.o, and
-- dictionary_compression.cpp with dictionary/compression.cpp), which is the
-- trap §28.3.5.1 calls out by name.
function M.relative(source)
    if source:sub(1, 1) ~= "/" then
        return (source:gsub("^%./", ""))
    end
    local root = workspace_root()
    if root ~= "" and source:sub(1, #root + 1) == root .. "/" then
        return source:sub(#root + 2)
    end
    -- Outside the workspace. §28.3.5.1: stay inside build/obj/<target>/ and
    -- stay injective. fs.* is sandboxed to the project root (§25.9) so this is
    -- only reachable when a caller hands cc.compile a literal absolute path.
    return "_external/" .. fnv1a(source) .. "/" .. (source:match("([^/]+)$") or "src")
end

-- build/obj/<target_name>/<source-relative-to-workspace-root>.o
function M.object(target_name, source)
    return "build/obj/" .. target_name .. "/" .. M.relative(source) .. ".o"
end

-- The depfile mirrors the OBJECT, never the source basename, so it is distinct
-- whenever the object is (§28.3.5).
function M.depfile(obj_out)
    return ".cook/deps/" .. obj_out .. ".d"
end

-- Spec hook: drop the cached workspace root.
function M._reset()
    root_cache = nil
end

return M
