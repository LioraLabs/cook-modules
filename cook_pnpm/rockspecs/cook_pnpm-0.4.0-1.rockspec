package = "cook_pnpm"
version = "0.4.0-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_pnpm-0.4.0-1",
}
description = {
   summary  = "Cook pnpm-monorepo blessed module (v0.4, correct-by-content caching)",
   detailed = [[
      Blessed Cook module for pnpm-driven JS/TS monorepos. One
      cook_pnpm.workspace{} call parses pnpm-workspace.yaml + each
      package.json, registers toolchain + install probes (keyed on the
      pnpm-lock.yaml hash), mints one <pkg>:<task> recipe per
      (package, task) in topological order, auto-mints conventional
      checks, and mints the install stage.

      0.4, shaped by the Cap port (CapSoftware/Cap, 25-project
      workspace, Turborepo replaced):
      - Dependency-output folding: a consumer's key covers the CONTENT
        of the dep artifacts it consumes. Builds record a
        discovered-inputs depfile over the dep packages' claimed output
        dirs (zero settle runs — the file list is unknowable at
        register on a cold build); checks take the dep dirs as
        ready-time glob inputs. Byte-identical dep output never re-runs
        a consumer; a real change re-runs exactly the direct consumers.
      - Per-package task overrides, Turbo-spelled: tasks map keys of
        the form "<pkg>#<task>" REPLACE the base cfg for that package.
      - Workspace-level `inputs` (Turbo globalDependencies): root-
        anchored extras on every minted task; missing literals drop.
      - `env` (workspace-level and per-task): named keys lower to
        consulted_env_keys on build units — declared, explainable env
        folding instead of Turbo's globalEnv "*".
      - Checks default to a {"^build"} edge (strictly resolved against
        the batch) — a typecheck racing its producers was a latent bug.
      - Negated output globs are rejected at register time with the
        engine rationale; install-probe seal value is deterministic
        (lockfile hash, not raw pnpm output); *.tsbuildinfo and the
        depfile are excluded from default inputs.

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
