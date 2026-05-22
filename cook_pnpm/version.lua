-- Minimal semver helper, mirrors cook_cc/version.lua surface but trimmed
-- for the operators pnpm-style ranges actually use in package.json /
-- pnpm-workspace.yaml engines fields: `^X.Y.Z`, `~X.Y.Z`, `>=X.Y.Z`, `X`, `X.Y`.

local M = {}

local function parse_int(s) return tonumber(s, 10) end

function M.parse(s)
    if type(s) ~= "string" or s == "" then return nil end
    local trunc = s:match("^([^+]+)") or s
    local core, prerelease = trunc:match("^([^-]+)%-?(.*)$")
    if not core then return nil end
    if prerelease == "" then prerelease = nil end
    local major, minor, patch = core:match("^(%d+)%.?(%d*)%.?(%d*)$")
    if not major then return nil end
    local M_ = parse_int(major)
    local m_ = parse_int(minor or "") or 0
    local p_ = parse_int(patch or "") or 0
    if not M_ then return nil end
    return { major = M_, minor = m_, patch = p_, prerelease = prerelease }
end

local function cmp_core(a, b)
    if a.major ~= b.major then return a.major - b.major end
    if a.minor ~= b.minor then return a.minor - b.minor end
    return a.patch - b.patch
end

-- Caret: ^1.2.3 means >=1.2.3 <2.0.0; ^0.2.3 means >=0.2.3 <0.3.0.
local function caret_matches(detected, base)
    if cmp_core(detected, base) < 0 then return false end
    if base.major > 0 then return detected.major == base.major end
    if base.minor > 0 then
        return detected.major == 0 and detected.minor == base.minor
    end
    return detected.major == 0 and detected.minor == 0 and detected.patch == base.patch
end

-- Tilde: ~1.2.3 means >=1.2.3 <1.3.0; ~1.2 means >=1.2 <1.3.
local function tilde_matches(detected, base)
    if cmp_core(detected, base) < 0 then return false end
    return detected.major == base.major and detected.minor == base.minor
end

function M.satisfies(detected_str, constraint_str)
    if not constraint_str or constraint_str == "" then return true end
    local detected = M.parse(detected_str)
    if not detected then return false end
    local op, rest = constraint_str:match("^([%^~>=<]+)(.+)$")
    if op == "^" then
        local base = M.parse(rest)
        return base and caret_matches(detected, base) or false
    elseif op == "~" then
        local base = M.parse(rest)
        return base and tilde_matches(detected, base) or false
    elseif op == ">=" then
        local base = M.parse(rest)
        return base and cmp_core(detected, base) >= 0 or false
    elseif op == ">" then
        local base = M.parse(rest)
        return base and cmp_core(detected, base) > 0 or false
    end
    local exact = M.parse(constraint_str)
    return exact and cmp_core(detected, exact) == 0 or false
end

return M
