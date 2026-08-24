local stub = require("spec.cook_stub")

local function load_module()
    package.loaded.cook_dotnet = nil
    stub.reset()
    return require("cook_dotnet")
end

describe("cook_dotnet.build", function()
    it("builds from a fresh isolated artifacts tree", function()
        local dotnet = load_module()
        stub.resolved(function(globs)
            if globs[1] == "src/**/packages.lock.json" then return {} end
            return { "src/App.csproj", "src/Program.cs" }
        end)
        stub.in_recipe("app", function()
            dotnet.build({ project = "src/App.csproj" })
        end)

        local probe = assert(stub.probe("dotnet:toolchain"))
        assert.same({ "dotnet" }, probe.inputs.tools)
        assert.same("@tools-identity", assert(stub.probe("dotnet:tool")).produce)

        local units = stub.units()
        assert.equal(1, #units)
        assert.same({ "src/App.csproj", "src/Program.cs" }, units[1].inputs)
        assert.same({ "build/dotnet/app/**" }, units[1].outputs)
        assert.is_truthy(units[1].command:find("rm -rf -- 'build/dotnet/app' &&", 1, true))
        assert.is_truthy(units[1].command:find('"$<dotnet:tool.dotnet.path>" restore', 1, true))
        assert.is_truthy(units[1].command:find('"$<dotnet:tool.dotnet.path>" build', 1, true))
        assert.is_falsy(units[1].command:find("--use-lock-file", 1, true))
        assert.is_truthy(units[1].command:find("-getProperty:UsingMicrosoftNETSdkWeb", 1, true))
        assert.is_truthy(units[1].command:find("AllowMissingPrunePackageData=true", 1, true))
        assert.is_truthy(units[1].command:find('DOTNET_CLI_HOME="$(pwd)/.cook/dotnet/home"', 1, true))
        assert.is_truthy(units[1].command:find('NUGET_PACKAGES="$(pwd)/.cook/dotnet/packages"', 1, true))
        assert.is_truthy(units[1].command:find("--artifacts-path 'build/dotnet/app'", 1, true))
        assert.is_truthy(units[1].command:find("--configuration 'Debug'", 1, true))
        assert.same({ "dotnet:tool", "dotnet:toolchain" }, units[1].probes)
        assert.same({ "dotnet:toolchain" }, units[1].seal)
        stub.command("'/stub/bin/dotnet' --version", "10.0.302\n")
        stub.command("'/stub/bin/dotnet' --info", "Base Path: /stub/dotnet/sdk/10.0.302/\n")
        stub.command("if [ -d '/stub/dotnet/packs/Microsoft.NETCore.App.Ref' ]; then for", "8.0.10\n10.0.10")
        stub.command("if [ -d '/stub/dotnet/packs/Microsoft.NETCore.App.Ref' ]; then cd", string.rep("n", 64))
        stub.command("if [ -d '/stub/dotnet/packs/Microsoft.AspNetCore.App.Ref' ]; then for", "10.0.10")
        stub.command("if [ -d '/stub/dotnet/packs/Microsoft.AspNetCore.App.Ref' ]; then cd", string.rep("a", 64))
        local toolchain = assert(load(probe.produce))()
        assert.same("dotnet" .. string.rep("0", 58), toolchain.dotnet_id)
        assert.same("10.0.302", toolchain.sdk)
        assert.same({ versions = "8.0.10\n10.0.10", digest = string.rep("n", 64) }, toolchain.netcore_ref)
        assert.same({ versions = "10.0.10", digest = string.rep("a", 64) }, toolchain.aspnetcore_ref)
        assert.is_falsy(require("cjson.safe").encode(toolchain):find("/stub/bin", 1, true))
        assert.same({ artifacts = "build/dotnet/app", outputs = { "build/dotnet/app/**" } },
            stub.export("app"))

        local gathered = stub.gathers()[1]
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
        assert.is_falsy(command:find("-getProperty:UsingMicrosoftNETSdkWeb", 1, true))
        assert.same({ "source/**/*.cs", "Directory.Build.props" }, stub.gathers()[1].globs)
        assert.same({ artifacts = "out/server", outputs = { "out/server/**" } },
            stub.export("nested:server"))
    end)

    it("supports a project at the workspace root", function()
        local dotnet = load_module()
        stub.in_recipe("app", function() dotnet.build({ project = "App.csproj" }) end)
        assert.same({ "**" }, stub.gathers()[1].globs)
    end)

    it("adds the lockfile even when callers choose explicit inputs", function()
        local dotnet = load_module()
        stub.resolved(function(globs)
            if globs[1] == "source/**/packages.lock.json" then return { "source/packages.lock.json" } end
            return { "source/App.csproj", "source/App.cs" }
        end)
        stub.in_recipe("app", function()
            dotnet.build({ project = "source/App.csproj", inputs = { "source/**/*.cs" } })
        end)
        assert.same({ "source/App.cs", "source/App.csproj", "source/packages.lock.json" }, stub.units()[1].inputs)
        assert.is_truthy(stub.units()[1].command:find("--use-lock-file --locked-mode", 1, true))
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
