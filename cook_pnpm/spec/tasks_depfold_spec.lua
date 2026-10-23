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
--   ENV    cfg.env / workspace env seal one pnpm:env:<NAME> probe per
--          variable on build AND check units (unset / empty / value).

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
        workspace = require("cook_pnpm.discovery.workspace")
        tasks     = require("cook_pnpm.units.tasks")
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

        local r = stub.recipes()["pnpm:app:typecheck"]
        assert.is_not_nil(r)
        assert.same({ "pnpm:lib:build" }, r.opts.requires)
        local t = test_for("--filter @scope/app run typecheck")
        assert.is_not_nil(t)
        assert.truthy(has(t.inputs, "./pkgs/lib/dist/**/*"))
    end)

    it("drops the defaulted check edge when the batch mints no build task", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.mint_from_workspace({ tasks = {} })   -- checks="auto" only

        local r = stub.recipes()["pnpm:app:typecheck"]
        assert.is_not_nil(r)
        assert.same({}, r.opts.requires)
    end)

    it("seals declared env vars on builds AND checks, registered before any recipe body", function()
        -- A probe first registered inside a recipe body is not scheduled
        -- for another recipe's unit that seals it.
        local in_body, in_body_probes = false, {}
        local recipe, probe = cook.recipe, cook.probe
        cook.recipe = function(name, opts, body)
            return recipe(name, opts, function(...)
                in_body = true
                local ok, err = pcall(body, ...)
                in_body = false
                if not ok then error(err, 0) end
            end)
        end
        cook.probe = function(key, opts)
            if in_body then in_body_probes[key] = true end
            return probe(key, opts)
        end
        bootstrap_two_pkg_workspace()
        local result = workspace.bootstrap({})
        tasks.mint_from_workspace({
            env    = { "CI" },
            tasks  = {
                build = { outputs = { "dist/**" } },
                ["@scope/app#build"] = { outputs = { "dist/**" },
                                         env = { "API_URL", "CI" } },
                typecheck = { kind = "check", env = { "NODE_ENV" } },
            },
            checks = false,
        })

        local id = "pnpm:toolchain:auto:identity"
        assert.same({ id, "pnpm:host", result.install_key, "pnpm:env:CI" },
            unit_for("--filter @scope/lib run build").seal)
        assert.same({ id, "pnpm:host", result.install_key, "pnpm:env:CI", "pnpm:env:API_URL" },
            unit_for("--filter @scope/app run build").seal, "duplicates collapse")
        assert.same({ id, "pnpm:host", result.install_key, "pnpm:env:CI", "pnpm:env:NODE_ENV" },
            test_for("--filter @scope/app run typecheck").seal)
        assert.is_nil(unit_for("--filter @scope/app run build").consulted_env_keys)
        for _, k in ipairs({ "pnpm:env:CI", "pnpm:env:API_URL", "pnpm:env:NODE_ENV" }) do
            assert.is_not_nil(stub.probe_opts(k), k .. " registered")
            assert.is_nil(in_body_probes[k], k .. " must be registered outside any recipe body")
        end
    end)

    it("keys unset, empty, and a value apart, reading only the declared name", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.mint_from_workspace({
            env = { "NODE_ENV" }, tasks = { build = { outputs = { "dist/**" } } }, checks = false,
        })
        local produce = stub.probe_opts("pnpm:env:NODE_ENV").produce
        local function value_with(envtbl)
            local asked = {}
            local fake_os = { getenv = function(n) asked[#asked + 1] = n; return envtbl[n] end }
            local chunk = assert(load("return (function()\n" .. produce .. "\nend)()",
                "produce", "t", { os = fake_os }))
            local v = chunk()
            assert.same({ "NODE_ENV" }, asked, "reads the declared name and nothing else")
            return v
        end
        local unset = value_with({})
        local empty = value_with({ NODE_ENV = "" })
        local dev   = value_with({ NODE_ENV = "development" })
        assert.same({ set = false, value = "" }, unset)
        assert.same({ set = true,  value = "" }, empty)
        assert.same({ set = true,  value = "development" }, dev)
    end)

    it("rejects an env entry that is not a variable name", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        assert.error_matches(function()
            tasks.mint_from_workspace({
                tasks  = { build = { outputs = { "dist/**" }, env = { "X\"); os.exit(1) --" } } },
                checks = false,
            })
        end, "not an environment variable name")
    end)

    it("rejects a non-list env, task-level and workspace-level", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        assert.error_matches(function()
            tasks.mint_from_workspace({
                tasks = { build = { outputs = { "dist/**" }, env = "NODE_ENV" } }, checks = false,
            })
        end, "env must be a list of variable names")
        assert.error_matches(function()
            tasks.mint_from_workspace({
                env = "NODE_ENV", tasks = { build = { outputs = { "dist/**" } } }, checks = false,
            })
        end, "env must be a list of variable names")
    end)
end)
