-- cook-modules/cook_pnpm/spec/tasks_workspace_inputs_spec.lua
-- Encodes the 0.4 workspace-level `inputs` contract (turbo
-- globalDependencies): root-relative entries appended to EVERY minted
-- task's inputs, builds and checks alike, never pkg-anchored. A literal
-- entry missing at register time is dropped — a declared-but-absent
-- input is never-a-clean-hit engine-side (silent cache-off), and the
-- register phase re-evaluates per invocation so the file re-enters the
-- moment it exists.

local stub = require("cook_stub")

local function bootstrap_web_pkg()
    stub.set_file_contents("./pnpm-workspace.yaml",
        "packages:\n  - \"apps/*\"\n")
    stub.set_file_contents("./apps/web/package.json",
        [[{"name":"@scope/web","version":"0.0.1","scripts":{"build":"vite build","test":"vitest run"}}]])
    stub.set_file_exists("./pnpm-lock.yaml", true)
    stub.set_glob("./apps/*/package.json", { "./apps/web/package.json" })
    stub.set_sh_handler("find './apps/web'", function()
        return "./apps/web/src\n"
    end)
    stub.set_glob("./apps/web/*", { "./apps/web/package.json" })
end

local function has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

describe("cook_pnpm 0.4 workspace-level inputs", function()
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

    it("appends root-relative literals to BUILD and CHECK inputs, un-prefixed", function()
        bootstrap_web_pkg()
        stub.set_file_exists("./.env", true)
        stub.set_file_exists("./tsconfig.json", true)
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            inputs = { ".env", "tsconfig.json" },
            tasks  = { build = { outputs = { "dist/**" } } },
            checks = { "test" },
        })

        local u = stub.added_units()[1]
        assert.is_true(has(u.inputs, "./.env"),
            "workspace inputs are root-anchored, never pkg.dir-prefixed")
        assert.is_true(has(u.inputs, "./tsconfig.json"))
        assert.is_false(has(u.inputs, "./apps/web/.env"))

        local t = stub.added_tests()[1]
        assert.is_true(has(t.inputs, "./.env"), "checks carry the extras too")
        assert.is_true(has(t.inputs, "./tsconfig.json"))
    end)

    it("drops a literal that does not exist at register time", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            inputs = { ".env" },   -- never created in the stub fs
            tasks  = { build = { outputs = { "dist/**" } } },
            checks = false,
        })

        local u = stub.added_units()[1]
        assert.is_false(has(u.inputs, "./.env"),
            "a missing declared literal would be never-a-clean-hit engine-side — drop it")
    end)

    it("passes glob entries through (normalised, root-anchored) without an existence gate", function()
        bootstrap_web_pkg()
        stub.set_glob("./patches/**/*", { "./patches/a.patch" })
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            inputs = { "patches/**" },
            tasks  = { build = { outputs = { "dist/**" } } },
            checks = { "test" },
        })

        local u = stub.added_units()[1]
        assert.is_true(has(u.inputs, "./patches/a.patch"),
            "BUILD extras expand at register time like every build input glob")
        local t = stub.added_tests()[1]
        assert.is_true(has(t.inputs, "./patches/**/*"),
            "CHECK extras ride as globs for ready-time engine resolution")
    end)

    it("appends extras even when the task declares explicit inputs", function()
        bootstrap_web_pkg()
        stub.set_file_exists("./.env", true)
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            inputs = { ".env" },
            tasks  = { test = { inputs = { "src/**" } } },
            checks = false,
        })

        local t = stub.added_tests()[1]
        assert.is_true(has(t.inputs, "./apps/web/src/**/*"))
        assert.is_true(has(t.inputs, "./.env"),
            "explicit per-task inputs replace the default tree, not the workspace extras")
    end)
end)
