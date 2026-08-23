package = "cook_rust"
version = "0.1.0-1"
source = { url = "git+https://github.com/lioralabs/cook-modules.git", tag = "cook_rust-0.1.0-1" }
description = {
   summary = "Cargo-aware portable project seals for Cook",
   homepage = "https://github.com/lioralabs/cook-modules",
   license = "MIT",
   maintainer = "Liora Labs <code@lioralabs.dev>",
}
dependencies = { "lua >= 5.4", "lua-cjson ~> 2.1" }
build = { type = "builtin", modules = { cook_rust = "cook_rust/cook_rust.lua" } }
