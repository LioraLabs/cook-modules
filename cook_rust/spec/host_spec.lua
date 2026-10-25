-- The host every rust:project seal carries: `rust:host`, rustc's own host
-- triple. Cook folds a sealed probe's VALUE into the unit key (§17.1.1), so two
-- hosts that observe different triples never share an artifact, and two runs
-- on one host observe the same value and still hit.
local stub = require("spec.cook_stub")

local function register()
    package.loaded.cook_rust = nil
    stub.reset()
    stub.command("'/path/bin/cargo' metadata", [[{"workspace_root":"/work",
        "workspace_members":["app"],
        "packages":[{"id":"app","name":"app","version":"0.1.0","manifest_path":"/work/app/Cargo.toml","source":null}],
        "resolve":{"nodes":[{"id":"app","dependencies":[]}]}}]])
    stub.command("pwd", "/work\n")
    stub.command("sh -c", "")
    stub.command("command -v 'cargo'", "/path/bin/cargo\n")
    stub.command("command -v 'rustc'", "/path/bin/rustc\n")
    stub.command("'/path/bin/rustc' --print sysroot", "/toolchains/stable\n")
    stub.resolved({ "app/src/lib.rs" })
    local rust = require("cook_rust")
    rust.project("app/Cargo.toml")
    _G.fs = { read = function() return "source" end }
    cook.tools = { id = function(path) return { hash = path .. "-hash" } end }
    return rust
end

-- rustc on PATH answers `answer` (a string, or a function that raises).
local function answer(value)
    stub.command("'/path/bin/rustc' -vV", function(cmd)
        assert.is_nil(cmd:find("2>", 1, true))   -- rustc's stderr is never dropped
        if type(value) == "function" then return value() end
        return value
    end)
end

local function vv(triple)
    return "rustc 1.80.0 (051478957 2024-07-21)\nbinary: rustc\ncommit-hash: 0514789\n"
        .. "host: " .. triple .. "\nrelease: 1.80.0\nLLVM version: 18.1.7\n"
end

local function project_on(triple)
    answer(vv(triple))
    return assert(load(stub.probe("rust:project").produce))()
end

describe("cook_rust rust:host", function()
    it("is declared from the rustc cargo asks, and rust:project requires it", function()
        register()
        assert.same({ "/path/bin/rustc" }, stub.probe("rust:host").inputs.tools)
        assert.same({ "rust:host" }, stub.probe("rust:project").inputs.requires)
        answer(vv("aarch64-apple-darwin"))
        assert.same({ host = "aarch64-apple-darwin" }, assert(load(stub.probe("rust:host").produce))())
    end)

    it("keys two hosts apart and one host alike, through rust:project", function()
        register()
        local linux  = project_on("x86_64-unknown-linux-gnu")
        local mac    = project_on("aarch64-apple-darwin")
        local linux2 = project_on("x86_64-unknown-linux-gnu")
        assert.equal("x86_64-unknown-linux-gnu", linux.host)
        assert.not_same(linux, mac)
        assert.same(linux, linux2)
    end)

    it("keys windows-gnu and windows-msvc apart", function()
        register()
        assert.not_same(project_on("x86_64-pc-windows-gnu"), project_on("x86_64-pc-windows-msvc"))
    end)

    it("reads a CRLF answer", function()
        register()
        answer((vv("x86_64-pc-windows-msvc"):gsub("\n", "\r\n")))
        assert.same({ host = "x86_64-pc-windows-msvc" }, assert(load(stub.probe("rust:host").produce))())
    end)

    it("registers once across repeated project calls", function()
        local rust = register()
        assert.equal("rust:project", rust.project("app/Cargo.toml"))   -- stub raises on a duplicate
    end)

    it("refuses an answer that is not rustc's -vV with one host triple", function()
        register()
        for _, bad in ipairs({ "", "error: no such toolchain\n", "rustc 1.80.0\nrelease: 1.80.0\n",
                               vv("x86_64 linux"), vv(""),
                               vv("a-b") .. "host: c-d\n", "cargo 1.80.0\nhost: x86_64-unknown-linux-gnu\n" }) do
            answer(bad)
            assert.error_matches(function() load(stub.probe("rust:host").produce)() end,
                "could not read the host")
        end
    end)

    it("lets a rustc crash through, with what rustc said", function()
        register()
        answer(function() error("rustc exited 1: error: toolchain 'nightly' is not installed") end)
        assert.error_matches(function() load(stub.probe("rust:host").produce)() end,
            "toolchain 'nightly' is not installed")
    end)
end)
