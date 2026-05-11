local cc         = require("cook_cc.cc")
local toolchain  = require("cook_cc.toolchain")
local transitive = require("cook_cc.transitive")

local M = {}

local function register_known(name)
    local known = cook.cache.get("known_targets") or {}
    for _, n in ipairs(known) do if n == name then return end end
    known[#known + 1] = name
    cook.cache.set("known_targets", known)
end

local function gather_sources(opts)
    local sources = opts.sources or {}
    if (#sources == 0) and opts.dir then
        for _, ext in ipairs({ "*.cpp", "*.c", "*.cc", "*.cxx" }) do
            for _, m in ipairs(fs.glob(opts.dir .. "**/" .. ext)) do
                sources[#sources + 1] = m
            end
        end
    end
    return sources
end

local function build_opts(opts, kind)
    opts = opts or {}
    local d = toolchain.get_defaults()
    local merged_includes = {}
    local merged_defines  = {}
    local merged_libs     = {}
    for _, v in ipairs(d.includes    or {}) do merged_includes[#merged_includes + 1] = v end
    for _, v in ipairs(opts.includes or {}) do merged_includes[#merged_includes + 1] = v end
    for _, v in ipairs(d.defines     or {}) do merged_defines [#merged_defines  + 1] = v end
    for _, v in ipairs(opts.defines  or {}) do merged_defines [#merged_defines  + 1] = v end
    for _, v in ipairs(d.system_libs    or {}) do merged_libs[#merged_libs + 1] = v end
    for _, v in ipairs(opts.system_libs or {}) do merged_libs[#merged_libs + 1] = v end
    return {
        includes      = merged_includes,
        defines       = merged_defines,
        system_libs   = merged_libs,
        standard      = opts.standard,
        warnings      = opts.warnings,
        extra_cflags  = opts.extra_cflags,
        extra_ldflags = opts.extra_ldflags,
        export_includes = opts.export_includes,
        links         = opts.links or {},
        fpic          = (kind == "shared"),
    }
end

local function record_export(name, sources, b)
    cook.export(name, {
        includes      = b.export_includes or b.includes,
        defines       = b.defines,
        system_libs   = b.system_libs,
        extra_ldflags = b.extra_ldflags or "",
        links         = b.links,
        compile_info  = {
            sources  = sources,
            includes = b.includes,
            defines  = b.defines,
            standard = b.standard,
            compiler = toolchain.get_compiler() and toolchain.get_compiler().cxx,
        },
    })
end

local function compile_all(name, sources, b)
    local objs = {}
    for _, src in ipairs(sources) do
        objs[#objs + 1] = cc.compile(src, {
            target_name  = name,
            includes     = b.includes,
            defines      = b.defines,
            standard     = b.standard,
            warnings     = b.warnings,
            extra_cflags = b.extra_cflags,
            fpic         = b.fpic,
        })
    end
    return objs
end

function M.bin(name, opts)
    local b = build_opts(opts, "bin")
    local sources = gather_sources(opts or {})
    if #sources == 0 then
        error("[cc.bin] no sources found for target '" .. name .. "'", 2)
    end
    register_known(name)
    record_export(name, sources, b)
    local objs = compile_all(name, sources, b)
    local merged = transitive.resolve_links(b.links)
    cc.link(objs, "build/bin/" .. name, {
        system_libs   = (#merged.system_libs > 0) and merged.system_libs or b.system_libs,
        extra_ldflags = (merged.extra_ldflags ~= "" and merged.extra_ldflags) or b.extra_ldflags,
    })
    return name
end

function M.lib(name, opts)
    local b = build_opts(opts, "lib")
    local sources = gather_sources(opts or {})
    if #sources == 0 then
        error("[cc.lib] no sources found for target '" .. name .. "'", 2)
    end
    register_known(name)
    record_export(name, sources, b)
    local objs = compile_all(name, sources, b)
    cc.archive(objs, "build/lib/lib" .. name .. ".a")
    return name
end

function M.shared(name, opts)
    local b = build_opts(opts, "shared")
    local sources = gather_sources(opts or {})
    if #sources == 0 then
        error("[cc.shared] no sources found for target '" .. name .. "'", 2)
    end
    register_known(name)
    record_export(name, sources, b)
    local objs = compile_all(name, sources, b)
    local merged = transitive.resolve_links(b.links)
    cc.link(objs, "build/lib/lib" .. name .. ".so", {
        system_libs   = (#merged.system_libs > 0) and merged.system_libs or b.system_libs,
        extra_ldflags = (merged.extra_ldflags ~= "" and merged.extra_ldflags) or b.extra_ldflags,
        shared        = true,
    })
    return name
end

function M.headers(name, opts)
    local b = build_opts(opts, "headers")
    register_known(name)
    record_export(name, {}, b)
    return name
end

return M
