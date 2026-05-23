-- Minimal cook-engine stub for cook_ai specs. Mirrors cook_pnpm/spec/cook_stub.lua;
-- mocks the cook API (cook.recipe, cook.add_unit, cook.probe, cook.env, cook.tmpfile, ...)
-- that cook_ai exercises across its task suite.

local M = {}

M.probes                  = {}      -- key -> opts (publicly inspectable)
M.units                   = {}      -- list of added units (publicly inspectable)
M.recipe_list             = {}      -- ordered list of { name, opts } pairs
M.fs_files                = {}      -- path -> content (drives fs.glob + fs.read)
local probe_registrations = M.probes
local cache_store         = {}      -- key -> any
local export_store        = {}      -- name -> info
local added_units         = M.units
local recipes             = {}      -- name -> { opts, body_executed }
local recipe_list         = M.recipe_list
local sh_handlers         = {}
local pkg_responses       = {}
local tool_responses      = {}
local file_exists_set     = {}
local file_contents       = {}
local glob_table          = {}      -- pattern -> list of matches (explicit override)
local platform_os         = "linux"

function M.reset()
    for k in pairs(probe_registrations) do probe_registrations[k] = nil end
    for k in pairs(added_units)          do added_units[k]          = nil end
    for k in pairs(recipe_list)          do recipe_list[k]          = nil end
    for k in pairs(M.fs_files)           do M.fs_files[k]           = nil end
    cache_store         = {}
    export_store        = {}
    recipes             = {}
    sh_handlers         = {}
    pkg_responses       = {}
    tool_responses      = {}
    file_exists_set     = {}
    file_contents       = {}
    glob_table          = {}
    platform_os         = "linux"
    -- Clear cook.env so per-test writes don't leak. Without this, specs that
    -- assert on the absence of a key (e.g. provider() without model must NOT
    -- write COOK_AI_MODEL) see stale values from previous tests.
    if _G.cook and _G.cook.env then
        for k in pairs(_G.cook.env) do _G.cook.env[k] = nil end
    end
    -- Clean up temp files emit() writes during register-phase.
    os.execute("rm -rf .cook/tmp/cook_ai 2>/dev/null")
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

-- Helpers for cook_ai prompt-emit specs.
--
-- Convert a glob pattern (with `**` and `*` wildcards) into a list of
-- Lua string patterns. Lua's pattern dialect lacks optional groups, so
-- we expand each `**/` segment into both forms (zero-segment and
-- one-or-more-segments) and return the cartesian product. Bare `**`
-- matches any path (`.*`); `*` matches a run of non-separator chars.
local GLOB_DOUBLE_SLASH = "\1"
local GLOB_DOUBLE       = "\2"
local GLOB_SINGLE       = "\3"

local function escape_lua_pattern_meta(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"))
end

local function glob_to_lua_patterns(g)
    -- Tag the wildcards before escaping.
    local s = g
    s = s:gsub("%*%*/", GLOB_DOUBLE_SLASH)
    s = s:gsub("%*%*",  GLOB_DOUBLE)
    s = s:gsub("%*",    GLOB_SINGLE)
    s = escape_lua_pattern_meta(s)
    s = s:gsub(GLOB_DOUBLE, ".*")
    s = s:gsub(GLOB_SINGLE, "[^/]*")
    -- Expand each `**/` placeholder into two forms: empty, and `.-/`.
    local forms = { s }
    while true do
        local next_forms = {}
        local saw = false
        for _, form in ipairs(forms) do
            if form:find(GLOB_DOUBLE_SLASH, 1, true) then
                saw = true
                next_forms[#next_forms + 1] = form:gsub(GLOB_DOUBLE_SLASH, "", 1)
                next_forms[#next_forms + 1] = form:gsub(GLOB_DOUBLE_SLASH, ".-/", 1)
            else
                next_forms[#next_forms + 1] = form
            end
        end
        forms = next_forms
        if not saw then break end
    end
    for i, f in ipairs(forms) do forms[i] = "^" .. f .. "$" end
    return forms
end

function M.recipes_by_name_prefix(prefix)
    local out = {}
    for _, entry in ipairs(recipe_list) do
        if entry.name:sub(1, #prefix) == prefix then
            out[#out + 1] = entry
        end
    end
    return out
end

function M.list_contains(list, value)
    if type(list) ~= "table" then return false end
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

-- Read each file path in unit.inputs from the real filesystem and return
-- the first one whose contents contain `needle`. cook_ai.emit() writes
-- the system/user templates to .cook/tmp/cook_ai/<hash>/ during register,
-- so these files exist on disk and the spec can verify cache-key
-- contributions.
function M.find_input_with_content(unit, needle)
    if not unit or type(unit.inputs) ~= "table" then return nil end
    for _, path in ipairs(unit.inputs) do
        local f = io.open(path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content and content:find(needle, 1, true) then
                return path
            end
        end
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
        probe = function(key, opts)
            if probe_registrations[key] ~= nil then
                error("[cook_stub] duplicate cook.probe key '" .. key .. "'")
            end
            probe_registrations[key] = opts
        end,
        export = function(name, info) export_store[name] = info end,
        import = function(name) return export_store[name] end,
        add_unit = function(u) added_units[#added_units + 1] = u end,
        recipe = function(name, opts_or_body, body_fn)
            -- Accept both cook.recipe(name, body_fn) and cook.recipe(name, opts, body_fn).
            local opts, body
            if type(opts_or_body) == "function" then
                opts, body = {}, opts_or_body
            else
                opts, body = opts_or_body, body_fn
            end
            recipes[name] = { opts = opts, body_executed = false }
            recipe_list[#recipe_list + 1] = { name = name, opts = opts }
            body()
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
            if M.fs_files[p] ~= nil then return true end
            return false
        end,
        read = function(p)
            if M.fs_files[p] ~= nil then return M.fs_files[p] end
            return file_contents[p] or ""
        end,
        write = function(p, content)
            added_units[#added_units + 1] = { kind = "fs.write", path = p, content = content }
        end,
        mkdir_p = function() end,
        glob = function(pattern)
            -- Explicit overrides win (legacy cook_pnpm pattern).
            if glob_table[pattern] then return glob_table[pattern] end
            -- Otherwise match against fs_files using glob semantics.
            local lua_pats = glob_to_lua_patterns(pattern)
            local seen, out = {}, {}
            for path in pairs(M.fs_files) do
                for _, lp in ipairs(lua_pats) do
                    if path:match(lp) and not seen[path] then
                        seen[path] = true
                        out[#out + 1] = path
                        break
                    end
                end
            end
            table.sort(out)
            return out
        end,
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
