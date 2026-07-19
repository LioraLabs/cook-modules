-- cook-modules/cook_pnpm/spec/tasks_defaults_spec.lua
-- Encodes the 0.3 safe-default-inputs contract and the one-call
-- workspace{tasks, checks, requires} minting surface. Found dogfooding
-- ppu-toys: 0.2's "omitted inputs -> package.json only" default was
-- silently-wrong caching, and the per-task register block it forced was
-- turbo.json-in-Lua boilerplate.

local stub = require("cook_stub")

local function bootstrap_web_pkg()
    stub.set_file_contents("./pnpm-workspace.yaml",
        "packages:\n  - \"apps/*\"\n")
    stub.set_file_contents("./apps/web/package.json",
        [[{"name":"@scope/web","version":"0.0.1","scripts":{"build":"vite build","test":"vitest run","typecheck":"tsc --noEmit","dev":"vite"}}]])
    stub.set_file_exists("./pnpm-lock.yaml", true)
    stub.set_glob("./apps/*/package.json", { "./apps/web/package.json" })
    -- Top-level directory enumeration (the §25.10 find escape hatch):
    -- src + dist; node_modules/.git never appear (excluded by find args).
    stub.set_sh_handler("find './apps/web'", function()
        return "./apps/web/src\n./apps/web/dist\n"
    end)
    -- Top-level files of the package.
    stub.set_glob("./apps/web/*", {
        "./apps/web/package.json",
        "./apps/web/vite.config.ts",
        "./apps/web/index.html",
        "./apps/web/web.tsbuildinfo",
    })
end

local function has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

local function test_named(task)
    for _, t in ipairs(stub.added_tests()) do
        if t.command:find("run " .. task, 1, true) then return t end
    end
    return nil
end

describe("cook_pnpm 0.3 default inputs + workspace minting", function()
    local workspace, tasks
    before_each(function()
        stub.reset()
        stub.install()
        for k in pairs(package.loaded) do
            if k:sub(1, #"cook_pnpm") == "cook_pnpm" then
                package.loaded[k] = nil
            end
        end
        workspace = require("cook_pnpm.workspace")
        tasks     = require("cook_pnpm.tasks")
    end)

    it("defaults a check's inputs to the package tree minus batch-declared outputs", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks = {
                build = { outputs = { "dist/**", "*.tsbuildinfo" } },
            },
            checks = { "test" },
        })

        local t = test_named("test")
        assert.is_not_nil(t, "check for `test` not minted")
        assert.is_true(has(t.inputs, "./apps/web/src/**/*"),
            "unclaimed top-level dirs enter as subtree globs (ready-time resolution)")
        assert.is_false(has(t.inputs, "./apps/web/dist/**/*"),
            "dist/ is claimed by build's outputs — must not self-invalidate the check")
        assert.is_true(has(t.inputs, "./apps/web/vite.config.ts"))
        assert.is_true(has(t.inputs, "./apps/web/index.html"))
        assert.is_false(has(t.inputs, "./apps/web/web.tsbuildinfo"),
            "top-level files matching an output glob are build products, not inputs")
        assert.is_true(has(t.inputs, "./pnpm-lock.yaml"))
    end)

    it("auto-mints conventional checks (test, typecheck) but never `dev`", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks = { build = { outputs = { "dist/**" } } },
            -- checks omitted -> "auto"
        })

        assert.is_not_nil(test_named("test"))
        assert.is_not_nil(test_named("typecheck"))
        assert.is_nil(test_named("dev"),
            "auto minting is an allowlist — arbitrary scripts (dev, clean, ...) are never minted")
        assert.is_nil(stub.recipes()["@scope/web:dev"])
    end)

    it("checks = false disables auto minting", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks  = { build = { outputs = { "dist/**" } } },
            checks = false,
        })
        assert.is_nil(test_named("test"))
    end)

    it("an explicit tasks entry overrides the auto check of the same name", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks = {
                test = { inputs = { "src/**" } },   -- explicit, narrow inputs
            },
        })
        local t = test_named("test")
        assert.is_not_nil(t)
        assert.is_true(has(t.inputs, "./apps/web/src/**/*"),
            "explicit inputs are pkg-anchored and **-normalised")
        assert.is_false(has(t.inputs, "./apps/web/index.html"),
            "explicit inputs replace the default tree entirely")
    end)

    it("workspace-level requires lands on every minted recipe, batch-wide", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            requires = { "wasm" },
            tasks    = { build = { outputs = { "dist/**" }, requires = { "codegen" } } },
            checks   = { "test" },
        })

        assert.same({ "wasm", "codegen" },
            stub.recipes()["@scope/web:build"].opts.requires,
            "workspace requires precede per-task requires")
        assert.same({ "wasm" },
            stub.recipes()["@scope/web:test"].opts.requires,
            "auto-minted checks inherit the workspace requires")
    end)

    it("workspace-minted recipes carry origin cook_pnpm.workspace; task() keeps cook_pnpm.task", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        tasks.mint_from_workspace({ tasks = { build = { outputs = { "dist/**" } } } })
        tasks.task("typecheck", { inputs = { "src/**" } })

        assert.equals("cook_pnpm.workspace",
            stub.recipes()["@scope/web:build"].opts.origin)
        assert.equals("cook_pnpm.workspace",
            stub.recipes()["@scope/web:test"].opts.origin)
        assert.equals("cook_pnpm.task",
            stub.recipes()["@scope/web:typecheck"].opts.origin)
    end)

    it("BUILD default inputs expand subtree globs at register time and drop output files", function()
        bootstrap_web_pkg()
        stub.set_glob("./apps/web/src/**/*", {
            "./apps/web/src/main.ts",
            "./apps/web/src/app.ts",
        })
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks = { build = { outputs = { "dist/**", "*.tsbuildinfo" } } },
            checks = false,
        })

        assert.equals(1, #stub.added_units())
        local u = stub.added_units()[1]
        assert.is_true(has(u.inputs, "./apps/web/src/main.ts"),
            "build inputs are concrete files (register-time fs.glob)")
        assert.is_true(has(u.inputs, "./apps/web/vite.config.ts"))
        assert.is_false(has(u.inputs, "./apps/web/web.tsbuildinfo"))
    end)
end)
