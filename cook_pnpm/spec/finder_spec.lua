-- Guards the input declaration on the `pnpm:find:<name>` probe.
--
-- CS-0244 removed `opts.inputs.env` and cook now rejects it at register
-- phase, so a reintroduction here would not be a subtle key regression: it
-- would break every project on the module the moment it registered a finder.
-- No Cookfile in the wild reaches `pnpm.find` today, which is exactly why
-- this needs a spec rather than a downstream smoke test.

local stub = require("cook_stub")

describe("cook_pnpm.discovery.finder", function()
    local finder
    before_each(function()
        stub.reset()
        stub.install()
        for k in pairs(package.loaded) do
            if k:sub(1, #"cook_pnpm") == "cook_pnpm" then
                package.loaded[k] = nil
            end
        end
        finder = require("cook_pnpm.discovery.finder")
    end)

    it("registers one probe per name, keyed pnpm:find:<name>", function()
        finder.find("vitest")
        assert.is_not_nil(stub.probe_opts("pnpm:find:vitest"))
    end)

    it("declares the tool it resolves", function()
        finder.find("vitest")
        local opts = stub.probe_opts("pnpm:find:vitest")
        assert.same({ "vitest" }, opts.inputs.tools)
    end)

    it("declares no env inputs (CS-0244)", function()
        finder.find("vitest")
        local opts = stub.probe_opts("pnpm:find:vitest")
        assert.is_nil(opts.inputs.env)
    end)
end)
