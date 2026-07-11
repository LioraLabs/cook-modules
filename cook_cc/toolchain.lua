local M = {}

local state = {
    compiler_override     = nil,         -- nil means "auto"
    default_standard      = nil,
    warnings              = "default",
    defaults              = {},
    probe_registered      = {},          -- set: key -> true
    -- 0.11.0: recipe names synthesized by defaults({ config_header = ... }).
    -- targets.merge_requires threads them into every cc target's `requires`
    -- so callers don't restate `requires = { cfg }` on each target.
    config_header_recipes = {},
}

local function probe_key()
    return "cc:compiler:" .. (state.compiler_override or "auto")
end

local function produce_body(override)
    local override_literal = override and string.format("%q", override) or "nil"
    return string.format([[
        local override = %s
        if override then
            local out = cook.sh("command -v " .. override .. " 2>/dev/null")
            if not out:match("%%S") then
                error("[cc.toolchain] override compiler '" .. override .. "' not on PATH")
            end
            local cc
            if override:match("clang") then cc = "clang"
            elseif override:match("g%%+%%+") then cc = "gcc"
            else cc = "cc" end
            return { cxx = override, cc = cc }
        end
        for _, c in ipairs({ {cxx="g++",cc="gcc"}, {cxx="clang++",cc="clang"} }) do
            local out = cook.sh("command -v " .. c.cxx .. " 2>/dev/null")
            if out:match("%%S") then return c end
        end
        error("[cc.toolchain] no C/C++ compiler on PATH (tried g++, clang++)")
    ]], override_literal)
end

function M.ensure_probe_registered()
    local key = probe_key()
    if state.probe_registered[key] then return end
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

function M.get_probe_key()
    return probe_key()
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

    -- 0.11.0: declarative config-header registration. When present, synthesize
    -- the recipe via cook_cc.config_header(from, to, vars) and remember the
    -- recipe name so target-makers can implicitly require it. Auto-join the
    -- output's directory to defaults.includes so consumers can `#include
    -- "config.h"` without restating the build dir. Lazy-required to avoid a
    -- toolchain ↔ config_header import cycle.
    if opts.config_header then
        local config_header = require("cook_cc.config_header")
        local ch = opts.config_header
        if not ch.from or not ch.to then
            error("[cc.defaults] config_header requires both `from` and `to` fields", 2)
        end
        local recipe_name = config_header.config_header(ch.from, ch.to, ch.vars or {})
        state.config_header_recipes[#state.config_header_recipes + 1] = recipe_name
        local outdir = path.dir(ch.to)
        if outdir and outdir ~= "" and outdir ~= "." then
            state.defaults.includes[#state.defaults.includes + 1] = outdir
        end
    end
end

function M.get_default_standard()      return state.default_standard      end
function M.get_warnings()              return state.warnings              end
function M.get_defaults()              return state.defaults              end
function M.get_config_header_recipes() return state.config_header_recipes end

function M.warning_flags(override)
    local w = override or state.warnings
    if w == "default" then return "-Wall"
    elseif w == "strict" then return "-Wall -Wextra -Wpedantic"
    elseif w == "none" then return ""
    else return w end
end

return M
