-- Minimal stand-ins for the cook-engine-provided globals so busted can
-- exercise cook_cc submodules in isolation. Each spec resets the state.

local M = {}

local cache_store = {}
local export_store = {}
local added_units = {}
local sh_handlers = {}      -- map[string] -> function(cmd) -> stdout
local pkg_responses = {}    -- name -> { cflags, libs, version, exists }
local tool_responses = {}   -- "tool args" -> output
local file_exists_set = {}  -- path -> bool
local platform_os = "linux"

function M.reset()
    cache_store = {}
    export_store = {}
    added_units = {}
    sh_handlers = {}
    pkg_responses = {}
    tool_responses = {}
    file_exists_set = {}
    platform_os = "linux"
end

function M.set_platform_os(os)
    platform_os = os
end

function M.set_sh_handler(prefix, handler)
    sh_handlers[prefix] = handler
end

function M.set_pkg_config_response(name, response)
    -- response = { exists = bool, cflags = string?, libs = string?, version = string? }
    pkg_responses[name] = response
end

function M.set_tool_config_response(cmd, output)
    tool_responses[cmd] = output
end

function M.set_file_exists(path, exists)
    file_exists_set[path] = exists and true or false
end

function M.added_units()
    return added_units
end

local function pkg_dispatch(cmd)
    -- "pkg-config --exists NAME" / "--cflags NAME" / "--libs NAME" / "--modversion NAME"
    local op, name = cmd:match("pkg%-config %-%-(%S+) (.+)$")
    if not op then return nil end
    local r = pkg_responses[name]
    if not r then return nil end
    if op == "exists" then
        if r.exists then return "" end
        error("[cook_stub] pkg-config exists " .. name .. " failed")
    elseif op == "cflags"      then return (r.cflags or "") .. "\n"
    elseif op == "libs"        then return (r.libs   or "") .. "\n"
    elseif op == "modversion"  then return (r.version or "") .. "\n"
    end
    return nil
end

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
        export = function(name, info) export_store[name] = info end,
        import = function(name) return export_store[name] end,
        add_unit = function(u) added_units[#added_units + 1] = u end,
        sh = function(cmd)
            local pkg = pkg_dispatch(cmd)
            if pkg ~= nil then return pkg end
            local tool = tool_responses[cmd]
            if tool ~= nil then return tool end
            for prefix, fn in pairs(sh_handlers) do
                if cmd:sub(1, #prefix) == prefix then return fn(cmd) end
            end
            error("[cook_stub] unhandled sh: " .. cmd)
        end,
    }

    _G.fs = {
        exists = function(p)
            if file_exists_set[p] ~= nil then return file_exists_set[p] end
            local h = sh_handlers["__exists"]
            if h then return h(p) end
            return false
        end,
        read = function(p)
            local h = sh_handlers["__read"]
            return h and h(p) or ""
        end,
        write   = function(p, content)
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
