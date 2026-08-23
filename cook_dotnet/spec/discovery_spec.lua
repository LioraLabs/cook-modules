local discovery = require("cook_dotnet.discovery")

describe("cook_dotnet discovery", function()
    it("keys and evaluates MSBuild queries by configuration", function()
        local debug_code = string.dump(discovery.producer("src/App.csproj", "Debug"))
        local release = string.dump(discovery.producer("src/App.csproj", "Release"))

        assert.not_equal(debug_code, release)
        assert.is_function(discovery.producer("src/App.csproj", "Release"))
    end)
end)
