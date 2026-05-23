local M = {}

function M._normalize_glob(g)
    if g == "**" then return "**/*" end
    if g:sub(-3) == "/**" then return g .. "/*" end
    return g
end

local function basename(p) return (p:match("([^/]+)$")) end
local function dirname(p)
    local d = p:match("^(.*)/[^/]+$"); return d or ""
end
local function split_ext(name)
    local stem, ext = name:match("^(.*)%.([^.]+)$")
    if stem then return stem, ext end
    return name, ""
end

function M._resolve_output(input_path, output_spec)
    if type(output_spec) == "function" then
        local out = output_spec(input_path)
        if not out or out == "" then
            error("[cook_ai] output function returned empty for " .. input_path, 2)
        end
        return out
    end
    if type(output_spec) ~= "string" then
        error("[cook_ai] output must be a string template or function, got " .. type(output_spec), 2)
    end
    local name       = basename(input_path)
    local stem, ext  = split_ext(name)
    local dir        = dirname(input_path)
    local subs = { path = input_path, stem = stem, ext = ext, dir = dir }
    return (output_spec:gsub("%{(%w+)%}", function(k)
        if subs[k] == nil then
            error("[cook_ai] unknown placeholder {" .. k .. "} in output template", 3)
        end
        return subs[k]
    end))
end

function M._resolve_templates(opts, input_path, content)
    local function resolve(field)
        if type(field) == "function" then return field(input_path, content) end
        return field
    end
    local user   = resolve(opts.user)
    local system = resolve(opts.system)
    if user == nil or system == nil then return nil end
    return { user = user, system = system }
end

local cjson = require("cjson.safe")

local function sha256_short(s)
    -- cook exposes a hash helper; fall back to system sha256sum.
    if cook and cook.hash_str then return cook.hash_str(s):sub(1, 16) end
    local tmp = os.tmpname()
    local f = io.open(tmp, "w")
    f:write(s)
    f:close()
    local p = io.popen("sha256sum < " .. tmp)
    local line = p:read("*l") or ""
    p:close()
    os.remove(tmp)
    return (line:match("^(%x+)") or "0000000000000000"):sub(1, 16)
end

local function ensure_dir(p)
    if not p or p == "" then return end
    os.execute("mkdir -p '" .. p:gsub("'", "'\\''") .. "'")
end

local function write_tmp(path, contents)
    ensure_dir(path:match("^(.*)/[^/]+$") or ".")
    local f, err = io.open(path, "w")
    if not f then error("[cook_ai] write " .. path .. ": " .. tostring(err), 2) end
    f:write(contents)
    f:close()
end

local function sh_quote(s) return "'" .. s:gsub("'", [['"'"']]) .. "'" end

local function emit_unit(opts, recipe_id, input_path, resolved, output_path, cfg)
    local model = opts.model or cfg.model
    local recipe_hash = sha256_short(recipe_id)
    local tmp_dir = ".cook/tmp/cook_ai/" .. recipe_hash
    local sys_path = tmp_dir .. "/system.txt"
    local usr_path = tmp_dir .. "/user.txt"
    local payload_tmp = tmp_dir .. "/payload.json"

    write_tmp(sys_path, resolved.system)
    write_tmp(usr_path, resolved.user)

    local rf_json = ""
    if opts.response_format then
        rf_json = " --response-format-json " .. sh_quote(cjson.encode(opts.response_format))
    end
    local tools_json = ""
    if opts.tools then
        tools_json = " --tools-json " .. sh_quote(cjson.encode(opts.tools))
    end
    local max_tokens = opts.max_tokens and (" --max-tokens " .. tostring(opts.max_tokens)) or ""
    local temperature = opts.temperature and (" --temperature " .. tostring(opts.temperature)) or ""

    local command = string.format(
        "cook_ai_call --provider %s --model %s --system-file %s --user-file %s --output %s --payload-tmp %s%s%s%s%s",
        cfg.provider, model, sys_path, usr_path, output_path, payload_tmp,
        max_tokens, temperature, rf_json, tools_json)

    cook.add_unit({
        inputs   = { input_path, sys_path, usr_path },
        outputs  = { output_path },
        command  = command,
        requires = { "ai:provider:" .. cfg.provider .. ":" .. model },
    })
end

function M.emit(opts)
    local state = require("cook_ai.state")
    local cfg = state.get_provider()
    if not cfg then
        error("[cook_ai] cook_ai.prompt called before cook_ai.provider — configure provider first", 2)
    end
    assert(type(opts) == "table", "[cook_ai] prompt(opts) requires a table")
    assert(opts.name, "[cook_ai] prompt.name is required")
    assert(opts.inputs and #opts.inputs > 0, "[cook_ai] prompt.inputs must be a non-empty list")
    assert(opts.output, "[cook_ai] prompt.output is required")
    assert(opts.user,   "[cook_ai] prompt.user is required")
    assert(opts.system, "[cook_ai] prompt.system is required")

    -- Expand inputs globs against the project root via fs.glob; collect
    -- the union (dedup via a set), then walk in sorted order so recipe
    -- registration is deterministic.
    local matched = {}
    for _, g in ipairs(opts.inputs) do
        for _, p in ipairs(fs.glob(M._normalize_glob(g))) do
            matched[p] = true
        end
    end
    local paths = {}
    for p in pairs(matched) do paths[#paths + 1] = p end
    table.sort(paths)

    -- Lazily register the model probe for any per-call model override so
    -- cache-keys downstream of this recipe pick up the bumped model id.
    if opts.model and opts.model ~= cfg.model then
        require("cook_ai.probes.model").register(cfg.provider, opts.model)
    end

    for _, input_path in ipairs(paths) do
        local content = fs.read(input_path)
        local resolved = M._resolve_templates(opts, input_path, content)
        if resolved then
            local out_path = M._resolve_output(input_path, opts.output)
            local recipe_id = opts.name .. "/" .. input_path
            cook.recipe(recipe_id, {}, function()
                emit_unit(opts, recipe_id, input_path, resolved, out_path, cfg)
            end)
        end
    end
end

return M
