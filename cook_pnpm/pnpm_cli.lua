-- Low-level pnpm CLI primitives. These let callers drop one level
-- below `pnpm.task` when they need to invoke pnpm directly (e.g., a
-- one-off `pnpm dlx` step or a custom orchestration script).

local toolchain = require("cook_pnpm.toolchain")
local workspace = require("cook_pnpm.workspace")

local M = {}

-- pnpm.install — recipe that runs `pnpm install --frozen-lockfile`.
-- Cached by pnpm-lock.yaml hash via the install probe; the recipe
-- itself is here for callers who want an explicit step in the DAG
-- (e.g. a CI flow's "install" stage).
function M.install(opts)
    opts = opts or {}
    local snap = workspace.snapshot()
    if not snap.install_key then
        error("[pnpm.install] pnpm.workspace(...) must be called first", 2)
    end
    cook.recipe(opts.name or "pnpm:install", { requires = opts.requires or {} }, function()
        cook.add_unit({
            inputs  = { (snap.root_dir or ".") .. "/pnpm-lock.yaml" },
            outputs = {},
            command = "$<" .. toolchain.get_probe_key() .. ".pnpm> install --frozen-lockfile ",
            probes  = { toolchain.get_probe_key(), snap.install_key },
        })
    end)
    return opts.name or "pnpm:install"
end

-- pnpm.run — single-package, single-script invocation. Returns the
-- recipe name for chaining.
function M.run(pkg_name, script, opts)
    opts = opts or {}
    local pkg = workspace.lookup(pkg_name)
    if not pkg then
        error("[pnpm.run] unknown package '" .. pkg_name .. "' in workspace", 2)
    end
    toolchain.ensure_probe_registered()
    local snap = workspace.snapshot()
    local r_name = opts.recipe_name or (pkg.name .. ":" .. script)
    local inputs = opts.inputs or {}
    inputs[#inputs + 1] = pkg.dir .. "/package.json"

    cook.recipe(r_name, { requires = opts.requires or {} }, function()
        cook.add_unit({
            inputs  = inputs,
            outputs = opts.outputs or {},
            command = "$<" .. toolchain.get_probe_key() .. ".pnpm> --filter "
                      .. pkg.name .. " run " .. script .. " ",
            probes  = { toolchain.get_probe_key(), snap.install_key },
        })
    end)
    return r_name
end

return M
