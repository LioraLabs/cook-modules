package = "cook_pnpm"
version = "0.3.0-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_pnpm-0.3.0-1",
}
description = {
   summary  = "Cook pnpm-monorepo blessed module (v0.3, inference + check caching)",
   detailed = [[
      Blessed Cook module for pnpm-driven JS/TS monorepos. One
      cook_pnpm.workspace{} call parses pnpm-workspace.yaml + each
      package.json, registers toolchain + install probes (keyed on the
      pnpm-lock.yaml hash), mints one <pkg>:<task> recipe per
      (package, task) in topological order, auto-mints conventional
      checks, and mints the install stage.

      0.3, shaped by the ppu-toys dogfood:
      - Shape inference: tasks with outputs are cook units (store-
        restored); tasks without are CHECK units (engine test units,
        Standard §8.6/§17.4) — content-fingerprinted, pass results
        replayed cross-machine, run by `cook test`. Fixes ≤0.2's
        never-cached test/lint tasks (empty-outputs cook units are
        engine OneShots).
      - Safe default inputs: omitted inputs = the package tree minus
        node_modules, dot-dirs, and batch-declared outputs (≤0.2
        defaulted to package.json alone — silently wrong keys).
      - Polyglot ordering: requires passthrough (workspace-level and
        per-task) names non-pnpm producer recipes, since path equality
        creates no ordering edge.
      - checks = "auto": allowlisted test/lint/typecheck/check-types
        minting; explicit tasks map for everything else.

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
     ["cook_pnpm"]                       = "cook_pnpm/init.lua",
     ["cook_pnpm.workspace"]             = "cook_pnpm/workspace.lua",
     ["cook_pnpm.tasks"]                 = "cook_pnpm/tasks.lua",
     ["cook_pnpm.pnpm_cli"]              = "cook_pnpm/pnpm_cli.lua",
     ["cook_pnpm.toolchain"]             = "cook_pnpm/toolchain.lua",
     ["cook_pnpm.finder"]                = "cook_pnpm/finder.lua",
     ["cook_pnpm.version"]               = "cook_pnpm/version.lua",
     ["cook_pnpm.probes.pnpm_install"]   = "cook_pnpm/probes/pnpm_install.lua",
     ["cook_pnpm.probes.package_json"]   = "cook_pnpm/probes/package_json.lua",
   },
}
