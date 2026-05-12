local M = {}

local function detect_cmake()
    local cached = cook.cache.get("cc.cmake-compat:driver")
    if cached then return cached end

    local path = cook.sh("command -v cmake 2>/dev/null") or ""
    path = path:gsub("%s+$", "")
    if path == "" then
        local r = { ok = false }
        cook.cache.set("cc.cmake-compat:driver", r)
        return r
    end

    local probe = cook.sh(
        "cmake --find-package -DNAME=ZLIB -DCOMPILER_ID=GNU "
        .. "-DLANGUAGE=C -DMODE=EXIST -DQUIET=TRUE 2>&1 || true") or ""
    local legacy_supported = not probe:match("[Uu]nknown option")
    local r = { ok = true, path = path, legacy_supported = legacy_supported }
    cook.cache.set("cc.cmake-compat:driver", r)
    return r
end

local FLAG_BASE = " -DCOMPILER_ID=GNU -DLANGUAGE=C -DQUIET=TRUE "

local function probe_exist(name)
    local cmd = "cmake --find-package -DNAME=" .. name .. FLAG_BASE
              .. "-DMODE=EXIST 2>&1"
    local ok, out = pcall(cook.sh, cmd)
    if not ok then return false end
    out = out or ""
    if out:match(name .. " not found%.") then return false end
    if out:match(name .. " found%.") then return true end
    return false
end

function M.main_chain(name, opts)
    opts = opts or {}
    if opts.version then
        return { strategy = "cmake-compat", outcome = "skip",
                 reason = "version detection unsupported by legacy cmake --find-package" }
    end
    local driver = detect_cmake()
    if not driver.ok then
        return { strategy = "cmake-compat", outcome = "skip",
                 reason = "cmake binary not on PATH",
                 hint = "install cmake: apt: cmake / brew: cmake / dnf: cmake" }
    end
    if not driver.legacy_supported then
        return { strategy = "cmake-compat", outcome = "skip",
                 reason = "this cmake build does not support --find-package legacy mode" }
    end
    if not probe_exist(name) then
        local hints = require("cook_cc.finders.cmake_compat.hints")
        return { strategy = "cmake-compat", outcome = "miss",
                 reason = "cmake found no Config or Find module for '" .. name .. "'",
                 hint = hints.for_package(name) }
    end
    return { strategy = "cmake-compat", outcome = "skip",
             reason = "not implemented yet" }
end

return M
