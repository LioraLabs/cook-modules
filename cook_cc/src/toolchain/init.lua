-- cook_cc.toolchain — compiler selection: registers the cc:compiler:<override> and cc:host:<override> probes, holds standard/warnings/default-flag state
-- domain:  toolchain — pure resolution: which compiler, identity, flag dialects
-- effects: cook.probe
-- std:     §12.7
local M = {}

local state = {
    compiler_override     = nil,         -- nil means "auto"
    default_standard      = nil,
    warnings              = "default",
    -- CS-0168 codegen vocabulary; nil means "not requested".
    optimize              = nil,
    debug_symbols         = nil,
    gc_sections           = nil,
    defaults              = {},
    probe_registered      = {},          -- set: key -> true
}

local function suffix() return state.compiler_override or "auto" end

local function probe_key() return "cc:compiler:" .. suffix() end

local function produce_body(override)
    local override_literal = override and string.format("%q", override) or "nil"
    return string.format([[
        local override = %s
        -- CS-0158: fold the CHOSEN drivers' canonical identities
        -- (resolved-binary content hashes) into the value. Names alone
        -- under-key: gcc 13 and gcc 14 sealed identically, so a compiler
        -- upgrade reused stale objects — including from the shared store
        -- across machines with different compilers. The hash is the
        -- machine-independent identity the seal policy demands (12.7.5);
        -- the path stays out (it would re-key identical toolchains at
        -- different locations).
        local function id_of(name)
            local t = cook.tools.id(name)
            return t and t.hash or "<missing>"
        end
        if override then
            local out = cook.sh("command -v " .. override .. " 2>/dev/null")
            if not out:match("%%S") then
                error("[cc.toolchain] override compiler '" .. override .. "' not on PATH")
            end
            local cc
            if override:match("clang") then cc = "clang"
            elseif override:match("g%%+%%+") then cc = "gcc"
            else cc = "cc" end
            return { cxx = override, cc = cc, cxx_id = id_of(override), cc_id = id_of(cc) }
        end
        for _, c in ipairs({ {cxx="g++",cc="gcc"}, {cxx="clang++",cc="clang"} }) do
            local out = cook.sh("command -v " .. c.cxx .. " 2>/dev/null")
            if out:match("%%S") then
                return { cxx = c.cxx, cc = c.cc, cxx_id = id_of(c.cxx), cc_id = id_of(c.cc) }
            end
        end
        error("[cc.toolchain] no C/C++ compiler on PATH (tried g++, clang++)")
    ]], override_literal)
end

-- A compiled object is bound to its target, and cook infers no machine
-- identity (§17.1.1): sealed on every compile and link unit, this keeps two
-- hosts' artifacts apart. Asks the CHOSEN compiler (same suffix as the
-- compiler key). Its stderr is not redirected: cook.sh attributes it to
-- the probe unit, so a crash reports why (CS-0188).
local function host_key()
    return "cc:host:" .. suffix()
end

local HOST_BODY = [[
    local c = cook.probes.get(%q)
    local cmd = c.cxx .. " -dumpmachine"
    local out = cook.sh(cmd)
    local triple = out:match("^%%s*(.-)%%s*$")
    -- two or more non-empty dash-separated [%%w_.] fields
    if not (triple:match("^[%%w_.]+%%-[%%w_.%%-]*[%%w_.]$") and not triple:find("--", 1, true)) then
        error("[cc.toolchain] could not read the target from '" .. cmd .. "': " .. out)
    end
    return { host = triple }
]]

-- Registered here, never from init(): init also runs on execute-phase VMs,
-- where cook.probe raises. Idempotent; returns the key.
local function ensure_host_registered(compiler_key)
    local hk = host_key()
    if state.probe_registered[hk] then return hk end
    cook.probe(hk, {
        inputs = { requires = { compiler_key } },
        produce = string.format(HOST_BODY, compiler_key),
    })
    state.probe_registered[hk] = true
    return hk
end

function M.ensure_probe_registered()
    local key = probe_key()
    if not state.probe_registered[key] then
        local tools
        if state.compiler_override then
            tools = { state.compiler_override }
        else
            tools = { "g++", "clang++" }
        end
        cook.probe(key, {
            inputs = { tools = tools },
            produce = produce_body(state.compiler_override),
        })
        state.probe_registered[key] = true
    end
    ensure_host_registered(key)
end

