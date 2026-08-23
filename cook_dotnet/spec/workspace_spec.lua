local stub = require("spec.cook_stub")

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
    stub.reset()
    local projects = duplicate
        and { project("App", "src/A/App.csproj"), project("App", "src/B/App.csproj") }
        or { project("App", "src/App/App.csproj", "src/Lib/Lib.csproj", "Exe"),
            project("Lib", "src/Lib/Lib.csproj") }
    stub.materialize_as({ configuration = "Debug", projects = projects })
    stub.resolved({ "src/Graph.slnx", "src/App/App.csproj", "src/App/App.cs",
        "src/Lib/Lib.csproj", "src/Lib/Lib.cs", "src/Directory.Build.props" })
    return require("cook_dotnet"), projects
end

describe("cook_dotnet.workspace", function()
    it("mints one ordered recipe per evaluated project", function()
        local dotnet, projects = load_workspace()
        assert.same({ "dotnet:build", "dotnet:run" }, dotnet.workspace({ solution = "src/Graph.slnx" }))
        local recipes = stub.recipes()
        assert.is_nil(recipes["dotnet:discover"])
        stub.execute("dotnet:build")

        assert.same({}, recipes["dotnet:Lib"].opts.requires)
        assert.same({ "dotnet:Lib" }, recipes["dotnet:App"].opts.requires)
        assert.same({ "dotnet:App" }, recipes["dotnet:App:run"].opts.requires)

        local units = stub.units()
        assert.equal(2, #units)
        local materialized = stub.materialized()
        assert.equal("graph", materialized.name)
        assert.same({ "dotnet" }, materialized.spec.tools)
        assert.is_function(materialized.produce)
        local by_output = {}
        for _, unit in ipairs(units) do
            if unit.outputs then by_output[unit.outputs[1]] = unit end
        end
        local lib, app = by_output["build/dotnet/bin/Lib/**"], by_output["build/dotnet/bin/App/**"]
        assert.same({ "build/dotnet/bin/Lib/**", "build/dotnet/obj/Lib/**" }, lib.outputs)
        assert.same({ "build/dotnet/bin/App/**", "build/dotnet/obj/App/**" }, app.outputs)
        assert.is_truthy(table.concat(app.inputs, "\n")
            :find("build/dotnet/obj/Lib/%*%*/ref/%*%.dll"))
        assert.is_truthy(app.command:find("RestoreRecursive=false", 1, true))
        assert.is_truthy(app.command:find("--no-dependencies", 1, true))
        assert.is_truthy(app.command:find("UseCommonOutputDirectory=true", 1, true))
        assert.same({ "dotnet:toolchain" }, app.probes)

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
            if unit.outputs[1] == "build/dotnet/bin/App/**" then
                inputs = table.concat(unit.inputs, "\n")
            end
        end
        assert.is_string(inputs)
        assert.is_truthy(inputs:find("build/dotnet/bin/Lib/**", 1, true))
        assert.is_falsy(inputs:find("build/dotnet/obj/Lib/%*%*/ref/%*%.dll"))
    end)

    it("does not rescan every project directory during registration", function()
        local dotnet = load_workspace()
        dotnet.workspace({ solution = "src/Graph.slnx" })
        stub.execute("dotnet:build")

        assert.equal(2, stub.gather_count())
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

    it("rejects duplicate recipe names and use inside a recipe", function()
        local dotnet = load_workspace(true)
        dotnet.workspace({ solution = "src/Graph.slnx" })
        local ok, err = pcall(stub.execute, "dotnet:build")
        assert.is_false(ok)
        assert.is_truthy(err:find("same recipe 'dotnet:App'", 1, true))

        dotnet = load_workspace()
        ok, err = pcall(function()
            stub.in_recipe("bad", function()
                dotnet.workspace({ solution = "src/Graph.slnx" })
            end)
        end)
        assert.is_false(ok)
        assert.is_truthy(err:find("top level", 1, true))
    end)
end)
