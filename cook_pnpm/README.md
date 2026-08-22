# cook_pnpm

Cook blessed module for pnpm-driven JS/TS monorepos. Turborepo-style task
pipelines on top of Cook's content-addressed DAG — the same workspace gets
remote caching, cached test/lint results, watcher-driven incremental
rebuilds, and a unified build graph with the rest of your stack (a wasm
step, codegen, a Rust backend).

**Status: v0.8 — single-package repos.** One
`workspace()` call parses the workspace (honouring `pnpm-workspace.yaml`
`!` exclusions — or, new in 0.8, a lone root `package.json` with no
workspace file at all, see "Single-package repos"), mints every
configured task (with Turbo-spelled
`"<pkg>#<task>"` per-package overrides), auto-mints conventional checks,
defaults inputs safely, folds dependency-output CONTENT into every
consumer's key — filtered to the artifact classes a task actually reads
(discovered-inputs depfiles on builds, ready-time glob inputs on
checks) — and lowers declared `env` keys to consulted-env folds. Shaped
by the Cap port (Turborepo replaced on a 25-project workspace) and by
refinedev/refine. Surface may still shift before the Standard chapter
§29 lands. Tracked in cliban under project `COOK`, milestone
`cook_pnpm parity`.

## Install

In your project's `cook.toml`:

