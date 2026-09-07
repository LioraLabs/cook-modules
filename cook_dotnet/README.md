# cook_dotnet

`cook_dotnet` delegates project evaluation and compilation to the .NET SDK.
`workspace` caches restore separately and rebuilds only changed projects and target
frameworks. The coarse `build` maker below retains a conservative empty-artifacts
build on each Cook cache miss; use `workspace` for project-level reuse.

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

The CLI home and NuGet package cache live under `.cook/dotnet/`; they are tool
state, excluded from project inputs and build artifacts.

Builds restore explicitly, then compile with `--no-restore`. When a project has
`packages.lock.json`, restore uses `--use-lock-file --locked-mode`; without a lockfile,
restore is unlocked. Commit lockfiles appropriate to each evaluated configuration;
a changed dependency graph must update its lockfile before locked restore can pass. The sealed toolchain
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

`root` defaults to `.` and scopes discovery and build inputs. A discovered project
outside it is rejected; expand `root` to include every project in the solution.

`cook dotnet:build` builds the whole solution. Discovery uses Cook's registration-time
`cook.materialize` cache and returns the structured graph directly, so warm runs
do not start MSBuild just to rediscover the graph. Each project restores and builds
inside `build/dotnet/{bin,obj}/<project>` with MSBuild's recursive build disabled.
Restore metadata has its own cached recipe. A private source edit reuses those
assets without starting restore. On a restore miss, only the owned metadata
files directly inside `obj/<project>/` are removed before native restore: malformed
assets or generated props can prevent NuGet itself from restoring. Configuration/framework subdirectories
remain intact; a private edit never performs this recovery.
Compile outputs belong to their SDK configuration
and framework directory, preserving unaffected frameworks in the active graph.

On a compile miss, `dotnet build --no-incremental` invokes the SDK's project-local
Rebuild target. This deliberately cleans and regenerates that project's tracked
compiler outputs: old source timestamps must not preserve stale code or resources.
It does not delete the whole artifacts tree or shared restore metadata, and it does
not rebuild project references. This is restore reuse, not timestamp-based skipping
of a changed project's compiler. The runnable projection is still recreated when
its implementation inputs change.

Restore work uses `sharing = "local"`: assets and generated NuGet props contain
absolute checkout and package-cache paths. Compiler units fold that restored
metadata into their input keys. They may share exact matching artifacts, but moving
to a fresh checkout regenerates restore metadata and changes the compiler keys;
it does not assume old absolute intermediate state is portable.

Consumers fold dependency reference assemblies, so an implementation-only
change can stop at the project whose public assembly surface did not change.

`dotnet:run` builds the selected application and its dependencies, assembles a
cached runnable tree from their current implementation outputs, then executes the
app interactively every time. Private dependency edits refresh this tree even
when unchanged reference assemblies keep consumer compilation cached.

Select a project and framework through the workspace options:

```cook
config
    var.PROJECT = ""
    var.CONFIGURATION = "Debug"
    var.FRAMEWORK = ""
    var.ARGS = "[]"

cook_dotnet.workspace({ solution = "Demo.slnx", project = var.PROJECT,
    configuration = var.CONFIGURATION, framework = var.FRAMEWORK,
    args = cook.json_decode(var.ARGS) })
```

```sh
cook dotnet:build --set PROJECT=App --set CONFIGURATION=Release --set FRAMEWORK=net8.0
cook why dotnet:build --set PROJECT=App --set CONFIGURATION=Release --set FRAMEWORK=net8.0
```

`project` accepts an exact evaluated project name or a workspace-relative `.csproj`
path. Empty project builds the whole workspace. Empty framework builds every
framework of the selected project; an explicit framework requires a project.
Dependencies use the SDK's compatible framework selection. Switching project or
framework reuses the discovered graph and preserves unrelated built outputs.
Configuration is a nonempty native MSBuild name, including custom configurations;
changing it selects a separately evaluated graph. Unknown project/framework errors
list available choices. Duplicate evaluated names or generated recipe-name
collisions are rejected with both paths because their SDK artifact directories
would collide; selecting by path does not make such a workspace safe.

