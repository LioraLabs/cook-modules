local M = {}
local json = require("cjson.safe")
local probes, units, exported, gathered, current_recipe, recipes, commands, resolved, files, materialized

function M.reset()
    probes, units, exported, gathered, current_recipe = {}, {}, {}, nil, nil
    recipes, commands, files, materialized = {}, {}, {}, nil
    resolved = { "src/App.csproj", "src/Program.cs" }
    _G.recipe = nil
    _G.cook = {
        probe = function(key, opts)
            if probes[key] then error("duplicate probe " .. key) end
            probes[key] = opts
        end,
        recipe_name = function()
            if not current_recipe then error("outside recipe") end
            return current_recipe
        end,
        resolve_gather = function(globs, excludes)
            gathered = { globs = globs, excludes = excludes }
            return type(resolved) == "function" and resolved(globs, excludes) or resolved
        end,
        add_unit = function(unit) units[#units + 1] = unit end,
        export = function(name, value) exported[name] = value end,
        json_decode = function(value) return assert(json.decode(value)) end,
        materialize = function(name)
            M.execute(name)
            return assert(materialized, "no materialized path configured")
        end,
        require_recipe = function(name) M.execute(name) end,
        sh = function(command)
            for prefix, response in pairs(commands) do
                if command:sub(1, #prefix) == prefix then
                    return type(response) == "function" and response(command) or response
                end
            end
            error("unexpected cook.sh: " .. command)
        end,
        recipe = function(name, opts, body)
            recipes[name] = { opts = opts, body = body }
        end,
    }
    _G.fs = {
        read = function(pathname) return assert(files[pathname], "no file configured: " .. pathname) end,
    }
end

function M.in_recipe(name, fn)
    current_recipe = name
    _G.recipe = { name = name:match("([^:]+)$") }
    local ok, err = pcall(fn)
    current_recipe, _G.recipe = nil, nil
    if not ok then error(err, 0) end
end

function M.probe(key) return probes[key] end
function M.units() return units end
function M.export(name) return exported[name] end
function M.gathered() return gathered end
function M.recipes() return recipes end
function M.command(prefix, response) commands[prefix] = response end
function M.resolved(files) resolved = files end
function M.materialized(pathname, contents) materialized, files[pathname] = pathname, contents end
function M.execute(name)
    local entry = assert(recipes[name], "unknown recipe " .. name)
    if entry.executed then return end
    entry.executed = true
    local prior_name, prior_recipe = current_recipe, _G.recipe
    current_recipe, _G.recipe = name, { name = name }
    entry.body()
    current_recipe, _G.recipe = prior_name, prior_recipe
end

return M
