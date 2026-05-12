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

    it("skips when opts.version is set, without touching cmake", function()
        local sh_called = false
        stub.set_sh_handler("cmake ", function() sh_called = true; return "" end)
        local mod = require("cook_cc.finders.cmake_compat")
        local a = mod.main_chain("Anything", { version = ">=1.0" })
        assert.equals("cmake-compat", a.strategy)
        assert.equals("skip", a.outcome)
        assert.matches("version detection unsupported", a.reason)
        assert.is_false(sh_called)
    end)
end)
