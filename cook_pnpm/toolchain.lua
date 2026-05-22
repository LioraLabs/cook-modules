-- pnpm + node toolchain probe.
--
-- Registers `pnpm:toolchain:<pin>` where <pin> is the pm= string (e.g.
-- `pnpm@9`) or "auto" when no pin is set. Resolves `{ node, pnpm }` to
-- the absolute paths on the host. Mirrors cook_cc/toolchain.lua's
-- ensure_probe_registered idiom.

local M = {}

local state = {
    pin_pm     = nil,           -- e.g. "pnpm@9"
    pin_node   = nil,           -- e.g. "^20.11"
    probe_registered = {},      -- set: key -> true
}

local function sanitize(s)
    -- Sigil resolver only accepts [A-Za-z0-9_+-] in probe-key segments
    -- (cf. cook_cc-0.6.1's lesson: a '.' in `has_header("stdint.h")`
    -- was being mis-parsed as $<key.field>). pnpm pin strings like
    -- "pnpm@9" contain '@', so collapse anything outside the allowed
    -- alphabet to '-'.
    return (s:gsub("[^A-Za-z0-9_%+%-]", "-"))
end

local function probe_key()
    return "pnpm:toolchain:" .. sanitize(state.pin_pm or "auto")
end

local function produce_body(pin_pm, pin_node)
    local pm_literal   = pin_pm   and string.format("%q", pin_pm)   or "nil"
    local node_literal = pin_node and string.format("%q", pin_node) or "nil"
    return string.format([[
        local pin_pm   = %s
        local pin_node = %s

        local function which(tool)
            local out = cook.sh("command -v " .. tool .. " 2>/dev/null")
            return out:match("^(%%S+)")
        end

        local node = which("node")
        if not node then
            error("[pnpm.toolchain] node not on PATH")
        end

        local pnpm_bin
        if pin_pm then
            -- "pnpm@9" -> use the binary named `pnpm` on PATH (corepack
            -- usually selects the right version per the package.json
            -- `packageManager` field). Honour PNPM env override.
            pnpm_bin = which("pnpm")
        else
            pnpm_bin = which("pnpm")
        end
        if not pnpm_bin then
            local hint = pin_pm and (" (need pm = '" .. pin_pm .. "')") or ""
            error("[pnpm.toolchain] pnpm not on PATH" .. hint)
        end

        local node_version = cook.sh(node .. " --version 2>/dev/null"):match("v?([%%d%%.]+)") or "unknown"
        local pnpm_version = cook.sh(pnpm_bin .. " --version 2>/dev/null"):match("([%%d%%.]+)") or "unknown"

        return {
            node            = node,
            node_version    = node_version,
            pnpm            = pnpm_bin,
            pnpm_version    = pnpm_version,
        }
    ]], pm_literal, node_literal)
end

function M.ensure_probe_registered()
    local key = probe_key()
    if state.probe_registered[key] then return end
    cook.probe(key, {
        inputs = { tools = { "node", "pnpm" } },
        produce = produce_body(state.pin_pm, state.pin_node),
    })
    state.probe_registered[key] = true
end

function M.get_probe_key()
    return probe_key()
end

function M.set(opts)
    opts = opts or {}
    if opts.pm   then state.pin_pm   = opts.pm   end
    if opts.node then state.pin_node = opts.node end
end

function M.snapshot()
    return { pin_pm = state.pin_pm, pin_node = state.pin_node }
end

return M
