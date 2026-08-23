local stub = require("spec.cook_stub")

local function load_module()
    package.loaded.cook_dotnet = nil
    stub.reset()
    return require("cook_dotnet")
end

describe("cook_dotnet.build", function()
    it("builds from a fresh isolated artifacts tree", function()
        local dotnet = load_module()
        stub.in_recipe("app", function()
            dotnet.build({ project = "src/App.csproj" })
        end)

        local probe = assert(stub.probe("dotnet:toolchain"))
        assert.same({ "dotnet" }, probe.inputs.tools)

        local units = stub.units()
        assert.equal(1, #units)
        assert.same({ "src/App.csproj", "src/Program.cs" }, units[1].inputs)
        assert.same({ "build/dotnet/app/**" }, units[1].outputs)
        assert.is_truthy(units[1].command:find("rm -rf -- 'build/dotnet/app' &&", 1, true))
        assert.is_truthy(units[1].command:find('"$<dotnet:toolchain.dotnet>" build', 1, true))
        assert.is_truthy(units[1].command:find('DOTNET_CLI_HOME="$(pwd)/.cook/dotnet/home"', 1, true))
        assert.is_truthy(units[1].command:find('NUGET_PACKAGES="$(pwd)/.cook/dotnet/packages"', 1, true))
        assert.is_truthy(units[1].command:find("--artifacts-path 'build/dotnet/app'", 1, true))
        assert.is_truthy(units[1].command:find("--configuration 'Debug'", 1, true))
        assert.same({ "dotnet:toolchain" }, units[1].probes)
        assert.same({ "dotnet:toolchain" }, units[1].seal)
        assert.same({ artifacts = "build/dotnet/app", outputs = { "build/dotnet/app/**" } },
            stub.export("app"))

        local gathered = stub.gathered()
        assert.same({ "src/**" }, gathered.globs)
        assert.is_truthy(table.concat(gathered.excludes, "\n"):find("src/obj/%*%*"))
        assert.is_truthy(table.concat(gathered.excludes, "\n"):find("build/dotnet/app/%*%*"))
    end)

    it("accepts explicit inputs and build dimensions", function()
        local dotnet = load_module()
        stub.in_recipe("nested:server", function()
            dotnet.build({
                project = "Server.slnx",
                root = "source",
                artifacts = "out/server",
                inputs = { "source/**/*.cs", "Directory.Build.props" },
                excludes = { "source/generated/**" },
                configuration = "Release",
                framework = "net10.0",
            })
        end)
        local command = stub.units()[1].command
        assert.is_truthy(command:find("--configuration 'Release'", 1, true))
        assert.is_truthy(command:find("--framework 'net10.0'", 1, true))
        assert.same({ "source/**/*.cs", "Directory.Build.props" }, stub.gathered().globs)
        assert.same({ artifacts = "out/server", outputs = { "out/server/**" } },
            stub.export("nested:server"))
    end)

    it("supports a project at the workspace root", function()
        local dotnet = load_module()
        stub.in_recipe("app", function() dotnet.build({ project = "App.csproj" }) end)
        assert.same({ "**" }, stub.gathered().globs)
    end)

    it("refuses unsafe cleanup paths and calls outside recipes", function()
        local dotnet = load_module()
        local ok, err = pcall(dotnet.build, { project = "App.csproj" })
        assert.is_false(ok)
        assert.is_truthy(err:find("inside a recipe block", 1, true))

        dotnet = load_module()
        ok, err = pcall(function()
            stub.in_recipe("app", function() dotnet.build({ project = "README.md" }) end)
        end)
        assert.is_false(ok)
        assert.is_truthy(err:find("must end in .csproj", 1, true))

        for _, artifacts in ipairs({ "", ".", "..", "../outside", "build/../../outside", "/tmp/out" }) do
            dotnet = load_module()
            ok, err = pcall(function()
                stub.in_recipe("app", function()
                    dotnet.build({ project = "App.csproj", artifacts = artifacts })
                end)
            end)
            assert.is_false(ok)
            assert.is_truthy(err:find("non%-root relative path"))
        end
    end)
end)
