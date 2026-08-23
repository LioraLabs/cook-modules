local M = {}
local probes, commands, gather, resolved

function M.reset()
    probes, commands, gather, resolved = {}, {}, nil, { "resolved/project/file.rs" }
    _G.cook = {
        sh = function(command)
            for prefix, response in pairs(commands) do
                if command:sub(1, #prefix) == prefix then
                    if type(response) == "function" then return response(command) end
                    return response
                end
            end
            error("unexpected cook.sh: " .. command)
        end,
        resolve_gather = function(globs, excludes)
            gather = { globs = globs, excludes = excludes }
            return resolved
        end,
        probe = function(key, opts)
            assert(type(key) == "string" and key ~= "", "probe key required")
            assert(type(opts) == "table" and type(opts.produce) == "string", "strict probe shape")
            assert(type(opts.inputs) == "table", "probe inputs required")
            if probes[key] then error("duplicate probe " .. key) end
            probes[key] = opts
        end,
    }
end

function M.command(prefix, response) commands[prefix] = response end
function M.resolved(files) resolved = files end
function M.probe(key) return probes[key] end
function M.gather() return gather end
return M
