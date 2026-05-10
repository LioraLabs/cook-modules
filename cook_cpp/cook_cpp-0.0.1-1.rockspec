package = "cook_cpp"
version = "0.0.1-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_cpp-0.0.1-1",
}
description = {
   summary = "Stub for the cook C/C++ build module — real implementation tracked in SHI-133",
   detailed = [[
      Stub rock published by SHI-176 Phase 4 to reserve the cook_cpp name on
      rocks.usecook.com and exercise the publish pipeline at realistic
      multi-rock scale. Calling cook_cpp.placeholder() errors with a pointer
      at the real-implementation ticket. Replace this rock's contents when
      SHI-133 lands.
   ]],
   homepage = "https://github.com/lioralabs/cook-modules",
   license = "MIT",
   maintainer = "Liora Labs <code@lioralabs.dev>",
}
dependencies = { "lua >= 5.4" }
build = {
   type = "builtin",
   modules = { cook_cpp = "cook_cpp/cook_cpp.lua" },
}
