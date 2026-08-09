-- Minimal stand-ins for the cook-engine-provided globals so busted can
-- exercise cook_cc submodules in isolation. Each spec resets the state.

-- src/ searcher: production installs map module names to paths via the
-- rockspec's build.modules, but no single-? package.path pattern can map
-- cook_cc.units.targets -> src/units/targets.lua, so resolve the prefix
-- here. Test-only; busted runs with cwd = cook_cc/.
table.insert(package.searchers or package.loaders, 2, function(name)
    local rest = name:match("^cook_cc%.(.+)$")
    if not rest then return nil end
    local rel = rest:gsub("%.", "/")
    for _, p in ipairs({ "./src/" .. rel .. ".lua", "./src/" .. rel .. "/init.lua" }) do
        local f = io.open(p, "r")
        if f then f:close(); return assert(loadfile(p)), p end
    end
    return "\n\tno file './src/" .. rel .. "[.lua|/init.lua]' (cook_cc src searcher)"
end)

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
local glob_results = {}       -- pattern -> array of absolute paths

-- Verb surfaces (COOK-285). A cc.* chore reads and rewrites the project's
-- own files, so the stub needs a filesystem with a memory rather than the
-- write-only sink the maker specs were content with.
local vfiles = {}                   -- path -> content; the virtual working tree
local vdirs = {}                    -- path -> true, from fs.mkdir_p
local module_calls = {}             -- recipe name -> { callee = , text = }
local chore_registrations = {}      -- name -> { name, meta, body }, plus [n] order
local splices = {}                  -- one entry per cook.cookfile.splice_field call

local current_recipe        = nil    -- name of the recipe body currently executing
local known_recipe_names    = {}     -- name -> true, for cook.require_recipe validation
local recipe_names_list     = {}     -- array of registered recipe names, registration order
local recipe_meta_store     = {}     -- name -> meta table captured from cook.recipe
local require_recipe_edges_list = {} -- array of names passed to cook.require_recipe, call order
local dep_order_edges_list  = {}     -- array of names passed to cook.dep_order, call order
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
    glob_results = {}
    platform_os = "linux"
    probe_registrations = {}
    probe_values        = {}
    current_recipe          = nil
    known_recipe_names      = {}
    recipe_names_list       = {}
    recipe_meta_store       = {}
    require_recipe_edges_list = {}
    dep_order_edges_list      = {}
    register_complete_queue   = {}
    step_group_log            = {}
    vfiles                    = {}
    vdirs                     = {}
    module_calls              = {}
    chore_registrations       = {}
    splices                   = {}
end

-- ---------------------------------------------------------------------------
-- Virtual working tree
-- ---------------------------------------------------------------------------

-- Seed a file. `fs.exists`, `fs.read` and `cook.cookfile.*` all agree about it,
-- which `set_file_exists` alone does not give: a verb that checks for a
-- Cookfile and then reads it must see one story, not two.
function M.set_file(path, content)
    vfiles[path] = content
end

function M.file(path)
    return vfiles[path]
end

function M.dirs()
    local out = {}
    for d in pairs(vdirs) do out[#out + 1] = d end
    table.sort(out)
    return out
end

-- Declare that `recipe` contains a module call, as cook.cookfile.find_call
-- would report it. Absent recipes and recipes without one both answer nil,
-- exactly as the engine's binding does (RecipeNotFound and NoModuleCall are
-- both mapped to nil there).
function M.set_module_call(recipe, call)
    module_calls[recipe] = call
end

-- One record per cook.cookfile.splice_field call, in call order.
function M.splices()
    return splices
end

-- ---------------------------------------------------------------------------
-- Module-registered chores (Standard §22.12)
-- ---------------------------------------------------------------------------

function M.chores()
    return chore_registrations
end

function M.chore(name)
    return chore_registrations[name]
end

