local stub = require("spec.cook_stub")

local metadata = [[{
  "workspace_root":"/work",
  "workspace_members":["app 0.1.0 (path+file:///work/app)"],
  "packages":[
    {"id":"app 0.1.0 (path+file:///work/app)","name":"app","version":"0.1.0","manifest_path":"/work/app/Cargo.toml","source":null},
    {"id":"shared 0.1.0 (path+file:///work/shared)","name":"shared","version":"0.1.0","manifest_path":"/work/shared/Cargo.toml","source":null},
    {"id":"optional 0.1.0 (path+file:///work/optional)","name":"optional","version":"0.1.0","manifest_path":"/work/optional/Cargo.toml","source":null},
    {"id":"serde 1.0.0 (registry+https://example.invalid)","manifest_path":"/cargo/registry/serde/Cargo.toml","source":"registry+https://example.invalid"}
  ],
  "resolve":{"nodes":[
    {"id":"app 0.1.0 (path+file:///work/app)","dependencies":["shared 0.1.0 (path+file:///work/shared)","optional 0.1.0 (path+file:///work/optional)","serde 1.0.0 (registry+https://example.invalid)"]},
    {"id":"shared 0.1.0 (path+file:///work/shared)","dependencies":[]},
    {"id":"optional 0.1.0 (path+file:///work/optional)","dependencies":[]},
    {"id":"serde 1.0.0 (registry+https://example.invalid)","dependencies":[]}
  ]}
}]]

local function load_module()
    package.loaded.cook_rust = nil
    stub.reset()
    stub.command("cargo metadata", function(command)
        assert.is_truthy(command:find("--all-features", 1, true))
        return metadata
    end)
    stub.command("pwd", "/work\n")
    stub.command("sh -c", "ancestor/0/.cargo/config.toml\t/work/.cargo/config.toml\n")
    stub.command("rustc --print sysroot", "/toolchains/stable\n")
    stub.resolved({ "app/src/lib.rs", ".cargo/config.toml", "Cargo.lock" })
    return require("cook_rust")
end

local function relocated_value(root, config_name)
    local external = root .. "/vendor/shared"
    local meta = ([=[{
      "workspace_root":"ROOT/app","workspace_members":["app"],
      "packages":[
        {"id":"app","name":"app","version":"0.1.0","manifest_path":"ROOT/app/Cargo.toml","source":null},
        {"id":"shared","name":"shared","version":"1.2.3","manifest_path":"EXTERNAL/Cargo.toml","source":null}
      ],
      "resolve":{"nodes":[{"id":"app","dependencies":["shared"]},{"id":"shared","dependencies":[]}]}
    }]=]):gsub("EXTERNAL", external):gsub("ROOT", root)
    package.loaded.cook_rust = nil
    stub.reset()
    stub.command("cargo metadata", meta)
    stub.command("pwd", root .. "\n")
    stub.command("sh -c", "ancestor/0/.cargo/" .. config_name .. "\t"
        .. root .. "/.cargo/" .. config_name .. "\n")
    stub.command("rustc --print sysroot", "/toolchains/stable\n")
    stub.resolved({ root .. "/app/src/lib.rs", external .. "/src/lib.rs",
        root .. "/.cargo/" .. config_name })
    require("cook_rust").project(root .. "/app/Cargo.toml")
    local probe = assert(stub.probe("rust:project"))
    _G.fs = { read = function(path)
        if path:find("/.cargo/config", 1, true) then return "[build]\nrustflags = ['--cfg=x']" end
        return path:find("shared", 1, true) and "shared source" or "app source"
    end }
    cook.tools = { id = function(path) return { hash = path:match("[^/]+$") .. "-hash" } end }
    return assert(load(probe.produce))()
end

describe("cook_rust.project", function()
    it("registers one portable seal from reachable local packages", function()
        local rust = load_module()
        assert.equal("rust:project", rust.project("app/Cargo.toml"))

        local probe = assert(stub.probe("rust:project"))
        assert.same({ "/toolchains/stable/bin/cargo", "/toolchains/stable/bin/rustc" }, probe.inputs.tools)
        assert.same({ "app/src/lib.rs", ".cargo/config.toml", "Cargo.lock" }, probe.inputs.files)

        _G.fs = { read = function() return "abc" end }
        cook.tools = { id = function(name) return { hash = name .. "-hash" } end }
        local value = assert(load(probe.produce))()
        assert.equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                     value.files["workspace/app/src/lib.rs"])
        assert.is_truthy(value.files["context/ancestor/0/.cargo/config.toml"])
        assert.is_truthy(value.files["context/workspace/Cargo.lock"])
        assert.same({ cargo = "/toolchains/stable/bin/cargo-hash",
                      rustc = "/toolchains/stable/bin/rustc-hash" }, value.tools)

        local gather = stub.gather()
        assert.is_truthy(table.concat(gather.globs, "\n"):find("app/%*%*"))
        assert.is_truthy(table.concat(gather.globs, "\n"):find("shared/%*%*"))
        assert.is_falsy(table.concat(gather.globs, "\n"):find("registry"))
        assert.is_truthy(table.concat(gather.globs, "\n"):find("Cargo%.lock"))
        assert.is_truthy(table.concat(gather.globs, "\n"):find("%.cargo/config%.toml"))
        assert.is_truthy(table.concat(gather.excludes, "\n"):find("target/%*%*"))
    end)

    it("includes optional local dependencies enabled by any feature", function()
        local rust = load_module()
        rust.project("app/Cargo.toml")
        assert.is_truthy(table.concat(stub.gather().globs, "\n"):find("optional/%*%*"))
    end)

    it("keeps workspace and external path identities stable after relocation", function()
        assert.same(relocated_value("/one/project", "config.toml"),
            relocated_value("/two/project", "config.toml"))
    end)

    it("changes the seal when active Cargo configuration moves scope", function()
        assert.not_same(relocated_value("/one/project", "config"),
            relocated_value("/one/project", "config.toml"))
    end)

    it("refuses untrackable user configuration instead of under-keying", function()
        local rust = load_module()
        stub.command("sh -c", "cargo-home/config.toml\t/home/user/.cargo/config.toml\n")
        local ok, err = pcall(rust.project, "app/Cargo.toml")
        assert.is_false(ok)
        assert.is_truthy(err:find("outside the Cook workspace", 1, true))
        assert.is_truthy(err:find("project's .cargo", 1, true))
    end)

    it("is idempotent for the same manifest and rejects a second project", function()
        local rust = load_module()
        rust.project("app/Cargo.toml")
        assert.equal("rust:project", rust.project("app/Cargo.toml"))
        local ok, err = pcall(rust.project, "other/Cargo.toml")
        assert.is_false(ok)
        assert.is_truthy(err:find("only one project seal", 1, true))
    end)

    it("reports invalid arguments and Cargo diagnostics", function()
        local rust = load_module()
        local ok, err = pcall(rust.project, 42)
        assert.is_false(ok)
        assert.is_truthy(err:find("non-empty path", 1, true))

        rust = load_module()
        stub.command("cargo metadata", function() error("manifest not found") end)
        ok, err = pcall(rust.project, "missing/Cargo.toml")
        assert.is_false(ok)
        assert.is_truthy(err:find("cargo metadata failed", 1, true))
    end)
end)
