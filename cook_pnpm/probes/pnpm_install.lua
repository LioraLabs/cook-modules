-- pnpm:install:<lockfile-hash> probe.
--
-- Side-effecting probe: runs `pnpm install --frozen-lockfile` once per
-- distinct pnpm-lock.yaml content hash. Keyed on the lockfile hash so
-- a lockfile edit invalidates the install probe (and, transitively,
-- every per-package recipe that consumed it). Source-only edits leave
-- the install probe's cached value untouched, so cook reuses the
-- existing node_modules tree.
--
-- The probe's produce body returns a trivial record `{ installed = true,
-- lockfile_hash = "..." }`. The recipes that depend on it don't read
-- the fields — they only care about the probe key participating in
-- their input fingerprint.

local toolchain = require("cook_pnpm.toolchain")

local M = {}

local state = { registered = {} }   -- lockfile-hash -> probe key

local function hash_file(path)
    -- contracts.hash_str isn't available from a blessed module; we shell
    -- out to sha256sum. The result is stable per file content and is
    -- only computed once per register phase.
    if not fs.exists(path) then
        error("[pnpm.install] lockfile not found at " .. path
              .. " — run `pnpm install` once to generate it.", 2)
    end
    local out = cook.sh("sha256sum '" .. path .. "' 2>/dev/null")
    local hash = out:match("^(%x+)")
    if not hash then
        error("[pnpm.install] could not hash lockfile at " .. path, 2)
    end
    return hash:sub(1, 16)
end

-- The returned value participates in every consuming recipe's seal
-- contribution, so it must be DETERMINISTIC for a given lockfile. Raw
-- `pnpm install` output is not (transient WARN lines vary run to run —
-- found dogfooding a 25-project workspace, where the churn cache-missed
-- every build every run); only the lockfile hash goes into the value.
local function produce_body(lockfile_hash)
    return string.format([[
        cook.sh("pnpm install --frozen-lockfile 2>&1")
        return { installed = true, lockfile_hash = %q }
    ]], lockfile_hash)
end

function M.ensure_probe_registered(lockfile_path)
    toolchain.ensure_probe_registered()
    local h = hash_file(lockfile_path)
    local key = "pnpm:install:" .. h
    if state.registered[key] then return key end
    cook.probe(key, {
        inputs = {
            requires = { toolchain.get_probe_key() },
            files    = { lockfile_path },
            tools    = { "pnpm" },
        },
        produce = produce_body(h),
    })
    state.registered[key] = true
    return key
end

function M.current_key(lockfile_path)
    local h = hash_file(lockfile_path)
    return "pnpm:install:" .. h
end

return M
