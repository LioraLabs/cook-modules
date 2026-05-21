local M = {}

local INSTALL_HINT = "apt: libcurl4-openssl-dev / macOS system / brew: curl"

local function parse_tool_output(out)
    local lpeg = require("lpeg")
    local P, S, C, Ct = lpeg.P, lpeg.S, lpeg.C, lpeg.Ct
    local space     = S(" \t")^0
    local non_space = (P(1) - S(" \t"))^1
    local include   = P("-I") * C(non_space) / function(v) return { kind = "I", value = v } end
    local libdir    = P("-L") * C(non_space) / function(v) return { kind = "L", value = v } end
    local syslib    = P("-l") * C(non_space) / function(v) return { kind = "l", value = v } end
    local other     = C(non_space)             / function(v) return { kind = "o", value = v } end
    local token     = include + libdir + syslib + other
    local line      = Ct((space * token)^0 * space)
    local toks      = line:match(out or "") or {}
    local payload = {
        cflags = "", libs = out or "", system_libs = {}, include_dirs = {}, lib_dirs = {},
        frameworks = {}, version = nil,
    }
    for _, t in ipairs(toks) do
        if     t.kind == "I" then payload.include_dirs[#payload.include_dirs + 1] = t.value
        elseif t.kind == "L" then payload.lib_dirs[#payload.lib_dirs + 1] = t.value
        elseif t.kind == "l" then payload.system_libs[#payload.system_libs + 1] = t.value
        end
    end
    return payload
end

function M.find(opts)
    opts = opts or {}
    local tool = require("cook_cc.finders.tool_config")
    -- Same fix as curated:sdl2 (0.10.1): query cflags and libs separately.
    -- Pre-0.10.2 the curated:libcurl finder also called `curl-config
    -- --cflags --libs` in one shot and stuffed the combined output into
    -- payload.libs. On systems where curl-config --cflags is empty
    -- (Arch, Debian default), the combined output is `\n-lcurl\n`, which
    -- after trailing-whitespace strip leaves a LEADING `\n` inside the
    -- libs string. The sigil $<cc:find:libcurl.libs> then injects that
    -- newline into the link command, splitting it across two /bin/sh -c
    -- lines and breaking the build.
    local cflags = tool.try("curl-config", "--cflags")
    local libs   = tool.try("curl-config", "--libs")
    local out = (cflags and libs) and (cflags .. " " .. libs) or nil
    if out then
        local payload = parse_tool_output(out)
        payload.cflags = cflags
        payload.libs   = libs
        local ver_out = tool.try("curl-config", "--version")
        if ver_out then
            payload.version = ver_out:match("libcurl%s+([%d%.]+)") or ver_out
        end
        if opts.version then
            local ver = require("cook_cc.version")
            if not ver.satisfies(payload.version or "", opts.version) then
                return { strategy = "curated:libcurl", outcome = "miss",
                         reason = "curl-config version " .. (payload.version or "(undetectable)")
                                  .. " does not satisfy " .. opts.version,
                         hint = INSTALL_HINT }
            end
        end
        return { strategy = "curated:libcurl", outcome = "hit", reason = "", payload = payload }
    end

    local pkg = require("cook_cc.finders.pkg_config")
    local a = pkg.try("libcurl")
    if a then
        if opts.version then
            local ver = require("cook_cc.version")
            if not (a.payload.version and ver.satisfies(a.payload.version, opts.version)) then
                return { strategy = "curated:libcurl", outcome = "miss",
                         reason = "pkg-config version " .. (a.payload.version or "(undetectable)")
                                  .. " does not satisfy " .. opts.version,
                         hint = INSTALL_HINT }
            end
        end
        return a
    end

    return { strategy = "curated:libcurl", outcome = "miss",
             reason = "neither curl-config nor pkg-config 'libcurl' located libcurl",
             hint = INSTALL_HINT }
end

return M
