package = "cook_smoke"
version = "0.1.0-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_smoke-0.1.0-1",
   dir = "cook_smoke",
}
description = {
   summary = "Phase 3 acceptance fixture for cook modules pipeline",
   detailed = [[
      Throwaway rock used by SHI-176 Phase 3 to validate the cook modules
      install pipeline against rocks.usecook.com end-to-end. Exposes a
      single function: cook_smoke.value() returns 42.
   ]],
   homepage = "https://github.com/lioralabs/cook-modules",
   license = "MIT",
   maintainer = "Liora Labs <code@lioralabs.dev>",
}
dependencies = {
   "lua >= 5.4",
}
build = {
   type = "builtin",
   modules = {
      cook_smoke = "cook_smoke.lua",
   },
}
