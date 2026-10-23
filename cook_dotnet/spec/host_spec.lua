-- The host every minted unit seals: `dotnet:host`, the SDK's runtime identifier.
-- Cook folds a sealed probe's value into the unit key, so two hosts that observe
-- different values never share an artifact, and one host observes the same value
-- on every run and still hits.
local stub = require("spec.cook_stub")

-- Observe dotnet:host as the engine would: run its produce body with
-- `dotnet --info` answering `answer` (a string, or a function that raises).
local function observe(answer)
    stub.command("'/stub/bin/dotnet' --info", function(command)
        assert.is_nil(command:find("2>", 1, true)) -- dotnet's stderr is never dropped
        if type(answer) == "function" then return answer() end
        return answer
    end)
    return assert(load(assert(stub.probe("dotnet:host")).produce))()
end

local function info(rid)
    return ".NET SDK:\n Version:           10.0.113\n\nRuntime Environment:\n OS Name:     cachyos\n"
        .. " OS Platform: Linux\n RID:         " .. rid .. "\n Base Path:   /usr/share/dotnet/sdk/10.0.113/\n"
end

describe("cook_dotnet dotnet:host", function()
    before_each(function()
        package.loaded.cook_dotnet = nil
        stub.reset()
        stub.in_recipe("app", function() require("cook_dotnet").build({ project = "src/App.csproj" }) end)
    end)

    it("asks the same dotnet the toolchain probe resolves", function()
        assert.same({ "dotnet" }, stub.probe("dotnet:host").inputs.tools)
    end)

    it("keys two hosts apart and one host alike", function()
        local linux, mac = observe(info("linux-x64")), observe(info("osx-arm64"))
        assert.same({ host = "linux-x64" }, linux)
        assert.same({ host = "osx-arm64" }, mac)
        assert.are_not.same(linux, mac)
        assert.same(linux, observe(info("linux-x64")))
        assert.same({ host = "win-x64" }, observe(info("win-x64"):gsub("\n", "\r\n")))
    end)

    it("keys glibc and musl linux apart", function()
        assert.same({ host = "linux-musl-arm64" }, observe(info("linux-musl-arm64")))
        assert.are_not.same(observe(info("linux-x64")), observe(info("linux-musl-x64")))
    end)

    it("takes a source-built SDK's distro RID verbatim", function()
        assert.same({ host = "arch-x64" }, observe(info("arch-x64")))
        assert.same({ host = "ubuntu.24.04-arm64" }, observe(info("ubuntu.24.04-arm64")))
        assert.same({ host = "linux-x64" }, observe(" RID: linux-x64"))
    end)

    it("refuses output that does not name a known RID", function()
        for _, bad in ipairs({ "", "dotnet: command failed\n", info(""), info("linux"),
                               info("linux-sparc"), info("Linux-x64"), info("linux-x64 extra"),
                               info("linux-bionic-arm64"), " XRID: linux-x64\n" }) do
            assert.error_matches(function() observe(bad) end, "could not read the host RID", 1, true)
        end
    end)

    it("lets a dotnet failure through, with what dotnet said", function()
        assert.error_matches(function()
            observe(function() error("dotnet exited 1: hostfxr not found") end)
        end, "hostfxr not found", 1, true)
    end)
end)
