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

describe("cook_pnpm.units.tasks 0.3 shape inference", function()
    local workspace, tasks
    before_each(function()
        stub.reset()
        stub.install()
        for k in pairs(package.loaded) do
            if k:sub(1, #"cook_pnpm") == "cook_pnpm" then
                package.loaded[k] = nil
            end
        end
        workspace = require("cook_pnpm.discovery.workspace")
        tasks     = require("cook_pnpm.units.tasks")
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

    it("mints a CHECK (step_kind test) when outputs are absent", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.task("build", {})

        assert.equals(0, #stub.added_units(), "no cook units for an outputs-less task")
        assert.equals(2, #stub.added_tests(), "one test unit per (pkg, build)")
        local web = test_for("@scope/web")
        assert.is_not_nil(web)
        assert.equals("pnpm --filter @scope/web run build", web.command,
            "check commands use plain pnpm — test commands get no probe substitution (CS-0127)")
        assert.equals("test", web.step_kind)
        assert.is_nil(web.suite,
            "suite was removed with cook.add_test (CS-0185)")
        assert.equals("pnpm:web:build", web._recipe,
            "the enclosing recipe names the test unit (CS-0185)")
    end)

    it("mints a CHECK when outputs = {}", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.task("build", { outputs = {} })

        assert.equals(0, #stub.added_units())
        assert.equals(2, #stub.added_tests())
    end)

    it("carries the lockfile + package.json as CHECK inputs", function()
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
    end)

    it("seals the toolchain identity on BUILD and CHECK units (§22.5.7: probes never key)", function()
        local registered_before_bodies   -- snapshot at the FIRST recipe call
        local recipe = cook.recipe
        cook.recipe = function(name, opts, body)
            if not registered_before_bodies then
                registered_before_bodies = {}
                for _, k in ipairs(stub.probe_keys()) do registered_before_bodies[k] = true end
            end
            return recipe(name, opts, body)
        end
        bootstrap_two_pkg_workspace()
        local result = workspace.bootstrap({})
        tasks.task("build", { outputs = { ".next/**" } })
        tasks.task("lint", {})

        local id = "pnpm:toolchain:auto:identity"
        assert.is_true(registered_before_bodies["pnpm:host"] == true,
            "the host probe is sealed too, so it registers outside bodies too")
        assert.is_true(registered_before_bodies[id] == true,
            "the sealed probe must be registered outside any recipe body — "
            .. "the engine does not schedule one registered in another recipe's body")
        local web = unit_for("@scope/web")
        assert.same({ id, "pnpm:host", result.install_key }, web.seal)
        assert.same({ "pnpm:toolchain:auto" }, web.probes,
            "the path probe stays a substitution-only data probe")
        assert.same({ id, "pnpm:host" }, test_for("@scope/web").seal)

        -- The identity is path-free: it reads versions off the path probe.
        local opts = stub.probe_opts(id)
        assert.same({ "pnpm:toolchain:auto" }, opts.inputs.requires)
        assert.is_not_nil(opts.produce:find("node_version", 1, true))
        assert.is_nil(opts.produce:find("t.node,", 1, true))

        -- The low-level install / run units are minted units too.
        local pnpm_cli = require("cook_pnpm.units.pnpm_cli")
        local before = #stub.added_units()
        pnpm_cli.install({})
        pnpm_cli.run("@scope/web", "lint", { recipe_name = "web-lint" })
        local units = stub.added_units()
        assert.equals(before + 2, #units)
        assert.same({ id, "pnpm:host", result.install_key }, units[before + 1].seal)
        assert.same({ id, "pnpm:host", result.install_key }, units[before + 2].seal)
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
        assert.same({ "pnpm:toolchain:auto:identity", "pnpm:host", result.install_key }, web.seal,
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
