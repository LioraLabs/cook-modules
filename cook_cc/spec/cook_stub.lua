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

-- Does `source` carry a top-level declaration of `recipe`? The engine locates
-- one before it will answer anything about a recipe, so the stub does too.
local function declares(source, recipe)
    for text in ((source or "") .. "\n"):gmatch("([^\n]*)\n") do
        for _, keyword in ipairs({ "recipe", "chore" }) do
            local rest = text:match("^" .. keyword .. "[ \t\"](.*)$")
            if rest then
                if text:sub(#keyword + 1, #keyword + 1) == '"' then rest = '"' .. rest end
                local name = rest:match('^%s*"([^"]*)"') or rest:match("^%s*([^%s:]+)")
                if name == recipe then return true end
            end
        end
    end
    return false
end

-- One lexical reading of Lua, for the three questions below.
--
-- The engine settled this shape the hard way: `cook-cookfile` asked "where
-- does a string or comment end" in three places at three fidelities, spliced
-- an entry into the middle of a `[[a}b]]`, and the answer went down to
-- `cook_contracts::lua_scan` (COOK-403, CS-0208). This file had grown the same
-- triplication and would have inherited the same defect, so it does the same
-- thing: one scanner, three consumers.
--
-- Returns the index just PAST the string or comment starting at `i`, or nil
-- when `i` is ordinary code. All six spellings, because the stub has to be as
-- strict as the engine and the engine knows all six: `"…"`, `'…'`, `[[…]]`,
-- `[=[…]=]` at any level, `--` to end of line, and `--[[…]]` at any level,
-- which ends at its bracket and NOT at the end of its line.
local function long_bracket_end(text, open)
    local level = text:match("^%[(=*)%[", open)
    if not level then return nil end
    local close = text:find("]" .. level .. "]", open + #level + 2, true)
    return close and (close + #level + 2) or (#text + 1)
end

local function skip_non_code(text, i)
    local c = text:sub(i, i)
    if c == '"' or c == "'" then
        local j = i + 1
        while j <= #text do
            local d = text:sub(j, j)
            if d == "\\" then j = j + 2
            elseif d == c then return j + 1
            else j = j + 1 end
        end
        return #text + 1
    end
    if c == "[" then return long_bracket_end(text, i) end
    if text:sub(i, i + 1) == "--" then
        local long = long_bracket_end(text, i + 2)
        if long then return long end
        local nl = text:find("\n", i + 2, true)
        return nl and (nl + 1) or (#text + 1)
    end
    return nil
end

local function is_ident_byte(c)
    return c ~= "" and c:match("[%w_]") ~= nil
end

local function skip_space(text, i)
    local at = text:find("[^%s]", i)
    return at or (#text + 1)
end

-- The bytes between the braces of the list that opens at `open`, or nil when
-- nothing closes it.
local function list_interior(text, open)
    local i, depth = open, 0
    while i <= #text do
        local past = skip_non_code(text, i)
        if past then
            i = past
        else
            local c = text:sub(i, i)
            if c == "{" then
                depth = depth + 1
            elseif c == "}" then
                depth = depth - 1
                if depth == 0 then return text:sub(open + 1, i - 1) end
            end
            i = i + 1
        end
    end
    return nil
end

-- A list interior split into its entries, as the engine's `field_entries`
-- reports them: verbatim, in order, trimmed of surrounding whitespace and of
-- comments at either end, with a separator inside a nested table, a call, a
-- string or a comment not counting as one. Lua admits `;` between entries as
-- well as `,`, and so does the engine.
local function split_entries(interior)
    local out, cuts = {}, {}
    local i, depth = 1, 0
    while i <= #interior do
        local past = skip_non_code(interior, i)
        if past then
            i = past
        else
            local c = interior:sub(i, i)
            if c == "{" or c == "(" or c == "[" then depth = depth + 1
            elseif c == "}" or c == ")" or c == "]" then depth = depth - 1
            elseif depth == 0 and (c == "," or c == ";") then cuts[#cuts + 1] = i end
            i = i + 1
        end
    end
    cuts[#cuts + 1] = #interior + 1

    local from = 1
    for _, cut in ipairs(cuts) do
        local slice = interior:sub(from, cut - 1)
        from = cut + 1
        -- Trim to the code: an entry preceded or followed by a comment is the
        -- entry, not the comment.
        local first, last = nil, nil
        local j = 1
        while j <= #slice do
            local past = skip_non_code(slice, j)
            local is_comment = past and slice:sub(j, j + 1) == "--"
            if past then
                if not is_comment then
                    first = first or j
                    last = past - 1
                end
                j = past
            else
                if not slice:sub(j, j):match("%s") then
                    first = first or j
                    last = j
                end
                j = j + 1
            end
        end
        if first then out[#out + 1] = slice:sub(first, last) end
    end
    return out
end

-- Is `field` a key at the TOP LEVEL of the call's table argument, and is its
-- value a `{ ... }` list? Returns `found, is_list, interior` — the interior
-- being the bytes between the list's braces, for `field_entries`.
--
-- §22.13 makes three specific misses normative — a `field =` inside a comment,
-- inside a string, or as the key of a NESTED table must not match — and calls
-- out the nested case as the one whose result still parses and still looks
-- like the file the author wrote. A plain `text:find(field .. "%s*=%s*{")`
-- accepts all three, which would green a `cc.link` or `cc.need` the engine
-- rejects. This tracks lexical state and brace depth so it does not.
--
-- The key is compared byte for byte rather than as a Lua pattern. `field` is
-- caller data: a name containing `-`, `.` or `%` would match something else as
-- a pattern, and an EMPTY one matches at every position — which is how the
-- engine's own `find_field_key` came to have an explicit guard against it.
--
-- It is a locator, not an editor: where the entry would land is the engine's
-- business (`splice_field` is recorded, not simulated) and no Lua here tries
-- to reproduce it.
local function top_level_field(text, field)
    local i, depth = 1, 0
    while i <= #text do
        local past = skip_non_code(text, i)
        if past then
            i = past
        else
            local c = text:sub(i, i)
            if c == "{" then
                depth = depth + 1
            elseif c == "}" then
                depth = depth - 1
            elseif depth == 1 and field ~= "" and text:sub(i, i + #field - 1) == field
                and not is_ident_byte(text:sub(i - 1, i - 1))
                and not is_ident_byte(text:sub(i + #field, i + #field)) then
                -- Brace depth only, so `f({ … })` and `f{ … }` both put the
                -- maker's own options at depth 1 and a nested table's keys at 2.
                local eq = skip_space(text, i + #field)
                if text:sub(eq, eq) == "=" and text:sub(eq + 1, eq + 1) ~= "=" then
                    local value = skip_space(text, eq + 1)
                    if text:sub(value, value) == "{" then
                        return true, true, list_interior(text, value)
                    end
                    return true, false, nil
                end
            end
            i = i + 1
        end
    end
    return false, false, nil
end

-- Does the call's argument table already bind `field` in the bracketed form?
--
-- §22.13 leaves `["links"] = { … }` outside what a field scan must match, and
-- the engine refuses to CREATE over one rather than reporting it absent: the
-- two spellings are one key, so the created field would win and the author's
-- value would be gone (CS-0221).
local function bracketed_key(text, field)
    local i, depth = 1, 0
    while i <= #text do
        local past = skip_non_code(text, i)
        local c = text:sub(i, i)
        if past then
            if depth == 1 and (c == '"' or c == "'") then
                local quoted = text:sub(i + 1, past - 2)
                local before = text:find("[^%s]", 1) and text:sub(1, i - 1):match("([^%s])%s*$")
                local after = skip_space(text, past)
                if quoted == field and before == "[" and text:sub(after, after) == "]" then
                    local eq = skip_space(text, after + 1)
                    if text:sub(eq, eq) == "=" and text:sub(eq + 1, eq + 1) ~= "=" then
                        return true
                    end
                end
            end
            i = past
        else
            if c == "{" then depth = depth + 1
            elseif c == "}" then depth = depth - 1 end
            i = i + 1
        end
    end
    return false
end

-- Does the call pass a `{ … }` argument table at all? A created field has
-- nowhere to go otherwise, and the engine refuses rather than wrapping
-- whatever the call was passed (CS-0221).
local function has_argument_table(text)
    local i = 1
    while i <= #text do
        local past = skip_non_code(text, i)
        if past then
            i = past
        elseif text:sub(i, i) == "{" then
            return true
        else
            i = i + 1
        end
    end
    return false
end

-- Lua reserved words, plus the identifier rule: `end = { … }` and ` = { … }`
-- are not table keys, and the engine refuses to write either (CS-0221).
local LUA_RESERVED = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
    ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true,
    ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true,
    ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true,
}

local function writable_key(field)
    return type(field) == "string" and field:match("^[%a_][%w_]*$") ~= nil
        and not LUA_RESERVED[field]
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
            -- The engine's signature is (String, LuaTable, LuaFunction). A nil
            -- meta is not "no metadata", it is a load-time type error — and a
            -- module that raises at load breaks every build of every project
            -- that uses it, not just that one verb.
            if type(meta) ~= "table" then
                error("[cook_stub] cook.chore: metadata must be a table, got " .. type(meta))
            end
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
            local reg = { name = name, meta = meta, body = body }
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
                local source = vfiles[path]
                if source == nil then
                    error("[cook_stub] cook.cookfile.find_call: " .. path .. ": no such file")
                end
                -- The engine locates the recipe's declaration first and maps
                -- RecipeNotFound to nil, so a declared module call for an
                -- undeclared recipe is not a thing a spec should be able to
                -- arrange.
                if not declares(source, recipe) then return nil end
                return module_calls[recipe]
            end,
            -- Recorded, not simulated. The engine's splice is a byte-preserving
            -- edit inside a located call span, and a Lua re-implementation of
            -- that here would be a second opinion about the hard part rather
            -- than a stand-in for it. What the stub CAN model faithfully is
            -- when the call fails: no such file, no module call in that
            -- recipe, no such field in its text.
            splice_field = function(path, recipe, field, entry, options)
                -- CS-0221: the fifth argument is the policy for an absent
                -- field, and the engine is strict about it — an unrecognised
                -- key would otherwise mean "refuse" silently, and the verb
                -- would report the engine declining an edit it was sure it
                -- had asked for. A stub more forgiving here greens exactly
                -- the typo it exists to catch.
                local create = false
                if options ~= nil then
                    if type(options) ~= "table" then
                        error("[cook_stub] cook.cookfile.splice_field: options must be a table")
                    end
                    for key, value in pairs(options) do
                        if key ~= "create_if_absent" then
                            error("[cook_stub] cook.cookfile.splice_field: unknown option '"
                                .. tostring(key) .. "'; the options are: create_if_absent")
                        end
                        if type(value) ~= "boolean" then
                            error("[cook_stub] cook.cookfile.splice_field: options.create_if_absent must be a boolean")
                        end
                        create = value
                    end
                end
                if vfiles[path] == nil then
                    error("[cook_stub] cook.cookfile.splice_field: " .. path .. ": no such file")
                end
                local call = module_calls[recipe]
                if not call then
                    error("[cook_stub] cook.cookfile.splice_field: no module call in recipe '" .. recipe .. "'")
                end
                local text = call.text or ""
                local found, is_list = top_level_field(text, field)
                if not found and not create then
                    error("[cook_stub] cook.cookfile.splice_field: no field '" .. field
                        .. "' in the module call in recipe '" .. recipe .. "'")
                end
                -- Creating relaxes the absent case and nothing else: a field
                -- that IS there and is not a list is still refused, because
                -- writing a second key of that name would discard the
                -- author's value.
                if found and not is_list then
                    error("[cook_stub] cook.cookfile.splice_field: field '" .. field
                        .. "' in recipe '" .. recipe .. "' is not a { ... } list")
                end
                -- The three other refusals CS-0221 attached to the create
                -- path. Each is a case where the stub answering "created"
                -- would green a verb the engine stops, and two of them are
                -- cases where the ENGINE's refusal is the only thing standing
                -- between the author and a Cookfile that no longer loads.
                if not found then
                    if not writable_key(field) then
                        error("[cook_stub] cook.cookfile.splice_field: '" .. tostring(field)
                            .. "' cannot be written as a table key")
                    end
                    if bracketed_key(text, field) then
                        error("[cook_stub] cook.cookfile.splice_field: recipe '" .. recipe
                            .. "' writes '" .. field .. "' as [\"" .. field .. "\"]")
                    end
                    if not has_argument_table(text) then
                        error("[cook_stub] cook.cookfile.splice_field: the call in recipe '"
                            .. recipe .. "' has no { ... } argument table")
                    end
                end
                splices[#splices + 1] = { path = path, recipe = recipe, field = field,
                    entry = entry, created = not found }
                return true
            end,
            -- CS-0221. Read-only, and unlike `splice_field` it can be
            -- modelled rather than recorded: what comes back is a function of
            -- the call text the spec declared, not of where bytes would land.
            field_entries = function(path, recipe, field)
                if vfiles[path] == nil then
                    error("[cook_stub] cook.cookfile.field_entries: " .. path .. ": no such file")
                end
                if not declares(vfiles[path], recipe) then return nil end
                local call = module_calls[recipe]
                if not call then return nil end
                local found, is_list, interior = top_level_field(call.text or "", field)
                if not found then return nil end
                if not is_list then
                    error("[cook_stub] cook.cookfile.field_entries: field '" .. field
                        .. "' in recipe '" .. recipe .. "' is not a { ... } list")
                end
                return split_entries(interior or "")
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
        -- CS-0079 §25.8: the argument is a pattern or a sequence of patterns,
        -- and the array form globs each in call order and concatenates the
        -- per-pattern blocks in that order. Modelled rather than collapsed to
        -- the single-string form because the order is observable — a caller
        -- that hands the engine an array gets a result this stub must be able
        -- to reproduce — and because a non-sequence argument is an error the
        -- engine raises, not a miss it tolerates.
        glob    = function(pattern)
            if type(pattern) == "string" then return glob_results[pattern] or {} end
            if type(pattern) ~= "table" then
                error("fs.glob: pattern must be a string or an array of strings", 2)
            end
            local out = {}
            for _, p in ipairs(pattern) do
                if type(p) ~= "string" then
                    error("fs.glob: pattern must be a string or an array of strings", 2)
                end
                for _, hit in ipairs(glob_results[p] or {}) do out[#out + 1] = hit end
            end
            return out
        end,
    }

    _G.path = {
        stem = function(p) return p:match("([^/]+)%.[^.]+$") end,
        dir  = function(p) return p:match("(.+)/[^/]+$") or "." end,
    }
end

return M
