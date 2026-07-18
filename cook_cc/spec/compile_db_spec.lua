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

describe("cc.compile_commands (top-level finalizer, CS-0149)", function()
    before_each(function()
        stub.reset(); stub.install()
        package.loaded["cook_cc.targets"]    = nil
        package.loaded["cook_cc.compile_db"] = nil
        stub.set_sh_handler("pwd", function() return "/proj\n" end)
    end)

    local function fs_writes()
        local out = {}
        for _, u in ipairs(stub.added_units()) do
            if u.kind == "fs.write" and u.path == "compile_commands.json" then
                out[#out + 1] = u
            end
        end
        return out
    end

    it("writes a DB covering targets registered AFTER the call, with no link between them (disconnected-plugin regression)", function()
        local db = require("cook_cc.compile_db")
        db.compile_commands()   -- top-level call FIRST, before any targets exist

        local tg = require("cook_cc.targets")
        tg._known_list[#tg._known_list + 1] = "base"
        cook.export("base", {
            compile_info = {
                sources  = { "base/a.cpp" },
                includes = {}, defines = {},
                standard = "c++17", compiler = "g++",
            },
        })
        tg._known_list[#tg._known_list + 1] = "d3xp"
        cook.export("d3xp", {
            compile_info = {
                sources  = { "d3xp/b.cpp" },
                includes = {}, defines = {},
                standard = "c++17", compiler = "g++",
            },
        })
        -- base and d3xp share no `links` edge — the disconnected-plugin case.

        stub.run_register_complete()

        local writes = fs_writes()
        assert.equals(1, #writes)
        local cjson = require("cjson")
        local entries = cjson.decode(writes[1].content)
        assert.equals(2, #entries)
        local files = {}
        for _, e in ipairs(entries) do files[e.file] = true end
        assert.is_true(files["base/a.cpp"])
        assert.is_true(files["d3xp/b.cpp"])
    end)

    it("is idempotent per VM: two top-level calls queue exactly one finalizer and write once", function()
        local db = require("cook_cc.compile_db")

        local queue_count = 0
        local original_on_register_complete = cook.on_register_complete
        cook.on_register_complete = function(fn)
            queue_count = queue_count + 1
            return original_on_register_complete(fn)
        end

        db.compile_commands()
        db.compile_commands()
        assert.equals(1, queue_count)

        stub.run_register_complete()

        assert.equals(1, #fs_writes())
    end)

    it("raises loudly when called from inside a recipe body, and queues nothing", function()
        local db = require("cook_cc.compile_db")

        local queued_anything = false
        local original_on_register_complete = cook.on_register_complete
        cook.on_register_complete = function(fn)
            queued_anything = true
            return original_on_register_complete(fn)
        end

        local ok, err = pcall(function()
            cook.recipe("app", {}, function()
                db.compile_commands()
            end)
        end)
        assert.is_false(ok)
        assert.matches("top%-level", err)
        assert.is_false(queued_anything)

        stub.run_register_complete()
        assert.equals(0, #fs_writes())
    end)
end)
