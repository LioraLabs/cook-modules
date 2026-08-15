package = "cook_pnpm"
version = "0.8.1-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_pnpm-0.8.1-1",
}
description = {
   summary  = "Cook pnpm blessed module (v0.8, single-package repos)",
   detailed = [[
      Blessed Cook module for pnpm-driven JS/TS projects. One
      cook_pnpm.workspace{} call parses pnpm-workspace.yaml + each
      package.json, registers toolchain + install probes (keyed on the
      pnpm-lock.yaml hash), mints one <pkg>:<task> recipe per
      (package, task) in topological order, auto-mints conventional
      checks, and mints the install stage.

      0.8.1 is the Language v2 terminology pass, and one line of it is a real
      diagnostic. Declaring a negated output glob ("!.next/cache/**") is still
      rejected at register time, but the error used to explain the rejection
      by saying `!` exclusion exists for `ingredients` — a keyword CS-0229
      deleted from the language, so the error pointed authors at a spelling
      the engine now refuses. It names `gather`, the surviving iteration
      declaration, instead. The README and the units.tasks commentary follow
      the same rename.

      No API and no accept/reject decision changed from 0.8.0; build.modules
      is unchanged, regenerated from disk to prove it.

      0.8 (single-package repos, shaped by the git-canvas testbed):
      - A repo with a root package.json and NO pnpm-workspace.yaml
        bootstraps as a workspace of ONE (solo mode). Explicit
        `packages = {...}` and an existing pnpm-workspace.yaml behave
        exactly as before.
      - Solo recipes mint UNPREFIXED: `build`, `lint`, `test` — so the
        minted `build` lands as the engine's default recipe and a bare
        `cook` builds the project.
      - Solo commands drop `--filter <pkg>` (there is no workspace to
        filter): `pnpm run <task>` at the root, both build and check
        units, plus cook_pnpm.run.

      0.7 (CS-0185 engine migration + 0.6.x follow-ups):
      - BREAKING-ENGINE COMPAT: checks register via
        cook.add_unit({ step_kind = "test" }) — cook.add_test and
        `suite` are gone from the engine; the minted <pkg>:<task>
        recipe names and groups the unit. Requires an engine at or
        past the CS-0185 removal; earlier engines are no longer
        supported by this module.
      - honour pnpm-workspace.yaml '!' exclusions
      - fold only the dep artifact classes a task consumes
      - lower a check's `consumes` onto the test unit (CS-0175)

      0.6 (repo layout convention, cook_cc pilot applied):
      - Sources move under src/ in domain folders — units/ (registers
        work on the engine), discovery/ (probes and workspace facts),
        toolchain/ (which node, which pnpm). Rockspec history moves to
        rockspecs/. Every file carries a domain:/effects: header, so
        `grep -rl "effects: .*add_unit" src/` is the registrar list.
      - tasks.lua splits 730 lines into five files by concern: units.tasks
        (minting), units.depfold (depends_on + dependency-output folding),
        units.inputs (default and workspace input sets), units.excludes
        (exclude_inputs), units.globs (normalise/match/anchor primitives).
      - BREAKING for direct internal requires only: cook_pnpm.tasks is now
        cook_pnpm.units.tasks, cook_pnpm.workspace is
        cook_pnpm.discovery.workspace, and so on. The public cook_pnpm
        surface (workspace, task, run, install, script, find, toolchain)
        is unchanged, so Cookfiles need no edit.
      - No behavior change: identical units, identical cache keys.

      0.5 (found benchmarking the Cap port):
      - `exclude_inputs`: declared input subtraction, workspace-level
        (root-relative) and per task cfg (package-relative). Tools that
        write derived state INTO source dirs (next build rewriting
        app/.well-known/... manifests) no longer self-invalidate their
        own task — the generalisation of the module's hardcoded
        *.tsbuildinfo / depfile exclusions. Build units filter at
        register-time glob expansion (nested files subtracted); check
        units drop input-glob entries wholly inside an excluded
        subtree.
      - `!`-prefixed entries on any *inputs* surface are now a LOUD
        register-time error pointing at exclude_inputs. Anchoring used
        to corrupt them into mid-path literals (./!apps/...) that
        silently matched nothing.

      0.4 (Cap port): dependency-output content folding (discovered-
      inputs depfiles on builds, ready-time glob inputs on checks),
      "<pkg>#<task>" per-package overrides, workspace-level `inputs`,
      declared `env` folding, defaulted {"^build"} check edges.

      Tracked in cliban: project COOK, milestone "cook_pnpm".
   ]],
   homepage   = "https://github.com/lioralabs/cook-modules",
   license    = "MIT",
   maintainer = "Liora Labs <code@lioralabs.dev>",
}
dependencies = {
   "lua >= 5.4",
   "lua-cjson ~> 2.1",
}
build = {
   type    = "builtin",
   modules = {
     ["cook_pnpm"]                               = "cook_pnpm/init.lua",
     ["cook_pnpm.discovery.finder"]              = "cook_pnpm/src/discovery/finder.lua",
     ["cook_pnpm.discovery.probes.package_json"] = "cook_pnpm/src/discovery/probes/package_json.lua",
     ["cook_pnpm.discovery.probes.pnpm_install"] = "cook_pnpm/src/discovery/probes/pnpm_install.lua",
     ["cook_pnpm.discovery.workspace"]           = "cook_pnpm/src/discovery/workspace.lua",
     ["cook_pnpm.toolchain"]                     = "cook_pnpm/src/toolchain/init.lua",
     ["cook_pnpm.toolchain.version"]             = "cook_pnpm/src/toolchain/version.lua",
     ["cook_pnpm.units.depfold"]                 = "cook_pnpm/src/units/depfold.lua",
     ["cook_pnpm.units.excludes"]                = "cook_pnpm/src/units/excludes.lua",
     ["cook_pnpm.units.globs"]                   = "cook_pnpm/src/units/globs.lua",
     ["cook_pnpm.units.inputs"]                  = "cook_pnpm/src/units/inputs.lua",
     ["cook_pnpm.units.pnpm_cli"]                = "cook_pnpm/src/units/pnpm_cli.lua",
     ["cook_pnpm.units.tasks"]                   = "cook_pnpm/src/units/tasks.lua",
   },
}
