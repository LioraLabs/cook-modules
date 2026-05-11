package = "cook_cc"
version = "0.1.2-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_cc-0.1.2-1",
}
description = {
   summary  = "Cook C-family (C + C++) native build module",
   detailed = [[
      Blessed Cook module for C and C++ native builds. Provides declarative
      target makers (cc.bin/lib/shared/headers), low-level primitives
      (cc.compile/archive/link), pkg-config discovery (cc.find), transitive
      link propagation, and compile_commands.json generation. Specified
      normatively at §9.2 of the Cook Standard.
   ]],
   homepage   = "https://github.com/lioralabs/cook-modules",
   license    = "MIT",
   maintainer = "Liora Labs <code@lioralabs.dev>",
}
dependencies = {
   "lua >= 5.4",
   "lua-cjson ~> 2.1",
   "lpeg ~> 1.0",
}
build = {
   type    = "builtin",
   modules = {
     ["cook_cc"]            = "cook_cc/init.lua",
     ["cook_cc.toolchain"]  = "cook_cc/toolchain.lua",
     ["cook_cc.cc"]         = "cook_cc/cc.lua",
     ["cook_cc.targets"]    = "cook_cc/targets.lua",
     ["cook_cc.finder"]     = "cook_cc/finder.lua",
     ["cook_cc.compile_db"] = "cook_cc/compile_db.lua",
     ["cook_cc.transitive"] = "cook_cc/transitive.lua",
   },
}
