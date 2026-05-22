package = "cook_pnpm"
version = "0.2.0-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_pnpm-0.2.0-1",
}
description = {
   summary  = "Cook pnpm-monorepo blessed module (v0.2, caching parity)",
   detailed = [[
      Blessed Cook module for pnpm-driven JS/TS monorepos. Reads
      pnpm-workspace.yaml + per-package package.json files, builds a
      topological workspace graph, registers toolchain + install
      probes (keyed on pnpm-lock.yaml hash), and emits one cook.recipe
      per (package, task) when callers register tasks with
      cook_pnpm.task("build", { depends_on = { "^build" }, ... }).

      0.2 closes the v0.1 caching gap. Outputs declared as glob
      patterns are now passed through to cook.add_unit.outputs[]
      verbatim (anchored at the package directory) and resolved
      post-execute by the engine per CS-0085. Inputs continue to use
      register-time fs.glob expansion with a bare-`**` -> `**/*`
      normalisation that works around COOK-28.

      Tracked in cliban: project COOK, milestone "cook_pnpm",
      issue COOK-47.
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
