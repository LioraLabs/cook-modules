-- cook_pnpm.toolchain — node/pnpm selection: registers the pnpm:toolchain:<pin> probe, holds the pin state
-- domain:  toolchain — pure resolution: which node, which pnpm, probe identity
-- effects: cook.probe (declares covers), cook.sh (register-time install-dir lookup)
-- std:     §12.7
--
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

-- The toolchain's IDENTITY: { node_version, pnpm_version } read off the
-- path probe above. This is the key minted units SEAL — a `probes`
-- reference only orders and substitutes, it never keys (§22.5.7) — and it
-- is a separate, path-free probe because a resolved path is location, not
-- identity: sealing it would re-key every unit across install locations
-- and machines (the CS-0157 portability rule). Reads the path probe via
-- `requires`, so node/pnpm are still asked once per invocation.
-- Install dir of a tool (`command -v` -> symlink target -> parent of its
-- bin/), or nil. Audit-only input: any failure just yields no entry.
local function install_dir(tool)
    local p = cook.sh("command -v " .. tool .. " 2>/dev/null"):match("^(%S+)")
    if not p then return nil end
    local real = cook.sh("readlink -f '" .. p .. "' 2>/dev/null"):match("^(%S+)")
    local dir = real and real:match("^(.*)/[^/]+$")
    if dir and dir:match("/bin$") then dir = dir:match("^(.*)/bin$") end
    -- Too broad to own (engine refuses these): `/`, a top-level dir, $HOME.
    if not dir or not dir:match("^/[^/]+/.") or dir == os.getenv("HOME") then return nil end
    return dir
end

local function tool_covers()
    local out = {}
    for _, tool in ipairs({ "pnpm", "node" }) do
        out[#out + 1] = install_dir(tool)
    end
    return out
end

function M.ensure_identity_registered()
    M.ensure_probe_registered()
    local tool_key = probe_key()
    local key = tool_key .. ":identity"
    if state.probe_registered[key] then return key end
    cook.probe(key, {
        covers = tool_covers(),
        inputs = { requires = { tool_key } },
        produce = string.format([[
            local t = cook.probes.get(%q)
            return { node_version = t.node_version, pnpm_version = t.pnpm_version }
        ]], tool_key),
    })
    state.probe_registered[key] = true
    return key
end

-- The HOST the toolchain installs for: node's `<platform>-<arch>`, plus
-- `-gnu` / `-musl` on linux — the axes pnpm selects native optional deps
-- on (esbuild, oxlint ship linux-x64-gnu and linux-x64-musl). Cook infers
-- no machine identity (§17.1.1), so one host's artifact or verdict would
-- otherwise serve another; this declared probe, sealed on every minted
-- unit, keeps them apart. Path-free and pin-free: it asks PATH's node
-- directly — the same node the toolchain probe resolves; follow the
-- toolchain if that ever picks another — so it needs no `requires` and
-- does not bind to whichever pin was current when it first registered.
-- Registered by seals(), never from init(): init() also runs on
-- execute-phase VMs, where cook.probe raises. node's stderr is not
-- redirected: cook.sh attributes it to the probe unit, so a crash
-- reports why (CS-0188).
local HOST_KEY = "pnpm:host"

local HOST_JS = "process.platform + '-' + process.arch + (process.platform === 'linux'"
    .. " ? (process.report.getReport().header.glibcVersionRuntime ? '-gnu' : '-musl') : '')"

local HOST_BODY = string.format([[
    local out = cook.sh(%q)
    local platform, arch, libc = out:match("^(%%w+)%%-([%%w_]+)%%-?(%%a*)%%s*$")
    local libc_ok = platform == "linux" and (libc == "gnu" or libc == "musl")
        or platform ~= "linux" and libc == ""
    if not (platform and libc_ok) then
        error("[pnpm.toolchain] could not read the host from node: " .. out)
    end
    return { host = platform .. "-" .. arch .. (libc ~= "" and ("-" .. libc) or "") }
]], 'node -p "' .. HOST_JS .. '"')

function M.ensure_host_registered()
    if state.probe_registered[HOST_KEY] then return HOST_KEY end
    cook.probe(HOST_KEY, {
        inputs = { tools = { "node" } },
        produce = HOST_BODY,
    })
    state.probe_registered[HOST_KEY] = true
    return HOST_KEY
end

-- The seal set of EVERY unit cook_pnpm mints (task builds and checks,
-- install, run): the toolchain identity, the host, then the unit's own sealed
-- determinants (`extra`: the install probe, declared `pnpm:env:<NAME>`
-- probes from units.tasks). One function so an observed determinant
-- reaches every minted unit or none. It lives here because the identity
-- and the host are the seals every unit shares; the per-unit probes stay
-- with their owners. Call it OUTSIDE recipe bodies: a probe first registered inside
-- one recipe's body is not scheduled for another recipe's unit that
-- seals it, and the seal keys on nothing (COOK-587).
function M.seals(extra)
    local out = { M.ensure_identity_registered(), M.ensure_host_registered() }
    for _, k in ipairs(extra or {}) do out[#out + 1] = k end
    return out
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
