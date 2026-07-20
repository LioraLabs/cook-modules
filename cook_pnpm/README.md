# cook_pnpm

Cook blessed module for pnpm-driven JS/TS monorepos. Turborepo-style task
pipelines on top of Cook's content-addressed DAG — the same workspace gets
remote caching, cached test/lint results, watcher-driven incremental
rebuilds, and a unified build graph with the rest of your stack (a wasm
step, codegen, a Rust backend).

**Status: v0.5 — input exclusions.** One `workspace()` call
parses the workspace, mints every configured task (with Turbo-spelled
`"<pkg>#<task>"` per-package overrides), auto-mints conventional checks,
defaults inputs safely, folds dependency-output CONTENT into every
consumer's key (discovered-inputs depfiles on builds, ready-time glob
inputs on checks), and lowers declared `env` keys to consulted-env
folds. Shaped by the Cap port (Turborepo replaced on a 25-project
workspace). Surface may still shift before the Standard chapter §29
lands. Tracked in cliban under project `COOK`, milestone `cook_pnpm`.

## Install

In your project's `cook.toml`:

```toml
[modules]
cook_pnpm = "0.5.0-1"
```

Then `cook modules install`.

## Use

```
use cook_pnpm

register
    cook_pnpm.workspace({
        packages = "auto",          -- read pnpm-workspace.yaml; or {"apps/*", "packages/*"}
        node     = ">=18",
        pm       = "pnpm@10",
        requires = { "wasm" },      -- non-pnpm producer recipes (see below)
        inputs   = { ".env" },      -- root-relative extras, every task (see below)
        tasks    = {
            build = {
                depends_on = { "^build" },      -- ^X = X in workspace deps
                outputs    = { "dist/**" },     -- pkg-anchored, post-execute (CS-0085)
            },
            ["@scope/web#build"] = {            -- per-package override (see below)
                depends_on = { "^build" },
                outputs    = { ".next/**" },
            },
        },
        install  = "install",       -- mint the install stage under this name
        -- checks = "auto"          -- the default; see "Checks" below
    })
```

That one call gives every workspace package a `<pkg>:build` recipe in
topological order, cached `<pkg>:test` / `<pkg>:lint` / `<pkg>:typecheck`
checks for the packages that declare those scripts, and an `install`
recipe — with no per-task input globs to write.

```
cook build               # or an aggregator recipe of your own
cook web:build           # one package (quoted in a Cookfile: "web:build")
cook test                # run every check, cached — pass results replay
cook why web:build       # audit every determinant of the key
```

## Build tasks vs checks

`cook_pnpm` infers each task's execution shape from its declared outputs
(override with `kind = "build" | "check"`):

| Task shape | Engine unit | Cached how |
|---|---|---|
| `outputs` non-empty → **build** | `cook` unit | Key over inputs + toolchain probe + install seal; outputs restored from the store on a hit |
| no `outputs` → **check** | `test` unit (§8.6) | Content fingerprint over inputs + consumed upstream outputs; **pass** results recorded and replayed, cross-machine (§17.4) |

