# cook_pnpm

Cook blessed module for pnpm-driven JS/TS monorepos. Turborepo-style task
pipelines on top of Cook's content-addressed DAG — so the same workspace
gets remote caching, watcher-driven incremental rebuilds, and a unified
build graph for the rest of your stack.

**Status: v0.1 first rough draft.** Surface may shift before the Standard
chapter §29 lands. Tracked in cliban under project `COOK`, milestone
`cook_pnpm`.

## Specification

The v0.1 surface is described in the cliban milestone description and in
this README. A normative chapter (§29) will land in the Cook Standard
once the surface stabilises against the smoke fixture.

## Install

In your project's `cook.toml`:

```toml
[modules]
cook_pnpm = "^0.1"
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
        inputs     = { "src/**", "tsconfig.json" },
        outputs    = { "dist/**" },
    })

    cook_pnpm.task("test", {
        depends_on = { "build" },                        -- X (no caret) = X in same package
        inputs     = { "src/**", "tests/**" },
    })

    cook_pnpm.task("lint", {
        inputs     = { "src/**", ".eslintrc*" },
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

## Probes

| Probe key | Purpose | Cache key |
|---|---|---|
| `pnpm:toolchain:<pin>` | Resolve absolute paths to node + pnpm | Pin string |
| `pnpm:install:<hash>` | `pnpm install --frozen-lockfile` once | pnpm-lock.yaml content hash |
| `pnpm:find:<tool>` | Locate a JS dev tool (node_modules/.bin → PATH) | Tool name |

Every per-package recipe carries the toolchain + install probes in its
`cook.add_unit` `probes` field. Lockfile drift invalidates everything
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
