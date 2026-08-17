-- cook_cc.discovery.checks — compile/run feature checks (has_header, has_function, sizeof, endian, flag probes) as cc:check probes
-- domain:  discovery — registers probes (dependency finders, feature checks); facts in, no work units
-- effects: cook.probe
-- std:     §12.7
local toolchain = require("cook_cc.toolchain")
local helpers   = require("cook_cc.discovery._check_helpers")

local M = {}

-- Per-VM probe-registration set: probe-key -> true
M._registered = M._registered or {}

local function opts_to_lua_literal(opts)
    opts = opts or {}
    local parts = {}
    if opts.standard then
        parts[#parts + 1] = "standard=" .. string.format("%q", opts.standard)
    end
    if opts.extra_cflags then
        parts[#parts + 1] = "extra_cflags=" .. string.format("%q", opts.extra_cflags)
    end
    if opts.extra_ldflags then
        parts[#parts + 1] = "extra_ldflags=" .. string.format("%q", opts.extra_ldflags)
    end
    if opts.defines then
        local lst = {}
        for _, d in ipairs(opts.defines) do lst[#lst + 1] = string.format("%q", d) end
        parts[#parts + 1] = "defines={" .. table.concat(lst, ",") .. "}"
    end
    if opts.includes then
        local lst = {}
        for _, d in ipairs(opts.includes) do lst[#lst + 1] = string.format("%q", d) end
        parts[#parts + 1] = "includes={" .. table.concat(lst, ",") .. "}"
    end
    if opts.system_libs then
        local lst = {}
        for _, d in ipairs(opts.system_libs) do lst[#lst + 1] = string.format("%q", d) end
        parts[#parts + 1] = "system_libs={" .. table.concat(lst, ",") .. "}"
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Build the produce body string for a given kind/name/opts.
-- `name` is the RAW name (the header path, function name, C type…) — it is
-- what h.probe_c compiles. `san`/`fp` are the sanitised/fingerprint segments
-- of the probe key; they double as the scratch-file stem so two checks of
-- the same kind never race on one .c path (raw names may contain '/').
local function produce_body(kind, name, opts, extra_flag, san, fp)
    local opts_lua    = opts_to_lua_literal(opts)
    local extra_lit   = extra_flag and string.format("%q", extra_flag) or "nil"
    local cc_key      = toolchain.get_probe_key()
    local cc_key_lit  = string.format("%q", cc_key)
    return string.format([[
        local h = require("cook_cc.discovery._check_helpers")
        local KIND  = %q
        local NAME  = %q
        local OPTS  = %s
        local EXTRA = %s
        local STEM  = %q
        local cc    = cook.probes.get(%s)
        if not cc then error("[cc.check] compiler probe not resolved: " .. %s) end

        local probe_dir = ".cook/probes/cc-check"
        local probe_c   = probe_dir .. "/" .. STEM .. ".c"
        local probe_out = probe_dir .. "/" .. STEM .. ".out"
        fs.mkdir_p(probe_dir)
        fs.write(probe_c, h.probe_c(KIND, NAME, OPTS))

        local cmd = h.compile_command(KIND, cc, probe_c, probe_out, OPTS, EXTRA)
        local compile_ok = pcall(cook.sh, cmd)

        local captured = ""
        if compile_ok and h.runs(KIND) then
            local run_ok, out = pcall(cook.sh, probe_out)
            if run_ok then captured = out or "" else compile_ok = false end
        end
        return h.evaluate(KIND, compile_ok, captured)
    ]], kind, name, opts_lua, extra_lit, kind .. "-" .. san .. "-" .. fp,
        cc_key_lit, cc_key_lit)
end

-- Strict probe-key <name> sanitiser. The sigil resolver in
-- cli/crates/cook-luagen/src/resolver.rs splits "$<key.field>" at the
-- first '.' after the colon section, so '.' MUST NOT appear in the
-- <name> segment of a probe key. Allowed charset: [A-Za-z0-9_+-].
-- KEY hygiene only — the raw name is what the probe body compiles.
-- (Pre-0.18 the sanitised form leaked into the generated C, so
-- has_header("stdint.h") probed `#include <stdint_h>` and every dotted
-- header came back false.)
local function sanitise_name(s)
    return (s:gsub("[^%w%+%-_]", "_"))
end

local function register_check(kind, name, opts, extra_flag)
    toolchain.ensure_probe_registered()
    local san = sanitise_name(name)
    -- The raw name folds into the fingerprint: the sanitised key segment is
    -- lossy ("sys/stat.h" and "sys_stat.h" both sanitise to "sys_stat_h"),
    -- so without it two distinct checks would collide on one probe key.
    local fp  = helpers.fingerprint(opts, name)
    local key = "cc:check:" .. kind .. ":" .. san .. ":" .. fp
    if M._registered[key] then
        return key
    end
    -- No `env` input (CS-0244). PATH was declared to catch a compiler swap,
    -- but the toolchain probe this one requires already hashes the resolved
    -- compiler, so a swap moves that value and re-runs the check anyway.
    cook.probe(key, {
        inputs = {
            requires = { toolchain.get_probe_key() },
        },
        produce = produce_body(kind, name, opts, extra_flag, san, fp),
    })
    M._registered[key] = true
    return key
end

-- Every maker passes the RAW name through; register_check owns key hygiene
-- (sanitise + fingerprint) and hands the raw name to the probe body intact.

function M.has_header(name, opts)
    local key = register_check("has-header", name, opts or {})
    return "$<" .. key .. ">"
end

function M.has_function(name, opts)
    local key = register_check("has-function", name, opts or {})
    return "$<" .. key .. ">"
end

function M.has_define(name, opts)
    local key = register_check("has-define", name, opts or {})
    return "$<" .. key .. ">"
end

function M.sizeof(type_name, opts)
    local key = register_check("sizeof", type_name, opts or {})
    return "$<" .. key .. ">"
end

function M.endian()
    local key = register_check("endian", "_", {})
    return "$<" .. key .. ">"
end

function M.has_compile_flag(flag)
    local key = register_check("has-compile-flag", flag, {}, flag)
    return "$<" .. key .. ">"
end

function M.has_link_flag(flag)
    local key = register_check("has-link-flag", flag, {}, flag)
    return "$<" .. key .. ">"
end

return M
