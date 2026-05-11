local toolchain = require("cook_cc.toolchain")
local cc        = require("cook_cc.cc")
local targets   = require("cook_cc.targets")
local finder    = require("cook_cc.finder")
local db        = require("cook_cc.compile_db")

local M = {}

function M.init()
    -- Loader-contract hook (Standard §6.3.4). Called once per VM.
    toolchain.rehydrate()
end

-- Public surface (the Standard §9.2 contract).
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
M.compile_commands = db.write

return M
