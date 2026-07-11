-- pnpm.task target maker.
--
-- For every package in the workspace, emits one `cook.recipe("<pkg>:<task>", ...)`
-- whose body registers a single `cook.add_unit` invoking
-- `pnpm --filter <pkg> run <script>`. Topology is derived from each
-- package's package.json `dependencies`/`devDependencies` keys
-- restricted to workspace members.
--
-- `depends_on` syntax:
--   - `"^build"`  — wait on `build` task in each workspace dependency
--   - `"build"`   — wait on `build` task in the SAME package

local toolchain = require("cook_pnpm.toolchain")
local workspace = require("cook_pnpm.workspace")

local M = {}

local function recipe_name(pkg, task) return pkg.name .. ":" .. task end

-- Rewrite a trailing bare "**" to "**/*" so fs.glob matches files,
-- not just directories. Workaround for COOK-28 — engine-side fs.glob
-- will eventually normalise this directly; the no-op when COOK-28
-- lands is harmless.
local function normalize_input_glob(g)
    if g:sub(-3) == "/**" then return g .. "/*" end
    if g == "**"          then return "**/*"    end
    return g
end

local function expand_globs_in_dir(globs, dir)
    if not globs or #globs == 0 then return {} end
    local out = {}
    for _, g in ipairs(globs) do
        local pattern = dir .. "/" .. normalize_input_glob(g)
        for _, m in ipairs(fs.glob(pattern)) do
            out[#out + 1] = m
        end
    end
    return out
end

-- Rewrite each output glob from package-relative to workspace-relative.
-- Never fs.glob-expand; the engine resolves these post-execute per
-- CS-0085 against the unit's working directory.
local function anchor_outputs(globs, dir)
    if not globs or #globs == 0 then return {} end
    local out = {}
    for _, g in ipairs(globs) do
        out[#out + 1] = dir .. "/" .. g
    end
    return out
end

-- A `requires` edge only fires if the referenced recipe will actually
-- exist. For `^X` the target is `<dep>:X`, which only exists when
-- <dep>'s package.json declares an X script. For bare `X` the target
-- is `<self>:X`, which only exists when the current package declares
-- it. Skip otherwise — matches Turborepo's "no-op on missing script"
-- behaviour and prevents dangling recipe edges.
local function resolve_depends_on(pkg, depends_on, by_name)
    local result = {}
    for _, dep in ipairs(depends_on or {}) do
        if dep:sub(1, 1) == "^" then
            local task_name = dep:sub(2)
            for _, dep_pkg_name in ipairs(pkg.workspace_deps) do
                local dep_pkg = by_name[dep_pkg_name]
                if dep_pkg and dep_pkg.package.scripts[task_name] then
                    result[#result + 1] = recipe_name(dep_pkg, task_name)
                end
            end
        else
            if pkg.package.scripts[dep] then
                result[#result + 1] = recipe_name(pkg, dep)
            end
        end
    end
    return result
end

local function command_for(pkg, task_name)
    toolchain.ensure_probe_registered()
    local key = toolchain.get_probe_key()
    -- $<pnpm:toolchain:....pnpm> is replaced at execute time with the
    -- absolute pnpm binary path resolved by the toolchain probe.
    return "$<" .. key .. ".pnpm> --filter " .. pkg.name .. " run " .. task_name
end

function M.task(task_name, opts)
    opts = opts or {}
    local packages = workspace.list()
    local snap = workspace.snapshot()
    local by_name = snap.by_name

    for _, pkg in ipairs(packages) do
        -- Skip if the package doesn't declare this script in package.json
        -- (the v0.1 behaviour is "silently skip"; an explicit `strict =
        -- true` option to elevate to error is a v0.2 polish item).
        if not pkg.package.scripts[task_name] then
            -- noop
        else
            local requires = resolve_depends_on(pkg, opts.depends_on, by_name)
            local r_name   = recipe_name(pkg, task_name)
            local inputs   = expand_globs_in_dir(opts.inputs,  pkg.dir)
            local outputs  = anchor_outputs(opts.outputs, pkg.dir)

            -- package.json itself participates in the input set so a
            -- `scripts` edit invalidates the cached value.
            inputs[#inputs + 1] = pkg.dir .. "/package.json"

            cook.recipe(r_name, { requires = requires }, function()
                cook.add_unit({
                    inputs   = inputs,
                    outputs  = outputs,
                    command  = command_for(pkg, task_name) .. " ",
                    -- Toolchain probe is consumed as DATA: command_for
                    -- interpolates $<pnpm:toolchain:...pnpm> for the binary
                    -- path, so its full value already folds into the key
                    -- (§12.7.4). The install probe is NOT consumed as data —
                    -- it is a deterministic, invalidate-only determinant
                    -- (pnpm-lock.yaml content hash), so it is a `seal`, not a
                    -- data probe (§12.7.5). cook.add_unit auto-adds sealed
                    -- keys to the DAG-ordering probe set.
                    probes   = { toolchain.get_probe_key() },
                    seal     = { snap.install_key },
                })
            end)
        end
    end
end

-- Escape hatch: register a custom recipe under <pkg>:<name>. The
-- caller supplies the body via a function that receives the parsed
-- WorkspaceInfo so it can build its own cook.add_unit.
function M.script(pkg_name, name, body_fn)
    local pkg = workspace.lookup(pkg_name)
    if not pkg then
        error("[pnpm.script] unknown package '" .. pkg_name .. "' in workspace", 2)
    end
    cook.recipe(recipe_name(pkg, name), {}, function()
        body_fn(pkg)
    end)
end

return M
