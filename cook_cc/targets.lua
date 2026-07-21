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

-- Maker-outside-recipe guard. cook.recipe_name() errors outside a recipe
-- body; a maker is a STEP CONTRIBUTOR, so it must run inside the caller's
-- `recipe` block. Returns the QUALIFIED recipe name (export identity).
local function current_recipe_or_error(kind)
    local ok, id = pcall(cook.recipe_name)
    if not ok then
        error("[cc." .. kind .. "] must be called inside a recipe block; wrap it in a `recipe` block", 2)
    end
    return id
end

-- `needs` is now REFERENCE-ONLY: probes are registered at top level by
-- cook_cc.uses(); the maker never mints a probe. Verify each referenced name
-- was declared, else fail loudly with the fix.
local function check_needs_declared(kind, needs)
    for _, n in ipairs(needs or {}) do
        if not finder.is_registered(n) then
            error("[cc." .. kind .. "] needs \"" .. n .. "\" is not declared; add cook_cc.uses(\"" .. n .. "\") at top level", 2)
        end
    end
end

-- Declare an ordering edge to each linked recipe. `links` names sibling
-- recipes (each built by its own maker). cook.require_recipe records the
-- ordering edge (and validates existence across all VMs), so the linked
-- artifact's export (includes/defines/lib_path) is available when we
-- resolve_links — regardless of declaration order.
--
-- NOTE (bare vs qualified): link refs are BARE declared names. Under an import
-- prefix the engine bridges bare link refs to the corresponding qualified
-- exports within scope; in the stub there is no prefix so bare == qualified.
local function declare_link_deps(_kind, links)
    for _, dep in ipairs(links or {}) do
        -- Declaration order is NOT a rule, and a fatal
        -- is_known() gate here is wrong. M._known_list is a per-VM accumulator;
        -- cook evaluates some maker bodies (notably `shared`) in separate worker
        -- VMs, so a perfectly valid cross-recipe link (e.g. base -> idLib) can be
        -- absent from THIS VM's list and would spuriously fail the gate — which
        -- blocked every dhewm3 build. Ordering AND unknown-recipe validation are
        -- the engine's job: cook.require_recipe records the ordering edge and
        -- raises on a genuinely nonexistent recipe (across all VMs), which the
        -- module cannot see. Do not re-add a module-side hard error here.
        cook.require_recipe(dep)
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

local function join_flags(a, b)
    if a and b then return a .. " " .. b end
    return a or b
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
        -- Toolchain-default extra flags APPEND, target flags follow —
        -- mirroring the defines/includes merge above. These were previously
        -- dropped whenever a target declared no extra_cflags of its own.
        extra_cflags  = join_flags(d.extra_cflags,  opts.extra_cflags),
        extra_ldflags = join_flags(d.extra_ldflags, opts.extra_ldflags),
        export_includes      = opts.export_includes,
        export_defines       = opts.export_defines,
        export_system_libs   = opts.export_system_libs,
        export_frameworks    = opts.export_frameworks,
        export_extra_ldflags = opts.export_extra_ldflags,
        links         = opts.links or {},
        fpic          = (kind == "shared"),
    }
end

