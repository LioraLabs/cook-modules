-- The one message shape every cc.* verb speaks in.
local function fresh()
    package.loaded["cook_cc.verbs._report"] = nil
    return require("cook_cc.verbs._report")
end

describe("verb reporting", function()
    local report, lines

    before_each(function()
        report = fresh()
        lines = {}
        report.emit = function(line) lines[#lines + 1] = line end
    end)

    describe("fail", function()
        it("prefixes the message with the verb", function()
            local ok, err = pcall(report.fail, "cc.add", "unknown kind 'static'")
            assert.is_false(ok)
            assert.equals("cc.add: unknown kind 'static'", err)
        end)

        it("puts a hint on its own indented line", function()
            local _, err = pcall(report.fail, "cc.add", "unknown kind 'static'",
                "accepted kinds: bin, lib")
            assert.equals("cc.add: unknown kind 'static'\n  accepted kinds: bin, lib", err)
        end)

        it("raises without a chunk:line prefix", function()
            local _, err = pcall(report.fail, "cc.add", "boom")
            assert.is_nil(err:match("^.-%.lua:%d+:"))
        end)

        it("emits nothing", function()
            pcall(report.fail, "cc.add", "boom")
            assert.same({}, lines)
        end)
    end)

    describe("did", function()
        it("renders the action and subject in aligned columns", function()
            report.did("created", "src/math/math.cpp")
            report.did("updated", "Cookfile")
            assert.same({
                "  created  src/math/math.cpp",
                "  updated  Cookfile",
            }, lines)
        end)

        it("pads a short action to the same column as a long one", function()
            report.did("ran", "clang-format")
            assert.equals("  ran      clang-format", lines[1])
        end)
    end)

    describe("suggest", function()
        it("offers the next command after a blank line", function()
            report.suggest("math")
            assert.same({ "", "  try: cook math" }, lines)
        end)
    end)

    describe("actions", function()
        it("refuses an action outside the shared vocabulary", function()
            -- An unlisted action would sit a character out of column, silently,
            -- in the module whose whole job is one shape.
            local ok, err = pcall(report.did, "conjured", "src/x.cpp")
            assert.is_false(ok)
            assert.is_truthy(err:find("add it to report.ACTIONS", 1, true))
        end)

        it("aligns every action in its vocabulary to one column", function()
            local width = nil
            for _, action in ipairs(report.ACTIONS) do
                lines = {}
                report.did(action, "x")
                local column = lines[1]:find("x", 1, true)
                width = width or column
                assert.equals(width, column, "action '" .. action .. "' broke the column")
            end
        end)
    end)

    describe("list", function()
        it("renders a set in a stable order however it was built", function()
            assert.equals("bin, lib, shared", report.list({ "shared", "bin", "lib" }))
        end)
    end)

    it("emits through print by default", function()
        local fresh_report = fresh()
        assert.equals(print, fresh_report.emit)
    end)
end)
