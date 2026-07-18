local stub = require("cook_stub")

describe("cook_stub probe API", function()
    before_each(function() stub.reset(); stub.install() end)

    it("captures cook.probe registrations", function()
        cook.probe("cc:test", { inputs = {}, produce = "return 42" })
        assert.same({ "cc:test" }, stub.probe_keys())
        local opts = stub.probe_opts("cc:test")
        assert.equals("return 42", opts.produce)
    end)

    it("rejects duplicate cook.probe key", function()
        cook.probe("cc:dup", { inputs = {}, produce = "return 1" })
        assert.has_error(function()
            cook.probe("cc:dup", { inputs = {}, produce = "return 2" })
        end, "[cook_stub] duplicate cook.probe key 'cc:dup'")
    end)

    it("set_probe_value lets tests inject probe outcomes", function()
        stub.set_probe_value("cc:test", { x = 1 })
        cook.probe("cc:test", { inputs = {}, produce = "return {x=1}" })
        assert.same({ x = 1 }, cook.probes.get("cc:test"))
    end)
end)

describe("cook_stub recipe identity + ordering edges", function()
    before_each(function() stub.reset(); stub.install() end)

    it("cook.recipe_name() inside a recipe body returns the recipe name", function()
        local seen
        cook.recipe("foo", {}, function()
            seen = cook.recipe_name()
        end)
        assert.equals("foo", seen)
    end)

    it("cook.recipe_name() errors when called outside a recipe body", function()
        assert.has_error(function()
            cook.recipe_name()
        end, "[cook_stub] cook.recipe_name() called outside a recipe body")
    end)

    it("recipe.name inside a body returns the live name", function()
        local seen
        cook.recipe("bar", {}, function()
            seen = recipe.name
        end)
        assert.equals("bar", seen)
    end)

    it("recipe.name outside a recipe body errors the same way", function()
        assert.has_error(function()
            local _ = recipe.name
        end, "[cook_stub] cook.recipe_name() called outside a recipe body")
    end)

    it("does not leak current_recipe when a recipe body raises", function()
        assert.has_error(function()
            cook.recipe("boom", {}, function()
                error("kaboom")
            end)
        end)
        assert.has_error(function()
            cook.recipe_name()
        end, "[cook_stub] cook.recipe_name() called outside a recipe body")
    end)

    it("cook.require_recipe records a cross-recipe ordering edge", function()
        cook.recipe("known", {}, function() end)
        cook.recipe("consumer", {}, function()
            cook.require_recipe("known")
        end)
        local edges = stub.require_recipe_edges()
        local found = false
        for _, name in ipairs(edges) do
            if name == "known" then found = true end
        end
        assert.is_true(found)
    end)

    it("cook.require_recipe errors for an unknown recipe name", function()
        assert.has_error(function()
            cook.require_recipe("nope")
        end, "[cook_stub] cook.require_recipe: unknown recipe 'nope'")
    end)

    it("captures meta so specs can read recipe_meta(name).origin", function()
        cook.recipe("cfg", { origin = "x" }, function() end)
        assert.equals("x", stub.recipe_meta("cfg").origin)
    end)

    it("stub.reset() clears edges and known recipe names", function()
        cook.recipe("known", {}, function()
            cook.require_recipe("known")
        end)
        assert.same({ "known" }, stub.require_recipe_edges())

        stub.reset()
        stub.install()

        assert.same({}, stub.require_recipe_edges())
        assert.has_error(function()
            cook.require_recipe("known")
        end, "[cook_stub] cook.require_recipe: unknown recipe 'known'")
    end)

    it("stub.recipe_names() returns registered recipe names in order", function()
        cook.recipe("first", {}, function() end)
        cook.recipe("second", {}, function() end)
        assert.same({ "first", "second" }, stub.recipe_names())
    end)
end)
