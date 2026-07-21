-- cook_cc.discovery.finders — curated finder registry: maps dependency names (and aliases) to finder modules
-- domain:  discovery — registers probes (dependency finders, feature checks); facts in, no work units
-- effects: pure
local M = {}

local CURATED = {
    raylib  = "cook_cc.discovery.finders.raylib",
    sdl2    = "cook_cc.discovery.finders.sdl2",
    openal  = "cook_cc.discovery.finders.openal",
    gl      = "cook_cc.discovery.finders.gl",
    threads = "cook_cc.discovery.finders.threads",
    zlib    = "cook_cc.discovery.finders.zlib",
    libcurl = "cook_cc.discovery.finders.libcurl",
}

local ALIASES = {
    opengl = "gl",
}

function M.lookup(name)
    local canonical = ALIASES[name] or name
    local mod_path = CURATED[canonical]
    if not mod_path then return nil end
    local ok, mod = pcall(require, mod_path)
    if not ok then return nil end
    return function(opts)
        local attempt = mod.find(opts)
        attempt.strategy = "curated:" .. canonical
        return attempt
    end
end

return M
