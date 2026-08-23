package = "cook_dotnet"
version = "0.1.0-1"
source = { url = "git+https://github.com/lioralabs/cook-modules.git", tag = "cook_dotnet-0.1.0-1" }
description = {
   summary = "Fresh, cacheable .NET builds for Cook",
   homepage = "https://github.com/lioralabs/cook-modules",
   license = "MIT",
   maintainer = "Liora Labs <code@lioralabs.dev>",
}
dependencies = { "lua >= 5.4" }
build = { type = "builtin", modules = {
   cook_dotnet = "cook_dotnet/cook_dotnet.lua",
   ["cook_dotnet.discovery"] = "cook_dotnet/cook_dotnet/discovery.lua",
} }