The check shape is why v0.3 exists: a cook unit with `outputs = {}` is an
engine OneShot — it re-runs every invocation and answers to no `cook
why`. cook_pnpm ≤0.2 minted exactly that for test/lint tasks. A test
unit is the engine's sanctioned pass/fail shape: it gets the same early
cutoff a build gets (an upstream rebuild that produces byte-identical
outputs leaves the check's key unchanged), and `cook test` runs it.

Two consequences of the test-unit contract (commands run verbatim via
`/bin/sh`, no probe substitution — CS-0127): check commands use plain
`pnpm` from `PATH` (the pnpm *version* is not folded into a check's key;
the lockfile and manifests are), and the lockfile determinant rides as a
declared **input** rather than a seal.

## Default inputs

Omitting `inputs` means "this package's file tree", computed per package
as every top-level directory except `node_modules`, dot-directories, and
any directory claimed by a declared output glob of any task in the same
`workspace()` batch — plus the package's top-level files, minus output
matches. So `web:test` never takes `web:build`'s `dist/` as an input and
self-invalidates.

Declare `inputs` explicitly to narrow (they replace the default set;
package-relative globs; a trailing bare `**` is normalised to `**/*`,
since the engine's glob matcher treats a bare `**` as directories-only):

```
tasks = {
    lint = { inputs = { "src/**", ".eslintrc*" } },
}
```

Build-task inputs expand at register time (`fs.glob`); check inputs pass
to the engine as globs and resolve at ready time.

## Per-package overrides: `<pkg>#<task>`

A tasks-map key of the form `"<pkg>#<task>"` (Turborepo's spelling)
configures that task for one package. The override cfg **replaces** the
base cfg entirely — turbo semantics, no merge: an override that omits
`requires` has no requires. A `<pkg>#<task>` key with no base entry
mints the task for that package only; base entries continue to apply to
every other package declaring the script. Override outputs claim
default-input exclusions for their package exactly like base outputs.
An override naming a package not in the workspace errors at register
time.

```
tasks = {
    build = { outputs = { "dist/**" }, depends_on = { "^build" } },
    ["@scope/web#build"] = { outputs = { ".next/**" }, depends_on = { "^build" } },
}
```

## Workspace-level inputs (turbo `globalDependencies`)

`workspace({ inputs = { ".env", "tsconfig.json" } })` appends
**workspace-root-relative** paths/globs to every minted task's inputs —
builds and checks, explicit per-task inputs or not. They are never
`pkg.dir`-prefixed. A literal entry that does not exist at register time
is dropped: the engine treats a declared-but-absent input as
never-a-clean-hit (silent cache-off for the whole task), and since the
register phase re-evaluates on every invocation, the file starts
participating the moment it exists. Glob entries pass through and
resolve to whatever exists.

## Excluding inputs: `exclude_inputs`

Some tools write derived, nondeterministic state INTO source
directories — `next build` rewriting
`app/.well-known/workflow/v1/manifest.json` is the flagship case. Left
in the input set, that file re-keys the very task that wrote it: every
foreign build makes the next `cook build` re-run the task with no stated
cause. `exclude_inputs` subtracts such paths:

```
workspace({
    -- ROOT-relative, subtracted from every minted task:
    exclude_inputs = { "apps/web/app/.well-known/workflow/**" },
    tasks = {
        -- or PACKAGE-relative, per task cfg (composes with the
        -- workspace level; also applies when `inputs` replaces the
        -- default set):
        build = { outputs  = { ".next/**" },
                  exclude_inputs = { "app/.well-known/workflow/**" } },
    },
})
```

The `!` is implied — write the glob without it. Build-unit inputs are
filtered at register-time expansion, so a matching file nested anywhere
inside a kept subtree glob is subtracted. Check-unit inputs resolve
engine-side at ready time, so exclusion there is entry-level: an input
glob **wholly inside** an excluded subtree is dropped whole, but a
single file nested in a kept subtree glob cannot be subtracted from a
check unit yet.

This generalises the module's own hardcoded exclusions (`*.tsbuildinfo`,
the depfile): tool state is never an input; it self-invalidates
otherwise.

## Negated input globs: rejected loudly

A `!`-prefixed entry on any *inputs* surface (workspace `inputs`, task
`inputs`) is a **register-time error** pointing at `exclude_inputs`.
Anchoring used to corrupt such entries into mid-path literals
(`./!apps/...`) that silently matched nothing.

## Negated output globs: not supported

Turbo's `outputs: [".next/**", "!.next/cache/**"]` shape is **rejected
at register time**. The engine's `outputs[]` surface recognises only
`*`, `?`, `[` as glob metacharacters (CS-0085); `!` exclusion exists for
`ingredients`, not outputs — a `"!"` entry would resolve as a literal
path and silently match nothing. Declare the positive globs only.

## Polyglot ordering: `requires`

Cook creates **no ordering edge from path equality**: when a pnpm task
reads files produced by a non-pnpm recipe (wasm-pack writing into
`src/`, codegen, a Rust build), the engine rejects the read-after-write
unless the producer is named. `depends_on` cannot express this — it only
resolves `<pkg>:<task>` names inside the workspace. Name the producer:

- workspace-wide: `cook_pnpm.workspace({ requires = { "wasm" }, ... })`
- per task: `tasks = { build = { requires = { "wasm" } } }`

Both are appended verbatim to every minted recipe's requires (workspace
first, then per-task, after the `depends_on` resolution).

## Checks

`checks = "auto"` (the default) additionally mints a check for every
*conventional* check script a package declares — `test`, `lint`,
`typecheck`, `check-types` — that the `tasks` map doesn't already
configure. Auto minting is an **allowlist**, deliberately: arbitrary
scripts (`dev`, `clean`, `postinstall`) are not build tasks, and a
minted `dev` would hang `cook test` forever. Pass a list to override the
convention, or `false` to disable. Anything else stays reachable
explicitly: `tasks = { ["your-script"] = {} }`.

## This module mints recipes (data-driven fan-out carve-out)

Under the explicit-recipes contract a module MUST NOT mint recipes
implicitly — but `cook_pnpm` is the documented exception: the workspace
manifests are data, and one call mints *N* recipes named `<pkg>:<task>`.
Every minted recipe carries origin metadata (CS-0143), so `cook list`
attributes it:

```
recipe web:build      (from cook_pnpm.workspace)
recipe web:test       (from cook_pnpm.workspace)
```

A name you did not write in the Cookfile is always traceable to the call
that created it.

## Probes

| Probe key | Purpose | Cache key |
|---|---|---|
| `pnpm:toolchain:<pin>` | Resolve absolute paths to node + pnpm | Pin string |
| `pnpm:install:<hash>` | `pnpm install --frozen-lockfile` once | pnpm-lock.yaml content hash |
| `pnpm:find:<tool>` | Locate a JS dev tool (node_modules/.bin → PATH) | Tool name |

Build units fold both workspace probes, by different dispositions per
the module-authoring seal policy (§12.7.5): the **toolchain** probe is
consumed as data (the command interpolates the resolved `pnpm` path —
§12.7.4); the **install** probe is a deterministic, invalidate-only
determinant, carried as a **seal**. Lockfile drift invalidates every
task downstream (builds via the seal, checks via the lockfile input);
source-only edits invalidate only the affected packages and their topo
descendants.

## Surface reference

| Function | Purpose |
|---|---|
| `cook_pnpm.workspace(opts)` | Parse + probe + mint (`tasks`, `checks`, `requires`, `inputs`, `install`) |
| `cook_pnpm.task(name, opts)` | Incremental single-task mint (single-batch defaults; prefer `workspace{tasks}`) |
| `cook_pnpm.run(pkg, script, opts)` | Single `pnpm --filter <pkg> run <script>` recipe |
| `cook_pnpm.install(opts)` | Explicit install-stage recipe |
| `cook_pnpm.script(pkg, name, fn)` | Custom recipe under `<pkg>:<name>` |
| `cook_pnpm.workspaces()` | Introspect the parsed workspace graph |
| `cook_pnpm.toolchain(opts)` | Pin node / pnpm versions |
| `cook_pnpm.find(tool)` / `find_or_error` / `register_finder` | JS dev-tool locators |

Per-task opts: `inputs`, `outputs`, `depends_on`, `requires`,
`kind = "build" | "check"`. Task keys: `"<task>"` (every declaring
package) or `"<pkg>#<task>"` (that package only; replaces the base cfg).

## Migrating from 0.2

- `task("test", {...})` with no outputs now mints a cached check (test
  unit) instead of a never-cached cook unit. If you relied on
  run-every-time semantics, that's a chore, or `kind = "build"`.
- Omitted `inputs` now defaults to the package tree, not `package.json`
  alone. Declare `inputs` to narrow.
- Serial `task()` calls still work but compute default inputs without
  sibling-task knowledge; move them into `workspace{tasks = {...}}`.

## Development

```sh
luarocks install --local busted
cd cook_pnpm && busted .
```

Or from the cook-modules root:

```sh
MODULE=cook_pnpm cook spec
```

## Roadmap

See the cliban milestone `cook_pnpm` under project `COOK`. Out of scope
for v0.3: remote-cache UX on Cook Cloud, `affected --since=<sha>`
integration, Standard chapter §29, npm/yarn parity, Windows.