The same selectors apply to `dotnet:run` and `cook why dotnet:run`. Run requires
an executable project. With multiple applications, set `PROJECT`; a single
application is selected automatically. A project with multiple frameworks requires
an explicit `FRAMEWORK`. Runtime files are isolated by project, configuration,
and framework. Switching frameworks preserves the sibling framework's runnable outputs.

```sh
cook dotnet:run --set PROJECT=App --set CONFIGURATION=Release --set FRAMEWORK=net8.0 \
    --set 'ARGS=["space value","","single quote: '\''","$(literal)"]'
cook why dotnet:run --set PROJECT=App --set FRAMEWORK=net8.0
```

`args` is a contiguous Lua list of strings, defaulting to `{}`. The example binds
it to a JSON array through Cook's existing `--set` and `cook.json_decode` APIs;
each argument is quoted separately, including empty strings and shell characters.
No shell command string is accepted. Invalid JSON fails during registration.
The native application inherits terminal input. Cook reports its failing exit
code and returns Cook's failure status: an application exit of 37 is reported as
37 while Cook returns 1. Ctrl-C interrupts the interactive process group, including
spawned descendants; Cook returns a nonzero status.

`demo/run.sh` proves selected execution, quoted arguments, current transitive
implementation bytes, native output agreement, actual terminal input and Ctrl-C
cleanup with SDK 10.0.111 (net8.0 and net10.0 targets). `demo/selection.sh` retains
the build/why selection, warm discovery reuse, and sibling preservation proof.

Project recipes are minted after `dotnet:build` or `dotnet:run` is dispatched.
Until Cook gains discovery-aware name dispatch, those two static entry points are
the public workspace surface; `cook dotnet:App` is intentionally unavailable.

Discovery requires MSBuild 17.8 or newer because it uses the supported JSON
`-getProperty`/`-getItem` evaluation interface. Project references outside the
Cook workspace and duplicate MSBuild project names are rejected.

Run `demo/demo.sh` for cold/warm builds, private-change cutoff, public-API propagation,
and projected execution. `demo/graph.sh` compares evaluated framework and generator
behavior with native MSBuild on SDKs 8.0.424 and 10.0.111.

`COOK=/path/to/cook demo/recovery.sh` exercises edit/revert, preserved timestamps,
branch and configuration changes, corrupt/missing outputs, dependency changes,
locked restore failures, and fresh-checkout recovery in isolated temporary trees.
It also reports five private-edit build/run samples for this module, the
pre-change `9a92715` revision, and native incremental MSBuild using SDK 10.0.111.
Run it from a repository checkout containing that baseline revision. The default
invocation is the full gate; `--matrix-only` or `--benchmark-only` isolates a phase.
`--fresh-timestamps` is diagnostic only and does not prove preserved-timestamp recovery.

`demo/discovery.sh` checks the reference-pack fingerprint against the original
per-file OpenSSL command, including installed packs, unusual filenames, missing
and empty packs, and content changes. It requires Python 3, Lua 5.4, OpenSSL, and
SDK packs under `/usr/share/dotnet`. Hashing uses native `find -exec ... +` batches;
it still reads every reference file and sorts the same filename/digest records.

Graph discovery runs at most four native SDK evaluations concurrently. It retains
each outer build, each explicitly selected framework's ordinary item evaluation,
and the SDK's separate project-reference compatibility query.

`demo/discovery.sh --graph-proof` compares the normalized graph with the sequential
producer on SDK 8.0.424, observes the process bound, and checks global-framework
imports, configuration-specific references, and native query errors. It requires
the existing LuaRocks `lua-cjson` test dependency and repository history containing
`9b0f642`. SDK 8 and 10 build/generator behavior is covered by `demo/graph.sh`.
