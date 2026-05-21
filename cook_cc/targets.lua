local cc         = require("cook_cc.cc")
local toolchain  = require("cook_cc.toolchain")
local transitive = require("cook_cc.transitive")
local finder     = require("cook_cc.finder")

local M = {}
M._known_list = M._known_list or {}     -- per-VM accumulator

function M._known()
    return M._known_list
end

local function register_known(name)
    for _, n in ipairs(M._known_list) do if n == name then return end end
    M._known_list[#M._known_list + 1] = name
end

local function register_needs(needs)
    for _, name in ipairs(needs or {}) do
        finder.find(name)   -- registers cc:find:<name> idempotently
    end
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
    local merged_fw       = {}
    for _, v in ipairs(d.includes    or {}) do merged_includes[#merged_includes + 1] = v end
    for _, v in ipairs(opts.includes or {}) do merged_includes[#merged_includes + 1] = v end
    for _, v in ipairs(d.defines     or {}) do merged_defines [#merged_defines  + 1] = v end
    for _, v in ipairs(opts.defines  or {}) do merged_defines [#merged_defines  + 1] = v end
    for _, v in ipairs(d.system_libs    or {}) do merged_libs[#merged_libs + 1] = v end
    for _, v in ipairs(opts.system_libs or {}) do merged_libs[#merged_libs + 1] = v end
    for _, v in ipairs(d.frameworks    or {}) do merged_fw[#merged_fw + 1] = v end
    for _, v in ipairs(opts.frameworks or {}) do merged_fw[#merged_fw + 1] = v end
    return {
        includes      = merged_includes,
        defines       = merged_defines,
        system_libs   = merged_libs,
        frameworks    = merged_fw,
        standard      = opts.standard,
        warnings      = opts.warnings,
        extra_cflags  = opts.extra_cflags,
        extra_ldflags = opts.extra_ldflags,
        export_includes      = opts.export_includes,
        export_defines       = opts.export_defines,
        export_system_libs   = opts.export_system_libs,
        export_frameworks    = opts.export_frameworks,
        export_extra_ldflags = opts.export_extra_ldflags,
        links         = opts.links or {},
        fpic          = (kind == "shared"),
    }
end

local function record_export(name, sources, b, lib_path)
    cook.export(name, {
        includes      = b.export_includes or b.includes,        -- backcompat fall-back (CS-0080 §28.4)
        defines       = b.export_defines       or {},           -- PRIVATE-by-default; explicit-public only
        system_libs   = b.export_system_libs   or {},           -- PRIVATE-by-default
        frameworks    = b.export_frameworks    or {},           -- PRIVATE-by-default
        extra_ldflags = b.export_extra_ldflags or "",           -- PRIVATE-by-default
        links         = b.links,
        lib_path      = lib_path or "",
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
            needs        = b.needs,
        })
    end
    return objs
end

-- Merge frameworks: transitive first, then local (dedup, first occurrence wins).
local function merge_frameworks(merged_transitive, local_fw)
    local seen = {}
    local result = {}
    for _, v in ipairs(merged_transitive or {}) do
        if not seen[v] then seen[v] = true; result[#result + 1] = v end
    end
    for _, v in ipairs(local_fw or {}) do
        if not seen[v] then seen[v] = true; result[#result + 1] = v end
    end
    return result
end

-- Merge system_libs: transitive first, then local (dedup, first occurrence wins).
local function merge_system_libs(merged_transitive, local_libs)
    local seen = {}
    local result = {}
    for _, v in ipairs(merged_transitive or {}) do
        if not seen[v] then seen[v] = true; result[#result + 1] = v end
    end
    for _, v in ipairs(local_libs or {}) do
        if not seen[v] then seen[v] = true; result[#result + 1] = v end
    end
    return result
end

-- Build extra_ldflags string: prepend archive paths, then transitive ldflags, then local.
local function build_ldflags(lib_paths, transitive_ldflags, local_ldflags)
    local parts = {}
    for _, p in ipairs(lib_paths or {}) do parts[#parts + 1] = p end
    if transitive_ldflags and transitive_ldflags ~= "" then
        parts[#parts + 1] = transitive_ldflags
    end
    if local_ldflags and local_ldflags ~= "" then
        parts[#parts + 1] = local_ldflags
    end
    return table.concat(parts, " ")
end

-- Merge transitive includes into b.includes (dedup, local first).
local function merge_includes(local_incs, transitive_incs)
    local seen = {}
    local result = {}
    for _, v in ipairs(local_incs or {}) do
        if not seen[v] then seen[v] = true; result[#result + 1] = v end
    end
    for _, v in ipairs(transitive_incs or {}) do
        if not seen[v] then seen[v] = true; result[#result + 1] = v end
    end
    return result
end

-- Merge transitive defines into b.defines (dedup, local first).
-- Mirrors merge_includes — CS-0080 requires consumer compiles to see
-- exported defines from linked libs (PUBLIC propagation).
local function merge_defines(local_defs, transitive_defs)
    local seen = {}
    local result = {}
    for _, v in ipairs(local_defs or {}) do
        if not seen[v] then seen[v] = true; result[#result + 1] = v end
    end
    for _, v in ipairs(transitive_defs or {}) do
        if not seen[v] then seen[v] = true; result[#result + 1] = v end
    end
    return result
end

-- Merge link-deps and explicit-deps into the recipe's `requires` set.
-- `opts.links` carries the cc-level link graph (libraries this target links
-- against, each being a recipe in its own right). `opts.requires` (added in
-- 0.7.0) is the escape hatch for declaring a non-link dependency — typically
-- a synthetic recipe like the one returned by `cc.config_header(...)` whose
-- output (a generated header) participates in the build via include paths
-- rather than the linker.
--
-- 0.11.0 prepends recipe names registered via toolchain.merge_defaults({
-- config_header = ... }) so every cc target picks up the build's generated
-- headers as transitive prereqs without the caller restating it.
local function merge_requires(opts)
    local out = {}
    for _, r in ipairs(toolchain.get_config_header_recipes()) do out[#out + 1] = r end
    for _, r in ipairs((opts and opts.links) or {}) do out[#out + 1] = r end
    for _, r in ipairs((opts and opts.requires) or {}) do out[#out + 1] = r end
    return out
end

function M.bin(name, opts)
    -- Top-level register-time side effects (probes). See CS-0083 / the
    -- 2026-05-20 probes-top-level-only design doc: cook.probe MUST be
    -- called at top-level register-phase, not inside a cook.recipe body
    -- (Phase 2 of the rollout makes this a hard error in cook itself).
    toolchain.ensure_probe_registered()
    register_needs(opts and opts.needs)

    cook.recipe(name, { requires = merge_requires(opts) }, function()
        local b = build_opts(opts, "bin")
        b.needs = (opts and opts.needs) or {}
        local sources = gather_sources(opts or {})
        if #sources == 0 then
            error("[cc.bin] no sources found for target '" .. name .. "'", 2)
        end
        register_known(name)
        local merged = transitive.resolve_links(b.links)
        b.includes = merge_includes(b.includes, merged.includes)
        b.defines  = merge_defines(b.defines, merged.defines)
        record_export(name, sources, b, "")
        local objs = compile_all(name, sources, b)
        cc.link(objs, "build/bin/" .. name, {
            system_libs   = merge_system_libs(merged.system_libs, b.system_libs),
            frameworks    = merge_frameworks(merged.frameworks, b.frameworks),
            extra_ldflags = build_ldflags(merged.lib_paths, merged.extra_ldflags, b.extra_ldflags),
            needs         = b.needs,
        })
    end)
    return name
end

function M.lib(name, opts)
    toolchain.ensure_probe_registered()
    register_needs(opts and opts.needs)

    cook.recipe(name, { requires = merge_requires(opts) }, function()
        local b = build_opts(opts, "lib")
        b.needs = (opts and opts.needs) or {}
        local sources = gather_sources(opts or {})
        if #sources == 0 then
            error("[cc.lib] no sources found for target '" .. name .. "'", 2)
        end
        local archive_path = "build/lib/lib" .. name .. ".a"
        register_known(name)
        local merged = transitive.resolve_links(b.links)
        b.includes = merge_includes(b.includes, merged.includes)
        b.defines  = merge_defines(b.defines, merged.defines)
        record_export(name, sources, b, archive_path)
        local objs = compile_all(name, sources, b)
        cc.archive(objs, archive_path)
    end)
    return name
end

function M.shared(name, opts)
    toolchain.ensure_probe_registered()
    register_needs(opts and opts.needs)

    cook.recipe(name, { requires = merge_requires(opts) }, function()
        local b = build_opts(opts, "shared")
        b.needs = (opts and opts.needs) or {}
        local sources = gather_sources(opts or {})
        if #sources == 0 then
            error("[cc.shared] no sources found for target '" .. name .. "'", 2)
        end
        -- CS-0084: opts.output overrides the default link path verbatim.
        local so_path = (opts and opts.output) or ("build/lib/lib" .. name .. ".so")
        register_known(name)
        local merged = transitive.resolve_links(b.links)
        b.includes = merge_includes(b.includes, merged.includes)
        b.defines  = merge_defines(b.defines, merged.defines)
        record_export(name, sources, b, so_path)
        local objs = compile_all(name, sources, b)
        cc.link(objs, so_path, {
            system_libs   = merge_system_libs(merged.system_libs, b.system_libs),
            frameworks    = merge_frameworks(merged.frameworks, b.frameworks),
            extra_ldflags = build_ldflags(merged.lib_paths, merged.extra_ldflags, b.extra_ldflags),
            shared        = true,
            needs         = b.needs,
        })
    end)
    return name
end

function M.headers(name, opts)
    toolchain.ensure_probe_registered()
    register_needs(opts and opts.needs)

    cook.recipe(name, { requires = merge_requires(opts) }, function()
        local b = build_opts(opts, "headers")
        register_known(name)
        record_export(name, {}, b, "")
    end)
    return name
end

return M
