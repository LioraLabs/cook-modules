local discovery = require("cook_dotnet.discovery")

describe("cook_dotnet discovery", function()
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
end)