```toml
[modules]
cook_pnpm = "0.8.0-1"
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

That one call gives every workspace package a `pnpm:<dir>:build` recipe in
topological order, cached `pnpm:<dir>:test` / `pnpm:<dir>:lint` / `pnpm:<dir>:typecheck`
checks for the packages that declare those scripts, and an `install`
recipe — with no per-task input globs to write.

```
cook pnpm:build          # workspace root package
cook pnpm:web:build      # member whose directory basename is `web`
cook test                # run every check, cached — pass results replay
cook why pnpm:web:build  # audit every determinant of the key
```

## Single-package repos (0.8)

A repo with a root `package.json` and **no** `pnpm-workspace.yaml`
bootstraps as a workspace of one (solo mode). Two visible differences,
both because the package prefix would carry no information:

- recipes omit the redundant package segment — `pnpm:build`, `pnpm:lint`,
  `pnpm:test` — while retaining the module prefix so they cannot collide
  with handwritten recipes;
- commands drop `--filter <pkg>` (there is no workspace to filter):
  `pnpm run <task>` at the root, build and check units alike.

Everything else is identical: same probes, same default inputs, same
task cfg surface. `depends_on = { "^build" }` resolves to nothing (no
workspace deps) and is harmless. An explicit `packages = {...}` list or
an existing `pnpm-workspace.yaml` takes precedence over solo mode.

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
matches. So `pnpm:web:test` never takes `pnpm:web:build`'s `dist/` as an input and
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

## What folds from a dependency: `consumes`

A build task's key folds the **content** of the artifacts its workspace
dependencies produced — that is the mechanism behind cook's headline
advantage over Turborepo, which cascades on the upstream task's *input*
hash instead. Rebuild a dependency to byte-identical output and every
consumer stays cached.

That only pays off if the folded set is the set the consumer actually
reads. It usually isn't: **tsup and esbuild inline `sourcesContent` into
sourcemaps**, so a comment-only edit upstream leaves `dist/index.mjs`
byte-identical but rewrites `dist/index.mjs.map`. Folding the whole
output directory re-keys every consumer on a sidecar none of them
import, and the cutoff never fires.

So sourcemaps are **never folded by default**. Nothing to configure:

```
tasks = {
    build = { outputs = { "dist/**" }, depends_on = { "^build" } },
}
```

`*.map` is excluded from the fold; every other artifact class still
folds, so an unanticipated file type can never go stale. The filter
narrows a *fingerprint* only — the map is still built, still stored,
still restored on a cache hit.

Declare `consumes` to state the classes a task reads outright. It
**replaces** the default (turbo semantics — an explicit statement is the
whole truth, not a delta on module policy), so a task that genuinely
reads maps can name them back in:

```
tasks = {
    build = {
        outputs  = { "dist/**" },
        depends_on = { "^build" },
        consumes = { "*.mjs", "*.cjs", "**/*.d.ts" },
    },
}
```

Entries are **basename globs**, matched at any depth under the
dependency's output dirs; a leading `**/` is accepted for people who
think in path globs. Three shapes are register-time errors rather than
silent no-ops, because a filter that matches nothing *under*-keys the
consumer — a stale-cache bug, strictly worse than the over-invalidation
this surface exists to fix:

| Rejected | Why |
|---|---|
| `"*.{mjs,cjs}"` | brace alternation is shell expansion, not glob — `find -name` would match the literal string |
| `"dist/esm/*.mjs"` | path-shaped; this surface matches basenames |
| `"!*.map"` | `consumes` is an allowlist of what the task reads, not a subtraction |

## `consumes` on checks

Checks honour `consumes` too, but through different machinery and with a
different default — worth knowing, because the difference is visible.

A check is a test unit, and a test unit's key folds its predecessors'
outputs engine-side. `consumes` on a check lowers onto the test unit
(`cook.add_unit{step_kind = "test", consumes}` — §17.4 rule 1, CS-0175,
registration shape per CS-0185), which narrows that fold. **This
requires a cook engine carrying CS-0175**; on older engines the field
is ignored.

The catch is that the engine surface is an **allowlist** — it folds what
you name — while the build-side default is a **denylist**, folding
everything except sourcemaps. "Everything except `*.map`" cannot be
spelled as an allowlist, so it is not the default for checks:

| | build task | check task |
|---|---|---|
| no `consumes` | sourcemaps excluded | **everything folds**, sourcemaps included |
| `consumes` declared | folds only what you name | folds only what you name |

So an unconfigured check still re-keys when an upstream sourcemap
changes, where an unconfigured build does not. Name what the check reads
to close it:

```
tasks = {
    typecheck = { consumes = { "*.d.ts" } },   -- tsc -b reads declarations
}
```

The asymmetry is deliberate on the engine's side: narrowing a *test* key
errs toward replaying a stale pass, so the engine narrows only to what a
caller explicitly names rather than applying a default of its own.

## Negated input globs: rejected loudly

A `!`-prefixed entry on any *inputs* surface (workspace `inputs`, task
`inputs`) is a **register-time error** pointing at `exclude_inputs`.
Anchoring used to corrupt such entries into mid-path literals
(`./!apps/...`) that silently matched nothing.

## Negated output globs: not supported

Turbo's `outputs: [".next/**", "!.next/cache/**"]` shape is **rejected
at register time**. The engine's `outputs[]` surface recognises only
`*`, `?`, `[` as glob metacharacters (CS-0085); `!` exclusion exists for
`gather`, not outputs — a `"!"` entry would resolve as a literal
path and silently match nothing. Declare the positive globs only.

## Polyglot ordering: `requires`

Cook creates **no ordering edge from path equality**: when a pnpm task
reads files produced by a non-pnpm recipe (wasm-pack writing into
`src/`, codegen, a Rust build), the engine rejects the read-after-write
unless the producer is named. `depends_on` cannot express this — it only
resolves `pnpm:<dir>:<task>` names inside the workspace. Name the producer:

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
manifests are data, and one call mints *N* recipes named `pnpm:<dir>:<task>`.
Every minted recipe carries origin metadata (CS-0143), so `cook list`
attributes it:

```
recipe pnpm:web:build (from cook_pnpm.workspace)
recipe pnpm:web:test  (from cook_pnpm.workspace)
```

Member package segments come from the package directory basename, not its
possibly-scoped npm name (`packages/ui` becomes `ui`). Duplicate basenames are
rejected at registration rather than producing colliding recipes.

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
| `cook_pnpm.script(pkg, name, fn)` | Custom recipe under `pnpm:<dir>:<name>` |
| `cook_pnpm.workspaces()` | Introspect the parsed workspace graph |
| `cook_pnpm.toolchain(opts)` | Pin node / pnpm versions |
| `cook_pnpm.find(tool)` / `find_or_error` / `register_finder` | JS dev-tool locators |

Per-task opts: `inputs`, `outputs`, `depends_on`, `requires`,
`exclude_inputs`, `env`, `consumes` (builds and checks — see above),
`kind = "build" | "check"`. Task keys: `"<task>"` (every declaring package) or `"<pkg>#<task>"` (that
package only; replaces the base cfg).

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
