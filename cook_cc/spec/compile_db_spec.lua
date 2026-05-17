local stub = require("cook_stub")

describe("cc.compile_commands", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.targets"]    = nil
        package.loaded["cook_cc.compile_db"] = nil
        stub.set_sh_handler("pwd", function() return "/proj\n" end)
    end)

    it("writes one entry per source per known target", function()
        local tg = require("cook_cc.targets")
        tg._known_list[#tg._known_list + 1] = "app"
        cook.export("app", {
            compile_info = {
                sources = { "src/a.cpp", "src/b.cpp" },
                includes = { "inc/" },
                defines = { "X=1" },
                standard = "c++17",
                compiler = "g++",
            },
        })
        local cjson = require("cjson")
        local db = require("cook_cc.compile_db")
        db.write()
        local fs_units = {}
        for _, u in ipairs(stub.added_units()) do
            if u.kind == "fs.write" and u.path == "compile_commands.json" then
                fs_units[#fs_units + 1] = u
            end
        end
        assert.equals(1, #fs_units)
        local entries = cjson.decode(fs_units[1].content)
        assert.equals(2, #entries)
        assert.equals("/proj", entries[1].directory)
        assert.equals("src/a.cpp", entries[1].file)
        assert.matches("^g%+%+ ", entries[1].command)
        assert.matches(" %-std=c%+%+17 ", entries[1].command)
    end)

    it("uses gcc instead of cxx for .c sources", function()
        local tg = require("cook_cc.targets")
        tg._known_list[#tg._known_list + 1] = "app"
        cook.export("app", {
            compile_info = {
                sources = { "src/main.c" },
                includes = {}, defines = {},
                standard = "c++17",  -- ignored for .c
                compiler = "g++",
            },
        })
        local cjson = require("cjson")
        local db = require("cook_cc.compile_db")
        db.write()
        for _, u in ipairs(stub.added_units()) do
            if u.kind == "fs.write" then
                local entries = cjson.decode(u.content)
                assert.matches("^gcc ", entries[1].command)
                assert.is_falsy(entries[1].command:match("%-std="))
            end
        end
    end)

    it("emits an empty array when there are no known targets", function()
        local cjson = require("cjson")
        local db = require("cook_cc.compile_db")
        db.write()
        for _, u in ipairs(stub.added_units()) do
            if u.kind == "fs.write" then
                assert.equals("[]\n", u.content)
            end
        end
    end)
end)
