local stub = require("cook_stub")

describe("init module surface", function()
    before_each(function()
        stub.reset(); stub.install()
        stub.set_sh_handler("command -v g++", function() return "/usr/bin/g++\n" end)
        stub.set_sh_handler("command -v clang++", function() error("nope") end)
        for _, m in ipairs({
            "cook_cc","cook_cc.toolchain","cook_cc.cc","cook_cc.targets",
            "cook_cc.transitive","cook_cc.finder","cook_cc.compile_db",
        }) do package.loaded[m] = nil end
    end)

    it("exposes only the public surface, calls init() to rehydrate", function()
        local cc = require("cook_cc")
        cc.init()  -- simulates Standard §6.3.4 hook
        for _, fn in ipairs({
            "toolchain","defaults","compile","archive","link",
            "bin","lib","shared","headers","find","compile_commands",
        }) do
            assert.is_function(cc[fn], "expected cc." .. fn .. " to be a function")
        end
        -- nothing else exposed
        assert.is_nil(cc.state)
        assert.is_nil(cc.executable)
        assert.is_nil(cc.static_library)
    end)
end)

describe("cook_cc init wiring (M3)", function()
    before_each(function()
        for _, m in ipairs({ "cook_cc", "cook_cc.checks", "cook_cc.config_header",
                             "cook_cc.config_header_renderer",
                             "cook_cc._check_helpers", "cook_cc.toolchain" }) do
            package.loaded[m] = nil
        end
        require("cook_stub").reset()
        require("cook_stub").install()
    end)

    it("exposes cook_cc.checks as the checks module table", function()
        local cc = require("cook_cc")
        assert.equals("function", type(cc.checks.has_header))
        assert.equals("function", type(cc.checks.has_function))
        assert.equals("function", type(cc.checks.has_define))
        assert.equals("function", type(cc.checks.sizeof))
        assert.equals("function", type(cc.checks.endian))
        assert.equals("function", type(cc.checks.has_compile_flag))
        assert.equals("function", type(cc.checks.has_link_flag))
    end)

    it("exposes cook_cc.config_header as a callable", function()
        local cc = require("cook_cc")
        assert.equals("function", type(cc.config_header))
    end)
end)
