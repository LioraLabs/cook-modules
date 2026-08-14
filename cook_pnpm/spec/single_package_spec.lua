-- Solo (single-package) workspace mode (0.8): a repo with a root
-- package.json and NO pnpm-workspace.yaml is a workspace of one.
-- Recipes mint unprefixed (`build`, not `<pkg>:build` — so `build` lands
-- as the engine's default recipe) and commands drop `--filter <pkg>`,
-- which has no workspace to filter.

local stub = require("cook_stub")

describe("cook_pnpm single-package mode", function()
    local workspace, tasks
    before_each(function()
        stub.reset()
        stub.install()
        -- Hot reload to drop per-VM state from prior tests.
        for k in pairs(package.loaded) do
            if k:sub(1, #"cook_pnpm") == "cook_pnpm" then
                package.loaded[k] = nil
            end
        end
        workspace = require("cook_pnpm.discovery.workspace")
        tasks     = require("cook_pnpm.units.tasks")
    end)

    local function solo_repo()
        -- No ./pnpm-workspace.yaml on purpose.
        stub.set_file_contents("./package.json",
            [[{"name":"git-canvas","version":"0.1.0","scripts":{"build":"vite build","lint":"oxlint","test":"node --test"}}]])
        stub.set_file_exists("./pnpm-lock.yaml", true)
    end

    it("bootstraps a workspace of one from the root package.json", function()
        solo_repo()
        local result = workspace.bootstrap({})
        assert.equals(1, #result.packages)
        assert.equals("git-canvas", result.packages[1].name)
        assert.equals(".", result.packages[1].dir)
        assert.is_true(result.packages[1].solo)
        assert.is_not_nil(result.install_key:match("^pnpm:install:"))
    end)

    it("mints unprefixed recipes and drops --filter", function()
        solo_repo()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks  = { build = { outputs = { "dist/**" }, inputs = { "src/**" } } },
            checks = { "lint" },
        })

        local recs = stub.recipes()
        assert.is_not_nil(recs["build"], "solo build recipe must be named `build`")
        assert.is_not_nil(recs["lint"], "solo check recipe must be named `lint`")
        assert.is_nil(recs["git-canvas:build"], "no <pkg>: prefix in solo mode")

        local unit = stub.added_units()[1]
        assert.is_nil(unit.command:find("--filter", 1, true),
            "solo build command must not pass --filter: " .. unit.command)
        assert.is_not_nil(unit.command:find("run build", 1, true))

        local check = stub.added_tests()[1]
        assert.equals("pnpm run lint", check.command)
    end)

    it("prefers pnpm-workspace.yaml when one exists", function()
        stub.set_file_contents("./pnpm-workspace.yaml",
            "packages:\n  - \"packages/*\"\n")
        stub.set_file_contents("./package.json",
            [[{"name":"root","version":"0.0.0"}]])
        stub.set_glob("./packages/*/package.json", { "./packages/a/package.json" })
        stub.set_file_contents("./packages/a/package.json",
            [[{"name":"a","version":"0.0.1","scripts":{}}]])
        stub.set_file_exists("./pnpm-lock.yaml", true)

        local result = workspace.bootstrap({})
        assert.equals(1, #result.packages)
        assert.equals("a", result.packages[1].name)
        assert.is_nil(result.packages[1].solo)
    end)
end)
