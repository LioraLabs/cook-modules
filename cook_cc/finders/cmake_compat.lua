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
    return { strategy = "cmake-compat", outcome = "skip",
             reason = "not implemented yet" }
end

return M
