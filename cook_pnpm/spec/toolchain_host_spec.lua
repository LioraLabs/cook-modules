-- cook-modules/cook_pnpm/spec/toolchain_host_spec.lua
-- The host every minted unit seals: `pnpm:host`, node's <platform>-<arch>.
-- Cook folds a sealed probe's VALUE into the unit key (§17.1.1), so two
-- hosts that observe different values never share a unit's artifact or
-- verdict, and two runs on one host observe the same value and still hit.

local stub = require("cook_stub")

local NODE = "/opt/node-20/bin/node"

-- Observe pnpm:host as the engine would: run its produce body with the
-- toolchain path probe it requires answering, and node reporting `host`.
local function observe(host_out)
    local opts = stub.probe_opts("pnpm:host")
    assert.same({ "pnpm:toolchain:auto" }, opts.inputs.requires)
    cook.probes = { get = function(k)
        assert.equals("pnpm:toolchain:auto", k)
        return { node = NODE, node_version = "20.11.0", pnpm = "/usr/bin/pnpm" }
    end }
    stub.set_sh_handler("'" .. NODE .. "' -p ", function() return host_out end)
    return assert(load(opts.produce))()
end

describe("cook_pnpm.toolchain pnpm:host", function()
    local toolchain

    before_each(function()
        stub.reset()
        stub.install()
        for k in pairs(package.loaded) do
            if k:match("^cook_pnpm") then package.loaded[k] = nil end
        end
        toolchain = require("cook_pnpm.toolchain")
    end)

    it("is sealed by every minted unit, after the identity, before the unit's own", function()
        assert.same({ "pnpm:toolchain:auto:identity", "pnpm:host", "pnpm:install:x" },
            toolchain.seals({ "pnpm:install:x" }))
        assert.same({ "pnpm:toolchain:auto:identity", "pnpm:host" }, toolchain.seals())
    end)

    it("keys two hosts apart and one host alike", function()
        toolchain.seals()
        local linux  = observe("linux-x64\n")
        local mac    = observe("darwin-arm64\n")
        local linux2 = observe("linux-x64\n")
        assert.same({ host = "linux-x64" }, linux)
        assert.same({ host = "darwin-arm64" }, mac)
        assert.are_not.same(linux, mac)
        assert.same(linux, linux2)
    end)

    it("carries no path, so one host shares across install locations", function()
        toolchain.seals()
        local v = observe("linux-x64\n")
        for _, field in pairs(v) do
            assert.is_nil(field:find("/", 1, true))
        end
    end)

    it("refuses an answer that is not <platform>-<arch>", function()
        toolchain.seals()
        assert.error_matches(function() observe("") end, "could not read the host")
        assert.error_matches(function() observe("node: bad option\n") end,
            "could not read the host")
    end)
end)
