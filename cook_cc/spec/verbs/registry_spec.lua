-- The one place cook_cc's project-management verbs get registered.
local stub = require("cook_stub")

local function fresh()
    for _, m in ipairs({
        "cook_cc.verbs", "cook_cc.verbs.add",
        "cook_cc.verbs._project", "cook_cc.verbs._report",
    }) do package.loaded[m] = nil end
    return require("cook_cc.verbs")
end

describe("verb registry", function()
    before_each(function()
        stub.reset(); stub.install()
    end)

    it("registers cc.add", function()
        fresh().register()
        assert.is_truthy(stub.chore("cc.add"))
    end)

    it("registers every verb it knows about and nothing else", function()
        fresh().register()
        local names = {}
        for _, reg in ipairs(stub.chores()) do names[#names + 1] = reg.name end
        table.sort(names)
        assert.same({ "cc.add" }, names)
    end)

    it("does nothing on a VM with no cook.chore", function()
        -- cook_cc is loaded on the execute-phase VM too, and that VM has no
        -- cook.chore: registering unguarded would kill every execute-phase
        -- module load with a nil call.
        cook.chore = nil
        assert.has_no.errors(function() fresh().register() end)
    end)

    it("keeps every verb's output going through _report", function()
        -- `print` is available on the register VM, so nothing stops a verb
        -- reaching past the shared sink and inventing its own output shape.
        -- This is the guard that catches it, since a rule stated only in prose
        -- is one four agents each discover the hard way.
        local offenders = {}
        for file in io.popen("ls src/verbs"):lines() do
            if file:match("%.lua$") and file ~= "_report.lua" then
                local handle = io.open("src/verbs/" .. file, "r")
                local source = handle:read("a"); handle:close()
                -- Strip comments before looking, so prose about print is fine.
                for line in source:gmatch("[^\n]+") do
                    if not line:match("^%s*%-%-") and line:find("print%s*%(") then
                        offenders[#offenders + 1] = file .. ": " .. line
                    end
                end
            end
        end
        assert.same({}, offenders)
    end)

    it("does nothing when there is no cook table at all", function()
        local saved = _G.cook
        _G.cook = nil
        local ok = pcall(function() fresh().register() end)
        _G.cook = saved
        assert.is_true(ok)
    end)
end)
