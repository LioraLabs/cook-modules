-- cook_pnpm — blessed Cook module for pnpm-driven JS/TS monorepos.
--
-- Public surface (v0.1, see milestone "cook_pnpm" in cliban project COOK).
-- This is a first rough draft; surface is NOT yet specified in the Cook
-- Standard. A future chapter §29 will normatively cover it once the
-- v0.1 surface has stabilised against the smoke fixture.

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

-- Workspace bootstrap. Parses pnpm-workspace.yaml + each package's
-- package.json, registers the toolchain + install probes, and primes
-- in-memory state for subsequent pnpm.task / pnpm.run calls.
M.workspace  = workspace.bootstrap

-- Register one cook.recipe per (package, task) with topo-correct deps.
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
