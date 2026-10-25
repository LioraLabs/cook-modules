package = "cook_rust"
version = "0.2.0-1"
source = { url = "git+https://github.com/lioralabs/cook-modules.git", tag = "cook_rust-0.2.0-1" }
description = {
   summary = "Cargo-aware portable project seals for Cook",
   detailed = [[
      0.2.0 seals the host into rust:project: rust:host, the host triple from
      `rustc -vV`, so units built on one platform are never served to another
      from a shared store. Every unit re-keys once on first run. Pair with
      cook >= 0.19.0 for a shared store.
   ]],
   homepage = "https://github.com/lioralabs/cook-modules",
   license = "MIT",
   maintainer = "Liora Labs <code@lioralabs.dev>",
}
dependencies = { "lua >= 5.4", "lua-cjson ~> 2.1" }
build = { type = "builtin", modules = { cook_rust = "cook_rust/cook_rust.lua" } }
