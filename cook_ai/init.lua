local M = {}

M.name = "cook_ai"

local provider = require("cook_ai.provider")
local prompt   = require("cook_ai.prompt")

M.provider = provider.configure
M.prompt   = prompt.call

return M
