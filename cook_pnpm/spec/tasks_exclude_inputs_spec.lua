-- cook-modules/cook_pnpm/spec/tasks_exclude_inputs_spec.lua
-- 0.5: `exclude_inputs` — the declared subtraction surface for
-- tool-written files inside source directories (a `next build` that
-- rewrites app/.well-known/... state must not re-key its own task).
--
-- Contract:
--  * task-cfg `exclude_inputs` entries are PACKAGE-relative globs;
--    workspace-level entries are ROOT-relative. The `!` is implied —
--    a `!`-prefixed entry on either surface is a register-time error.
--  * build units: excluded files are dropped at fs.glob expansion, so a
--    nested tool-written file inside a kept subtree glob is subtracted.
--  * check units: an input-glob entry wholly inside an excluded subtree
--    is dropped whole (their globs resolve engine-side; per-file
--    filtering is not possible module-side).
--  * `!`-prefixed entries on any *inputs* surface (workspace or task
--    cfg) are a loud register-time error pointing at exclude_inputs —
--    anchoring used to corrupt them into mid-path literals that
--    silently matched nothing.

local stub = require("cook_stub")

local function bootstrap_web_pkg()
    stub.set_file_contents("./pnpm-workspace.yaml",
        "packages:\n  - \"apps/*\"\n")
    stub.set_file_contents("./apps/web/package.json",
        [[{"name":"@scope/web","version":"0.0.1","scripts":{"build":"next build","test":"vitest run"}}]])
    stub.set_file_exists("./pnpm-lock.yaml", true)
    stub.set_glob("./apps/*/package.json", { "./apps/web/package.json" })
    stub.set_sh_handler("find './apps/web'", function()
        return "./apps/web/app\n./apps/web/src\n"
    end)
    stub.set_glob("./apps/web/*", { "./apps/web/package.json" })
    -- The app/ subtree contains a tool-written manifest next to real source.
    stub.set_glob("./apps/web/app/**/*", {
        "./apps/web/app/page.tsx",
        "./apps/web/app/.well-known/workflow/v1/manifest.json",
    })
    stub.set_glob("./apps/web/src/**/*", { "./apps/web/src/util.ts" })
end

local function has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

describe("cook_pnpm 0.5 exclude_inputs", function()
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

    it("task-level exclude subtracts a nested tool-written file from BUILD inputs", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks  = { build = {
                outputs = { ".next/**" },
                exclude_inputs = { "app/.well-known/workflow/**" },
            } },
            checks = false,
        })

        local u = stub.added_units()[1]
        assert.is_truthy(u, "build unit minted")
        assert.is_true(has(u.inputs, "./apps/web/app/page.tsx"),
            "sibling source files survive the subtraction")
        assert.is_false(
            has(u.inputs, "./apps/web/app/.well-known/workflow/v1/manifest.json"),
            "the tool-written file must not enter the input set")
    end)

    it("workspace-level exclude (root-relative) subtracts for every task", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            exclude_inputs = { "apps/web/app/.well-known/workflow/**" },
            tasks  = { build = { outputs = { ".next/**" } } },
            checks = false,
        })

        local u = stub.added_units()[1]
        assert.is_false(
            has(u.inputs, "./apps/web/app/.well-known/workflow/v1/manifest.json"),
            "root-relative workspace exclusion reaches the build unit")
        assert.is_true(has(u.inputs, "./apps/web/app/page.tsx"))
    end)

    it("drops a whole default subtree entry for CHECK units when excluded", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks  = { build = { outputs = { ".next/**" } } },
            checks = { "test" },
            exclude_inputs = { "apps/web/app/**" },
        })

        local t = stub.added_tests()[1]
        assert.is_truthy(t, "check unit minted")
        assert.is_false(has(t.inputs, "./apps/web/app/**/*"),
            "an input-glob entry wholly inside an excluded subtree is dropped whole")
        assert.is_true(has(t.inputs, "./apps/web/src/**/*"),
            "unexcluded subtree entries survive")
    end)

    it("rejects a '!'-prefixed workspace inputs entry loudly", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        local ok, err = pcall(function()
            tasks.mint_from_workspace({
                inputs = { "!apps/web/app/.well-known/workflow/**" },
                tasks  = { build = { outputs = { ".next/**" } } },
                checks = false,
            })
        end)
        assert.is_false(ok, "negated inputs entry must error, not silently match nothing")
        assert.is_truthy(tostring(err):find("exclude_inputs", 1, true),
            "error must point at exclude_inputs; got: " .. tostring(err))
    end)

    it("rejects a '!'-prefixed task-cfg inputs entry loudly", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        local ok, err = pcall(function()
            tasks.mint_from_workspace({
                tasks  = { build = {
                    outputs = { ".next/**" },
                    inputs  = { "src/**", "!src/generated/**" },
                } },
                checks = false,
            })
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("exclude_inputs", 1, true),
            "error must point at exclude_inputs; got: " .. tostring(err))
    end)

    it("rejects a '!'-prefixed exclude_inputs entry (the ! is implied)", function()
        bootstrap_web_pkg()
        workspace.bootstrap({})
        local ok, err = pcall(function()
            tasks.mint_from_workspace({
                tasks  = { build = {
                    outputs = { ".next/**" },
                    exclude_inputs = { "!app/.well-known/**" },
                } },
                checks = false,
            })
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("implied", 1, true),
            "error must say the ! is implied; got: " .. tostring(err))
    end)

    it("exclusion composes with explicit cfg.inputs replacement", function()
        bootstrap_web_pkg()
        stub.set_glob("./apps/web/src/**/*", {
            "./apps/web/src/util.ts",
            "./apps/web/src/generated/api.ts",
        })
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks  = { build = {
                outputs = { ".next/**" },
                inputs  = { "src/**" },
                exclude_inputs = { "src/generated/**" },
            } },
            checks = false,
        })

        local u = stub.added_units()[1]
        assert.is_true(has(u.inputs, "./apps/web/src/util.ts"))
        assert.is_false(has(u.inputs, "./apps/web/src/generated/api.ts"),
            "exclusion applies to replaced input sets too")
    end)
end)
