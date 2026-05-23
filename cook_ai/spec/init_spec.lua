require("spec.cook_stub")
local cook_ai = require("cook_ai")

describe("cook_ai public surface", function()
    it("exports provider/prompt functions", function()
        assert.is_function(cook_ai.provider)
        assert.is_function(cook_ai.prompt)
        assert.equals("cook_ai", cook_ai.name)
    end)

    it("placeholder is removed", function()
        assert.is_nil(cook_ai.placeholder)
    end)
end)
