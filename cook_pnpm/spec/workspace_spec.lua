-- Smoke test for cook_pnpm.workspace bootstrap + topo sort.
-- Exercises pnpm-workspace.yaml parsing, package.json reads, and the
-- recipe emission contract from cook_pnpm.task.

local stub = require("cook_stub")

describe("cook_pnpm.workspace", function()
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
        workspace = require("cook_pnpm.workspace")
        tasks     = require("cook_pnpm.tasks")
    end)

    it("parses pnpm-workspace.yaml + package.json files and builds topo order", function()
        stub.set_file_contents("./pnpm-workspace.yaml", [[
packages:
  - "packages/*"
  - "apps/*"
]])
        stub.set_file_contents("./packages/utils/package.json",
            [[{"name":"@scope/utils","version":"0.0.1","scripts":{"build":"tsc"}}]])
        stub.set_file_contents("./packages/ui/package.json",
            [[{"name":"@scope/ui","version":"0.0.1","scripts":{"build":"tsc"},"dependencies":{"@scope/utils":"workspace:*"}}]])
        stub.set_file_contents("./apps/web/package.json",
            [[{"name":"@scope/web","version":"0.0.1","scripts":{"build":"vite build"},"dependencies":{"@scope/ui":"workspace:*"}}]])
        stub.set_file_exists("./pnpm-lock.yaml", true)

        stub.set_glob("./packages/*/package.json", {
            "./packages/utils/package.json",
            "./packages/ui/package.json",
        })
        stub.set_glob("./apps/*/package.json", { "./apps/web/package.json" })

        local result = workspace.bootstrap({})
        assert.equals(3, #result.packages)
        -- Topo order: utils before ui, ui before web.
        local names = {}
        for _, p in ipairs(result.packages) do names[#names + 1] = p.name end
        assert.equals("@scope/utils", names[1])
        assert.equals("@scope/ui",    names[2])
        assert.equals("@scope/web",   names[3])

        assert.is_not_nil(result.install_key:match("^pnpm:install:"))
    end)

    it("emits one recipe per (package, task) with topo-correct requires", function()
        stub.set_file_contents("./pnpm-workspace.yaml",
            "packages:\n  - \"packages/*\"\n")
        stub.set_file_contents("./packages/a/package.json",
            [[{"name":"a","version":"0.0.1","scripts":{"build":"tsc"}}]])
        stub.set_file_contents("./packages/b/package.json",
            [[{"name":"b","version":"0.0.1","scripts":{"build":"tsc"},"dependencies":{"a":"workspace:*"}}]])
        stub.set_file_exists("./pnpm-lock.yaml", true)
        stub.set_glob("./packages/*/package.json", {
            "./packages/a/package.json",
            "./packages/b/package.json",
        })

        workspace.bootstrap({})
        tasks.task("build", { depends_on = { "^build" } })

        local recs = stub.recipes()
        assert.is_not_nil(recs["a:build"])
        assert.is_not_nil(recs["b:build"])
        -- b:build must require a:build.
        local b_reqs = recs["b:build"].opts.requires
        local found = false
        for _, r in ipairs(b_reqs) do
            if r == "a:build" then found = true end
        end
        assert.is_true(found, "b:build must `requires = { a:build, ... }`")
        -- a has no workspace deps, so a:build's requires set is empty.
        assert.equals(0, #recs["a:build"].opts.requires)
        -- Data-driven fan-out carve-out: every minted recipe MUST carry origin
        -- metadata so `cook list` annotates it (explicit-recipes contract).
        assert.equals("cook_pnpm.task", recs["a:build"].opts.origin)
        assert.equals("cook_pnpm.task", recs["b:build"].opts.origin)
    end)
end)
