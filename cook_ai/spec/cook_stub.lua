-- Minimal cook-engine stub for cook_ai specs. Mirrors cook_pnpm/spec/cook_stub.lua;
-- mocks the cook API (cook.recipe, cook.add_unit, cook.probe, cook.env, cook.tmpfile, ...)
-- that cook_ai exercises across its task suite.

local M = {}

M.probes                  = {}      -- key -> opts (publicly inspectable)
local probe_registrations = M.probes
local cache_store         = {}      -- key -> any
local export_store        = {}      -- name -> info
local added_units         = {}
local recipes             = {}      -- name -> { opts, body_executed }
local sh_handlers         = {}
local pkg_responses       = {}
local tool_responses      = {}
local file_exists_set     = {}
local file_contents       = {}
local glob_table          = {}      -- pattern -> list of matches
local platform_os         = "linux"

function M.reset()
    for k in pairs(probe_registrations) do probe_registrations[k] = nil end
    cache_store         = {}
    export_store        = {}
    added_units         = {}
    recipes             = {}
    sh_handlers         = {}
    pkg_responses       = {}
    tool_responses      = {}
    file_exists_set     = {}
    file_contents       = {}
    glob_table          = {}
    platform_os         = "linux"
end

function M.probe_keys()
    local keys = {}
    for k in pairs(probe_registrations) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

function M.probe_opts(key)   return probe_registrations[key] end
function M.added_units()     return added_units end
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
        add_unit = function(u) added_units[#added_units + 1] = u end,
        recipe = function(name, opts, body_fn)
            recipes[name] = { opts = opts, body_executed = false }
            body_fn()
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

-- Auto-install on require so specs that just `require("spec.cook_stub")` get
-- a populated cook/fs/path global surface without an explicit install() call.
M.install()

return M
