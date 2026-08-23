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
end)
