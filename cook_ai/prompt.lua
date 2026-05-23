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

function M.emit(opts)
    error("[cook_ai.prompt] emit() filled in by Task 6", 2)
end

return M
