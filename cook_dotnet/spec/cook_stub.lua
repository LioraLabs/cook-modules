local M = {}
local json = require("cjson.safe")
local probes, units, exported, gathered, gathers, gather_count, current_recipe, recipes, commands, resolved, materialized, materialized_value

function M.reset()
    probes, units, exported, gathered, gathers, gather_count, current_recipe = {}, {}, {}, nil, {}, 0, nil
    recipes, commands, materialized, materialized_value = {}, {}, nil, nil
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
            gather_count = gather_count + 1
            gathered = { globs = globs, excludes = excludes }
            gathers[#gathers + 1] = gathered
            return type(resolved) == "function" and resolved(globs, excludes) or resolved
        end,
        add_unit = function(unit) units[#units + 1] = unit end,
        export = function(name, value) exported[name] = value end,
        json_decode = function(value) return assert(json.decode(value)) end,
        materialize = function(name, spec, produce)
            materialized = { name = name, spec = spec, produce = produce }
            return assert(materialized_value, "no materialized value configured")
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
        tools = {
            id = function(name)
                return { hash = (name .. string.rep("0", 64)):sub(1, 64), path = "/stub/bin/" .. name }
            end,
        },
    }
    _G.fs = {}
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
function M.gathers() return gathers end
function M.gather_count() return gather_count end
function M.recipes() return recipes end
function M.command(prefix, response) commands[prefix] = response end
function M.resolved(files) resolved = files end
function M.materialize_as(value)
    value.toolchain = value.toolchain or {
        dotnet_id = string.rep("d", 64), sdk = "10.0.302",
        netcore_ref = { versions = "8.0.10\n10.0.10", digest = string.rep("n", 64) },
        aspnetcore_ref = { versions = "8.0.10\n10.0.10", digest = string.rep("a", 64) },
    }
    materialized_value = value
end
function M.materialized() return materialized end
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
