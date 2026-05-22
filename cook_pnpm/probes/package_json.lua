-- package.json reader.
--
-- Uses lua-cjson (declared in the rockspec deps) as the primary parser
-- and falls back to a minimal pattern-based scan only when cjson is
-- unavailable — e.g., when busted is invoked without cjson on the
-- package path. Production paths inside the cook engine always have
-- cjson available because the engine bundles it.
--
-- Only the fields cook_pnpm cares about are surfaced: name, version,
-- private, scripts, dependencies, devDependencies, peerDependencies.

local M = {}

local function require_cjson()
    local ok, cjson = pcall(require, "cjson.safe")
    if ok and type(cjson) == "table" then return cjson end
    local ok2, cjson2 = pcall(require, "cjson")
    if ok2 and type(cjson2) == "table" then return cjson2 end
    return nil
end

local function parse_with_cjson(raw)
    local cjson = require_cjson()
    if not cjson then return nil, "cjson-unavailable" end
    if cjson.decode then
        local ok, decoded = pcall(cjson.decode, raw)
        if ok and type(decoded) == "table" then return decoded end
        return nil, "cjson-decode-failed: " .. tostring(decoded)
    end
    return nil, "cjson-missing-decode"
end

local function pluck_string_map(raw, key)
    local body = raw:match('"' .. key .. '"%s*:%s*({.-})')
    if not body then return {} end
    local out = {}
    for k, v in body:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
        out[k] = v
    end
    return out
end

local function parse_fallback(raw)
    local pkg = {}
    pkg.name    = raw:match('"name"%s*:%s*"([^"]+)"')
    pkg.version = raw:match('"version"%s*:%s*"([^"]+)"')
    pkg.private = raw:match('"private"%s*:%s*true') ~= nil
    pkg.dependencies     = pluck_string_map(raw, "dependencies")
    pkg.devDependencies  = pluck_string_map(raw, "devDependencies")
    pkg.peerDependencies = pluck_string_map(raw, "peerDependencies")
    pkg.scripts          = pluck_string_map(raw, "scripts")
    return pkg
end

-- Normalise: cjson decodes empty JSON objects {} to a Lua table that is
-- both array and map (length 0, no keys). We always want maps here.
local function ensure_map(t)
    if type(t) ~= "table" then return {} end
    return t
end

function M.read(path)
    if not fs.exists(path) then
        error("[pnpm.workspace] package.json not found at " .. path, 2)
    end
    local raw = fs.read(path)
    local decoded, err = parse_with_cjson(raw)
    if not decoded then
        decoded = parse_fallback(raw)
    end
    if not decoded or not decoded.name then
        local hint = err and (" (" .. err .. ")") or ""
        error("[pnpm.workspace] package.json at " .. path
              .. " has no `name` field" .. hint, 2)
    end
    decoded.dependencies     = ensure_map(decoded.dependencies)
    decoded.devDependencies  = ensure_map(decoded.devDependencies)
    decoded.peerDependencies = ensure_map(decoded.peerDependencies)
    decoded.scripts          = ensure_map(decoded.scripts)
    decoded.private          = decoded.private and true or false
    return decoded
end

return M
