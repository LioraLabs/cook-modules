local M = {}

-- 0.13.0: module-level state. config_header() is now a standalone top-level
-- call (moved out of cook_cc.defaults({ config_header = ... })). state.headers
-- lets a later task's target-makers auto-join generated header output dirs
-- onto include paths and declare the generated header file as a compile-unit
-- input. state.target_registered lets us loudly reject a config_header() call
-- that arrives after a cc target has already been registered.
local state = { headers = {}, target_registered = false }

function M.mark_target_registered() state.target_registered = true end
function M.was_target_registered()  return state.target_registered  end
function M.get_headers()            return state.headers            end

local function renderer_path()
    local p = package.searchpath("cook_cc.config_header_renderer", package.path)
    if not p then
        error("[cc.config_header] cannot locate cook_cc.config_header_renderer on package.path", 2)
    end
    return p
end

local function shell_quote(s)
    -- Single-quote and escape any embedded single quotes.
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

local function value_to_lua_literal(v)
    local t = type(v)
    if t == "string" then
        local probe = v:match("^%$<(cc:check:.+)>$")
        if probe then
            -- Sigil — emit verbatim so the sigil pipeline expands it.
            return v, probe
        end
        return string.format("%q", v), nil
    elseif t == "boolean" or t == "number" then
        return tostring(v), nil
    elseif t == "nil" then
        return "nil", nil
    end
    error("[cc.config_header] unsupported var type: " .. t)
end

local function build_vars_literal(vars)
    local entries = {}
    local probes  = {}
    -- Stable ordering for fingerprint determinism.
    local keys = {}
    for k in pairs(vars) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local lit, probe_key = value_to_lua_literal(vars[k])
        entries[#entries + 1] = k .. " = " .. lit
        if probe_key then probes[#probes + 1] = probe_key end
    end
    return "{ " .. table.concat(entries, ", ") .. " }", probes
end

local function recipe_name_for(output)
    -- Synthesize a stable recipe name from the output path so consumers can
    -- declare a `requires` against it. Sanitize separators / dots into _.
    local sanitized = output:gsub("[/.]", "_")
    return "__cc_config_header__" .. sanitized
end

-- Register a synthetic "support recipe" whose body emits the config-header
-- generation unit. CS-0077 (SHI-222) — the new register_cookfile model keeps
-- the body_slot=None during top-level register-block execution, so
-- cook.add_unit at top level errors "called outside a recipe body". Wrapping
-- in cook.recipe mirrors the other target-makers (cc.bin/lib/shared/archive/
-- headers) and gives the caller a recipe name they can declare a `requires`
-- against:
--
--     local cfg = cc.config_header({ from = template, to = output, vars = {...} })
--     cc.bin("game", { sources = {...}, requires = { cfg } })
--
-- The recipe carries `origin = "cook_cc.config_header"` metadata so `cook
-- list` can annotate it as cook_cc-minted support machinery rather than an
-- author-declared target.
--
-- 0.13.0: config_header() moved OUT of cook_cc.defaults({...}) and became
-- this standalone top-level call. It must be declared before any cc target
-- is registered — later tasks' target-makers rely on state.headers (recorded
-- below) being complete by the time they run.
function M.config_header(opts)
    opts = opts or {}
    if not opts.from or not opts.to then
        error("[cc.config_header] config_header requires both `from` and `to` fields", 2)
    end
    if state.target_registered then
        error("[cc.config_header] config_header declared after a cc target; declare config_header before cc targets", 2)
    end
    local template = opts.from
    local output   = opts.to
    local vars      = opts.vars or {}
    local vars_literal, probes = build_vars_literal(vars)
    local cmd = "lua " .. renderer_path()
        .. " " .. template
        .. " " .. output
        .. " " .. shell_quote(vars_literal)
    local recipe = recipe_name_for(output)
    cook.recipe(recipe, { origin = "cook_cc.config_header" }, function()
        cook.add_unit({
            inputs  = { template },
            output  = output,
            command = cmd,
            probes  = probes,
        })
    end)
    local outdir = path.dir(output)
    if outdir == "" or outdir == "." then outdir = nil end
    state.headers[#state.headers + 1] = { output = output, outdir = outdir }
    return recipe
end

setmetatable(M, { __call = function(_, opts) return M.config_header(opts) end })

return M
