local stub = require("spec.cook_stub")
local passthrough

local function reset()
    stub.reset()
    passthrough = nil
    cook.step_group = function(body) body() end
    cook.passthrough = function(outputs) passthrough = outputs end
end

local function project(name, path, reference, output_type)
    return { path = path, value = { Properties = { MSBuildProjectName = name, TargetFramework = "net8.0",
        TargetFrameworks = "", OutputType = output_type or "Library", TargetFileName = name .. ".dll",
        MSBuildAllProjects = path }, Items = { ProjectReference = reference and { { FullPath = reference } } or {},
        Compile = { { FullPath = path:match("(.+)/[^/]+$") .. "/" .. name .. ".cs" } }, Content = {},
        EmbeddedResource = {}, None = {}, AdditionalFiles = {}, Analyzer = {}, EditorConfigFiles = {},
        RazorComponent = {} } } }
end

local function multi_target(name, path, frameworks)
    local value = project(name, path).value
    value.Properties.TargetFramework = ""
    value.Properties.TargetFrameworks = frameworks
    return { path = path, value = value }
end

local function load_workspace(duplicate)
    package.loaded.cook_dotnet = nil
    reset()
    local projects = duplicate
        and { project("App", "src/A/App.csproj"), project("App", "src/B/App.csproj") }
        or { project("App", "src/App/App.csproj", "src/Lib/Lib.csproj", "Exe"),
            project("Lib", "src/Lib/Lib.csproj") }
    stub.materialize_as({ configuration = "Debug", toolchain = {
        dotnet_id = string.rep("d", 64), sdk = "10.0.302",
        netcore_ref = { versions = "8.0.10\n10.0.10", digest = string.rep("n", 64) },
        aspnetcore_ref = { versions = "8.0.10\n10.0.10", digest = string.rep("a", 64) },
    }, projects = projects })
    stub.resolved({ "src/Graph.slnx", "src/App/App.csproj", "src/App/App.cs",
        "src/Lib/Lib.csproj", "src/Lib/Lib.cs", "src/Directory.Build.props" })
    return require("cook_dotnet"), projects
end

