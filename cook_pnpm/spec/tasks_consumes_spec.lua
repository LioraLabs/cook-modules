-- cook-modules/cook_pnpm/spec/tasks_consumes_spec.lua
-- Encodes the 0.7 dependency-output FOLD FILTER.
--
-- 0.4 folded a dep package's entire claimed output dir by content. That
-- is correct but not useful: tsup/esbuild inline `sourcesContent`, so a
-- comment-only edit upstream rewrites `dist/index.mjs.map` while leaving
-- `dist/index.mjs` byte-identical — and the whole-dir fold re-keys every
-- consumer on a sidecar none of them read, cancelling the content cutoff
-- the module's headline advantage rests on. Measured on refinedev/refine,
-- whose packages/core/tsup.config.ts sets `sourcemap: true`.
--
--   DEFAULT   sourcemaps are never folded; everything else is.
--   consumes  an explicit allowlist REPLACES the default (turbo
--             semantics: an explicit statement is the whole truth).
--   REJECTED  shapes that would silently fold nothing — brace
--             alternation, path-shaped entries, `!` negation — and
--             `consumes` on a check, where the fold is engine-side.

local stub = require("cook_stub")

local function bootstrap_two_pkg_workspace()
    stub.set_file_contents("./pnpm-workspace.yaml",
        "packages:\n  - \"pkgs/*\"\n")
    stub.set_file_contents("./pkgs/lib/package.json",
        [[{"name":"@scope/lib","version":"0.0.1","scripts":{"build":"tsup"}}]])
    stub.set_file_contents("./pkgs/app/package.json",
        [[{"name":"@scope/app","version":"0.0.1","scripts":{"build":"vite build","typecheck":"tsc -b"},"dependencies":{"@scope/lib":"workspace:*"}}]])
    stub.set_file_exists("./pnpm-lock.yaml", true)
    stub.set_glob("./pkgs/*/package.json",
        { "./pkgs/lib/package.json", "./pkgs/app/package.json" })
    stub.set_sh_handler("find './pkgs/lib'", function() return "./pkgs/lib/src\n" end)
    stub.set_sh_handler("find './pkgs/app'", function() return "./pkgs/app/src\n" end)
    stub.set_glob("./pkgs/lib/*", { "./pkgs/lib/package.json" })
    stub.set_glob("./pkgs/app/*", { "./pkgs/app/package.json" })
end

local function unit_for(cmd_fragment)
    for _, u in ipairs(stub.added_units()) do
        if u.command and u.command:find(cmd_fragment, 1, true) then return u end
    end
    return nil
end

-- The `find ... -type f <predicate>` slice of a consumer's depfile command.
local function depfile_predicate(unit)
    return unit.command:match("%-type f(.-)2>/dev/null")
end

local function mint(consumes)
    bootstrap_two_pkg_workspace()
    require("cook_pnpm.discovery.workspace").bootstrap({})
    require("cook_pnpm.units.tasks").mint_from_workspace({
        tasks = {
            build = { outputs = { "dist/**" }, depends_on = { "^build" } },
            ["@scope/app#build"] = {
                outputs = { "dist/**" }, depends_on = { "^build" },
                consumes = consumes,
            },
        },
        checks = false,
    })
    return unit_for("--filter @scope/app run build")
end

describe("cook_pnpm 0.7 dependency-output fold filter", function()
    local tasks
    before_each(function()
        stub.reset()
        stub.install()
        for k in pairs(package.loaded) do
            if k:sub(1, #"cook_pnpm") == "cook_pnpm" then
                package.loaded[k] = nil
            end
        end
        tasks = require("cook_pnpm.units.tasks")
    end)

    it("excludes sourcemaps from the fold by default", function()
        -- THE FLAGSHIP CASE: an upstream comment edit rewrites the map
        -- and leaves the bundle identical; the consumer must not re-key.
        local pred = depfile_predicate(mint(nil))
        assert.truthy(pred:find("! -name '*.map'", 1, true),
            "default fold must subtract sourcemap sidecars, got: " .. pred)
    end)

    it("still folds every other artifact class by default", function()
        -- The default is a subtraction, not an allowlist: a `.mjs`, a
        -- `.d.ts`, or a file class nobody anticipated still folds, so
        -- the filter can never go stale on an unmodelled artifact.
        local pred = depfile_predicate(mint(nil))
        assert.is_nil(pred:find("-name '*.mjs'", 1, true))
        assert.is_nil(pred:find(" -o ", 1, true))
    end)

    it("lets consumes replace the default with an allowlist", function()
        local pred = depfile_predicate(mint({ "*.mjs", "**/*.d.ts" }))
        assert.truthy(pred:find("\\( -name '*.mjs' -o -name '*.d.ts' \\)", 1, true),
            "consumes must lower to an OR of -name predicates, got: " .. pred)
        -- Replaces, not composes — a task that says what it reads has
        -- stated the whole truth, so it can name maps back in.
        assert.is_nil(pred:find("! -name", 1, true))
    end)

    it("leaves a dependency-less build untouched by either filter", function()
        mint(nil)
        local lib = unit_for("--filter @scope/lib run build")
        assert.is_nil(lib.discovered_inputs)
        assert.is_nil(lib.command:find("-name", 1, true))
    end)

    it("rejects brace alternation, which would fold nothing", function()
        -- `find -name '*.{mjs,cjs}'` matches the literal string. Silently
        -- folding nothing UNDER-keys the consumer — a stale-cache bug,
        -- strictly worse than the over-invalidation this surface fixes.
        assert.error_matches(function() mint({ "*.{mjs,cjs}" }) end,
            "brace alternation")
    end)

    it("rejects a path-shaped entry, which -name cannot match", function()
        assert.error_matches(function() mint({ "dist/esm/*.mjs" }) end,
            "path%-shaped")
    end)

    it("rejects a negated entry — consumes is an allowlist", function()
        assert.error_matches(function() mint({ "!*.map" }) end, "negated")
    end)

    it("rejects consumes on a check, where the fold is engine-side", function()
        -- A test unit's key folds every immediate-predecessor output
        -- engine-side (§17.4 ready-time fingerprint) — no module-declared
        -- input can subtract from it, so accepting the filter here would
        -- be a silent no-op.
        bootstrap_two_pkg_workspace()
        require("cook_pnpm.discovery.workspace").bootstrap({})
        assert.error_matches(function()
            tasks.mint_from_workspace({
                tasks  = { typecheck = { kind = "check", consumes = { "*.d.ts" } } },
                checks = false,
            })
        end, "would not bite")
    end)
end)
