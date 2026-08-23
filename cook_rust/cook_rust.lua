local json = require("cjson.safe")
local M = { name = "cook_rust" }
local registered_manifest

local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function trim(s) return (s:gsub("%s+$", "")) end
local function lua_list(values)
    local quoted = {}
    for i, value in ipairs(values) do quoted[i] = string.format("%q", value) end
    return "{" .. table.concat(quoted, ",") .. "}"
end
local function relative(p, root)
    if p == root then return "." end
    local prefix = root .. "/"
    return p:sub(1, #prefix) == prefix and p:sub(#prefix + 1) or p
end
local function normalize(p)
    local parts = {}
    for part in p:gmatch("[^/]+") do
        if part == ".." then table.remove(parts)
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return (p:sub(1, 1) == "/" and "/" or "") .. table.concat(parts, "/")
end

local function metadata(manifest)
    local cmd = "cargo metadata --format-version 1 --manifest-path " .. quote(manifest)
    local ok, raw = pcall(cook.sh, cmd .. " 2>&1")
    if not ok then
        error("[cook_rust.project] cargo metadata failed for '" .. manifest .. "': " .. tostring(raw), 3)
    end
    local value, err = json.decode(raw)
    if not value then
        error("[cook_rust.project] cargo metadata returned invalid JSON for '" .. manifest
            .. "': " .. tostring(err) .. "\n" .. trim(raw), 3)
    end
    return value
end

local function toolchain()
    local ok, root = pcall(cook.sh, "rustc --print sysroot 2>&1")
    if not ok or not trim(root):match("%S") then
        error("[cook_rust.project] could not resolve the active Rust sysroot: " .. tostring(root), 3)
    end
    root = trim(root)
    return root .. "/bin/cargo", root .. "/bin/rustc"
end

local function local_packages(meta, manifest_path, manifest_label)
    local packages, nodes = {}, {}
    for _, p in ipairs(meta.packages or {}) do packages[p.id] = p end
    for _, n in ipairs((meta.resolve or {}).nodes or {}) do nodes[n.id] = n end

    local seeds = {}
    for _, p in pairs(packages) do
        if normalize(p.manifest_path) == manifest_path then seeds[#seeds + 1] = p.id end
    end
    if #seeds == 0 then
        for _, id in ipairs(meta.workspace_members or {}) do seeds[#seeds + 1] = id end
    end

    local seen, found, cursor = {}, {}, 1
    while cursor <= #seeds do
        local id = seeds[cursor]
        cursor = cursor + 1
        if not seen[id] then
            seen[id] = true
            local p = packages[id]
            if p and (p.source == nil or p.source == json.null) then found[#found + 1] = p end
            for _, dep in ipairs((nodes[id] or {}).dependencies or {}) do seeds[#seeds + 1] = dep end
        end
    end
    if #found == 0 then
        error("[cook_rust.project] Cargo metadata found no local package reachable from '" .. manifest_label .. "'", 3)
    end
    return found
end

function M.project(manifest)
    if type(manifest) ~= "string" or manifest == "" then
        error("[cook_rust.project] manifest must be a non-empty path to Cargo.toml", 2)
    end
    if registered_manifest then
        if registered_manifest == manifest then return "rust:project" end
        error("[cook_rust.project] only one project seal may be registered per Cookfile (already '"
            .. registered_manifest .. "')", 2)
    end

    local meta = metadata(manifest)
    local cwd = trim(cook.sh("pwd"))
    local manifest_path = normalize(manifest:sub(1, 1) == "/" and manifest or cwd .. "/" .. manifest)
    local globs, excludes = {}, {}
    for _, p in ipairs(local_packages(meta, manifest_path, manifest)) do
        local dir = relative(assert(p.manifest_path:match("^(.*)/[^/]+$")), cwd)
        globs[#globs + 1] = dir .. "/**"
        excludes[#excludes + 1] = dir .. "/target/**"
        excludes[#excludes + 1] = dir .. "/.git/**"
    end
    local workspace = relative(meta.workspace_root, cwd)
    for _, file in ipairs({ "Cargo.toml", "Cargo.lock", "rust-toolchain", "rust-toolchain.toml",
                            ".cargo/config", ".cargo/config.toml" }) do
        globs[#globs + 1] = workspace .. "/" .. file
    end
    table.sort(globs)
    table.sort(excludes)

    local files = cook.resolve_gather(globs, excludes)
    local cargo, rustc = toolchain()
    cook.probe("rust:project", {
        inputs = {
            files = files,
            tools = { cargo, rustc },
        },
        produce = [[
            local files = ]] .. lua_list(files) .. [[
            local cargo, rustc = ]] .. string.format("%q, %q", cargo, rustc) .. [[
            local K = { 0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
                0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
                0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
                0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
                0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
                0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
                0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
                0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 }
            local function r(x,n) return ((x >> n) | (x << (32-n))) & 0xffffffff end
            local function sha256(s)
                local bits = #s * 8
                s = s .. "\128" .. string.rep("\0", (55 - #s) % 64)
                    .. string.pack(">I8", bits)
                local h = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                    0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 }
                for offset = 1, #s, 64 do
                    local w = { string.unpack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", s, offset) }
                    w[17] = nil
                    for i=17,64 do
                        local a,b=w[i-15],w[i-2]
                        w[i]=(w[i-16]+(r(a,7)~r(a,18)~(a>>3))+w[i-7]+(r(b,17)~r(b,19)~(b>>10)))&0xffffffff
                    end
                    local a,b,c,d,e,f,g,hh=table.unpack(h)
                    for i=1,64 do
                        local s1=r(e,6)~r(e,11)~r(e,25)
                        local t1=(hh+s1+((e&f)~((~e)&g))+K[i]+w[i])&0xffffffff
                        local s0=r(a,2)~r(a,13)~r(a,22)
                        local t2=(s0+((a&b)~(a&c)~(b&c)))&0xffffffff
                        hh,g,f,e,d,c,b,a=g,f,e,(d+t1)&0xffffffff,c,b,a,(t1+t2)&0xffffffff
                    end
                    for i,v in ipairs({a,b,c,d,e,f,g,hh}) do h[i]=(h[i]+v)&0xffffffff end
                end
                local out={}; for i,v in ipairs(h) do out[i]=string.format("%08x",v) end
                return table.concat(out)
            end
            local identities = {}
            for _, path in ipairs(files) do identities[path] = sha256(fs.read(path)) end
            local cargo_id, rustc_id = assert(cook.tools.id(cargo)), assert(cook.tools.id(rustc))
            return {
                schema = 1,
                files = identities,
                tools = { cargo = cargo_id.hash, rustc = rustc_id.hash },
            }
        ]],
    })
    registered_manifest = manifest
    return "rust:project"
end

return M
