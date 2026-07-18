# cook_pnpm

Cook blessed module for pnpm-driven JS/TS monorepos. Turborepo-style task
pipelines on top of Cook's content-addressed DAG — so the same workspace
gets remote caching, watcher-driven incremental rebuilds, and a unified
build graph for the rest of your stack.

**Status: v0.2 — caching parity.** Outputs resolve post-execute per
CS-0085 and restore from cache on a hit. Surface may shift before the
Standard chapter §29 lands. Tracked in cliban under project `COOK`,
milestone `cook_pnpm`.

## Specification

The v0.1 surface is described in the cliban milestone description and in
this README. A normative chapter (§29) will land in the Cook Standard
once the surface stabilises against the smoke fixture.

## Install

In your project's `cook.toml`:

```toml
[modules]
cook_pnpm = "0.2.0-1"
```

Then `cook modules install`.

## Use

```
use cook_pnpm

register
    cook_pnpm.workspace({
        packages = "auto",          -- read pnpm-workspace.yaml; or pass {"apps/*", "packages/*"}
        node     = "^20.11",        -- node version pin
        pm       = "pnpm@9",        -- pnpm version pin
    })

    cook_pnpm.task("build", {
        depends_on = { "^build" },                       -- ^X = X in workspace deps
        inputs     = { "src/**", "tsconfig.json" },      -- bare ** auto-normalised to **/*
        outputs    = { "dist/**" },                      -- workspace-anchored, post-execute
    })

    cook_pnpm.task("test", {
        depends_on = { "build" },                        -- X (no caret) = X in same package
        inputs     = { "src/**", "tests/**" },
    })

    cook_pnpm.task("lint", {
        inputs     = { "src/**", ".eslintrc*" },         -- outputs omitted → cache by inputs+success
    })
```

Then:

```
cook game build              # build every package in topo order
cook game @scope/web:build   # build just that package and its workspace deps
cook game test               # build then test every package
```

## Surface (v0.1)

| Function | Purpose |
|---|---|
| `cook_pnpm.workspace(opts)` | Parse pnpm-workspace.yaml + each package.json; register toolchain + install probes |
| `cook_pnpm.task(name, opts)` | Emit one `cook.recipe` per (pkg, task); topo from `depends_on` |
| `cook_pnpm.run(pkg, script, opts)` | Single `pnpm --filter <pkg> run <script>` recipe |
| `cook_pnpm.install(opts)` | Recipe that runs `pnpm install --frozen-lockfile`; cached by lockfile hash |
| `cook_pnpm.script(pkg, name, fn)` | Register a custom recipe under `<pkg>:<name>` |
| `cook_pnpm.workspaces()` | Introspect the parsed workspace graph |
| `cook_pnpm.toolchain(opts)` | Pin node / pnpm versions |
| `cook_pnpm.find(tool)` / `cook_pnpm.find_or_error(tool)` | Locate a JS dev tool |
| `cook_pnpm.register_finder(name, fn)` | Project-scoped custom finder |

## This module mints recipes (data-driven fan-out carve-out)

Under the explicit-recipes contract a module MUST NOT mint recipes implicitly —
single-target makers are step contributors a user-written `recipe` body calls.
`cook_pnpm` is the documented exception: **`cook_pnpm.task(name, opts)` is a
data-driven fan-out** — one call parses the workspace manifests and mints *N*
recipes named `<pkg>:<task>` (e.g. `web:build`, `api:build`). `cook_pnpm.run`,
`cook_pnpm.install`, and `cook_pnpm.script` likewise register recipes.

Every recipe minted this way carries `origin = "cook_pnpm.task"` metadata, so
`cook list` attributes it to the call that created it:

```
recipe web:build   (from cook_pnpm.task)
recipe api:build   (from cook_pnpm.task)
```

A name you did not write in the Cookfile is always traceable to the module that
minted it. See the Cook Standard's module-authoring contract (CS-0143 origin
annotation; the fan-out carve-out).

## Caching (v0.2)

`outputs` semantics changed from v0.1: each entry is a glob pattern
(no bare-path shortcut), anchored at the package directory, and
resolved by the engine **after** the recipe runs (per CS-0085). On a
cache hit, the literal file set recorded post-execute is restored.

| `outputs =` | Behaviour |
|---|---|
| `{ ".next/**" }` | Post-execute resolve in `apps/web/.next/**`; restore on hit |
| `{}` or absent | Cache by inputs + success; no files restored |
| `{ "dist/**", "*.tsbuildinfo" }` | Each glob anchored independently |

Inputs continue to expand at register time via `fs.glob`. Trailing
bare `**` is normalised to `**/*` (workaround for COOK-28).

A recipe with globbed `outputs` MUST NOT have those outputs declared
as `inputs[]` of another recipe — use `requires=` for ordering only.

## Probes

| Probe key | Purpose | Cache key |
|---|---|---|
| `pnpm:toolchain:<pin>` | Resolve absolute paths to node + pnpm | Pin string |
| `pnpm:install:<hash>` | `pnpm install --frozen-lockfile` once | pnpm-lock.yaml content hash |
| `pnpm:find:<tool>` | Locate a JS dev tool (node_modules/.bin → PATH) | Tool name |

Every per-package recipe folds both the toolchain and the install probe
into its cache key, but by different dispositions per the module-authoring
seal policy (Cook Standard §12.7.5):

- **Toolchain probe** — consumed as **data**. The command interpolates
  `$<pnpm:toolchain:<pin>.pnpm>` for the resolved binary path, so the
  probe's full value already folds in via `cook.add_unit.probes` (§12.7.4).
- **Install probe** — a deterministic, **invalidate-only** determinant
  (the `pnpm-lock.yaml` content hash). It is never read as data, so it is
  carried as a **`seal`** (`cook.add_unit.seal`), not a data probe. Sealing
  is the sanctioned surface for a pure-function-of-inputs determinant and
  keeps the shared cache key reproducible across machines.

Lockfile drift changes the install probe's value and invalidates everything
downstream; source-only edits invalidate only the affected packages and
their topo descendants.

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
for v0.1 (M0): remote-cache UX on Cook Cloud, `affected --since=<sha>`,
Standard chapter §29, npm/yarn parity, Windows.
