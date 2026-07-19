-- cook-modules/cook_pnpm/spec/tasks_depfold_spec.lua
-- Encodes the 0.4 dependency-output folding + env contracts. Found
-- dogfooding the Cap port: minted units ignored dep dist content
-- entirely (byte-correct only for externals-style bundlers), checks
-- raced their producers, and env drift never invalidated.
--
--   BUILD  consumer command gains a depfile generator over the dep
--          packages' claimed output dirs, declared via discovered_inputs
--          (make format) — dep content folds with zero settle runs.
--   CHECK  gains a defaulted {"^build"} edge (strict: batch-minted
--          targets only) and the dep dirs as ready-time glob inputs.
--   ENV    cfg.env / workspace env lower to consulted_env_keys on build
--          units (§17.1.2.1 auto-fold); env on a check is an error.

local stub = require("cook_stub")

local function bootstrap_two_pkg_workspace()
    stub.set_file_contents("./pnpm-workspace.yaml",
        "packages:\n  - \"pkgs/*\"\n")
    stub.set_file_contents("./pkgs/lib/package.json",
        [[{"name":"@scope/lib","version":"0.0.1","scripts":{"build":"tsdown"}}]])
    stub.set_file_contents("./pkgs/app/package.json",
        [[{"name":"@scope/app","version":"0.0.1","scripts":{"build":"vite build","typecheck":"tsc -b"},"dependencies":{"@scope/lib":"workspace:*"}}]])
    stub.set_file_exists("./pnpm-lock.yaml", true)
    stub.set_glob("./pkgs/*/package.json",
        { "./pkgs/lib/package.json", "./pkgs/app/package.json" })
    stub.set_sh_handler("find './pkgs/lib'", function()
        return "./pkgs/lib/src\n"
    end)
    stub.set_sh_handler("find './pkgs/app'", function()
        return "./pkgs/app/src\n"
    end)
    stub.set_glob("./pkgs/lib/*", { "./pkgs/lib/package.json" })
    stub.set_glob("./pkgs/app/*", { "./pkgs/app/package.json" })
end

local function unit_for(cmd_fragment)
    for _, u in ipairs(stub.added_units()) do
        if u.command and u.command:find(cmd_fragment, 1, true) then return u end
    end
    return nil
end

local function test_for(cmd_fragment)
    for _, t in ipairs(stub.added_tests()) do
        if t.command:find(cmd_fragment, 1, true) then return t end
    end
    return nil
end

local function has(list, v)
    for _, x in ipairs(list or {}) do if x == v then return true end end
    return false
end

describe("cook_pnpm 0.4 dependency-output folding + env", function()
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

    it("folds dep outputs into a consumer build via a discovered-inputs depfile", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks  = { build = { outputs = { "dist/**" }, depends_on = { "^build" } } },
            checks = false,
        })

        local app = unit_for("--filter @scope/app run build")
        assert.is_not_nil(app)
        -- Paths are working-dir-relative: the engine requires a relative
        -- discovered_inputs.from, and relative depfile bodies stay
        -- machine-portable.
        assert.truthy(app.command:find("find 'pkgs/lib/dist'", 1, true),
            "depfile generator must enumerate the dep's claimed output dir")
        assert.same({ from = "pkgs/app/" .. tasks.DEPFILE_NAME, format = "make" },
            app.discovered_inputs)
    end)

    it("leaves a dependency-less build command untouched", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks  = { build = { outputs = { "dist/**" }, depends_on = { "^build" } } },
            checks = false,
        })

        local lib = unit_for("--filter @scope/lib run build")
        assert.is_not_nil(lib)
        assert.is_nil(lib.command:find("&&", 1, true))
        assert.is_nil(lib.discovered_inputs)
    end)

    it("gives an auto check a strict ^build edge and ready-time dep glob inputs", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            tasks = { build = { outputs = { "dist/**" }, depends_on = { "^build" } } },
        })

        local r = stub.recipes()["@scope/app:typecheck"]
        assert.is_not_nil(r)
        assert.same({ "@scope/lib:build" }, r.opts.requires)
        local t = test_for("--filter @scope/app run typecheck")
        assert.is_not_nil(t)
        assert.truthy(has(t.inputs, "./pkgs/lib/dist/**/*"))
    end)

    it("drops the defaulted check edge when the batch mints no build task", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.mint_from_workspace({ tasks = {} })   -- checks="auto" only

        local r = stub.recipes()["@scope/app:typecheck"]
        assert.is_not_nil(r)
        assert.same({}, r.opts.requires)
    end)

    it("lowers workspace env + task env to consulted_env_keys on builds", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            env    = { "CI" },
            tasks  = {
                build = { outputs = { "dist/**" } },
                ["@scope/app#build"] = { outputs = { "dist/**" },
                                         env = { "API_URL" } },
            },
            checks = false,
        })

        assert.same({ "CI" },
            unit_for("--filter @scope/lib run build").consulted_env_keys)
        assert.same({ "CI", "API_URL" },
            unit_for("--filter @scope/app run build").consulted_env_keys)
    end)

    it("rejects env on a check at register time", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        assert.error_matches(function()
            tasks.mint_from_workspace({
                tasks  = { typecheck = { kind = "check", env = { "CI" } } },
                checks = false,
            })
        end, "consulted%-env surface")
    end)
end)
