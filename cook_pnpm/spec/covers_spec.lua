-- cook_pnpm probes declare `covers` for `cook audit` (COOK-584): the
-- install probe owns node_modules reads, the toolchain identity probe owns
-- the pnpm/node install dirs. Audit-only; a missing entry leaves a finding.

local stub = require("cook_stub")

local function load()
    stub.reset()
    stub.install()
    for k in pairs(package.loaded) do
        if k:sub(1, #"cook_pnpm") == "cook_pnpm" then package.loaded[k] = nil end
    end
end

-- tool -> { found = "/path/to/bin/tool", real = readlink -f result or nil }
local function host(tools)
    for tool, t in pairs(tools) do
        stub.set_tool_path(tool, t.found)
        stub.set_sh_handler("readlink -f '" .. t.found .. "'", function()
            return t.real and (t.real .. "\n") or ""
        end)
    end
end

describe("install probe covers", function()
    before_each(load)

    it("covers the lockfile dir's node_modules at any depth", function()
        stub.set_file_exists("./pnpm-lock.yaml", true)
        local key = require("cook_pnpm.discovery.probes.pnpm_install")
            .ensure_probe_registered("./pnpm-lock.yaml")
        assert.same({ "./**/node_modules" }, stub.probe_opts(key).covers)
    end)

    it("a bare lockfile name has no dir prefix", function()
        stub.set_file_exists("pnpm-lock.yaml", true)
        local key = require("cook_pnpm.discovery.probes.pnpm_install")
            .ensure_probe_registered("pnpm-lock.yaml")
        assert.same({ "**/node_modules" }, stub.probe_opts(key).covers)
    end)

    it("keeps a nested root as given", function()
        stub.set_file_exists("ws/pnpm-lock.yaml", true)
        local key = require("cook_pnpm.discovery.probes.pnpm_install")
            .ensure_probe_registered("ws/pnpm-lock.yaml")
        assert.same({ "ws/**/node_modules" }, stub.probe_opts(key).covers)
    end)
end)

describe("toolchain identity probe covers", function()
    before_each(load)

    local function covers()
        local tc = require("cook_pnpm.toolchain")
        return stub.probe_opts(tc.ensure_identity_registered()).covers
    end

    it("lists the install dirs of pnpm and node; the path probe has none", function()
        host({
            pnpm = { found = "/opt/n/bin/pnpm", real = "/opt/n/lib/node_modules/pnpm/bin/pnpm.cjs" },
            node = { found = "/opt/n/bin/node", real = "/opt/n/bin/node" },
        })
        assert.same({ "/opt/n/lib/node_modules/pnpm", "/opt/n" }, covers())
        assert.is_nil(stub.probe_opts("pnpm:toolchain:auto").covers)
    end)

    it("skips top-level dirs, / and $HOME, and tools that do not resolve", function()
        local home = os.getenv("HOME") or "/home/x"
        host({
            pnpm = { found = "/usr/bin/pnpm", real = nil },          -- readlink fails
            node = { found = "/usr/bin/node", real = "/usr/bin/node" }, -- /usr: too broad
        })
        assert.same({}, covers())

        load()
        host({
            pnpm = { found = home .. "/bin/pnpm", real = home .. "/bin/pnpm" }, -- $HOME
            node = { found = "/bin/node", real = "/bin/node" },                -- /
        })
        assert.same({}, covers())
    end)

    it("a tool missing from PATH yields no entry", function()
        host({ node = { found = "/opt/n/bin/node", real = "/opt/n/bin/node" } })
        assert.same({ "/opt/n" }, covers())
    end)
end)
