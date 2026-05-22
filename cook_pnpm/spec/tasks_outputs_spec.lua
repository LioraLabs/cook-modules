-- cook-modules/cook_pnpm/spec/tasks_outputs_spec.lua
-- Encodes the cook_pnpm 0.2 outputs contract (post-execute resolution
-- via CS-0085). See COOK-47.

local stub = require("cook_stub")

local function bootstrap_two_pkg_workspace()
    stub.set_file_contents("./pnpm-workspace.yaml",
        "packages:\n  - \"apps/*\"\n")
    stub.set_file_contents("./apps/web/package.json",
        [[{"name":"@scope/web","version":"0.0.1","scripts":{"build":"next build","lint":"eslint ."}}]])
    stub.set_file_contents("./apps/docs/package.json",
        [[{"name":"@scope/docs","version":"0.0.1","scripts":{"build":"next build"}}]])
    stub.set_file_exists("./pnpm-lock.yaml", true)
    stub.set_glob("./apps/*/package.json", {
        "./apps/web/package.json",
        "./apps/docs/package.json",
    })
end

local function unit_for(pkg_name)
    for _, u in ipairs(stub.added_units()) do
        if u.command and u.command:find(pkg_name, 1, true) then return u end
    end
    return nil
end

describe("cook_pnpm.tasks v0.2 outputs", function()
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

    it("forwards `.next/**` as workspace-anchored `apps/web/.next/**`, never pre-expanded", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.task("build", { outputs = { ".next/**" } })

        assert.equals(2, #stub.added_units(), "expected one unit per (pkg, build)")
        local web = unit_for("@scope/web")
        assert.is_not_nil(web, "missing @scope/web unit")
        assert.same({ "./apps/web/.next/**" }, web.outputs,
            "outputs must be the literal workspace-anchored glob, NOT fs.glob-expanded")
    end)

    it("treats `outputs = {}` as no-restoration (empty outputs on the emitted unit)", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.task("build", { outputs = {} })

        assert.equals(2, #stub.added_units())
        for _, u in ipairs(stub.added_units()) do
            assert.same({}, u.outputs, "outputs={} must yield empty outputs[]")
        end
    end)

    it("treats absent `outputs` as no-restoration (empty outputs on the emitted unit)", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.task("build", {})

        assert.equals(2, #stub.added_units())
        for _, u in ipairs(stub.added_units()) do
            assert.same({}, u.outputs, "absent outputs must yield empty outputs[]")
        end
    end)

    it("anchors each entry of a multi-glob outputs array at the package dir", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.task("build", { outputs = { "dist/**", "*.tsbuildinfo", "coverage/**" } })

        local web = unit_for("@scope/web")
        assert.is_not_nil(web)
        assert.same({
            "./apps/web/dist/**",
            "./apps/web/*.tsbuildinfo",
            "./apps/web/coverage/**",
        }, web.outputs)
    end)
end)
