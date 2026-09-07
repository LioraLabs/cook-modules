local discovery = require("cook_dotnet.discovery")

describe("cook_dotnet discovery", function()
    it("retains native inventory roots and rejects failed native queries", function()
        local stub = require("spec.cook_stub")
        stub.reset()
        cook.sh = function(command)
            if command == "pwd" then return "/workspace\n" end
            return [[SDK notice
{"Items":{"CookInventoryRoots":[{"Identity":"/workspace/shared"},{"Identity":"/workspace/App/deep"},{"Identity":"/workspace/App"}]}}]]
        end
        local query = discovery.inventory_producer("App/App.csproj", "Debug", ".", "build/dotnet")
        assert.same({ roots = { "App", "shared" } }, query())
        assert.not_equal(string.dump(query), string.dump(discovery.inventory_producer("App/App.csproj", "Release", ".", "build/dotnet")))
        cook.sh = function(command)
            if command == "pwd" then return "/workspace" end
            error("native inventory failed", 0)
        end
        assert.has_error(query, "native inventory failed")
    end)

    it("keys and evaluates MSBuild queries by configuration", function()
        local debug_code = string.dump(discovery.producer("src/App.csproj", "Debug"))
        local release = string.dump(discovery.producer("src/App.csproj", "Release"))

        assert.not_equal(debug_code, release)
        assert.is_function(discovery.producer("src/App.csproj", "Release"))
    end)


    it("retains project-reference build metadata", function()
        local dumped = string.dump(discovery.producer("src/App.csproj", "Debug"))
        assert.is_truthy(dumped:find("OutputItemType", 1, true))
        assert.is_truthy(dumped:find("ReferenceOutputAssembly", 1, true))
    end)
    it("accepts SDK notices before JSON but preserves failed and malformed queries", function()
        local stub = require("spec.cook_stub")
        local function run_query(response, failed)
            stub.reset()
            cook.sh = function(command)
                if command == "pwd" then return "/workspace" end
                if command:find("-getProperty:", 1, true) then
                    if failed then error("SDK query failed", 0) end
                    return response
                end
                if command:find("--version", 1, true) then return "8.0.424" end
                if command:find("--info", 1, true) then return "Base Path: /dotnet/sdk/8.0.424/" end
                return ""
            end
            return discovery.producer("App.csproj", "Debug")()
        end
        local json = [[{"Properties":{"MSBuildProjectName":"App","TargetFramework":"net8.0"},"Items":{}}]]
        local graph = run_query("An issue was encountered verifying workloads.\n" .. json)
        assert.equal("net8.0", graph.projects[1].builds["net8.0"].Properties.TargetFramework)
        assert.has_error(function() run_query(json, true) end, "SDK query failed")
        assert.has_error(function() run_query("notice\n{broken}") end)
    end)
    it("rejects outer references outside the workspace before compatibility queries", function()
        local stub = require("spec.cook_stub")
        stub.reset()
        local compatibility_queries = 0
        cook.sh = function(command)
            if command == "pwd" then return "/workspace" end
            if command:find("-getProperty:", 1, true) then
                return [[{"Properties":{"TargetFramework":"net8.0"},"Items":{"ProjectReference":[{"FullPath":"/outside/Lib.csproj"}]}}]]
            end
            if command:find("-getItem:_MSBuildProjectReferenceExistent", 1, true) then
                compatibility_queries = compatibility_queries + 1
                error("compatibility query must not precede workspace rejection", 0)
            end
            return ""
        end
        local ok, message = pcall(discovery.producer("App.csproj", "Debug"))
        assert.is_false(ok)
        assert.is_truthy(tostring(message):find("project reference outside the Cook workspace: /outside/Lib.csproj", 1, true))
        assert.equal(0, compatibility_queries)
    end)

end)
