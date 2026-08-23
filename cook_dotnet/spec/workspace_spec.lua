local stub = require("spec.cook_stub")

local function project_lua(name, path, reference, output_type)
    local ref = reference and ('{{FullPath=%q}}'):format(reference) or "{}"
    return ([=[{path=%q,value={Properties={MSBuildProjectName=%q,TargetFramework="net8.0",TargetFrameworks="",
      OutputType=%q,TargetFileName=%q,MSBuildAllProjects=%q},Items={ProjectReference=%s,
      Compile={{FullPath=%q}},Content={},EmbeddedResource={},None={},AdditionalFiles={},Analyzer={},
      EditorConfigFiles={},RazorComponent={}}}}]=]):format(path, name, output_type or "Library",
        name .. ".dll", path, ref, path:match("(.+)/[^/]+$") .. "/" .. name .. ".cs")
end

local function load_workspace(duplicate)
    package.loaded.cook_dotnet = nil
    stub.reset()
    local projects
    if duplicate then
        projects = project_lua("App", "src/A/App.csproj") .. "," .. project_lua("App", "src/B/App.csproj")
    else
        projects = project_lua("App", "src/App/App.csproj", "src/Lib/Lib.csproj", "Exe") .. ","
            .. project_lua("Lib", "src/Lib/Lib.csproj")
    end
    stub.materialized("build/dotnet/discovery.lua", "return {projects={" .. projects .. "}}")
    stub.resolved({ "src/Graph.slnx", "src/App/App.csproj", "src/App/App.cs",
        "src/Lib/Lib.csproj", "src/Lib/Lib.cs", "src/Directory.Build.props" })
    return require("cook_dotnet")
end

describe("cook_dotnet.workspace", function()
    it("mints one ordered recipe per evaluated project", function()
        local dotnet = load_workspace()
        assert.same({ "dotnet:build", "dotnet:run" }, dotnet.workspace({ solution = "src/Graph.slnx" }))
        stub.execute("dotnet:build")

        local recipes = stub.recipes()
        assert.same({}, recipes["dotnet:Lib"].opts.requires)
        assert.same({ "dotnet:Lib" }, recipes["dotnet:App"].opts.requires)
        assert.is_truthy(recipes["dotnet:discover"])
        assert.same({ "dotnet:App" }, recipes["dotnet:App:run"].opts.requires)

        local units = stub.units()
        assert.equal(3, #units)
        assert.equal("build/dotnet/discovery.lua", units[1].output)
        assert.is_truthy(units[1].lua_code:find('configuration, query_items = "src/Graph.slnx", "build/dotnet/discovery.lua", "Debug"', 1, true))
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

        assert.is_truthy(stub.units()[1].lua_code:find('configuration, query_items = "src/Graph.slnx", "build/dotnet/discovery.lua", "Release"', 1, true))
    end)

    it("keeps project bin and obj trees out of build inputs", function()
        local dotnet = load_workspace()
        dotnet.workspace({ solution = "src/Graph.slnx" })
        stub.resolved(function(_, excludes)
            local excluded = {}
            for _, pattern in ipairs(excludes) do excluded[pattern] = true end
            local files = { "src/App/App.cs", "src/App/bin/generated.dll", "src/App/obj/generated.dll",
                "src/App/nested/bin/generated.dll", "src/App/nested/obj/generated.dll" }
            local kept = {}
            for _, file in ipairs(files) do
                local immediate = file:match("^src/App/(bin)/") or file:match("^src/App/(obj)/")
                local nested = file:match("^src/App/.+/(bin)/") or file:match("^src/App/.+/(obj)/")
                if not (immediate and excluded["src/App/" .. immediate .. "/**"])
                    and not (nested and excluded["src/App/**/" .. nested .. "/**"]) then
                    kept[#kept + 1] = file
                end
            end
            return kept
        end)
        stub.execute("dotnet:build")

        for _, unit in ipairs(stub.units()) do
            if unit.outputs and unit.outputs[1] == "build/dotnet/bin/App/**" then
                local inputs = table.concat(unit.inputs, "\n")
                assert.is_falsy(inputs:find("/bin/generated.dll", 1, true))
                assert.is_falsy(inputs:find("/obj/generated.dll", 1, true))
            end
        end
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
