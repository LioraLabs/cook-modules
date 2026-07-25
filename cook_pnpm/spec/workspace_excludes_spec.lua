-- pnpm-workspace.yaml `!` exclusion globs.
--
-- pnpm treats a `!`-prefixed entry in `packages:` as a subtraction from the
-- directories the positive globs matched. cook_pnpm anchored them as
-- positive patterns instead ("./!examples/blog-*/package.json"), which
-- matches nothing — so the exclusion silently never fired and cook minted
-- tasks for packages pnpm does not consider part of the workspace.

local stub = require("cook_stub")

describe("cook_pnpm.discovery.workspace ! exclusions", function()
    local workspace
    before_each(function()
        stub.reset()
        stub.install()
        for k in pairs(package.loaded) do
            if k:sub(1, #"cook_pnpm") == "cook_pnpm" then
                package.loaded[k] = nil
            end
        end
        workspace = require("cook_pnpm.discovery.workspace")
    end)

    local function names_of(result)
        local t = {}
        for _, p in ipairs(result.packages) do t[#t + 1] = p.name end
        table.sort(t)
        return t
    end

    it("subtracts a `!dir/*` glob from the matched package set", function()
        stub.set_file_contents("./pnpm-workspace.yaml", [[
packages:
  - "packages/*"
  - "examples/*"
  - "!examples/blog-*"
]])
        stub.set_file_contents("./packages/core/package.json",
            [[{"name":"@r/core","version":"0.0.1","scripts":{"build":"tsup"}}]])
        stub.set_file_contents("./examples/basic/package.json",
            [[{"name":"@r/basic","version":"0.0.1","scripts":{"build":"tsup"}}]])
        stub.set_file_contents("./examples/blog-one/package.json",
            [[{"name":"@r/blog-one","version":"0.0.1","scripts":{"build":"tsup"}}]])
        stub.set_file_contents("./examples/blog-two/package.json",
            [[{"name":"@r/blog-two","version":"0.0.1","scripts":{"build":"tsup"}}]])
        stub.set_file_exists("./pnpm-lock.yaml", true)
        stub.set_glob("./packages/*/package.json", { "./packages/core/package.json" })
        stub.set_glob("./examples/*/package.json", {
            "./examples/basic/package.json",
            "./examples/blog-one/package.json",
            "./examples/blog-two/package.json",
        })

        local result = workspace.bootstrap({})
        assert.same({ "@r/basic", "@r/core" }, names_of(result))
    end)

    it("subtracts a bare `!dir` literal", function()
        stub.set_file_contents("./pnpm-workspace.yaml", [[
packages:
  - "packages/*"
  - "documentation"
  - "!documentation"
]])
        stub.set_file_contents("./packages/core/package.json",
            [[{"name":"@r/core","version":"0.0.1","scripts":{"build":"tsup"}}]])
        stub.set_file_contents("./documentation/package.json",
            [[{"name":"@r/docs","version":"0.0.1","scripts":{"build":"docusaurus"}}]])
        stub.set_file_exists("./pnpm-lock.yaml", true)
        stub.set_glob("./packages/*/package.json", { "./packages/core/package.json" })
        stub.set_glob("./documentation/package.json", { "./documentation/package.json" })

        local result = workspace.bootstrap({})
        assert.same({ "@r/core" }, names_of(result))
    end)

    it("applies exclusions regardless of their order in the list", function()
        -- pnpm processes the whole list; a `!` before its positive glob
        -- must still subtract.
        stub.set_file_contents("./pnpm-workspace.yaml", [[
packages:
  - "!examples/blog-*"
  - "packages/*"
  - "examples/*"
]])
        stub.set_file_contents("./packages/core/package.json",
            [[{"name":"@r/core","version":"0.0.1","scripts":{"build":"tsup"}}]])
        stub.set_file_contents("./examples/blog-one/package.json",
            [[{"name":"@r/blog-one","version":"0.0.1","scripts":{"build":"tsup"}}]])
        stub.set_file_exists("./pnpm-lock.yaml", true)
        stub.set_glob("./packages/*/package.json", { "./packages/core/package.json" })
        stub.set_glob("./examples/*/package.json", { "./examples/blog-one/package.json" })

        local result = workspace.bootstrap({})
        assert.same({ "@r/core" }, names_of(result))
    end)

    it("errors when every matched package is excluded", function()
        -- Distinct from "no packages matched globs": the globs DID match,
        -- the exclusions removed everything. Say so.
        stub.set_file_contents("./pnpm-workspace.yaml", [[
packages:
  - "examples/*"
  - "!examples/*"
]])
        stub.set_file_contents("./examples/basic/package.json",
            [[{"name":"@r/basic","version":"0.0.1","scripts":{"build":"tsup"}}]])
        stub.set_file_exists("./pnpm-lock.yaml", true)
        stub.set_glob("./examples/*/package.json", { "./examples/basic/package.json" })

        assert.has_error(function() workspace.bootstrap({}) end)
    end)

    it("keeps the full refine exclusion set honest", function()
        -- The real refinedev/refine workspace shape: 6 exclusion globs over
        -- packages/* + examples/*, which drop 40 of its 246 matched dirs.
        stub.set_file_contents("./pnpm-workspace.yaml", [[
packages:
  - "packages/*"
  - "examples/*"
  - "!examples/monorepo-*"
  - "!examples/with-nx"
  - "!documentation"
  - "!examples/blog-*"
  - "!examples/store"
]])
        stub.set_file_contents("./packages/core/package.json",
            [[{"name":"@r/core","version":"0.0.1","scripts":{"build":"tsup"}}]])
        for _, d in ipairs({ "basic", "monorepo-a", "with-nx", "blog-x", "store" }) do
            stub.set_file_contents("./examples/" .. d .. "/package.json",
                string.format([[{"name":"@r/%s","version":"0.0.1","scripts":{"build":"tsup"}}]], d))
        end
        stub.set_file_exists("./pnpm-lock.yaml", true)
        stub.set_glob("./packages/*/package.json", { "./packages/core/package.json" })
        stub.set_glob("./examples/*/package.json", {
            "./examples/basic/package.json",
            "./examples/monorepo-a/package.json",
            "./examples/with-nx/package.json",
            "./examples/blog-x/package.json",
            "./examples/store/package.json",
        })

        local result = workspace.bootstrap({})
        assert.same({ "@r/basic", "@r/core" }, names_of(result))
    end)
end)
