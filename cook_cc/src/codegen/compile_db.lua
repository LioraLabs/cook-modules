-- cook_cc.codegen.compile_db — compile_commands(): queues a post-register finalizer that writes compile_commands.json from target exports
-- domain:  codegen — files cook_cc writes itself
-- effects: cook.on_register_complete, fs.write
local cjson = require("cjson")

local M = {}

-- Per-VM idempotence latch (0.14.0). compile_commands() is a top-level call
-- that queues exactly one post-register finalizer; a second call in the same
-- VM is a no-op. Module-level state, cleared on module reload
-- (package.loaded[...] = nil), same convention as config_header.lua's `state`.
local queued = false

local function is_c(source) return source:match("%.[cC]$") ~= nil end

local function shell_chomp(s) return (s or ""):gsub("%s+$", "") end

local function format_command(src, ci)
    local compiler = ci.compiler or "g++"
    if is_c(src) then
        if compiler:match("g%+%+")    then compiler = "gcc"
        elseif compiler:match("clang") then compiler = "clang"
        else compiler = "cc" end
    end
    local flags = { "-c" }
    if ci.standard and not is_c(src) then
        flags[#flags + 1] = "-std=" .. ci.standard
    end
    for _, inc in ipairs(ci.includes or {}) do flags[#flags + 1] = "-I" .. inc end
    for _, def in ipairs(ci.defines  or {}) do flags[#flags + 1] = "-D" .. def end
    local stem = src:match("([^/]+)%.[^.]+$") or src
    -- Trailing space so spec assertions like " -std=... " match the last token.
    return compiler .. " " .. table.concat(flags, " ") .. " " .. src
        .. " -o build/obj/" .. (ci.target_name or "default") .. "/" .. stem .. ".o "
end

function M.write()
    local targets = require("cook_cc.units.targets")._known()
    if #targets == 0 then
        fs.write("compile_commands.json", "[]\n")
        return
    end
    local wd = shell_chomp(cook.sh("pwd"))
    local entries = {}
    for _, name in ipairs(targets) do
        local info = cook.import(name)
        if info and info.compile_info then
            local ci = info.compile_info
            ci.target_name = name
            for _, src in ipairs(ci.sources or {}) do
                entries[#entries + 1] = {
                    directory = wd,
                    command   = format_command(src, ci),
                    file      = src,
                }
            end
        end
    end
    fs.write("compile_commands.json", cjson.encode(entries) .. "\n")
end

-- 0.14.0: compile_commands() moved OUT of the recipe body and became a
-- top-level call (CS-0149). It queues exactly one cook.on_register_complete
-- finalizer per VM; when the finalizer fires (after ALL recipe bodies have
-- been evaluated) it renders the DB from the full targets._known() snapshot
-- at that time — including targets registered after this call and targets
-- in no link closure of any other target (the base/d3xp "disconnected
-- plugin" case this replaces the manual-ordering-dep form for).
function M.compile_commands()
    local ok = pcall(cook.recipe_name)
    if ok then
        error("[cc.compile_commands] compile_commands() is a top-level call since 0.14.0; "
            .. "move it out of the recipe body (and drop the ordering dep) — the "
            .. "post-register finalizer guarantees completeness", 2)
    end
    if queued then return end
    queued = true
    cook.on_register_complete(M.write)
end

return M
