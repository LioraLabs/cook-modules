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

describe("version.satisfies", function()
    before_each(function()
        package.loaded["cook_cc.version"] = nil
    end)

    it("honours a single >= clause", function()
        local v = require("cook_cc.version")
        assert.is_true(v.satisfies("4.5.0", ">=4.0"))
        assert.is_false(v.satisfies("3.9.0", ">=4.0"))
    end)

    it("treats missing operator as =", function()
        local v = require("cook_cc.version")
        assert.is_true(v.satisfies("4.0.0", "4.0"))
        assert.is_false(v.satisfies("4.0.1", "=4.0.0"))
    end)

    it("supports comma-AND clauses", function()
        local v = require("cook_cc.version")
        assert.is_true(v.satisfies("4.5.0", ">=4.0,<5.0"))
        assert.is_false(v.satisfies("5.0.0", ">=4.0,<5.0"))
    end)

    it("excludes prerelease against a non-prerelease constraint", function()
        local v = require("cook_cc.version")
        assert.is_false(v.satisfies("4.0.0-rc1", ">=4.0.0"))
        assert.is_true(v.satisfies("4.0.0-rc1", ">=4.0.0-rc1"))
    end)

    it("returns false when detected is unparseable", function()
        local v = require("cook_cc.version")
        assert.is_false(v.satisfies("garbage", ">=4.0"))
    end)

    it("vacuously passes empty constraint", function()
        local v = require("cook_cc.version")
        assert.is_true(v.satisfies("1.0.0", ""))
    end)

    it("tolerates whitespace inside the constraint", function()
        local v = require("cook_cc.version")
        assert.is_true(v.satisfies("4.5.0", " >= 4.0 , < 5 "))
    end)

    it("zero-fills <X strictly", function()
        local v = require("cook_cc.version")
        assert.is_false(v.satisfies("4.0.0", "<4"))
    end)

    it("raises on unparseable constraint clause", function()
        local v = require("cook_cc.version")
        assert.has_error(function() v.satisfies("4.0.0", ">=abc") end)
    end)
end)
