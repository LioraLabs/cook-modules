local state = require("cook_ai.state")

local M = {}

function M.configure(opts)
    state.set_provider(opts)
end

return M
