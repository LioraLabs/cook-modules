package = "cook_dotnet"
version = "0.3.0-1"
source = { url = "git+https://github.com/lioralabs/cook-modules.git", tag = "cook_dotnet-0.3.0-1" }
description = {
   summary = "Fresh, cacheable .NET builds for Cook",
   detailed = [[
      0.3.0 makes workspace aggregate builds expose their generated projects'
      existing bin and obj outputs, so downstream recipes can consume the
      aggregate without duplicating the project graph (COOK-558).


      0.2.0 accepts executables that declare a single target framework via
      plural <TargetFrameworks> (COOK-557): run candidates key on the
      normalized framework list, discovery re-queries TargetFileName with an
      explicit TargetFramework for such projects, and the exactly-one-
      executable check no longer aborts registration — dotnet:run mints a
      failing unit instead, so the diagnostic surfaces only when dotnet:run
      is dispatched and dotnet:build always registers.

      0.1.0 is the first cook_dotnet release: workspace discovery via a
      cook materializer over MSBuild evaluation, per-project recipes with
      framework fan-out, runnable projection, and toolchain sealing.
]],
   homepage = "https://github.com/lioralabs/cook-modules",
   license = "MIT",
   maintainer = "Liora Labs <code@lioralabs.dev>",
}
dependencies = { "lua >= 5.4" }
build = { type = "builtin", modules = {
   cook_dotnet = "cook_dotnet/cook_dotnet.lua",
   ["cook_dotnet.discovery"] = "cook_dotnet/cook_dotnet/discovery.lua",
} }
