# cook_dotnet

`cook_dotnet` makes stale .NET build state disposable. Each build starts with
an empty, recipe-owned artifacts tree; Cook then caches the exact result.

```cook
use cook_dotnet

recipe app
    cook_dotnet.build({ project = "src/App/App.csproj" })
```

The default output is `build/dotnet/<recipe>/**`. The input set is every file
below the project directory except `bin/`, `obj/`, `.git/`, `.cook/`, and the
artifacts tree. Override `inputs` or `excludes` when the project reads shared
files outside that directory.

```cook
recipe app-release
    cook_dotnet.build({
        project = "src/App/App.csproj",
        inputs = { "src/**", "Directory.Build.*", "global.json", "NuGet.config" },
        configuration = "Release",
        framework = "net10.0",
    })
```

This first version intentionally leaves project evaluation and compilation to
the .NET SDK. It replaces mutable `bin/obj` state, not MSBuild's target model.
The CLI home and NuGet package cache live under `.cook/dotnet/`; they are tool
state, excluded from project inputs and build artifacts.

Builds restore explicitly with `--use-lock-file --locked-mode` and then build with
`--no-restore`; commit each generated `packages.lock.json`. The sealed toolchain
probe carries the chosen SDK, canonical `dotnet` identity, and paired reference-pack
versions without sealing a machine path. The Web-SDK-only ref-pack workaround is
applied from MSBuild's evaluated `UsingMicrosoftNETSdkWeb` property.

## Project graph

`workspace` asks MSBuild for evaluated projects, sources, target frameworks,
and `ProjectReference` edges, then mints one Cook recipe per project plus a
`dotnet:build` aggregate:

```cook
use cook_dotnet

cook_dotnet.workspace({ solution = "src/Product.slnx" })
```

`cook dotnet:build` builds the whole solution. Discovery uses Cook's registration-time
`cook.materialize` cache and returns the structured graph directly, so warm runs
do not start MSBuild just to rediscover the graph. Each project restores and builds
inside `build/dotnet/{bin,obj}/<project>` with MSBuild's recursive build disabled.
Consumers fold dependency reference assemblies, so an implementation-only
change can stop at the project whose public assembly surface did not change.

`dotnet:run` works when the graph has exactly one single-target executable. It assembles
a cached runnable tree from the current implementation outputs of every
transitive project, then executes the app.

Project recipes are minted after `dotnet:build` or `dotnet:run` is dispatched.
Until Cook gains discovery-aware name dispatch, those two static entry points are
the public workspace surface; `cook dotnet:App` is intentionally unavailable.

Discovery requires MSBuild 17.8 or newer because it uses the supported JSON
`-getProperty`/`-getItem` evaluation interface. Project references outside the
Cook workspace and duplicate MSBuild project names are rejected.

Run `demo/demo.sh` for the complete proof: cold build, unchanged cache hit,
private-change cutoff, public-API propagation, and execution of the projected
application. The demo works in a temporary directory and checks each claim.