-- The seal set of every compile and link unit: compiler, host, then the
-- unit's own `extra` probes (cc:find:*). One function, so a determinant
-- reaches every unit or none.
function M.seals(extra)
    M.ensure_probe_registered()
    local out = { probe_key(), host_key() }
    for _, k in ipairs(extra or {}) do out[#out + 1] = k end
    return out
end

function M.get_probe_key()
    return probe_key()
end

function M.get_host_key()
    return host_key()
end

function M.get_compiler()
    M.ensure_probe_registered()
    return cook.probes.get(probe_key())
end

function M.set(opts)
    opts = opts or {}
    if opts.compiler then state.compiler_override = opts.compiler end
    if opts.standard then state.default_standard = opts.standard end
    if opts.warnings then state.warnings = opts.warnings end
    if opts.optimize      ~= nil then state.optimize      = opts.optimize      end
    if opts.debug_symbols ~= nil then state.debug_symbols = opts.debug_symbols end
    if opts.gc_sections   ~= nil then state.gc_sections   = opts.gc_sections   end
    -- Register the compiler probe at TOP LEVEL when the user calls
    -- cook_cc.toolchain({...}) (probes must be top-level per CS-0083; makers
    -- must not mint probes inside a body). Idempotent, so safe to call here.
    M.ensure_probe_registered()
end

local function append_list(dst, src)
    if not src then return end
    for _, v in ipairs(src) do dst[#dst + 1] = v end
end

function M.merge_defaults(opts)
    opts = opts or {}
    state.defaults.defines     = state.defaults.defines     or {}
    state.defaults.includes    = state.defaults.includes    or {}
    state.defaults.system_libs = state.defaults.system_libs or {}
    append_list(state.defaults.defines,     opts.defines)
    append_list(state.defaults.includes,    opts.includes)
    append_list(state.defaults.system_libs, opts.system_libs)
    if opts.extra_cflags then
        local prev = state.defaults.extra_cflags
        state.defaults.extra_cflags = prev and (prev .. " " .. opts.extra_cflags) or opts.extra_cflags
    end
    if opts.extra_ldflags then
        local prev = state.defaults.extra_ldflags
        state.defaults.extra_ldflags = prev and (prev .. " " .. opts.extra_ldflags) or opts.extra_ldflags
    end
    if opts.standard then state.default_standard = opts.standard end
    if opts.warnings then state.warnings = opts.warnings end
end

function M.get_default_standard() return state.default_standard end
function M.get_warnings()         return state.warnings         end
function M.get_defaults()         return state.defaults         end

function M.warning_flags(override)
    local w = override or state.warnings
    if w == "default" then return "-Wall"
    elseif w == "strict" then return "-Wall -Wextra -Wpedantic"
    elseif w == "none" then return ""
    else return w end
end

-- §28.3.10.1. A preset, or any other string passed through as raw flags —
-- the same escape hatch warnings offers.
local OPTIMIZE_PRESETS = {
    ["none"]   = "-O0",
    ["debug"]  = "-Og",
    ["size"]   = "-Os -DNDEBUG",
    ["speed"]  = "-O2 -DNDEBUG",
    ["max"]    = "-O3 -DNDEBUG",
}

-- Compile-side codegen flags for a target. `opts` carries the target-level
-- overrides; anything nil there falls back to the toolchain-wide setting.
function M.codegen_cflags(opts)
    opts = opts or {}
    local parts = {}

    local o = opts.optimize
    if o == nil then o = state.optimize end
    if o ~= nil then
        parts[#parts + 1] = OPTIMIZE_PRESETS[o] or o
    end

    local g = opts.debug_symbols
    if g == nil then g = state.debug_symbols end
    -- Independent of optimize: `max` + symbols is the ordinary
    -- shippable-with-symbols build, and neither option may suppress the other.
    if g then parts[#parts + 1] = "-g" end

    local gc = opts.gc_sections
    if gc == nil then gc = state.gc_sections end
    if gc then parts[#parts + 1] = "-ffunction-sections -fdata-sections" end

    return table.concat(parts, " ")
end

-- Link-side half of gc_sections. Emitting the compile half without this is the
-- silent, strictly-costly state §28.3.10.1 forbids: bigger objects, slower
-- links, none of the reduction. The two halves are produced by one option so a
-- half-configured build cannot be expressed.
function M.codegen_ldflags(opts)
    opts = opts or {}
    local gc = opts.gc_sections
    if gc == nil then gc = state.gc_sections end
    if not gc then return "" end
    if cook.platform.os == "macos" then return "-Wl,-dead_strip" end
    return "-Wl,--gc-sections"
end

return M