-- `id` is the QUALIFIED recipe name — the export IDENTITY key. Consumers
-- (resolve_links, compile_db) look up exports with the BARE recipe names that
-- appear in `links` / `_known`; the engine bridges those bare refs to the
-- qualified export within the module's own import scope. In a root Cookfile
-- (no prefix) qualified == bare, so the two coincide.
local function record_export(id, sources, b, lib_path)
    cook.export(id, {
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

-- One step group for the whole fan-out: compile units are independent, and
-- bare add_unit calls are sequential per §15.1 — without the group, N sources
-- become a depth-N chain and compiles serialize. The archive/link units the
-- makers register afterwards stay bare, so the §15.1 barrier still orders
-- all-compiles → archive → link. Nested step_group is unspecified (§22.5):
-- nothing under cc.compile may open one.
local function compile_all(name, sources, b)
    local objs = {}
    cook.step_group(function()
        for _, src in ipairs(sources) do
            objs[#objs + 1] = cc.compile(src, {
                target_name       = name,
                includes          = b.includes,
                defines           = b.defines,
                standard          = b.standard,
                warnings          = b.warnings,
                extra_cflags      = b.extra_cflags,
                fpic              = b.fpic,
                needs             = b.needs,
                generated_headers = b.generated_headers,
            })
        end
    end)
    return objs
end

-- Auto-join each generated config-header's output dir onto include paths and
-- collect the generated header output paths so compiles declare them as
-- inputs (the data edge to the config_header generation unit).
local function apply_config_headers(b)
    local ch = require("cook_cc.config_header")
    local gen = {}
    for _, h in ipairs(ch.get_headers()) do
        if h.outdir then b.includes[#b.includes + 1] = h.outdir end
        gen[#gen + 1] = h.output
        -- Declare the recipe-ordering edge to the config_header
        -- support recipe (the 0.11 "thread the synthesised recipe into every cc
        -- target's requires" contract, re-expressed via the 0.13 require_recipe
        -- API). The generated-header file-input edge below is not enough on its
        -- own: cook only schedules recipes inside the requested target's
        -- require_recipe closure, so without this edge `cook game` never runs
        -- the generator and every compile fails on a missing config.h.
        if h.recipe then cook.require_recipe(h.recipe) end
    end
    b.generated_headers = gen
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

-- The four makers are STEP CONTRIBUTORS: their body runs directly inside the
-- caller's `recipe` block. They add compile/link/archive units + the export
-- to the ENCLOSING recipe; they do NOT call cook.recipe themselves.
--
-- Naming (critical): `id` (cook.recipe_name()) is QUALIFIED and is the export
-- IDENTITY (record_export/cook.export). `name` (recipe.name) is BARE and
-- drives every human-facing artifact PATH (build/bin/<name>,
-- build/lib/lib<name>.a/.so, build/obj/<name>/) and register_known. In the
-- stub there is no import prefix so the two coincide, but code both roles
-- explicitly; under a prefix the engine bridges bare link refs to qualified
-- exports within scope.

function M.bin(opts)
    opts = opts or {}
    local id = current_recipe_or_error("bin")   -- qualified; also the outside-recipe guard
    local name = recipe.name                      -- bare
    toolchain.ensure_probe_registered()           -- idempotent; toolchain() registered it top-level
    require("cook_cc.config_header").mark_target_registered()
    check_needs_declared("bin", opts.needs)
    declare_link_deps("bin", opts.links)
    local b = build_opts(opts, "bin")
    b.needs = opts.needs or {}
    apply_config_headers(b)
    local sources = gather_sources(opts)
    if #sources == 0 then
        error("[cc.bin] no sources found for target '" .. name .. "'", 2)
    end
    register_known(name)
    local merged = transitive.resolve_links(b.links)
    b.includes = merge_includes(b.includes, merged.includes)
    b.defines  = merge_defines(b.defines, merged.defines)
    record_export(id, sources, b, "")
    local objs = compile_all(name, sources, b)
    cc.link(objs, "build/bin/" .. name, {
        system_libs   = merge_system_libs(merged.system_libs, b.system_libs),
        frameworks    = merge_frameworks(merged.frameworks, b.frameworks),
        extra_ldflags = build_ldflags(merged.lib_paths, merged.extra_ldflags, b.extra_ldflags),
        link_inputs   = merged.lib_paths,   -- fold dep archive paths into the link unit's inputs (cache-key fold)
        needs         = b.needs,
    })
end

function M.lib(opts)
    opts = opts or {}
    local id = current_recipe_or_error("lib")   -- qualified
    local name = recipe.name                      -- bare
    toolchain.ensure_probe_registered()
    require("cook_cc.config_header").mark_target_registered()
    check_needs_declared("lib", opts.needs)
    -- An archive does not consume dependency archives, but its OWN compiles
    -- depend on the linked libs' exported includes/defines (resolve_links
    -- reads their exports), so we still declare the ordering edges here.
    declare_link_deps("lib", opts.links)
    local b = build_opts(opts, "lib")
    b.needs = opts.needs or {}
    apply_config_headers(b)
    local sources = gather_sources(opts)
    if #sources == 0 then
        error("[cc.lib] no sources found for target '" .. name .. "'", 2)
    end
    local archive_path = "build/lib/lib" .. name .. ".a"
    register_known(name)
    local merged = transitive.resolve_links(b.links)
    b.includes = merge_includes(b.includes, merged.includes)
    b.defines  = merge_defines(b.defines, merged.defines)
    record_export(id, sources, b, archive_path)
    local objs = compile_all(name, sources, b)
    cc.archive(objs, archive_path)   -- archives (no link) → no link_inputs
end

function M.shared(opts)
    opts = opts or {}
    local id = current_recipe_or_error("shared")   -- qualified
    local name = recipe.name                         -- bare
    toolchain.ensure_probe_registered()
    require("cook_cc.config_header").mark_target_registered()
    check_needs_declared("shared", opts.needs)
    declare_link_deps("shared", opts.links)
    local b = build_opts(opts, "shared")
    b.needs = opts.needs or {}
    apply_config_headers(b)
    local sources = gather_sources(opts)
    if #sources == 0 then
        error("[cc.shared] no sources found for target '" .. name .. "'", 2)
    end
    -- CS-0084: opts.output overrides the default link path verbatim.
    local so_path = opts.output or ("build/lib/lib" .. name .. ".so")
    register_known(name)
    local merged = transitive.resolve_links(b.links)
    b.includes = merge_includes(b.includes, merged.includes)
    b.defines  = merge_defines(b.defines, merged.defines)
    record_export(id, sources, b, so_path)
    local objs = compile_all(name, sources, b)
    cc.link(objs, so_path, {
        system_libs   = merge_system_libs(merged.system_libs, b.system_libs),
        frameworks    = merge_frameworks(merged.frameworks, b.frameworks),
        extra_ldflags = build_ldflags(merged.lib_paths, merged.extra_ldflags, b.extra_ldflags),
        link_inputs   = merged.lib_paths,   -- fold dep archive paths into the link unit's inputs (cache-key fold)
        shared        = true,
        needs         = b.needs,
    })
end

function M.headers(opts)
    opts = opts or {}
    local id = current_recipe_or_error("headers")   -- qualified
    local name = recipe.name                          -- bare
    toolchain.ensure_probe_registered()
    require("cook_cc.config_header").mark_target_registered()
    check_needs_declared("headers", opts.needs)
    -- No links: headers export includes/defines only, no units to build.
    local b = build_opts(opts, "headers")
    register_known(name)
    record_export(id, {}, b, "")
end

return M
