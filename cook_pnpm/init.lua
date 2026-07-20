-- cook_pnpm — blessed Cook module for pnpm-driven JS/TS monorepos.
--
-- Public surface (v0.4). The one-call form:
--
--   cook_pnpm.workspace({
--       packages = "auto",            -- read pnpm-workspace.yaml; or {"apps/*", ...}
--       node     = ">=18",
--       pm       = "pnpm@10",
--       requires = { "wasm" },        -- non-pnpm producer recipes, every minted task
--       inputs   = { ".env" },        -- ROOT-relative extras appended to every
--                                     -- minted task's inputs (turbo
--                                     -- globalDependencies); missing literals drop
--       exclude_inputs =              -- ROOT-relative globs SUBTRACTED from every
--           { "apps/web/app/.well-known/workflow/**" },
--                                     -- minted task's inputs (tool-written
--                                     -- files in source dirs must not self-invalidate;
--                                     -- also on task cfg, package-relative)
--       env      = { "CI" },          -- env keys folded into every BUILD unit's
--                                     -- key (consulted_env_keys auto-fold)
--       tasks    = {                  -- the task map, minted as one batch
--           build = { outputs = { "dist/**" } },
--           ["@scope/web#build"] =    -- per-package override: REPLACES the base
--               { outputs = { ".next/**" },    -- cfg for that package (no merge)
--                 env = { "API_URL" } },       -- per-task consulted env
--       },
--       checks   = "auto",            -- auto-mint test/lint/typecheck/check-types
--       install  = "install",         -- opt-in: mint the install recipe under
--                                     -- this name (true → "pnpm:install")
--   })
--
-- Tasks with outputs become cached cook units (restored from the store);
-- tasks without become cached CHECK units (engine test units: pass
-- results replayed, run by `cook test`). Omitted inputs default to the
-- package's file tree minus node_modules and declared outputs. A
-- depends_on edge also folds the dependency's OUTPUT CONTENT into the
-- consumer's key (discovered-inputs depfile on builds, ready-time glob
-- inputs on checks; checks with no depends_on default to {"^build"}) —
-- a dep that rebuilds to byte-identical output never re-runs its
-- consumers. Negated output globs ("!...") are rejected — no engine
-- support (CS-0085). See tasks.lua for the full contract.

local workspace = require("cook_pnpm.workspace")
local tasks     = require("cook_pnpm.tasks")
local pnpm_cli  = require("cook_pnpm.pnpm_cli")
local toolchain = require("cook_pnpm.toolchain")
local finder    = require("cook_pnpm.finder")

local M = {}

function M.init()
    -- Toolchain + install probes are registered lazily on the first
    -- `cook_pnpm.workspace(...)` call. Nothing to do here.
end

-- Workspace bootstrap + task minting. Parses pnpm-workspace.yaml + each
-- package's package.json, registers the toolchain + install probes, then
-- mints opts.tasks / opts.checks as one batch (full-output-picture
-- default inputs) and the install recipe.
function M.workspace(opts)
    opts = opts or {}
    local result = workspace.bootstrap(opts)
    tasks.mint_from_workspace(opts)
    -- Opt-in (a default mint would duplicate-register against Cookfiles
    -- that already call cook_pnpm.install() explicitly).
    if opts.install then
        pnpm_cli.install({
            name = (type(opts.install) == "string") and opts.install or nil,
        })
    end
    return result
end

-- Incremental task minting (single-batch defaults; prefer workspace{tasks}).
M.task       = tasks.task

-- Low-level escape hatches.
M.run        = pnpm_cli.run
M.install    = pnpm_cli.install
M.script     = tasks.script

-- Introspection (register-time only). Returns the list of parsed
-- workspace packages: { { name, dir, dependencies = { ... } }, ... }.
M.workspaces = workspace.list

-- Toolchain controls (mirror cc.toolchain / cc.defaults).
M.toolchain  = toolchain.set

-- cc.find-style locator for JS dev tools (node, pnpm, tsc, vite, ...).
M.find          = finder.find
M.find_or_error = finder.find_or_error
M.register_finder = finder.register

return M
