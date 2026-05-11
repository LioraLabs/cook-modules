-- Minimal stand-ins for the cook-engine-provided globals so busted can
-- exercise cook_cc submodules in isolation. Each spec resets the state.

local M = {}

local cache_store = {}
local export_store = {}
local added_units = {}
local sh_handlers = {}   -- map[string] -> function(cmd) -> stdout

function M.reset()
    cache_store = {}
    export_store = {}
    added_units = {}
    sh_handlers = {}
end

function M.set_sh_handler(prefix, handler)
    sh_handlers[prefix] = handler
end

function M.added_units()
    return added_units
end

function M.install()
    _G.cook = {
        env = setmetatable({}, { __index = function() return nil end }),
        platform = { os = "linux" },
        cache = {
            get = function(k) return cache_store[k] end,
            set = function(k, v) cache_store[k] = v end,
        },
        export = function(name, info) export_store[name] = info end,
        import = function(name) return export_store[name] end,
        add_unit = function(u) added_units[#added_units + 1] = u end,
        sh = function(cmd)
            for prefix, fn in pairs(sh_handlers) do
                if cmd:sub(1, #prefix) == cmd:sub(1, #prefix) and cmd:sub(1, #prefix) == prefix then
                    return fn(cmd)
                end
            end
            error("[cook_stub] unhandled sh: " .. cmd)
        end,
    }

    _G.fs = {
        exists = function(p)
            local h = sh_handlers["__exists"]
            return h and h(p) or true
        end,
        read = function(p)
            local h = sh_handlers["__read"]
            return h and h(p) or ""
        end,
        write  = function(p, content)
            added_units[#added_units + 1] = { kind = "fs.write", path = p, content = content }
        end,
        mkdir_p = function() end,
        glob    = function(_) return {} end,
    }

    _G.path = {
        stem = function(p) return p:match("([^/]+)%.[^.]+$") end,
        dir  = function(p) return p:match("(.+)/[^/]+$") or "." end,
    }
end

return M
