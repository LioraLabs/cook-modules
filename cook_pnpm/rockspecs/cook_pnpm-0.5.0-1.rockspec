package = "cook_pnpm"
version = "0.5.0-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_pnpm-0.5.0-1",
}
description = {
   summary  = "Cook pnpm-monorepo blessed module (v0.5, input exclusions)",
   detailed = [[
      Blessed Cook module for pnpm-driven JS/TS monorepos. One
      cook_pnpm.workspace{} call parses pnpm-workspace.yaml + each
      package.json, registers toolchain + install probes (keyed on the
      pnpm-lock.yaml hash), mints one <pkg>:<task> recipe per
      (package, task) in topological order, auto-mints conventional
      checks, and mints the install stage.

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
