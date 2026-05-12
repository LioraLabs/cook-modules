local stub = require("cook_stub")

describe("version.parse", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.version"] = nil
    end)

    it("parses major.minor.patch", function()
        local v = require("cook_cc.version")
        assert.same({ major = 4, minor = 5, patch = 0 }, v.parse("4.5.0"))
    end)

    it("zero-fills missing fields", function()
        local v = require("cook_cc.version")
        assert.same({ major = 4, minor = 0, patch = 0 }, v.parse("4"))
        assert.same({ major = 4, minor = 5, patch = 0 }, v.parse("4.5"))
    end)

    it("captures prerelease tags", function()
        local v = require("cook_cc.version")
        local parsed = v.parse("4.0.0-rc1")
        assert.equals("rc1", parsed.prerelease)
    end)

    it("drops build metadata after +", function()
        local v = require("cook_cc.version")
        assert.same({ major = 1, minor = 2, patch = 3 }, v.parse("1.2.3+sha.abc"))
    end)

    it("returns nil on non-numeric major", function()
        local v = require("cook_cc.version")
        assert.is_nil(v.parse("garbage"))
        assert.is_nil(v.parse(""))
    end)
end)
