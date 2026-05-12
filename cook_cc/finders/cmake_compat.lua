local M = {}

function M.main_chain(name, opts)
    opts = opts or {}
    if opts.version then
        return { strategy = "cmake-compat", outcome = "skip",
                 reason = "version detection unsupported by legacy cmake --find-package" }
    end
    return { strategy = "cmake-compat", outcome = "skip",
             reason = "not implemented yet" }
end

return M
