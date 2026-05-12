local stub = require("cook_stub")

describe("finders.bare_probe.try", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.finders.bare_probe"] = nil
        stub.set_sh_handler("cc -print-search-dirs", function()
            return "libraries: =/usr/lib:/usr/local/lib\n"
        end)
        -- Seed all probe paths to false; individual tests opt specific paths in.
        -- (The stub's __exists handler has a Lua `h(p) or true` bug for false returns,
        --  so we enumerate explicitly.)
        for _, dir in ipairs({ "/usr/lib", "/usr/local/lib" }) do
            for _, ext in ipairs({ ".so", ".dylib", ".a" }) do
                stub.set_file_exists(dir .. "/libz.so", false)
                stub.set_file_exists(dir .. "/libz.dylib", false)
                stub.set_file_exists(dir .. "/libz.a", false)
                stub.set_file_exists(dir .. "/libnonesuch" .. ext, false)
            end
        end
    end)

    it("hits when libNAME.so exists on default linker path", function()
        stub.set_file_exists("/usr/lib/libz.so", true)
        local bare = require("cook_cc.finders.bare_probe")
        local a = bare.try("z")
        assert.equals("hit", a.outcome)
        assert.same({ "z" }, a.payload.system_libs)
        assert.equals("-lz", a.payload.libs)
    end)

    it("returns nil when nothing exists", function()
        local bare = require("cook_cc.finders.bare_probe")
        local a = bare.try("nonesuch")
        assert.is_nil(a)
    end)

    it("prefers .dylib first on macOS", function()
        stub.set_platform_os("macos")
        stub.set_file_exists("/usr/lib/libz.dylib", true)
        local bare = require("cook_cc.finders.bare_probe")
        local a = bare.try("z")
        assert.equals("hit", a.outcome)
    end)

    it("main_chain returns skip when version constraint set", function()
        local bare = require("cook_cc.finders.bare_probe")
        local a = bare.main_chain("z", { version = ">=1.0" })
        assert.equals("skip", a.outcome)
        assert.matches("version", a.reason)
    end)

    it("main_chain returns miss when not found and no version", function()
        local bare = require("cook_cc.finders.bare_probe")
        local a = bare.main_chain("nonesuch", {})
        assert.equals("miss", a.outcome)
    end)
end)
