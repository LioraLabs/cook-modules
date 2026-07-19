-- cook-modules/cook_pnpm/spec/tasks_overrides_spec.lua
-- Encodes the 0.4 per-package override contract (Turborepo
-- "<pkg>#<task>"): the override cfg REPLACES the base cfg for that
-- package (no merge); an override with no base entry mints for that
-- package only; override outputs claim default-input exclusions like
-- base outputs; an unknown package name is a register-time error. Also
-- pins the negated-output rejection — the engine's outputs[] surface
-- (CS-0085) has no `!` exclusion, so the module refuses the Turbo shape
-- instead of letting it silently match nothing.

local stub = require("cook_stub")

local function bootstrap_two_pkg_workspace()
    stub.set_file_contents("./pnpm-workspace.yaml",
        "packages:\n  - \"apps/*\"\n")
    stub.set_file_contents("./apps/web/package.json",
        [[{"name":"@scope/web","version":"0.0.1","scripts":{"build":"next build","test":"vitest run"}}]])
    stub.set_file_contents("./apps/desktop/package.json",
        [[{"name":"@scope/desktop","version":"0.0.1","scripts":{"build":"tauri build"}}]])
    stub.set_file_exists("./pnpm-lock.yaml", true)
    stub.set_glob("./apps/*/package.json", {
        "./apps/web/package.json",
        "./apps/desktop/package.json",
    })
    stub.set_sh_handler("find './apps/web'", function()
        return "./apps/web/src\n./apps/web/.next\n"
    end)
    stub.set_sh_handler("find './apps/desktop'", function()
        return "./apps/desktop/src\n"
    end)
    stub.set_glob("./apps/web/*", { "./apps/web/package.json" })
    stub.set_glob("./apps/desktop/*", { "./apps/desktop/package.json" })
end

local function has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

local function unit_for(pkg_name)
    for _, u in ipairs(stub.added_units()) do
        if u.command and u.command:find(pkg_name, 1, true) then return u end
    end
    return nil
end

describe("cook_pnpm 0.4 per-package task overrides", function()
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

    it("override cfg REPLACES the base cfg for that package; others keep base", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks = {
                build = { outputs = { "dist/**" } },
                ["@scope/web#build"] = { outputs = { ".next/**" } },
            },
            checks = false,
        })

        assert.equals(2, #stub.added_units())
        assert.same({ "./apps/web/.next/**" }, unit_for("@scope/web").outputs,
            "override outputs replace the base outputs — turbo semantics, no merge")
        assert.same({ "./apps/desktop/dist/**" }, unit_for("@scope/desktop").outputs,
            "non-overridden packages keep the base cfg")
    end)

    it("does not inherit base fields the override omits (no deep merge)", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks = {
                build = { outputs = { "dist/**" }, requires = { "wasm" } },
                ["@scope/web#build"] = { outputs = { ".next/**" } },
            },
            checks = false,
        })

        assert.same({}, stub.recipes()["@scope/web:build"].opts.requires,
            "an override that omits `requires` drops the base requires entirely")
        assert.same({ "wasm" }, stub.recipes()["@scope/desktop:build"].opts.requires)
    end)

    it("an override key with no base entry mints for that package only", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks = {
                ["@scope/web#build"] = { outputs = { ".next/**" } },
            },
            checks = false,
        })

        assert.equals(1, #stub.added_units())
        assert.is_not_nil(stub.recipes()["@scope/web:build"])
        assert.is_nil(stub.recipes()["@scope/desktop:build"],
            "no base entry — the task exists solely for the overridden package")
    end)

    it("override outputs enter that package's default-input exclusion set", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks = {
                build = { outputs = { "dist/**" } },
                ["@scope/web#build"] = { outputs = { ".next/**" } },
            },
            checks = { "test" },   -- only @scope/web declares test
        })

        assert.equals(1, #stub.added_tests())
        local t = stub.added_tests()[1]
        assert.is_true(has(t.inputs, "./apps/web/src/**/*"))
        assert.is_false(has(t.inputs, "./apps/web/.next/**/*"),
            ".next/ is claimed by the OVERRIDE's outputs — the check must not self-invalidate")
    end)

    it("errors at register time on an unknown package in an override key", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        assert.error_matches(function()
            tasks.mint_from_workspace({
                tasks = { ["@scope/nope#build"] = { outputs = { "dist/**" } } },
            })
        end, "unknown package '@scope/nope'")
    end)

    it("rejects a Turbo-style negated output glob, naming the engine gap", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        assert.error_matches(function()
            tasks.mint_from_workspace({
                tasks = {
                    build = { outputs = { ".next/**", "!.next/cache/**" } },
                },
            })
        end, "CS%-0085")
    end)

    it("rejects negated outputs in override cfgs too", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        assert.error_matches(function()
            tasks.mint_from_workspace({
                tasks = {
                    ["@scope/web#build"] = { outputs = { ".next/**", "!.next/cache/**" } },
                },
            })
        end, "negated glob")
    end)
end)
