-- cook_cc.codegen.config_header — config_header(): synthesizes a support recipe whose unit renders a config header from a template
-- domain:  codegen — files cook_cc writes itself
-- effects: cook.recipe, cook.add_unit
local M = {}

-- 0.13.0: module-level state. config_header() is now a standalone top-level
-- call (moved out of cook_cc.defaults({ config_header = ... })). state.headers
-- lets a later task's target-makers auto-join generated header output dirs
-- onto include paths and declare the generated header file as a compile-unit
-- input. state.target_registered lets us loudly reject a config_header() call
-- that arrives after a cc target has already been registered.
local state = { headers = {}, target_registered = false }

function M.mark_target_registered() state.target_registered = true end
function M.get_headers()            return state.headers            end

local function value_to_lua_literal(v)
    local t = type(v)
    if t == "string" then
        local probe = v:match("^%$<(cc:check:.+)>$")
        if probe then
            -- Check sigil — emit a typed cook.probes.get read for the
            -- execute-phase body. The probe key ALSO goes on the unit's
            -- `probes` list (the DAG edge + fingerprint fold); reading the
            -- value in Lua keeps its type: a boolean stays a boolean, a
            -- sizeof stays a number, and a string check (endian) stays a
            -- string. The old shell path rendered the value as bare text
            -- inside a Lua table literal, where any string value produced
            -- an invalid literal.
            return 'cook.probes.get("' .. probe .. '")', probe
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
-- The recipe carries `origin = "cook_cc.codegen.config_header"` metadata so `cook
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
    -- The unit is a Lua-code unit (§22.1): the body require()s the renderer
    -- by MODULE NAME on the worker VM, exactly as the cc:check produce
    -- bodies require _check_helpers. The previous shape shelled out to
    -- `lua <package.searchpath(...)>`, which baked the renderer's ABSOLUTE
    -- path into the command string — a cache-key determinant — so the unit
    -- re-keyed whenever the workspace directory moved (CS-0196 made every
    -- other cook_cc unit portable) and it silently required a host `lua`
    -- on PATH.
    local body = "local r = require(\"cook_cc.codegen.config_header_renderer\")\n"
        .. "r.render(" .. string.format("%q", template)
        .. ", " .. string.format("%q", output)
        .. ", " .. vars_literal .. ")"
    local recipe = recipe_name_for(output)
    cook.recipe(recipe, { origin = "cook_cc.codegen.config_header" }, function()
        cook.add_unit({
            inputs   = { template },
            output   = output,
            lua_code = body,
            probes   = probes,
        })
    end)
    local outdir = path.dir(output)
    if outdir == "" or outdir == "." then outdir = nil end
    -- Record the support-recipe name alongside the output so
    -- target-makers can declare a recipe-ordering edge to it (cook.require_recipe).
    -- Without that edge a targeted build (e.g. `cook game`) never schedules the
    -- generator and the compile fails on a missing config.h; the generated-header
    -- file-input edge alone does not pull an otherwise-unreferenced recipe in.
    state.headers[#state.headers + 1] = { output = output, outdir = outdir, recipe = recipe }
    return recipe
end

setmetatable(M, { __call = function(_, opts) return M.config_header(opts) end })

return M
