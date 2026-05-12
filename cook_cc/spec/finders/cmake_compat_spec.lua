local stub = require("cook_stub")

local function reset_all()
    stub.reset(); stub.install()
    package.loaded["cook_cc.finders.cmake_compat"] = nil
    package.loaded["cook_cc.finders.cmake_compat.hints"] = nil
end

describe("cmake_compat strategy", function()
    before_each(reset_all)

    it("module loads cleanly", function()
        local mod = require("cook_cc.finders.cmake_compat")
        assert.is_function(mod.main_chain)
    end)
end)
