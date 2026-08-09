-- cook_cc — public entry point wiring toolchain, target makers, finders, checks, and codegen into the exported api
-- domain:  public surface — re-exports the module API
-- effects: pure
-- std:     §28
local toolchain     = require("cook_cc.toolchain")
local cc            = require("cook_cc.units.cc")
local targets       = require("cook_cc.units.targets")
local finder        = require("cook_cc.discovery.finder")
local db            = require("cook_cc.codegen.compile_db")
local checks        = require("cook_cc.discovery.checks")
local config_header = require("cook_cc.codegen.config_header")

local M = {}

function M.init()
    -- Toolchain probe is registered lazily on first get_compiler() / target-maker call.
end

-- Public surface (Standard §28 v0.6 contract).
M.toolchain        = toolchain.set
M.defaults         = toolchain.merge_defaults
M.compile          = cc.compile
M.archive          = cc.archive
M.link             = cc.link
M.bin              = targets.bin
M.lib              = targets.lib
M.shared           = targets.shared
M.headers          = targets.headers
M.find             = finder.find
M.find_or_error    = finder.find_or_error
M.uses             = finder.uses
M.register_finder  = finder.register
M.compile_commands = db.compile_commands
M.checks           = checks
M.config_header    = config_header.config_header

-- Project-management verbs (§22.12). Registered here, inside cook_cc's own
-- chunk, because that is the only window in which the engine can check a
-- module-registered chore's namespace against the module registering it —
-- a call made later, from a function this table returns, is rejected.
-- No-ops on a VM without `cook.chore`, which is every execute-phase VM.
require("cook_cc.verbs").register()

return M
