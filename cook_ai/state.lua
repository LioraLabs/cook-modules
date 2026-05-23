local M = {}

local current_provider = nil

function M.set_provider(opts)
    current_provider = opts
end

function M.get_provider()
    return current_provider
end

function M.reset()
    current_provider = nil
end

return M
