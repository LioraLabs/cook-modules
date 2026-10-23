-- cook_cc.units.cc — compile/archive/link unit construction
-- domain:  units — builds commands and registers work on the engine
-- effects: cook.add_unit
-- std:     §28.3
local toolchain = require("cook_cc.toolchain")
local object_path = require("cook_cc.units.object_path")

local M = {}

local function is_c(source) return source:match("%.[cC]$") ~= nil end

function M.compile(source, opts)
    opts = opts or {}
    if not fs.exists(source) then
        error("[cc.compile] source file not found: " .. source, 2)
    end
    local target_name = opts.target_name or "default"
    -- §28.3.5.1: source-relative, injective by construction. An explicit
    -- opts.output still wins verbatim.
    local obj_out = opts.output or object_path.object(target_name, source)
    -- The depfile's identity follows the OBJECT, not the source's basename.
    -- Repeated file names are normal in a real tree (DuckDB has 34 such
    -- pairs), and two translation units sharing one `.d` is doubly wrong: each
    -- compile overwrites the other's discovered-header set, and cook then sees
    -- the loser's recorded depfile as drifted and restores it on EVERY
    -- subsequent run — permanent cache churn plus a silently incorrect header
    -- dependency set.
    local dep_file = object_path.depfile(obj_out)
    local dep_dir = path.dir(dep_file)

    fs.mkdir_p(path.dir(obj_out))
    fs.mkdir_p(dep_dir)

    -- Compiler comes from the cc:compiler:<override> probe at execute time.
    local cc_probe_key = toolchain.get_probe_key()
    local cc_field = is_c(source) and "cc" or "cxx"
    local compiler_sigil = "$<" .. cc_probe_key .. "." .. cc_field .. ">"

    local flags = { "-c", "-MMD", "-MF", dep_file }
    local std = opts.standard or toolchain.get_default_standard()
    if std and not is_c(source) then
        flags[#flags + 1] = "-std=" .. std
    end
    for _, inc in ipairs(opts.includes or {}) do flags[#flags + 1] = "-I" .. inc end
    for _, def in ipairs(opts.defines  or {}) do flags[#flags + 1] = "-D" .. def end
    local wflags = toolchain.warning_flags(opts.warnings)
    if wflags ~= "" then flags[#flags + 1] = wflags end
    if opts.fpic then flags[#flags + 1] = "-fPIC" end
    if opts.extra_cflags and opts.extra_cflags ~= "" then
        flags[#flags + 1] = opts.extra_cflags
    end

    local needs = opts.needs or {}
    local finds = {}
    local cflags_sigils = {}
    for _, n in ipairs(needs) do
        finds[#finds + 1] = "cc:find:" .. n
        cflags_sigils[#cflags_sigils + 1] = "$<cc:find:" .. n .. ".cflags>"
    end
    local probes = toolchain.seals(finds)

    local cmd = compiler_sigil .. " " .. table.concat(flags, " ")
        .. " " .. source .. " -o " .. obj_out
    if #cflags_sigils > 0 then
        cmd = cmd .. " " .. table.concat(cflags_sigils, " ")
    end
    cmd = cmd .. " "

    -- §12.7.5 seal policy: fold the resolved, deterministic toolchain identity
    -- (cc:compiler:<override>), its target (cc:host:<override>) and finder
    -- results (cc:find:<name>) into the cache key as explicit, auditable
    -- named-probe determinants. Values are pure functions of declared
    -- tool/env inputs, and are value-folded (not candidate-tool fingerprints)
    -- so the key stays stable across machines with the same compiler bytes AND
    -- the same reported target. Default 'shared' disposition is correct — compile
    -- output is reproducible.
    -- Generated config headers (opts.generated_headers) become declared
    -- compile-unit inputs — the data edge to the config_header gen unit.
    local unit_inputs = { source }
    for _, gh in ipairs(opts.generated_headers or {}) do
        unit_inputs[#unit_inputs + 1] = gh
    end

    cook.add_unit({
        inputs            = unit_inputs,
        output            = obj_out,
        command           = cmd,
        probes            = probes,
        seal              = probes,
        discovered_inputs = { from = dep_file, format = "make" },
    })

    return obj_out
end

function M.archive(objects, output, opts)
    opts = opts or {}
    fs.mkdir_p(path.dir(output))
    -- Trailing space ensures assertions like "x.o " match the last token.
    local cmd = "ar rcs " .. output .. " " .. table.concat(objects, " ") .. " "
    -- CS-0161 §28.3.6: order this unit after each named recipe without folding
    -- anything into its cache inputs. Called here — after the compile step
    -- group has closed — so the refs attach to the archive unit and nothing
    -- earlier, which is what fine-covers the recipe's `requires` edges.
    for _, dep in ipairs(opts.dep_recipes or {}) do
        cook.dep_order(dep)
    end
    -- ar tool identity is an unmodeled determinant (no probe today) — a known
    -- pre-existing gap, out of scope for this seal adoption.
    cook.add_unit({
        inputs = objects,
        output = output,
        command = cmd,
    })
    return output
end

function M.link(objects, output, opts)
    opts = opts or {}
    fs.mkdir_p(path.dir(output))

    local cc_probe_key = toolchain.get_probe_key()
    local compiler_sigil = "$<" .. cc_probe_key .. ".cxx>"

    local needs = opts.needs or {}
    local finds = {}
    local libs_sigils = {}
    for _, n in ipairs(needs) do
        finds[#finds + 1] = "cc:find:" .. n
        libs_sigils[#libs_sigils + 1] = "$<cc:find:" .. n .. ".libs>"
    end
    local probes = toolchain.seals(finds)

    local parts = { compiler_sigil, table.concat(objects, " "), "-o", output }
    for _, lib in ipairs(opts.system_libs or {}) do
        parts[#parts + 1] = "-l" .. lib
    end
    if cook.platform.os == "macos" then
        for _, fw in ipairs(opts.frameworks or {}) do
            parts[#parts + 1] = "-framework"
            parts[#parts + 1] = fw
        end
    end
    if opts.extra_ldflags and opts.extra_ldflags ~= "" then
        parts[#parts + 1] = opts.extra_ldflags
    end
    if opts.shared then parts[#parts + 1] = "-shared" end
    if #libs_sigils > 0 then
        parts[#parts + 1] = table.concat(libs_sigils, " ")
    end

    -- Trailing space ensures assertions like " -lpthread " match the last token.
    local cmd = table.concat(parts, " ") .. " "

    -- Dependency archive paths (opts.link_inputs) fold into the link unit's
    -- inputs for the cache key; they also remain on the command line via
    -- extra_ldflags (do not remove that).
    local unit_inputs = {}
    for _, o in ipairs(objects) do unit_inputs[#unit_inputs + 1] = o end
    for _, li in ipairs(opts.link_inputs or {}) do
        unit_inputs[#unit_inputs + 1] = li
    end

    -- CS-0161 §28.3.7: execution edges onto every artifact-producing target in
    -- the link closure. The DATA dependency is already carried by link_inputs
    -- above (folded into the cache key); these refs supply the ordering that
    -- makes those reads safe once the recipe-level `requires` edges narrow.
    for _, dep in ipairs(opts.dep_recipes or {}) do
        cook.dep_order(dep)
    end

    -- §12.7.5: seal the resolved toolchain + finder determinants (see
    -- M.compile's comment above for the full rationale).
    cook.add_unit({
        inputs  = unit_inputs,
        output  = output,
        command = cmd,
        probes  = probes,
        seal    = probes,
    })
    return output
end

return M
