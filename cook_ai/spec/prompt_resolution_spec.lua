local stub = require("spec.cook_stub")

describe("cook_ai.prompt input/output resolution", function()
    local resolver
    before_each(function()
        stub.reset()
        package.loaded["cook_ai.prompt"] = nil
        resolver = require("cook_ai.prompt")
    end)

    it("normalises bare ** to **/* (cook_pnpm parity)", function()
        assert.equals("**/*",       resolver._normalize_glob("**"))
        assert.equals("docs/**/*",  resolver._normalize_glob("docs/**"))
        assert.equals("docs/en/*.md", resolver._normalize_glob("docs/en/*.md"))
    end)

    it("string-template output resolves {stem}/{ext}/{dir}/{path}", function()
        local out = resolver._resolve_output("docs/en/intro.md", "docs/fr/{stem}.{ext}")
        assert.equals("docs/fr/intro.md", out)
        local out2 = resolver._resolve_output("a/b/c.txt", "build/{dir}/{stem}-out.{ext}")
        assert.equals("build/a/b/c-out.txt", out2)
        local out3 = resolver._resolve_output("x.md", "y/{path}")
        assert.equals("y/x.md", out3)
    end)

    it("function output gets called with input path", function()
        local out = resolver._resolve_output("docs/en/intro.md",
            function(p) return (p:gsub("/en/", "/fr/")) end)
        assert.equals("docs/fr/intro.md", out)
    end)

    it("resolve_template returns user/system strings", function()
        local got = resolver._resolve_templates({
            user   = function(p, c) return "U:" .. p .. ":" .. c end,
            system = "S",
        }, "docs/en/a.md", "BODY")
        assert.equals("U:docs/en/a.md:BODY", got.user)
        assert.equals("S", got.system)
    end)

    it("nil user returns nil templates (per-file opt-out)", function()
        local got = resolver._resolve_templates({
            user = function() return nil end, system = "S",
        }, "x", "")
        assert.is_nil(got)
    end)

    it("nil system returns nil templates", function()
        local got = resolver._resolve_templates({
            user = "U", system = function() return nil end,
        }, "x", "")
        assert.is_nil(got)
    end)
end)
