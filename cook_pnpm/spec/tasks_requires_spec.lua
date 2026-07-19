-- cook-modules/cook_pnpm/spec/tasks_requires_spec.lua
-- Encodes the 0.2.1 `requires` passthrough: extra recipe names appended
-- verbatim to every minted recipe's requires, so a pnpm task can name a
-- non-pnpm producer (wasm-pack, codegen) whose outputs it reads. Found
-- dogfooding ppu-toys: path equality creates no ordering edge in Cook,
-- and depends_on can only resolve to <pkg>:<task> names inside the
-- workspace.

local stub = require("cook_stub")

local function bootstrap_two_pkg_workspace()
    stub.set_file_contents("./pnpm-workspace.yaml",
        "packages:\n  - \"apps/*\"\n")
    stub.set_file_contents("./apps/web/package.json",
        [[{"name":"@scope/web","version":"0.0.1","scripts":{"build":"next build","lint":"eslint ."}}]])
    stub.set_file_contents("./apps/docs/package.json",
        [[{"name":"@scope/docs","version":"0.0.1","scripts":{"build":"next build"}}]])
    stub.set_file_exists("./pnpm-lock.yaml", true)
    stub.set_glob("./apps/*/package.json", {
        "./apps/web/package.json",
        "./apps/docs/package.json",
    })
end

describe("cook_pnpm.tasks 0.2.1 requires passthrough", function()
    local workspace, tasks
    before_each(function()
        stub.reset()
        stub.install()
        for k in pairs(package.loaded) do
            if k:sub(1, #"cook_pnpm") == "cook_pnpm" then
                package.loaded[k] = nil
            end
        end
        workspace = require("cook_pnpm.workspace")
        tasks     = require("cook_pnpm.tasks")
    end)

    it("appends opts.requires verbatim to every minted recipe", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.task("build", { requires = { "wasm", "codegen" } })

        for _, name in ipairs({ "@scope/web:build", "@scope/docs:build" }) do
            local r = stub.recipes()[name]
            assert.is_not_nil(r, "missing minted recipe " .. name)
            assert.same({ "wasm", "codegen" }, r.opts.requires)
        end
    end)

    it("keeps depends_on-resolved edges ahead of the passthrough", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        -- @scope/web declares a `lint` script, so bare "lint" resolves to
        -- the same-package recipe; @scope/docs has no lint script, so it
        -- gets only the passthrough (Turborepo no-op-on-missing-script).
        tasks.task("build", { depends_on = { "lint" }, requires = { "wasm" } })

        assert.same({ "@scope/web:lint", "wasm" },
            stub.recipes()["@scope/web:build"].opts.requires)
        assert.same({ "wasm" },
            stub.recipes()["@scope/docs:build"].opts.requires)
    end)

    it("leaves requires untouched when the option is absent", function()
        bootstrap_two_pkg_workspace()
        workspace.bootstrap({})
        tasks.task("build", {})

        assert.same({}, stub.recipes()["@scope/web:build"].opts.requires)
    end)
end)
