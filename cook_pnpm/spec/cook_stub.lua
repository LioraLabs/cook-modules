-- Minimal cook-engine stub for cook_pnpm specs. Mirrors cook_cc/spec/cook_stub.lua
-- pared down to the surface cook_pnpm actually uses.

-- src/ searcher: production installs map module names to paths via the
-- rockspec's build.modules, but no single-? package.path pattern can map
-- cook_pnpm.units.tasks -> src/units/tasks.lua, so resolve the prefix
-- here. Test-only; busted runs with cwd = cook_pnpm/.
table.insert(package.searchers or package.loaders, 2, function(name)
    local rest = name:match("^cook_pnpm%.(.+)$")
    if not rest then return nil end
    local rel = rest:gsub("%.", "/")
    for _, p in ipairs({ "./src/" .. rel .. ".lua", "./src/" .. rel .. "/init.lua" }) do
        local f = io.open(p, "r")
        if f then f:close(); return assert(loadfile(p)), p end
    end
    return "\n\tno file './src/" .. rel .. "[.lua|/init.lua]' (cook_pnpm src searcher)"
end)

local M = {}

local probe_registrations = {}      -- key -> opts
local cache_store         = {}      -- key -> any
local export_store        = {}      -- name -> info
local added_units         = {}
local added_tests         = {}      -- add_unit(step_kind = "test") captures (CS-0185)
local current_recipe      = nil     -- recipe body currently executing
local recipes             = {}      -- name -> { opts, body_executed }
local sh_handlers         = {}
local pkg_responses       = {}
local tool_responses      = {}
local file_exists_set     = {}
local file_contents       = {}
local glob_table          = {}      -- pattern -> list of matches
local platform_os         = "linux"

function M.reset()
    probe_registrations = {}
    cache_store         = {}
    export_store        = {}
    added_units         = {}
    added_tests         = {}
    recipes             = {}
    sh_handlers         = {}
    pkg_responses       = {}
    tool_responses      = {}
    file_exists_set     = {}
    file_contents       = {}
    glob_table          = {}
    platform_os         = "linux"
    current_recipe      = nil
end

function M.probe_keys()
    local keys = {}
    for k in pairs(probe_registrations) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

function M.probe_opts(key)   return probe_registrations[key] end
function M.added_units()     return added_units end
function M.added_tests()     return added_tests end
function M.recipes()         return recipes end
function M.set_file_exists(p, exists) file_exists_set[p] = exists and true or false end
function M.set_file_contents(p, c)    file_contents[p] = c; file_exists_set[p] = true end
function M.set_glob(pattern, matches) glob_table[pattern] = matches end
function M.set_sh_handler(prefix, handler) sh_handlers[prefix] = handler end
function M.set_platform_os(os) platform_os = os end

function M.install()
    _G.cook = {
        env = setmetatable({}, { __index = function() return nil end }),
        platform = setmetatable({}, { __index = function(_, k)
            if k == "os" then return platform_os end
        end }),
        cache = {
            get = function(k) return cache_store[k] end,
            set = function(k, v) cache_store[k] = v end,
        },
        probe = function(key, opts)
            if probe_registrations[key] ~= nil then
                error("[cook_stub] duplicate cook.probe key '" .. key .. "'")
            end
            probe_registrations[key] = opts
        end,
        export = function(name, info) export_store[name] = info end,
        import = function(name) return export_store[name] end,
        -- Mirrors the engine's CS-0185 surface: a test unit registers
        -- through add_unit with step_kind = "test"; suite and outputs are
        -- register-time errors there, so they are errors here too.
        add_unit = function(u)
            if u.step_kind == "test" then
                if u.suite ~= nil then
                    error("[cook_stub] `suite` was removed with cook.add_test "
                        .. "(CS-0185); the enclosing recipe names a test unit")
                end
                if u.outputs ~= nil and #u.outputs > 0 then
                    error("[cook_stub] a step_kind = \"test\" unit declares no "
                        .. "outputs (CS-0185)")
                end
                local has_cmd = u.command ~= nil and u.command ~= ""
                local has_lua = u.lua_code ~= nil and u.lua_code ~= ""
                if has_cmd == has_lua then
                    error("[cook_stub] a step_kind = \"test\" unit requires "
                        .. "exactly one of `command` or `lua_code` (CS-0185)")
                end
                u._recipe = current_recipe   -- attribution, spec-side only
                added_tests[#added_tests + 1] = u
            else
                added_units[#added_units + 1] = u
            end
        end,
        add_test = function()
            error("[cook_stub] cook.add_test was removed (CS-0185); register "
                .. "a test unit via cook.add_unit({ step_kind = \"test\" })")
        end,
        recipe = function(name, opts, body_fn)
            recipes[name] = { opts = opts, body_executed = false }
            current_recipe = name
            body_fn()
            current_recipe = nil
            recipes[name].body_executed = true
        end,
        sh = function(cmd)
            for prefix, fn in pairs(sh_handlers) do
                if cmd:sub(1, #prefix) == prefix then return fn(cmd) end
            end
            local probe = cmd:match("^test %-x '(.+)' && echo y || echo n$")
            if probe then
                return file_exists_set[probe] and "y\n" or "n\n"
            end
            local probe2 = cmd:match("^test %-e '(.+)' && echo y || echo n$")
            if probe2 then
                return file_exists_set[probe2] and "y\n" or "n\n"
            end
            local cmdv = cmd:match("^command %-v (%S+)")
            if cmdv then
                return tool_responses[cmdv] or ""
            end
            local sha = cmd:match("^sha256sum '(.+)'")
            if sha then
                return string.rep("a", 64) .. "  " .. sha .. "\n"
            end
            return tool_responses[cmd] or ""
        end,
    }

    _G.fs = {
        exists = function(p)
            if file_exists_set[p] ~= nil then return file_exists_set[p] end
            return false
        end,
        read = function(p) return file_contents[p] or "" end,
        write = function(p, content)
            added_units[#added_units + 1] = { kind = "fs.write", path = p, content = content }
        end,
        mkdir_p = function() end,
        glob = function(pattern) return glob_table[pattern] or {} end,
    }

    _G.path = {
        stem = function(p) return p:match("([^/]+)%.[^.]+$") end,
        dir  = function(p) return p:match("(.+)/[^/]+$") or "." end,
    }
end

function M.set_tool_path(tool, abs_path)
    tool_responses[tool] = abs_path .. "\n"
end

return M
