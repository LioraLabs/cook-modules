package = "cook_pnpm"
version = "0.1.0-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_pnpm-0.1.0-1",
}
description = {
   summary  = "Cook pnpm-monorepo blessed module (v0.1, first rough draft)",
   detailed = [[
      First-cut blessed Cook module for pnpm-driven JS/TS monorepos.
      Reads pnpm-workspace.yaml + per-package package.json files, builds
      a topological workspace graph, registers toolchain + install
      probes (keyed on pnpm-lock.yaml hash), and emits one cook.recipe
      per (package, task) when callers register tasks with
      cook_pnpm.task("build", { depends_on = { "^build" }, ... }).

      Models the Turborepo task-pipeline shape on top of Cook's
      content-addressed DAG, giving turborepo-style monorepo builds
      with remote caching for free via Cook's caching primitives.

      v0.1 is a rough draft — surface is NOT yet specified in the Cook
      Standard. Chapter §29 will normatively cover it once the surface
      has stabilised against the cook OSS smoke fixture.

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
