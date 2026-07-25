package = "cook_pnpm"
version = "0.6.0-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_pnpm-0.6.0-1",
}
description = {
   summary  = "Cook pnpm-monorepo blessed module (v0.6, src/ layout)",
   detailed = [[
      Blessed Cook module for pnpm-driven JS/TS monorepos. One
      cook_pnpm.workspace{} call parses pnpm-workspace.yaml + each
      package.json, registers toolchain + install probes (keyed on the
      pnpm-lock.yaml hash), mints one <pkg>:<task> recipe per
      (package, task) in topological order, auto-mints conventional
      checks, and mints the install stage.

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
