package = "cook_pnpm"
version = "0.0.1-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_pnpm-0.0.1-1",
}
description = {
   summary = "Stub for the cook pnpm-monorepo module — real implementation tracked in SHI-191",
   detailed = [[
      Stub rock published by SHI-176 Phase 4 to reserve the cook_pnpm name on
      rocks.usecook.com and exercise the publish pipeline at realistic
      multi-rock scale. Calling cook_pnpm.placeholder() errors with a pointer
      at the real-implementation ticket. Replace this rock's contents when
      SHI-191 lands.
   ]],
   homepage = "https://github.com/lioralabs/cook-modules",
   license = "MIT",
   maintainer = "Liora Labs <code@lioralabs.dev>",
}
dependencies = { "lua >= 5.4" }
build = {
   type = "builtin",
   modules = { cook_pnpm = "cook_pnpm/cook_pnpm.lua" },
}
