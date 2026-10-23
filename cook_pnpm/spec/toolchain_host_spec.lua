-- cook-modules/cook_pnpm/spec/toolchain_host_spec.lua
-- The host every minted unit seals: `pnpm:host`, node's <platform>-<arch>.
-- Cook folds a sealed probe's VALUE into the unit key (§17.1.1), so two
-- hosts that observe different values never share a unit's artifact or
-- verdict, and two runs on one host observe the same value and still hit.

local stub = require("cook_stub")

-- Observe pnpm:host as the engine would: run its produce body with node
-- on PATH answering `answer` (a string, or a function that raises).
local function observe(answer)
    local opts = stub.probe_opts("pnpm:host")
    stub.set_sh_handler("node -p ", function(cmd)
        assert.is_nil(cmd:find("2>", 1, true))   -- node's stderr is never dropped
        if type(answer) == "function" then return answer() end
        return answer
    end)
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
        local linux  = observe("linux-x64-gnu\n")
        local mac    = observe("darwin-arm64\n")
        local linux2 = observe("linux-x64-gnu\n")
        assert.same({ host = "linux-x64-gnu" }, linux)
        assert.same({ host = "darwin-arm64" }, mac)
        assert.are_not.same(linux, mac)
        assert.same(linux, linux2)
    end)

    it("keys glibc and musl linux apart", function()
        toolchain.seals()
        local gnu  = observe("linux-x64-gnu\n")
        local musl = observe("linux-x64-musl\n")
        assert.same({ host = "linux-x64-musl" }, musl)
        assert.are_not.same(gnu, musl)
    end)

    it("asks node itself for the libc, only on linux", function()
        toolchain.seals()
        local js = stub.probe_opts("pnpm:host").produce
        assert.truthy(js:find("glibcVersionRuntime", 1, true))
        assert.truthy(js:find("process.platform === 'linux'", 1, true))
    end)

    it("is pin-free: node from PATH, no requires on the toolchain path probe", function()
        toolchain.set({ pm = "pnpm@9" })
        toolchain.seals()
        local opts = stub.probe_opts("pnpm:host")
        assert.is_nil(opts.inputs.requires)
        assert.same({ "node" }, opts.inputs.tools)
    end)

    it("registers once across minting calls", function()
        toolchain.seals()
        assert.same({ "pnpm:toolchain:auto:identity", "pnpm:host" }, toolchain.seals())
    end)

    it("refuses an answer that is not a known <platform>-<arch>[-libc]", function()
        toolchain.seals()
        for _, bad in ipairs({ "", "node: bad option\n", "linux-x64\n",
                               "linux-x64-uclibc\n", "darwin-arm64-gnu\n" }) do
            assert.error_matches(function() observe(bad) end, "could not read the host")
        end
    end)

    it("lets a node crash through, with what node said", function()
        toolchain.seals()
        assert.error_matches(function()
            observe(function() error("node exited 1: TypeError: getReport is not a function") end)
        end, "getReport is not a function")
    end)
end)
