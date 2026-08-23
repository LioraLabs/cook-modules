local stub = require("spec.cook_stub")

local metadata = [[{
  "workspace_root":"/work",
  "workspace_members":["app 0.1.0 (path+file:///work/app)"],
  "packages":[
    {"id":"app 0.1.0 (path+file:///work/app)","manifest_path":"/work/app/Cargo.toml","source":null},
    {"id":"shared 0.1.0 (path+file:///work/shared)","manifest_path":"/work/shared/Cargo.toml","source":null},
    {"id":"serde 1.0.0 (registry+https://example.invalid)","manifest_path":"/cargo/registry/serde/Cargo.toml","source":"registry+https://example.invalid"}
  ],
  "resolve":{"nodes":[
    {"id":"app 0.1.0 (path+file:///work/app)","dependencies":["shared 0.1.0 (path+file:///work/shared)","serde 1.0.0 (registry+https://example.invalid)"]},
    {"id":"shared 0.1.0 (path+file:///work/shared)","dependencies":[]},
    {"id":"serde 1.0.0 (registry+https://example.invalid)","dependencies":[]}
  ]}
}]]

local function load_module()
    package.loaded.cook_rust = nil
    stub.reset()
    stub.command("cargo metadata", metadata)
    stub.command("pwd", "/work\n")
    stub.command("rustc --print sysroot", "/toolchains/stable\n")
    return require("cook_rust")
end

describe("cook_rust.project", function()
    it("registers one portable seal from reachable local packages", function()
        local rust = load_module()
        assert.equal("rust:project", rust.project("app/Cargo.toml"))

        local probe = assert(stub.probe("rust:project"))
        assert.same({ "/toolchains/stable/bin/cargo", "/toolchains/stable/bin/rustc" }, probe.inputs.tools)
        assert.same({ "resolved/project/file.rs" }, probe.inputs.files)

        _G.fs = { read = function() return "abc" end }
        cook.tools = { id = function(name) return { hash = name .. "-hash" } end }
        local value = assert(load(probe.produce))()
        assert.equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                     value.files["resolved/project/file.rs"])
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
