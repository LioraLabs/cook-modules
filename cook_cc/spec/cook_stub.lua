-- Minimal stand-ins for the cook-engine-provided globals so busted can
-- exercise cook_cc submodules in isolation. Each spec resets the state.

local M = {}

local probe_registrations = {}      -- key -> opts
local probe_values        = {}      -- key -> any (injected by tests)
local cache_store = {}
local export_store = {}
local added_units = {}
local sh_handlers = {}      -- map[string] -> function(cmd) -> stdout
local pkg_responses = {}    -- name -> { cflags, libs, version, exists }
local tool_responses = {}   -- "tool args" -> output
local file_exists_set = {}  -- path -> bool
local platform_os = "linux"

local current_recipe        = nil    -- name of the recipe body currently executing
local known_recipe_names    = {}     -- name -> true, for cook.require_recipe validation
local recipe_names_list     = {}     -- array of registered recipe names, registration order
local recipe_meta_store     = {}     -- name -> meta table captured from cook.recipe
local require_recipe_edges_list = {} -- array of names passed to cook.require_recipe, call order
local register_complete_queue = {}   -- array of fns passed to cook.on_register_complete, queue order
local step_group_log = {}            -- one entry per cook.step_group call: array of added_units indices registered inside it

function M.reset()
    cache_store = {}
    export_store = {}
    added_units = {}
    sh_handlers = {}
    pkg_responses = {}
    tool_responses = {}
    file_exists_set = {}
    platform_os = "linux"
    probe_registrations = {}
    probe_values        = {}
    current_recipe          = nil
    known_recipe_names      = {}
    recipe_names_list       = {}
    recipe_meta_store       = {}
    require_recipe_edges_list = {}
    register_complete_queue   = {}
    step_group_log            = {}
end

function M.probe_keys()
    local keys = {}
    for k in pairs(probe_registrations) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

function M.probe_opts(key)
    return probe_registrations[key]
end

function M.set_probe_value(key, value)
    probe_values[key] = value
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

-- One array of added_units indices per cook.step_group invocation, in call
-- order. Lets specs assert which units were registered inside a group.
function M.step_groups()
    return step_group_log
end

function M.require_recipe_edges()
    return require_recipe_edges_list
end

function M.recipe_meta(name)
    return recipe_meta_store[name]
end

function M.recipe_names()
    return recipe_names_list
end

-- Drains cook.on_register_complete callbacks in queue order (CS-0149 stub
-- surface). Fires each callback exactly once: the queue is fully drained
-- (including any callbacks a callback itself queues, which run after the
-- rest of the originally-queued batch) and left empty, so a second drain
-- call is a no-op. Runs with current_recipe = nil so body-scoped APIs
-- (cook.recipe_name) raise the same way they do outside a recipe body,
-- mirroring the real engine's post-register finalizer context.
function M.run_register_complete()
    local previous_recipe = current_recipe
    current_recipe = nil
    local i = 1
    while register_complete_queue[i] do
        register_complete_queue[i]()
        i = i + 1
    end
    register_complete_queue = {}
    current_recipe = previous_recipe
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

local function current_recipe_name_or_error()
    if current_recipe == nil then
        error("[cook_stub] cook.recipe_name() called outside a recipe body")
    end
    return current_recipe
end

function M.install()
    _G.cook = {
        env = setmetatable({}, { __index = function() return nil end }),
        platform = setmetatable({}, { __index = function(_, k)
            if k == "os" then return platform_os end
        end }),
        -- cook.cache was renamed to cook.probes in v1.0 (CS-0136).
        probes = {
            get = function(k)
                if cache_store[k] ~= nil then return cache_store[k] end
                return probe_values[k]
            end,
            set = function(k, v) cache_store[k] = v end,
        },
        probe = function(key, opts)
            if probe_registrations[key] ~= nil then
                error("[cook_stub] duplicate cook.probe key '" .. key .. "'")
            end
            probe_registrations[key] = opts
        end,
        -- CS-0158: cook.tools.id(name) → { hash, path } | nil. Deterministic
        -- stand-in: a fake 64-hex "hash" derived from the name so specs can
        -- assert identity folding without touching the real filesystem.
        tools = {
            id = function(name)
                local h = ("%s"):format(name):gsub("[^%w]", "x")
                local hash = (h .. string.rep("0", 64)):sub(1, 64)
                return { hash = hash, path = "/stub/bin/" .. name }
            end,
        },
        export = function(name, info) export_store[name] = info end,
        import = function(name) return export_store[name] end,
        add_unit = function(u) added_units[#added_units + 1] = u end,
        step_group = function(fn)
            if type(fn) ~= "function" then
                error("[cook_stub] cook.step_group requires a function", 2)
            end
            local first = #added_units + 1
            fn()
            local members = {}
            for i = first, #added_units do members[#members + 1] = i end
            step_group_log[#step_group_log + 1] = members
        end,
        recipe_name = current_recipe_name_or_error,
        on_register_complete = function(fn)
            if type(fn) ~= "function" then
                error("[cook_stub] cook.on_register_complete requires a function", 2)
            end
            register_complete_queue[#register_complete_queue + 1] = fn
        end,
        require_recipe = function(name)
            if not known_recipe_names[name] then
                error("[cook_stub] cook.require_recipe: unknown recipe '" .. name .. "'")
            end
            require_recipe_edges_list[#require_recipe_edges_list + 1] = name
        end,
        recipe = function(name, meta, body_fn)
            if not known_recipe_names[name] then
                known_recipe_names[name] = true
                recipe_names_list[#recipe_names_list + 1] = name
            end
            recipe_meta_store[name] = meta

            local previous_recipe = current_recipe
            current_recipe = name
            local ok, err = pcall(body_fn)
            current_recipe = previous_recipe
            if not ok then
                error(err, 0)
            end
        end,
        sh = function(cmd)
            local pkg = pkg_dispatch(cmd)
            if pkg ~= nil then return pkg end
            local tool = tool_responses[cmd]
            if tool ~= nil then return tool end
            for prefix, fn in pairs(sh_handlers) do
                if cmd:sub(1, #prefix) == prefix then return fn(cmd) end
            end
            -- CS-0045: bare_probe and other system-path checks now route
            -- existence probes through `cook.sh ("test -e '<path>' && echo y || echo n")`
            -- because the sandbox blocks `fs.exists` on /usr paths. Reuse
            -- the file_exists_set the spec already populates via
            -- `stub.set_file_exists(...)` so tests can stay declarative
            -- about which paths exist regardless of which API the impl
            -- chose to probe with.
            local probe = cmd:match("^test %-e '(.+)' && echo y || echo n$")
            if probe then
                return file_exists_set[probe] and "y\n" or "n\n"
            end
            error("[cook_stub] unhandled sh: " .. cmd)
        end,
    }

    _G.recipe = setmetatable({}, {
        __index = function(_, k)
            if k == "name" then return current_recipe_name_or_error() end
            return nil
        end,
    })

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
