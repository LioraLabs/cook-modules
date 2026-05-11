local lpeg = require("lpeg")
local P, S, C, Ct = lpeg.P, lpeg.S, lpeg.C, lpeg.Ct

local M = {}

-- Grammar: parses a pkg-config-output line into structured tokens.
local space     = S(" \t")^0
local non_space = (P(1) - S(" \t"))^1
local include   = P("-I") * C(non_space)
local libdir    = P("-L") * C(non_space)
local syslib    = P("-l") * C(non_space)
local define    = P("-D") * C(non_space)
local framework = P("-framework") * S(" \t")^1 * C(non_space)
local other     = C(non_space)

local token = framework / function(v) return { kind = "framework", value = v } end
            + include   / function(v) return { kind = "include",   value = v } end
            + libdir    / function(v) return { kind = "libdir",    value = v } end
            + syslib    / function(v) return { kind = "syslib",    value = v } end
            + define    / function(v) return { kind = "define",    value = v } end
            + other     / function(v) return { kind = "other",     value = v } end

local line_pattern = Ct((space * token)^0 * space)

local function parse_tokens(s)
    return line_pattern:match(s or "") or {}
end

local function shell_chomp(s) return (s or ""):gsub("%s+$", "") end

local function try_sh(cmd)
    local ok, out = pcall(cook.sh, cmd)
    return ok, ok and shell_chomp(out) or nil
end

local function blank_result()
    return {
        found        = false,
        cflags       = "",
        libs         = "",
        system_libs  = {},
        include_dirs = {},
        lib_dirs     = {},
        frameworks   = {},
        version      = nil,
    }
end

function M.find(name, _opts)
    local cache_key = "pkg:" .. name
    local cached = cook.cache.get(cache_key)
    if cached then return cached end

    local ok = try_sh("pkg-config --exists " .. name)
    if not ok then
        local r = blank_result()
        cook.cache.set(cache_key, r)
        return r
    end
    local _, cflags = try_sh("pkg-config --cflags " .. name)
    local _, libs   = try_sh("pkg-config --libs "   .. name)

    local result = blank_result()
    result.found  = true
    result.cflags = cflags or ""
    result.libs   = libs   or ""

    local function bucket(toks)
        for _, t in ipairs(toks) do
            if     t.kind == "include"   then result.include_dirs[#result.include_dirs + 1] = t.value
            elseif t.kind == "libdir"    then result.lib_dirs[#result.lib_dirs + 1] = t.value
            elseif t.kind == "syslib"    then result.system_libs[#result.system_libs + 1] = t.value
            elseif t.kind == "framework" then result.frameworks[#result.frameworks + 1] = t.value
            end
        end
    end
    bucket(parse_tokens(result.cflags))
    bucket(parse_tokens(result.libs))

    cook.cache.set(cache_key, result)
    return result
end

return M
