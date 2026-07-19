-- cook-modules/cook_pnpm/spec/tasks_outputs_spec.lua
-- Encodes the cook_pnpm 0.3 shape-inference contract:
--   outputs non-empty -> BUILD (cook.add_unit, post-execute output
--     resolution per CS-0085, install-probe seal per §12.7.5);
--   outputs empty/absent -> CHECK (cook.add_test, Standard §8.6/§17.4
--     test-result caching; lockfile rides as a declared input).
-- Supersedes the 0.2 "outputs={} yields an empty-outputs cook unit"
-- contract — that shape was an engine OneShot and never cached.

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

local function test_for(pkg_name)
    for _, t in ipairs(stub.added_tests()) do
        if t.command and t.command:find(pkg_name, 1, true) then return t end
    end
    return nil
end

describe("cook_pnpm.tasks 0.3 shape inference", function()
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

        assert.equals(2, #stub.added_units(), "expected one BUILD unit per (pkg, build)")
        local web = unit_for("@scope/web")
        assert.is_not_nil(web, "missing @scope/web unit")
        assert.same({ "./apps/web/.next/**" }, web.outputs,
            "outputs must be the literal workspace-anchored glob, NOT fs.glob-expanded")
    end)

    it("mints a CHECK (cook.add_test) when outputs are absent", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.task("build", {})

        assert.equals(0, #stub.added_units(), "no cook units for an outputs-less task")
        assert.equals(2, #stub.added_tests(), "one test unit per (pkg, build)")
        local web = test_for("@scope/web")
        assert.is_not_nil(web)
        assert.equals("pnpm --filter @scope/web run build", web.command,
            "check commands use plain pnpm — test commands get no probe substitution (CS-0127)")
        assert.equals("@scope/web", web.suite)
    end)

    it("mints a CHECK when outputs = {}", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.task("build", { outputs = {} })

        assert.equals(0, #stub.added_units())
        assert.equals(2, #stub.added_tests())
    end)

    it("carries the lockfile + package.json as CHECK inputs (no seal field on test units)", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.task("lint", {})   -- only @scope/web declares lint

        assert.equals(1, #stub.added_tests())
        local t = stub.added_tests()[1]
        local has_lock, has_manifest = false, false
        for _, i in ipairs(t.inputs) do
            if i == "./pnpm-lock.yaml" then has_lock = true end
            if i == "./apps/web/package.json" then has_manifest = true end
        end
        assert.is_true(has_lock,
            "lockfile must be a declared input — the check's install determinant")
        assert.is_true(has_manifest)
        assert.is_nil(t.seal, "test units take no seal field")
    end)

    it("rejects kind=\"check\" with declared outputs", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        assert.error_matches(function()
            tasks.task("build", { kind = "check", outputs = { "dist/**" } })
        end, "declares outputs but kind")
    end)

    it("honours kind=\"build\" without outputs (explicit OneShot escape hatch)", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.task("build", { kind = "build" })

        assert.equals(2, #stub.added_units())
        assert.equals(0, #stub.added_tests())
        assert.same({}, unit_for("@scope/web").outputs)
    end)

    it("seals the install probe on BUILD units and keeps toolchain in probes (§12.7.5)", function()
        bootstrap_two_pkg_workspace()
        local result = workspace.bootstrap({})
        tasks.task("build", { outputs = { ".next/**" } })

        local web = unit_for("@scope/web")
        assert.is_not_nil(web)
        assert.same({ result.install_key }, web.seal,
            "install probe must be sealed, not consumed as a data probe")
        for _, k in ipairs(web.probes or {}) do
            assert.is_nil(k:match("^pnpm:install:"),
                "install probe must not sit in the data `probes` set")
        end
        assert.is_not_nil(result.install_key:match("^pnpm:install:"))
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
