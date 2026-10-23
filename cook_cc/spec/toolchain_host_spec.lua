-- The target every compile and link unit seals: `cc:host:<override-or-auto>`,
-- the chosen compiler's -dumpmachine. Cook folds a sealed probe's VALUE into
-- the unit key (§17.1.1), so hosts that observe different values never share
-- an artifact, and one host observing the same value still hits.

local stub = require("cook_stub")

-- Observe the host probe as the engine would: run its produce body with the
-- compiler answering `answer` (a string, or a function that raises).
local function observe(key, cxx, answer)
    local opts = stub.probe_opts(key)
    stub.set_probe_value(opts.inputs.requires[1], { cxx = cxx, cc = "cc" })
    stub.set_sh_handler(cxx .. " -dumpmachine", function(cmd)
        assert.is_nil(cmd:find("2>", 1, true))   -- the compiler's stderr is never dropped
        if type(answer) == "function" then return answer() end
        return answer
    end)
    return assert(load(opts.produce))()
end

describe("cook_cc.toolchain cc:host", function()
    local tc

    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.toolchain"] = nil
        tc = require("cook_cc.toolchain")
        tc.ensure_probe_registered()
    end)

    it("is keyed like the compiler and requires it", function()
        assert.equals("cc:host:auto", tc.get_host_key())
        assert.same({ "cc:compiler:auto" }, stub.probe_opts("cc:host:auto").inputs.requires)
    end)

    it("registers once across calls", function()
        tc.ensure_probe_registered()
        assert.same({ "cc:compiler:auto", "cc:host:auto" }, stub.probe_keys())
    end)

    it("keys two hosts apart and one host alike", function()
        local a  = observe("cc:host:auto", "g++", "x86_64-pc-linux-gnu\n")
        local b  = observe("cc:host:auto", "g++", "arm64-apple-darwin24.6.0\n")
        local a2 = observe("cc:host:auto", "g++", "x86_64-pc-linux-gnu\n")
        assert.same({ host = "x86_64-pc-linux-gnu" }, a)
        assert.are_not.same(a, b)
        assert.same(a, a2)
    end)

    it("returns each accepted triple verbatim", function()
        for _, t in ipairs({ "x86_64-pc-linux-gnu", "x86_64-linux-gnu", "arm64-apple-darwin24.6.0",
                             "x86_64-w64-mingw32", "aarch64-linux-gnu" }) do
            assert.same({ host = t }, observe("cc:host:auto", "g++", t .. "\n"))
        end
    end)

    it("asks the CHOSEN compiler", function()
        package.loaded["cook_cc.toolchain"] = nil
        stub.reset(); stub.install()
        tc = require("cook_cc.toolchain")
        tc.set({ compiler = "aarch64-linux-gnu-g++" })
        assert.equals("cc:host:aarch64-linux-gnu-g++", tc.get_host_key())
        local ran
        local opts = stub.probe_opts("cc:host:aarch64-linux-gnu-g++")
        stub.set_probe_value("cc:compiler:aarch64-linux-gnu-g++", { cxx = "aarch64-linux-gnu-g++" })
        stub.set_sh_handler("aarch64-linux-gnu-g++ ", function(cmd) ran = cmd; return "aarch64-linux-gnu\n" end)
        assert.same({ host = "aarch64-linux-gnu" }, assert(load(opts.produce))())
        assert.equals("aarch64-linux-gnu-g++ -dumpmachine", ran)
    end)

    it("refuses output that is not a dash-separated target", function()
        for _, bad in ipairs({ "", "\n", "g++: command not found\n", "x86_64: pc\n", "gcc version 13",
                               "x86_64\n", "x86_64-\n", "-linux\n", "x86_64--gnu\n", "a-b-\n" }) do
            local ok, err = pcall(observe, "cc:host:auto", "g++", bad)
            assert.is_false(ok, "accepted " .. bad)
            assert.matches("could not read the target from 'g%+%+ %-dumpmachine': ", err)
            assert.matches(bad, err, 1, true)
        end
    end)

    it("lets a compiler crash through, with what it said", function()
        assert.error_matches(function()
            observe("cc:host:auto", "g++", function() error("g++ exited 1: cannot execute 'cc1plus'") end)
        end, "cannot execute 'cc1plus'")
    end)
end)
