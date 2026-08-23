local discovery = require("cook_dotnet.discovery")

describe("cook_dotnet discovery", function()
    it("keys and evaluates MSBuild queries by configuration", function()
        local debug = discovery.code("src/App.csproj", "build/discovery.lua", "Debug")
        local release = discovery.code("src/App.csproj", "build/discovery.lua", "Release")

        assert.not_equal(debug, release)
        assert.is_truthy(release:find("local solution, output, configuration", 1, true))
        assert.is_truthy(release:find('configuration, query_items = "src/App.csproj", "build/discovery.lua", "Release"', 1, true))
        assert.is_truthy(release:find(' -property:Configuration=', 1, true))
        assert.is_truthy(release:find("configuration = configuration", 1, true))
    end)
end)
