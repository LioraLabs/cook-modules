-- pnpm.find — cc.find-style locator for JS dev tools.
--
-- Strategies, in order: project-registered finder, `node_modules/.bin/<tool>`,
-- PATH. The result is a sigil record exposing `path` and `found`,
-- consumable from recipe bodies via `$<pnpm:find:<tool>.path>`.
--
-- v0.1 keeps this small. cc.find's pkg-config / cmake-compat strategy
-- stack is borrowed only as a structural model.

local M = {}

M._registry   = M._registry   or {}     -- name -> custom finder fn
M._registered = M._registered or {}     -- probe-key -> true

local function sigil_record(name)
    local fields = { "path", "version", "found", "tried" }
    local backing = {}
    for _, f in ipairs(fields) do
        backing[f] = string.format("$<pnpm:find:%s.%s>", name, f)
    end
    return setmetatable({}, {
        __index = backing,
        __newindex = function(_, k, _)
            error("[pnpm.find] cannot mutate find result; field '" .. tostring(k)
                  .. "' is a probe-sigil placeholder", 2)
        end,
        __pairs = function() return pairs(backing) end,
    })
end

local function produce_body(name, raise_on_miss)
    local raise_block = raise_on_miss and string.format([[
        error("[pnpm.find_or_error] could not locate JS tool '%s' (tried: node_modules/.bin, PATH)")
    ]], name) or [[
        return { path = "", version = "", found = false, tried = tried }
    ]]
    return string.format([[
        local tried = {}
        local function attempt(p)
            tried[#tried+1] = p
            local out = cook.sh("test -x '" .. p .. "' && echo y || echo n")
            return out:match("^y") ~= nil and p or nil
        end

        local local_bin = "node_modules/.bin/%s"
        local resolved = attempt(local_bin)
        if not resolved then
            local out = cook.sh("command -v %s 2>/dev/null")
            local cand = out:match("^(%%S+)")
            if cand then
                tried[#tried+1] = cand
                resolved = cand
            end
        end

        if resolved then
            local v = cook.sh(resolved .. " --version 2>/dev/null"):match("([%%d%%.]+)") or ""
            return { path = resolved, version = v, found = true, tried = tried }
        end
%s
    ]], name, name, raise_block)
end

local function register_find_probe(name, opts, raise_on_miss)
    local key = "pnpm:find:" .. name
    if M._registered[key] then return end
    cook.probe(key, {
        inputs = {
            env   = { "PATH" },
            tools = { name },
        },
        produce = produce_body(name, raise_on_miss),
    })
    M._registered[key] = true
end

function M.register(name, finder)
    if type(finder) ~= "function" then
        error("[pnpm.register_finder] requires a function, got " .. type(finder), 2)
    end
    M._registry[name] = finder
end

function M.find(name, opts)
    register_find_probe(name, opts or {}, false)
    return sigil_record(name)
end

function M.find_or_error(name, opts)
    register_find_probe(name, opts or {}, true)
    return sigil_record(name)
end

return M
