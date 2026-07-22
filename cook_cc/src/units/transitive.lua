-- cook_cc.units.transitive — walks link closures and merges exported includes/defines/libs/lib_paths/ldflags
-- domain:  units — builds commands and registers work on the engine
-- effects: pure
local M = {}

local function add_unique(dst, src, seen)
    if not src then return end
    for _, v in ipairs(src) do
        if not seen[v] then
            seen[v] = true
            dst[#dst + 1] = v
        end
    end
end

function M.resolve_links(links)
    local merged = {
        includes      = {},
        defines       = {},
        system_libs   = {},
        frameworks    = {},
        lib_paths     = {},
        extra_ldflags = "",
        -- CS-0161 §28.4: names of walked targets whose export carries a
        -- non-empty lib_path, in first-seen walk order. Target makers pass
        -- this as `dep_recipes` to cc.archive / cc.link so the emitted unit
        -- is ordered after every artifact-producing target in its closure.
        link_dep_recipes = {},
    }
    local seen_inc, seen_def, seen_lib, seen_fw, seen_path = {}, {}, {}, {}, {}
    local visited = {}

    local function walk(name)
        if visited[name] then return end
        visited[name] = true
        local info = cook.import(name)
        if not info then return end
        add_unique(merged.includes,    info.includes,    seen_inc)
        add_unique(merged.defines,     info.defines,     seen_def)
        add_unique(merged.system_libs, info.system_libs, seen_lib)
        add_unique(merged.frameworks,  info.frameworks,  seen_fw)
        -- Collect the archive/shared-lib path for local targets so the linker
        -- can include it.  Exported by M.lib / M.shared via lib_path.
        if info.lib_path and info.lib_path ~= "" then
            add_unique(merged.lib_paths, { info.lib_path }, seen_path)
            merged.link_dep_recipes[#merged.link_dep_recipes + 1] = name
        end
        if info.extra_ldflags and info.extra_ldflags ~= "" then
            if merged.extra_ldflags ~= "" then
                merged.extra_ldflags = merged.extra_ldflags .. " " .. info.extra_ldflags
            else
                merged.extra_ldflags = info.extra_ldflags
            end
        end
        for _, child in ipairs(info.links or {}) do walk(child) end
    end

    for _, name in ipairs(links or {}) do walk(name) end
    return merged
end

return M