describe("cook_dotnet.workspace", function()
    it("stages cached restore before native identity and named test children", function()
        local dotnet = load_workspace()
        dotnet.workspace({ solution = "src/Graph.slnx", project = "App", test_filter = "Name~Pass",
            test_args = { "--logger:console;verbosity=minimal", "" } })
        assert.has_error(function() cook.child_command("dotnet:App") end)
        assert.has_error(function() cook.chore("dotnet.late", {}, function() end) end)
        stub.execute("dotnet.test")
        local unit = stub.units()[1]
        assert.is_false(unit.cache)
        assert.is_true(unit.interactive)
        assert.is_truthy(unit.command:find("+__dotnet:test:restore", 1, true))
        assert.is_truthy(unit.command:find("-getProperty:IsTestProject", 1, true))
        assert.is_truthy(unit.command:find("UseArtifactsOutput=true", 1, true))
        assert.is_truthy(unit.command:find("+dotnet:App:test", 1, true))
        assert.is_falsy(unit.command:find("+dotnet:Lib:test", 1, true))
        assert.is_truthy(unit.command:find("invalid IsTestProject", 1, true))
        stub.execute("__dotnet:test:restore")
        for _, candidate in ipairs(stub.units()) do
            assert.is_falsy(candidate.command:find(" --no-incremental", 1, true))
        end
    end)

    it("keeps test-only diagnostics out of build and projects current dependency bytes", function()
        local dotnet = load_workspace()
        dotnet.workspace({ solution = "src/Graph.slnx", test_args = { [2] = "gap" } })
        assert.has_no.errors(function() stub.execute("dotnet:build") end)
        stub.execute("dotnet:App:test")
        assert.is_truthy(stub.units()[#stub.units()].command:find("contiguous list", 1, true))
        dotnet = load_workspace()
        dotnet.workspace({ solution = "src/Graph.slnx", test_filter = "Name~Pass" })
        stub.execute("dotnet:build")
        stub.execute("dotnet:App:test")
        local units = stub.units()
        local projection, runner = units[#units - 1], units[#units]
        assert.same({ "build/dotnet/bin/App/debug/**", "build/dotnet/bin/Lib/debug/**" }, projection.inputs)
        assert.same({ "build/dotnet/test/App/debug/**" }, projection.outputs)
        assert.is_false(runner.cache)
        assert.is_truthy(runner.command:find(" vstest ", 1, true))
        assert.is_truthy(runner.command:find("--TestCaseFilter:Name~Pass", 1, true))
        assert.is_truthy(runner.command:find("test-results/App/debug", 1, true))
    end)

    it("forwards generated project terminal outputs through dotnet:build", function()
        local dotnet = load_workspace()
        dotnet.workspace({ solution = "src/Graph.slnx" })
        stub.execute("dotnet:build")

        assert.same({
            "build/dotnet/bin/App/debug/**", "build/dotnet/bin/Lib/debug/**",
            "build/dotnet/obj/App/*", "build/dotnet/obj/App/debug/**",
            "build/dotnet/obj/Lib/*", "build/dotnet/obj/Lib/debug/**",
        }, passthrough)
    end)

    it("mints one ordered recipe per evaluated project", function()
        local dotnet, projects = load_workspace()
        assert.same({ "dotnet:build", "dotnet:run", "dotnet:test" }, dotnet.workspace({ solution = "src/Graph.slnx" }))
        local recipes = stub.recipes()
        assert.is_nil(recipes["dotnet:discover"])
        stub.execute("dotnet:build")

        assert.same({ "__dotnet:restore:Lib" }, recipes["dotnet:Lib"].opts.requires)
        assert.same({ "__dotnet:restore:App", "dotnet:Lib" }, recipes["dotnet:App"].opts.requires)
        assert.same({ "dotnet:App" }, recipes["dotnet:App:run"].opts.requires)

        local units = stub.units()
        assert.equal(2, #units)
        local materialized = stub.materialized()
        assert.equal("graph", materialized.name)
        assert.same({ "dotnet" }, materialized.spec.tools)
        assert.same({ "dotnet:toolchain" }, materialized.spec.seals)
        assert.is_falsy(table.concat(materialized.spec.files, "\n"):find("packages.lock.json", 1, true))
        assert.is_function(materialized.produce)
        local by_output = {}
        for _, unit in ipairs(units) do
            if unit.outputs then by_output[unit.outputs[1]] = unit end
        end
        local lib, app = by_output["build/dotnet/bin/Lib/debug/**"], by_output["build/dotnet/bin/App/debug/**"]
        assert.same({ "build/dotnet/bin/Lib/debug/**", "build/dotnet/obj/Lib/debug/**" }, lib.outputs)
        assert.same({ "build/dotnet/bin/App/debug/**", "build/dotnet/obj/App/debug/**" }, app.outputs)
        assert.is_truthy(table.concat(app.inputs, "\n")
            :find("build/dotnet/obj/Lib/debug/ref/%*%.dll"))
        stub.execute("__dotnet:restore:App")
        local restore = stub.units()[#stub.units()]
        assert.same({ "build/dotnet/obj/App/*" }, restore.outputs)
        assert.equal("local", restore.sharing)
        assert.is_truthy(restore.command:find("RestoreRecursive=false", 1, true))
        assert.is_falsy(restore.command:find("--use-lock-file", 1, true))
        assert.is_truthy(app.command:find("--no-incremental", 1, true))
        assert.is_truthy(app.command:find("--no-dependencies", 1, true))
        assert.is_falsy(app.command:find("UseCommonOutputDirectory", 1, true))
        assert.is_falsy(app.command:find("AllowMissingPrunePackageData", 1, true))
        assert.same({ "dotnet:tool", "dotnet:toolchain" }, app.probes)

        assert.same("src/App/App.csproj", stub.export("dotnet:App").project)
        assert.same("net8.0", stub.export("dotnet:App").framework)
    end)

    it("puts configuration in the discovery unit identity", function()
        local dotnet = load_workspace()
        dotnet.workspace({ solution = "src/Graph.slnx", configuration = "Release" })
        stub.execute("dotnet:build")

        assert.is_function(stub.materialized().produce)
    end)

    it("mints and keys one unit per target framework", function()
        local dotnet = load_workspace()
        stub.materialize_as({ configuration = "Release", projects = {
            multi_target("Lib", "src/Lib/Lib.csproj", "net8.0;net10.0"),
        } })
        dotnet.workspace({ solution = "src/Lib/Lib.csproj", configuration = "Release" })
        stub.execute("dotnet:build")

        local recipes = stub.recipes()
        assert.is_table(recipes["dotnet:Lib:tfm-6e6574382e30"])
        assert.is_table(recipes["dotnet:Lib:tfm-6e657431302e30"])
        assert.equal(2, #stub.units())
        for _, unit in ipairs(stub.units()) do
            assert.is_truthy(unit.command:find("--framework 'net", 1, true))
            assert.same({ "dotnet:toolchain" }, unit.seal)
        end
    end)

    it("uses implementation outputs only for source-generator references", function()
        local dotnet, projects = load_workspace()
        projects[1].value.Properties.OutputType = "Library"
        projects[1].value.Items.ProjectReference[1].OutputItemType = "Analyzer"
        projects[1].value.Items.ProjectReference[1].ReferenceOutputAssembly = "false"
        dotnet.workspace({ solution = "src/App/App.csproj" })
        stub.execute("dotnet:build")

        local inputs
        for _, unit in ipairs(stub.units()) do
            if unit.outputs[1] == "build/dotnet/bin/App/debug/**" then
                inputs = table.concat(unit.inputs, "\n")
            end
        end
        assert.is_string(inputs)
        assert.is_truthy(inputs:find("build/dotnet/bin/Lib/debug/**", 1, true))
        assert.is_falsy(inputs:find("build/dotnet/obj/Lib/debug/ref/%*%.dll"))
    end)

    it("isolates reference and generator inputs by target framework", function()
        local dotnet = load_workspace()
        local app = multi_target("App", "src/App/App.csproj", "net8.0;net10.0")
        app.value.Items.ProjectReference = {
            { FullPath = "src/Lib/Lib.csproj" },
            { FullPath = "src/Gen/Gen.csproj", OutputItemType = "Analyzer",
                ReferenceOutputAssembly = "false" },
        }
        stub.materialize_as({ configuration = "Release", projects = {
            app,
            multi_target("Lib", "src/Lib/Lib.csproj", "net8.0;net10.0"),
            multi_target("Gen", "src/Gen/Gen.csproj", "net8.0;net10.0"),
        } })
        dotnet.workspace({ solution = "src/App/App.csproj", configuration = "Release" })
        stub.execute("dotnet:build")

        for _, unit in ipairs(stub.units()) do
            local framework = unit.command:match("%-%-framework '([^']+)'$")
            if unit.outputs[1]:find("build/dotnet/bin/App/", 1, true) then
                local inputs = table.concat(unit.inputs, "\n")
                assert.is_truthy(inputs:find("build/dotnet/obj/Lib/release_" .. framework
                    .. "/ref/*.dll", 1, true))
                assert.is_truthy(inputs:find("build/dotnet/bin/Gen/release_" .. framework
                    .. "/**", 1, true))
                local sibling = framework == "net8.0" and "net10.0" or "net8.0"
                assert.is_falsy(inputs:find("release_" .. sibling, 1, true))
            end
        end
    end)

    it("does not rescan every project directory during registration", function()
        local dotnet = load_workspace()
        dotnet.workspace({ solution = "src/Graph.slnx" })
        stub.execute("dotnet:build")

        assert.equal(3, stub.gather_count())
    end)

    it("scopes workspace inputs to an explicit root and includes ancestor configuration", function()
        local dotnet = load_workspace()
        dotnet.workspace({ solution = "apps/radarr/src/Graph.slnx", root = "apps/radarr/src" })

        local graph, inputs = stub.gathers()[1].globs, stub.gathers()[2].globs
        local function has(list, value)
            for _, item in ipairs(list) do if item == value then return true end end
            return false
        end
        assert.is_true(has(graph, "apps/radarr/src/**/*.csproj"))
        assert.is_false(has(graph, "**/*.csproj"))
        assert.is_true(has(graph, "Directory.Build.props"))
        assert.is_true(has(graph, "apps/NuGet.config"))
        assert.is_true(has(graph, "apps/radarr/Directory.Build.targets"))
        assert.is_false(has(graph, "apps/**/*.props"))
        assert.is_false(has(graph, "apps/radarr/src/**/packages.lock.json"))
        assert.is_true(has(inputs, "apps/radarr/src/**/packages.lock.json"))
    end)

    it("rejects projects MSBuild discovers outside an explicit root", function()
        local dotnet = load_workspace()
        stub.materialize_as({ configuration = "Debug", projects = {
            project("App", "src/App/App.csproj", "shared/$(Flavor)/Lib.csproj"),
            project("Lib", "shared/$(Flavor)/Lib.csproj"),
        } })
        dotnet.workspace({ solution = "src/App/App.csproj", root = "src" })

        assert.has_error(function() stub.execute("dotnet:build") end,
            "[cook_dotnet.workspace] MSBuild discovered project 'shared/$(Flavor)/Lib.csproj' outside root 'src'; expand root to include it")
    end)

    it("keeps evaluated project bin and obj items out of build inputs", function()
        local dotnet, projects = load_workspace()
        projects[1].value.Properties.OutputType = "Library"
        projects[1].value.Properties.MSBuildAllProjects = "src/App/App.csproj;src/App/obj/generated.props"
        projects[1].value.Items.ProjectReference = {}
        projects[1].value.Items.None = { { FullPath = "src/App/bin/Debug/net8.0/App.dll" },
            { FullPath = "src/App/obj/Debug/net8.0/App.dll" }, { FullPath = "src/App/assets/kept.txt" },
            { FullPath = "src/Shared/bin/kept.txt" } }
        dotnet.workspace({ solution = "src/App/App.csproj" })
        stub.execute("dotnet:build")

        local inputs = table.concat(stub.units()[1].inputs, "\n")
        assert.is_falsy(inputs:find("src/App/bin/", 1, true))
        assert.is_falsy(inputs:find("src/App/obj/", 1, true))
        assert.is_truthy(inputs:find("src/App/assets/kept.txt", 1, true))
        assert.is_truthy(inputs:find("src/Shared/bin/kept.txt", 1, true))
    end)

    it("scopes lockfiles and applies the Web workaround only to evaluated Web SDK projects", function()
        local dotnet, projects = load_workspace()
        projects[1].value.Properties.UsingMicrosoftNETSdkWeb = "true"
        stub.materialize_as({ configuration = "Debug", toolchain = {
            dotnet_id = string.rep("d", 64), sdk = "10.0.302",
            netcore_ref = { versions = "8.0.10", digest = string.rep("n", 64) },
            aspnetcore_ref = { versions = "", digest = "<missing>" },
        }, projects = projects })
        stub.resolved({ "src/Graph.slnx", "global.json", "NuGet.config", "src/Directory.Build.props",
            "src/App/App.csproj", "src/App/App.cs", "src/App/packages.lock.json",
            "src/Lib/Lib.csproj", "src/Lib/Lib.cs", "src/Lib/packages.lock.json" })
        dotnet.workspace({ solution = "src/Graph.slnx" })
        stub.execute("dotnet:build")
        local by_output = {}; for _, unit in ipairs(stub.units()) do by_output[unit.outputs[1]] = unit end
        local app, lib = by_output["build/dotnet/bin/App/debug/**"], by_output["build/dotnet/bin/Lib/debug/**"]
        assert.is_truthy(app.command:find("AllowMissingPrunePackageData=true", 1, true))
        assert.is_falsy(lib.command:find("AllowMissingPrunePackageData=true", 1, true))
        assert.is_truthy(table.concat(app.inputs, "\n"):find("src/App/packages.lock.json", 1, true))
        assert.is_falsy(table.concat(app.inputs, "\n"):find("src/Lib/packages.lock.json", 1, true))
        assert.is_truthy(table.concat(lib.inputs, "\n"):find("src/Lib/packages.lock.json", 1, true))
        assert.is_falsy(table.concat(lib.inputs, "\n"):find("src/App/packages.lock.json", 1, true))
        stub.execute("__dotnet:restore:App")
        stub.execute("__dotnet:restore:Lib")
        local restore_units = stub.units()
        assert.is_truthy(restore_units[#restore_units - 1].command:find("--use-lock-file --locked-mode", 1, true))
        assert.is_truthy(restore_units[#restore_units].command:find("--use-lock-file --locked-mode", 1, true))

        package.loaded.cook_dotnet = nil
        reset()
        stub.materialize_as({ configuration = "Debug", toolchain = {
            dotnet_id = string.rep("d", 64), sdk = "10.0.302",
            netcore_ref = { versions = "8.0.10", digest = string.rep("n", 64) },
            aspnetcore_ref = { versions = "", digest = "<missing>" },
        }, projects = { projects[1], projects[2] } })
        stub.resolved({ "src/Graph.slnx", "src/App/App.csproj", "src/Lib/Lib.csproj" })
        dotnet = require("cook_dotnet")
        dotnet.workspace({ solution = "src/Graph.slnx" })
        stub.execute("dotnet:build")
        local web_unit
        for _, unit in ipairs(stub.units()) do
            if unit.outputs[1] == "build/dotnet/bin/App/debug/**" then web_unit = unit end
        end
        assert.is_truthy(web_unit.command:find("AllowMissingPrunePackageData=true", 1, true))
        assert.is_falsy(web_unit.command:find("--use-lock-file", 1, true))
    end)

    it("treats single-entry TargetFrameworks executables as runnable", function()
        local dotnet = load_workspace()
        local app = multi_target("App", "src/App/App.csproj", "net8.0")
        app.value.Properties.OutputType = "Exe"
        app.value.Items.ProjectReference = { { FullPath = "src/Lib/Lib.csproj" } }
        stub.materialize_as({ configuration = "Debug", projects = {
            app, multi_target("Lib", "src/Lib/Lib.csproj", "net8.0"),
        } })
        dotnet.workspace({ solution = "src/Graph.slnx" })
        stub.execute("dotnet:build")
        stub.execute("dotnet:run")

        local recipes = stub.recipes()
        assert.is_table(recipes["dotnet:App:run"])
        assert.same({ "dotnet:App" }, recipes["dotnet:App:run"].opts.requires)
        local run_unit
        for _, unit in ipairs(stub.units()) do
            if unit.command:find("run/App/debug_net8.0/App.dll'", 1, true) then run_unit = unit end
        end
        assert.is_table(run_unit)
        assert.is_false(run_unit.cache)
    end)

    it("defers run-target validation until dotnet:run is dispatched", function()
        local dotnet = load_workspace()
        stub.materialize_as({ configuration = "Debug", projects = {
            project("Lib", "src/Lib/Lib.csproj"),
        } })
        dotnet.workspace({ solution = "src/Lib/Lib.csproj" })
        stub.execute("dotnet:build")
        for _, unit in ipairs(stub.units()) do
            assert.is_falsy(unit.command:find("dotnet:run requires", 1, true))
        end

        stub.execute("dotnet:run")
        local failure = stub.units()[#stub.units()]
        assert.is_false(failure.cache)
        assert.is_truthy(failure.command:find("found 0 executable projects", 1, true))
    end)

    it("rejects duplicate recipe names and use inside a recipe", function()
        local dotnet = load_workspace(true)
        local ok, err = pcall(dotnet.workspace, { solution = "src/Graph.slnx" })
        assert.is_false(ok)
        assert.is_truthy(err:find("same recipe 'dotnet:App:test'", 1, true))
        assert.is_truthy(err:find("src/A/App.csproj", 1, true))
        assert.is_truthy(err:find("src/B/App.csproj", 1, true))

        dotnet = load_workspace()
        ok, err = pcall(function()
            stub.in_recipe("bad", function()
                dotnet.workspace({ solution = "src/Graph.slnx" })
            end)
        end)
        assert.is_false(ok)
        assert.is_truthy(err:find("top level", 1, true))
    end)
    it("selects only the native framework closure and its passthrough outputs", function()
        local dotnet = load_workspace()
        local app = multi_target("App", "src/App/App.csproj", "net8.0;net10.0")
        app.value.Items.ProjectReference = { { FullPath = "src/Lib/Lib.csproj", NearestTargetFramework = "netstandard2.1" } }
        local lib = project("Lib", "src/Lib/Lib.csproj")
        lib.value.Properties.TargetFramework = "netstandard2.1"
        stub.materialize_as({ projects = { app, lib, project("Other", "src/Other/Other.csproj") } })
        dotnet.workspace({ solution = "src/Graph.slnx", project = "App", framework = "net8.0" })
        stub.execute("dotnet:build")
        assert.is_nil(stub.recipes()["dotnet:Other"].executed)
        local commands = {}
        for _, unit in ipairs(stub.units()) do commands[#commands + 1] = unit.command end
        local text = table.concat(commands, "\n")
        assert.is_truthy(text:find("--framework 'netstandard2.1'", 1, true))
        assert.is_truthy(text:find("--framework 'net8.0'", 1, true))
        assert.is_nil(text:find("--framework 'net10.0'", 1, true))
        assert.same({ "build/dotnet/bin/App/debug_net8.0/**", "build/dotnet/bin/Lib/debug/**",
            "build/dotnet/obj/App/*", "build/dotnet/obj/App/debug_net8.0/**",
            "build/dotnet/obj/Lib/*", "build/dotnet/obj/Lib/debug/**" }, passthrough)
    end)

    it("keeps project and framework selection out of discovery identity", function()
        local dotnet = load_workspace()
        dotnet.workspace({ solution = "src/Graph.slnx", project = "App", framework = "net8.0" })
        local first = string.dump(stub.materialized().produce)
        dotnet = load_workspace()
        dotnet.workspace({ solution = "src/Graph.slnx", project = "src/Lib/./Lib.csproj" })
        assert.equal(first, string.dump(stub.materialized().produce))
        stub.execute("dotnet:build")
        assert.is_nil(stub.recipes()["dotnet:App"].executed)
        assert.is_true(stub.recipes()["dotnet:Lib"].executed)
    end)

    it("reports selector choices and validates even single-target framework requests", function()
        local function rejected(options, message)
            local dotnet = load_workspace()
            options.solution = "src/Graph.slnx"
            local ok, err = pcall(function() dotnet.workspace(options); stub.execute("dotnet:build") end)
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find(message, 1, true))
        end
        rejected({ project = "Missing" }, "choose one of: App (src/App/App.csproj)")
        rejected({ project = "Lib", framework = "net9.0" }, "choose one of: net8.0")
        rejected({ framework = "net8.0" }, "framework requires a project")
        rejected({ project = 42 }, "project and framework must be strings")
        rejected({ project = "../Lib/Lib.csproj" }, "project must be a non-root relative path")
    end)

    it("runs the selected inner-build executable with quoted arguments and its compatible closure", function()
        local dotnet = load_workspace()
        local app = multi_target("App", "src/App/App.csproj", "net8.0;net10.0")
        local inner = project("App", "src/App/App.csproj", "src/Lib/Lib.csproj", "Exe").value
        inner.Properties.TargetFileName = "ActualTarget.dll"
        inner.Items.ProjectReference[1].NearestTargetFramework = "net8.0"
        app.builds = { ["net10.0"] = inner, ["net8.0"] = project("App", "src/App/App.csproj").value }
        stub.materialize_as({ projects = { app, project("Lib", "src/Lib/Lib.csproj"),
            project("Other", "src/Other/Other.csproj", nil, "Exe") } })
        dotnet.workspace({ solution = "src/Graph.slnx", project = "App", framework = "net10.0",
            args = { "space value", "", "$(echo literal)" } })
        stub.execute("dotnet:run")
        local units = stub.units()
        local projection, execution = units[#units - 1], units[#units]
        assert.same({ "build/dotnet/bin/App/debug_net10.0/**", "build/dotnet/bin/Lib/debug/**" }, projection.inputs)
        assert.same({ "build/dotnet/run/App/debug_net10.0/ActualTarget.dll" }, execution.inputs)
        assert.is_true(execution.interactive)
        assert.is_false(execution.cache)
        assert.is_truthy(execution.command:find(" 'space value' '' '$(echo literal)'", 1, true))
        assert.is_nil(stub.recipes()["dotnet:Other"].executed)
        assert.is_nil(passthrough)
    end)

    it("rejects ambiguous applications, multi-target runs, and invalid argument lists", function()
        local function rejected(options, projects, message)
            local dotnet = load_workspace()
            if projects then stub.materialize_as({ projects = projects }) end
            options.solution = "src/Graph.slnx"
            local ok, err = pcall(function() dotnet.workspace(options); stub.execute("dotnet:run") end)
            if ok then
                local failure = stub.units()[#stub.units()]
                assert.is_false(failure.cache)
                assert.is_truthy(failure.command:find("exit 1", 1, true))
                err = failure.command
            end
            assert.is_truthy(tostring(err):find(message, 1, true))
        end
        rejected({}, { project("A", "src/A/A.csproj", nil, "Exe"),
            project("B", "src/B/B.csproj", nil, "Exe") }, "choose one of: A (src/A/A.csproj), B (src/B/B.csproj)")
        rejected({ project = "App" }, { multi_target("App", "src/App/App.csproj", "net8.0;net10.0") },
            "requires FRAMEWORK")
        rejected({ project = "Lib" }, nil, "not executable")
        rejected({ args = "shell string" }, nil, "args must be a list of strings")
        rejected({ args = { 42 } }, nil, "args must be a list of strings")
        rejected({ args = { [2] = "hole" } }, nil, "contiguous list")
        rejected({ args = { "nul" .. string.char(0) } }, nil, "NUL bytes")
    end)

end)