-- Invoke a registered chore the way a `cook <name> <argv...>` dispatch does:
-- bind argv against the declared `__params` and call the body with the single
-- params table. Binding is modelled to the same strictness as the engine
-- (§7.1.2) so a spec cannot pass against an invocation the engine rejects.
function M.invoke_chore(name, argv)
    local reg = chore_registrations[name]
    if not reg then
        error("[cook_stub] no chore registered as '" .. name .. "'")
    end
    argv = argv or {}
    local params = {}
    local i = 1
    local absorbed = false
    for _, p in ipairs((reg.meta or {}).__params or {}) do
        if p.kind == "required" then
            if argv[i] == nil then
                error("[cook_stub] chore '" .. name .. "' requires parameter '" .. p.name .. "'")
            end
            params[p.name] = argv[i]; i = i + 1
        elseif p.kind == "defaulted_string" then
            if argv[i] ~= nil then params[p.name] = argv[i]; i = i + 1
            else params[p.name] = p.default end
        elseif p.kind == "variadic_plus" or p.kind == "variadic_star" then
            local rest = {}
            while argv[i] ~= nil do rest[#rest + 1] = argv[i]; i = i + 1 end
            if p.kind == "variadic_plus" and #rest == 0 then
                error("[cook_stub] chore '" .. name .. "' requires one or more values for '" .. p.name .. "'")
            end
            params[p.name] = rest
            absorbed = true
        else
            error("[cook_stub] unsupported chore param kind '" .. tostring(p.kind) .. "'")
        end
    end
    if not absorbed and argv[i] ~= nil then
        error("[cook_stub] chore '" .. name .. "' takes "
            .. #(((reg.meta or {}).__params) or {}) .. " parameter(s) but "
            .. #argv .. " were supplied")
    end
    return reg.body(params)
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

-- Declare what a glob pattern matches. Values are stored as the engine
-- delivers them: ABSOLUTE paths (see fs.glob's contract), so specs exercise
-- the same normalisation a real run does.
function M.set_glob(pattern, paths)
    glob_results[pattern] = paths
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

-- CS-0161: names passed to cook.dep_order, in call order. This is the channel
-- `links` uses now — it forces the referent's body exactly as require_recipe
-- did, but records a per-unit edge instead of a whole-recipe one.
function M.dep_order_edges()
    return dep_order_edges_list
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
        -- CS-0161: cook.import forces the referent's body when called from
        -- inside a recipe body, so an unknown recipe name surfaces the
        -- forcer's error here rather than degrading to nil. The stub has no
        -- body driver to re-enter, so it models the validation half only:
        -- known name -> whatever it has exported so far (possibly nil);
        -- unknown name -> the same hard error the engine raises.
        import = function(name)
            -- Already exported => the engine skips the forcer entirely and
            -- returns the stored value. Model that first, so a spec that
            -- seeds the export store directly needs no recipe registration.
            local exported = export_store[name]
            if exported ~= nil then return exported end
            if not known_recipe_names[name] then
                error("[cook_stub] cook.import: unknown recipe '" .. name .. "'")
            end
            return nil
        end,
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
        dep_order = function(name)
            if not known_recipe_names[name] then
                error("[cook_stub] cook.dep_order: unknown recipe '" .. name .. "'")
            end
            dep_order_edges_list[#dep_order_edges_list + 1] = name
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
        -- CS-0176 §22.12. The namespace rule is enforced here at the same
        -- strictness as the engine, against cook_cc's identity (this stub is
        -- cook_cc's, as its src searcher above already assumes): a spec must
        -- not be able to green a chore name the engine would reject.
        chore = function(name, meta, body)
            if type(body) ~= "function" then
                error("[cook_stub] cook.chore requires a body function", 2)
            end
            local prefix = name:match("^([^.]+)%.")
            if not prefix or not name:find("%.") then
                error("[cook_stub] cook.chore: '" .. name .. "' must be namespaced (try 'cc." .. name .. "')")
            end
            if prefix ~= "cc" and prefix ~= "cook_cc" then
                error("[cook_stub] cook.chore: '" .. name .. "' claims namespace '" .. prefix
                    .. "', but module 'cook_cc' may only register under 'cc' or 'cook_cc'")
            end
            if chore_registrations[name] then
                error("[cook_stub] cook.chore: duplicate registration of '" .. name .. "'")
            end
            local reg = { name = name, meta = meta or {}, body = body }
            chore_registrations[name] = reg
            chore_registrations[#chore_registrations + 1] = reg
        end,
        -- CS-0179 §22.13. Failure is total: a request the engine could not
        -- locate raises and leaves the file untouched, so the stub raises too
        -- rather than answering nil and letting a verb spec pass on an edit
        -- that would have aborted the real run.
        cookfile = {
            append = function(path, text)
                local source = vfiles[path]
                if source == nil then
                    error("[cook_stub] cook.cookfile.append: " .. path .. ": no such file")
                end
                local trimmed = source:gsub("%s+$", "")
                local body = text:gsub("%s+$", "")
                vfiles[path] = (trimmed == "") and (body .. "\n") or (trimmed .. "\n\n" .. body .. "\n")
                return true
            end,
            find_call = function(path, recipe)
                if vfiles[path] == nil then
                    error("[cook_stub] cook.cookfile.find_call: " .. path .. ": no such file")
                end
                return module_calls[recipe]
            end,
            -- Recorded, not simulated. The engine's splice is a byte-preserving
            -- edit inside a located call span, and a Lua re-implementation of
            -- that here would be a second opinion about the hard part rather
            -- than a stand-in for it. What the stub CAN model faithfully is
            -- when the call fails: no such file, no module call in that
            -- recipe, no such field in its text.
            splice_field = function(path, recipe, field, entry)
                if vfiles[path] == nil then
                    error("[cook_stub] cook.cookfile.splice_field: " .. path .. ": no such file")
                end
                local call = module_calls[recipe]
                if not call then
                    error("[cook_stub] cook.cookfile.splice_field: no module call in recipe '" .. recipe .. "'")
                end
                if not (call.text or ""):find(field .. "%s*=%s*{") then
                    error("[cook_stub] cook.cookfile.splice_field: no field '" .. field
                        .. "' in the module call in recipe '" .. recipe .. "'")
                end
                splices[#splices + 1] =
                    { path = path, recipe = recipe, field = field, entry = entry }
                return true
            end,
        },
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
            if vfiles[p] ~= nil or vdirs[p] then return true end
            -- A directory exists once something is in it, as it does on a real
            -- filesystem — `fs.exists` is `Path::exists`, which is true for a
            -- directory. Without this a verb's "is this path already taken?"
            -- guard would be untestable.
            local prefix = p:gsub("/$", "") .. "/"
            for f in pairs(vfiles) do
                if f:sub(1, #prefix) == prefix then return true end
            end
            for d in pairs(vdirs) do
                if d:sub(1, #prefix) == prefix then return true end
            end
            if file_exists_set[p] ~= nil then return file_exists_set[p] end
            local h = sh_handlers["__exists"]
            if h then return h(p) end
            return false
        end,
        read = function(p)
            if vfiles[p] ~= nil then return vfiles[p] end
            local h = sh_handlers["__read"]
            return h and h(p) or ""
        end,
        -- Still logged to added_units, which the codegen specs assert against,
        -- and now also landed in the virtual tree so a later exists/read sees
        -- what was written.
        write   = function(p, content)
            added_units[#added_units + 1] = { kind = "fs.write", path = p, content = content }
            vfiles[p] = content
        end,
        mkdir_p = function(p) vdirs[p] = true end,
        glob    = function(pattern) return glob_results[pattern] or {} end,
    }

    _G.path = {
        stem = function(p) return p:match("([^/]+)%.[^.]+$") end,
        dir  = function(p) return p:match("(.+)/[^/]+$") or "." end,
    }
end

return M
