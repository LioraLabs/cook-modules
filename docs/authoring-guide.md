# Authoring a Cook module

This guide is a non-normative companion to the Cook Standard's **§12.7
Module-authoring contract** (`#mods.authoring`). It walks through how to
build a Cook module in practice — worked examples and patterns drawn from
the real `cook_cc` and `cook_pnpm` modules in this repo — but it does not
own any rule. Where this guide and the Standard disagree, the Standard
wins; every rule stated here cites the §-section that governs it.

## How to read this guide

Read Standard §12 (Modules) first for the module lifecycle — phases, the
register/execute split, the API chapters a module is built from — then
come back here for the how-to. Keep §12.7 open alongside this guide as
you work: each section below points back to the subsection of §12.7 (or
the adjacent §22 field reference) that it is illustrating.

## Contents

1. [What a module is and when its code runs](#1-what-a-module-is-and-when-its-code-runs)
2. [Anatomy of a module on disk](#2-anatomy-of-a-module-on-disk)
3. [Registering work units with `cook.add_unit`](#3-registering-work-units-with-cookadd_unit)
4. [Registering probes](#4-registering-probes)
5. [Reading probe values and dependency outputs](#5-reading-probe-values-and-dependency-outputs)
6. [Seals and sharing dispositions](#6-seals-and-sharing-dispositions)
7. [Probe-key naming](#7-probe-key-naming)
8. [Cross-module patterns](#8-cross-module-patterns)
9. [Testing with the `cook_stub` double](#9-testing-with-the-cook_stub-double)
10. [Publishing a blessed module](#10-publishing-a-blessed-module)
11. [New-module checklist](#11-new-module-checklist)

## 1. What a module is and when its code runs

A module is a Lua table you pull into a Cookfile with `use <name>` (§12.1).
The call binds that table into the Cookfile's Lua environment under the
name you gave it, and from then on the Cookfile calls into the module like
any other library.

The module's top-level chunk and its `init()` both run on the
**register-phase** VM, and neither one is allowed to register work — see
the phase obligations in §12.7.1 (`#mods.authoring.phases`) and the
lifecycle overview in §12.3 (`#mods.lifecycle`). What a module exposes
instead is a set of functions — **target makers** — and by default a
target maker is a **step contributor**: it takes a single `opts` table
(no name — the recipe identity comes from the caller), it is called from
*inside* a user-written `recipe` body, and it adds units to *that*
enclosing recipe via `cook.add_unit` and records that recipe's export via
`cook.export`. A step-contributor maker does **not** call `cook.recipe`
itself — the recipe already exists; the maker is contributing a step to
it. Two carve-outs MAY mint a recipe of their own instead — a maker doing
data-driven fan-out over register-time-parsed data (one recipe per
workspace member, say), or a maker minting a small support recipe to carry
generated configuration — see §12.7.8 (`#mods.authoring.minting`) and the
worked examples in [Section 3 below](#3-registering-work-units-with-cookadd_unit).
A target maker runs at register phase either way, so it may call the
register-phase API (`cook.add_unit`, `cook.step_group`, `cook.recipe`,
`cook.probe`, `cook.require_recipe`). Anything a module records for
later — a `>{ … }` body carried on a unit — runs at **execute phase**
instead, and may only call the execute-phase and both-phase API; calling a
register-only function from execute-phase Lua raises a runtime error
(§12.7.1).

In short: `init()` sets up state, it does not register units. `cook_pnpm`
is a clean example — its `init()` registers nothing at all, because the
toolchain and install probes are only registered lazily the first time a
Cookfile actually calls `cook_pnpm.workspace(...)`:

```lua
local M = {}
function M.init()
    -- Toolchain + install probes are registered lazily on the first
    -- `cook_pnpm.workspace(...)` call. Nothing to do here.
end
M.workspace = workspace.bootstrap   -- register toolchain+install probes, parse workspace
```

`cook_cc` follows the same shape: `M.init()` is empty, and the toolchain
probe is registered lazily on the first target-maker (`cook_cc.bin`,
`cook_cc.lib`, …) or `get_compiler` call. If your module has nothing to
do until a recipe asks for something, give it an empty `init()` too.

## 2. Anatomy of a module on disk

`cook_cc` and `cook_pnpm` in this repo are the reference layouts. A
trimmed view of `cook_cc/`:

```
cook_cc/
  init.lua                    -- returns M, wires the public surface
  toolchain.lua               -- compiler detection / toolchain probe
  targets.lua                 -- target makers: bin, lib, shared
  cc.lua                      -- M.compile and friends
  finder.lua, finders/        -- pkg-config / cmake-compat / per-library finders
  checks.lua, config_header.lua
  version.lua
  cook_cc-0.11.0-1.rockspec   -- LuaRocks package manifest, one per released revision
  spec/
    cook_stub.lua             -- the cook/fs/path test double (Section 9)
    *_spec.lua                -- busted specs
  README.md
```

`cook_pnpm/` mirrors it with `workspace.lua` and `tasks.lua` standing in
for `targets.lua`, plus a `probes/` directory (`pnpm_install.lua`,
`package_json.lua`) for probes big enough to earn their own file.

`init.lua` is the only file a Cookfile ever sees directly: it `require`s
the submodules and returns a single table `M` that re-exports the public
surface. Reduced from `cook_cc/init.lua`:

```lua
local toolchain = require("cook_cc.toolchain")
local targets   = require("cook_cc.targets")
-- ...
local M = {}
function M.init() end   -- toolchain probe registered lazily on first target-maker/get_compiler call
M.toolchain        = toolchain.set
M.compile          = cc.compile
M.bin              = targets.bin      -- target makers
M.lib              = targets.lib
M.shared           = targets.shared
M.find             = finder.find
M.compile_commands = db.write
return M
```

Split submodules by responsibility, not by file size: toolchain detection
(`toolchain.lua`) is separate from target makers (`targets.lua` /
`tasks.lua`), which are separate from probes (`probes/`) and from finders
(`finder.lua`). This keeps each file testable against the `cook_stub`
double in isolation ([Section 9 below](#9-testing-with-the-cook_stub-double)).

Every published module also carries a `cook_<name>-X.Y.Z-R.rockspec` —
the LuaRocks package manifest a release bumps
([Section 10 below](#10-publishing-a-blessed-module)) — and a `spec/`
directory with a `cook_stub.lua` double plus the busted specs that exercise
your module against it ([Section 9 below](#9-testing-with-the-cook_stub-double)).

On disk, `use "<name>"` resolves `cook_modules/<name>.lua` then
`cook_modules/<name>/init.lua`, first hit wins. The normative search order
and per-Cookfile `use` scoping rules live at §12.5 (`#mods.local`) and
§12.2 (`#mods.use-scope`) — don't re-derive them here.

## 3. Registering work units with `cook.add_unit`

By default a target maker is a **step contributor**, not a recipe-minter.
It takes a single `opts` table — no name parameter — it MUST be called
from *inside* a user-written `recipe` body, and it registers one or more
units into *that enclosing recipe* via `cook.add_unit`, plus that
recipe's export via `cook.export`. It does **not** call `cook.recipe`
itself: the recipe already exists, the maker is only contributing steps
to it. Call a step-contributor maker at top level — outside any `recipe`
block — and it MUST fail loudly rather than silently mint or misattach
its units; `cook_cc`'s makers do this by calling `cook.recipe_name()` and
raising `"must be called inside a recipe block; wrap it in a \`recipe\`
block"` if that call errors (§12.7.1).

`cook_cc` 0.13's `cook_cc.bin`/`lib`/`shared`/`headers` are the reference
shape:

```lua
use cook_cc
cook_cc.toolchain({ standard = "c++14", warnings = "none" })   -- top-level; see below
cook_cc.uses("sdl2", "gl")                                     -- top-level: cc:find:sdl2 / cc:find:gl probes
cook_cc.config_header({ from = "neo/config.h.in", to = "build/dhewm3/config.h", vars = { ... } })

recipe idLib
    cook_cc.lib({ sources = srcs("neo/idlib"), includes = {"neo","neo/idlib"}, needs = {"sdl2"} })

recipe framework
    cook_cc.lib({ sources = srcs("neo/framework"), links = {"idLib"}, needs = {"sdl2"} })
```

(`srcs(...)` above is an illustrative Cookfile-local source-globbing
helper, not part of `cook_cc`'s own surface — `cook_cc.lib` also accepts
a bare `dir = "neo/idlib"` and globs `*.c`/`*.cc`/`*.cpp`/`*.cxx` under it
itself if you'd rather not write one.)

### Name derivation: two names, two roles

A step-contributor maker has two different names available to it inside
the recipe body, and they drive two different things:

- **`recipe.name`** — the **bare** name the enclosing `recipe NAME` block
  was declared with. This drives every human-facing artifact *path* the
  maker produces: `build/bin/<name>` for `cook_cc.bin`,
  `build/lib/lib<name>.a` for `cook_cc.lib`, `build/lib/lib<name>.so` for
  `cook_cc.shared`, `build/obj/<name>/` for the intermediate objects.
- **`cook.recipe_name()`** — the **qualified** name, carrying any import
  prefix the enclosing Cookfile was pulled in under. This is the identity
  key the maker passes to `cook.export`, so a downstream `cook.import`
  resolves it correctly regardless of where in the import tree it lives.

In a root Cookfile with no import prefix the two coincide. Under an
import prefix they diverge, and the two roles must not be conflated: a
maker builds a filename from the *bare* name and an export identity from
the *qualified* name — never strip a prefix off the qualified form to
reconstruct a filename, and never use the bare form as an export key
once a prefix is in play.

### Top-level setup calls: `toolchain()` and `uses()`

Two calls in the worked example above run at top level, before any
`recipe` block, and both exist to keep probe registration out of recipe
bodies (CS-0083):

- **`cook_cc.toolchain({ standard = ..., warnings = ..., compiler = ... })`**
  registers the compiler-detection probe and records the standard/warning
  defaults every subsequent maker call picks up. Call it before the
  first target maker so those defaults are in place before anything
  compiles against them.
- **`cook_cc.uses("sdl2", "gl", ...)`** registers one `cc:find:<name>`
  probe per argument, at top level (§12.7.3, `#mods.authoring.probes`).
  A maker's in-body `needs = {"sdl2"}` does not itself register
  anything — it only *references* a probe `uses()` already declared, and
  wires the sigils that resolve it. An undeclared `needs` entry is a
  loud register-phase error: `needs "sdl2" is not declared; add
  cook_cc.uses("sdl2") at top level`. This declare-at-top-level /
  reference-in-body split is exactly what keeps a step-contributor maker
  from minting probes from inside a recipe body.

### `config_header()`: top-level configuration that mints a support recipe

`cook_cc.config_header({ from = ..., to = ..., vars = { ... } })` is
itself a top-level call, not something you invoke from inside a `recipe`
body. It's the second §12.7.8 (`#mods.authoring.minting`) carve-out
alongside data-driven fan-out below: rather than contribute to an
enclosing recipe, it mints exactly one small **support recipe** of its
own — via `cook.recipe(name, { origin = "cook_cc.config_header" },
body)` — whose unit renders the header. The `origin` metadata is what
lets `cook list` attribute that recipe to `cook_cc` rather than show it
as an author-declared target (§12.7.8; §22.6 keeps it dispatchable like
any other recipe).

It MUST be declared before any `cc.bin`/`lib`/`shared`/`headers` call —
calling it after one is a loud error, `declare config_header before cc
targets`, because every target maker registered after it auto-joins the
generated header's output directory onto its include paths and declares
the generated header as one of its compile units' `inputs` (that's the
data edge — a fold, not an ordering declaration on your part to make).

### `links`: fold for cache weight, `cook.require_recipe` for ordering

This is the subtle part, and it's worth reading slowly. When a maker
sees `links = {"idLib"}` in `opts`, it does three separate things:

1. Verifies `idLib` names a target already declared earlier in the same
   Cookfile, erroring with a closest-match hint otherwise — `links
   references unknown recipe 'idLib'; did you mean '...'?`.
2. Resolves `idLib`'s export via `cook.import` and folds its archive
   path, `build/lib/libidLib.a`, into the link unit's `inputs`. This
   earns **cache-key weight only** — it makes the link unit's fingerprint
   depend on the archive's content, nothing more.
3. Declares the cross-recipe **ordering edge** itself, by calling
   **`cook.require_recipe("idLib")`** (§22.8) — so `framework`'s units
   don't run before `idLib`'s do.

State this emphatically because it's easy to get backwards: the ordering
edge *is* the `cook.require_recipe` name reference. It is **not** inferred
from the fact that `build/lib/libidLib.a` appears as both `idLib`'s
output and `framework`'s link-unit input — §10.6 forbids an
implementation from inferring an edge from path-string equality; the path
match in step 2 above is fold-only, cache weight, not an edge. There is
also **no declaration-order rule for you, the module author's caller, to
learn** here: `cook_cc.lib` declares the ordering edge on your behalf the
moment it sees `links = {"idLib"}`, regardless of which recipe you
happened to write first in the Cookfile. Cross-reference §10.6 and §22.8;
[Section 8](#8-cross-module-patterns) revisits this same distinction for
the general case of any module, not just `cook_cc`.

### The data-driven fan-out carve-out: `cook_pnpm.task`

Not every target maker is a step contributor — §12.7.8 carves out a
second legitimate shape: a maker that mints one recipe per item of
register-time-parsed data, carrying `origin` metadata so `cook list` can
still attribute the minted recipes to the module. `cook_pnpm.task` is
this case: a pnpm workspace's `package.json` files are parsed at register
time, and the maker mints one recipe per workspace member, not one recipe
per Cookfile-authored `recipe` block. Reduced from `cook_pnpm/tasks.lua`'s
`M.task`:

```lua
function M.task(task_name, opts)
    local snap     = workspace.snapshot()                                -- parsed workspace + install_key
    local requires = resolve_depends_on(pkg, opts.depends_on, by_name)   -- recipe-level order deps
    local inputs   = expand_globs_in_dir(opts.inputs,  pkg.dir)
    local outputs  = anchor_outputs(opts.outputs, pkg.dir)
    inputs[#inputs + 1] = pkg.dir .. "/package.json"

    cook.recipe(pkg.name .. ":" .. task_name, { requires = requires }, function()
        cook.add_unit({
            inputs   = inputs,
            outputs  = outputs,
            command  = command_for(pkg, task_name) .. " ",
            probes   = { toolchain.get_probe_key() },   -- toolchain: consumed as data
            seal     = { snap.install_key },            -- install: invalidate-only determinant
        })
    end)
end
```

Two `requires` show up here, and they are not the same thing. The
`requires` in `cook.recipe`'s options table is a **recipe-level ordering
dependency** — it just says "run this recipe after that one," and it's
fine to use freely. `cook.add_unit` has no `requires` field at all: the
legacy `add_unit.requires` spelling — a pre-`probes` way of naming a
probe a unit consumes — is REJECTED, and a conforming implementation
raises a register-phase diagnostic pointing you at `probes` instead
(§22.1 field-provenance note, `#lua.add-unit`). If a unit needs a
probe's value, name the probe in `probes`; never in `requires`.

Reach for this shape only when the recipe set genuinely isn't knowable
until you've parsed data at register time — a workspace member list, a
generated manifest. If your maker's recipe boundary is simply "one call
site, one recipe" — which is the common case — the caller should be
writing the `recipe` block and your maker should be a step contributor
instead, per the default above.

Every unit you register through a target maker has to hold up its end of
§12.7.2 (`#mods.authoring.units`):

- MUST declare a unit's real file inputs in `inputs` and its real outputs
  in `output`/`outputs`, so the cache keys on content instead of an
  under-declared surface (§12.7.2).
- MUST carry any determinant a probe produces into the unit's key via
  `seal` or `probes` — never by interpolating a probe's value into the
  command at register time in a form the cache can't observe (§12.7.2).
  The unit above shows both: the toolchain probe is consumed as data via
  `probes`, the lockfile-hash install probe is an invalidate-only
  determinant via `seal`. [Section 6 below](#6-seals-and-sharing-dispositions)
  draws that line in full.
- SHOULD leave the `sharing`/`record` disposition to the recipe author's
  surface rather than hard-coding it in the module, unless the unit you
  own is intrinsically local or non-reproducible (§12.7.2).

### `cook.add_unit` field cheat-sheet

§22.1 (`#lua.add-unit`) is the authoritative field reference for
`cook.add_unit`; this table is the working subset a module author
actually sets.

| Field | What you set |
|---|---|
| `command` | Shell command, run via `/bin/sh -c` at execute phase. |
| `inputs` | Array of file paths whose content folds into the cache key. |
| `output` / `outputs` | A single output path, or an array of output paths / glob patterns (globs resolve post-execute against the unit's working dir, §22.1.2). |
| `probes` | Array of probe keys this unit consumes as data; each resolved probe's fingerprint folds into the unit's fingerprint and adds a DAG edge. |
| `seal` | Array of bare probe keys forming the unit's effective seal set; each named probe's canonical value folds into the cache key (see [Section 6 below](#6-seals-and-sharing-dispositions)). |
| `discovered_inputs` | Table `{ from = <path>, format = "make" }` declaring a depfile the command writes during execute, so paths not known at register time still fold into the key (§22.1.1). |
| `sharing` | `"local"` / `"pinned"` / `"shared"` (default `"shared"`) — the unit's cache-sharing disposition. |
| `record` | Boolean (default `false`) — marks the output intrinsically non-reproducible; the key is unchanged, byte-equivalence is waived. |
| `cache` | Boolean (default `true`) — `false` disables caching for this unit entirely; it re-runs every invocation. |

`consulted_env_keys`, `file_refs`, `member`, `step_kind`, `env`, and the
`sharing`/`record` dispositions are normally emitted by codegen from
surface syntax, not hand-written — `cook.add_unit` accepts each directly
under the same field-typing discipline, but you'll rarely set them yourself
from module code. `seal` is the exception a module *does* set directly (for
a deterministic determinant the unit doesn't read;
[Section 6 below](#6-seals-and-sharing-dispositions)). And, again: the
legacy `requires` probe-spelling on `add_unit` is rejected — reach for
`probes`.

### `discovered_inputs`: folding in a depfile

A compiler often can't tell you which headers it will read until it
actually runs — but it can write that list out as a side effect.
`discovered_inputs` lets a unit fold those paths into its key
retroactively instead of your module trying to predict them. Reduced
from `cook_cc/cc.lua`'s `M.compile`:

```lua
function M.compile(source, opts)
    toolchain.ensure_probe_registered()
    local cc_probe_key = toolchain.get_probe_key()      -- e.g. "cc:compiler:auto"
    local probes = { cc_probe_key }
    for _, n in ipairs(opts.needs or {}) do
        probes[#probes + 1] = "cc:find:" .. n           -- consume each pkg-config find probe
    end
    cook.add_unit({
        inputs            = { source },
        output            = obj_out,                     -- e.g. build/obj/app/main.o
        command           = compile_command,
        probes            = probes,                      -- toolchain + finds fold into key
        discovered_inputs = { from = dep_file, format = "make" },  -- headers the compiler read
    })
    return obj_out
end
```

`compile_command` passes the compiler a flag that makes it emit a
Make-format depfile listing every header it opened; `discovered_inputs =
{ from = dep_file, format = "make" }` tells the engine to read that file
after the command runs and fold the listed paths in as inputs, so
editing a header invalidates the cache on the next run even though your
module never saw that header at register time (§22.1.1,
`#lua.add-unit-discovered-inputs`).

## 4. Registering probes

A **probe** is the sanctioned surface for a memoised, cache-folded
computation a module needs but doesn't own as a unit in its own right —
compiler detection, a package-config query, a resolved toolchain
identity. You register one with `cook.probe(key, opts)`, where
`opts.inputs` declares the probe's determinants (`tools`, `env`, `files`,
`requires`) and `opts.produce` is the code that computes the value
(§12.7.3, `#mods.authoring.probes`).

### The lazy, idempotent registration idiom

A target maker may be called many times in one Cookfile, but a probe
should only be registered once per key. `cook_cc` and `cook_pnpm` both
solve this the same way: a per-VM `registered` table, and an
`ensure_probe_registered()` that returns immediately if the key is
already in it. Reduced from `cook_pnpm/toolchain.lua`:

```lua
local function probe_key() return "pnpm:toolchain:" .. sanitize(state.pin_pm or "auto") end

function M.ensure_probe_registered()
    local key = probe_key()
    if state.probe_registered[key] then return end       -- idempotent, per-VM
    cook.probe(key, {
        inputs  = { tools = { "node", "pnpm" } },         -- resolved-binary content hash = value+trigger
        produce = produce_body(state.pin_pm, state.pin_node),   -- a Lua SOURCE STRING
    })
    state.probe_registered[key] = true
end
```

Every target maker and helper that needs this probe calls
`ensure_probe_registered()` first and then reads back the key — there's
no separate "have I set this up yet?" check scattered across the module.

### `produce` is a Lua source string, not a closure

`produce_body(...)` doesn't return a function value — it returns a
*string* of Lua source:

```lua
-- produce_body returns a Lua source string that, on a cache miss, runs on a worker VM:
--   local node = which("node"); local pnpm_bin = which("pnpm")
--   return { node = node, node_version = ..., pnpm = pnpm_bin, pnpm_version = ... }
```

It has to be a string because it doesn't run in the VM that called
`cook.probe`. On a cache miss, the engine wraps that source as the body
of a producing function and runs it on a separate worker VM, and the
value it returns must be serialisable so it can cross that VM/phase
boundary and be stored (§12.7.3). You cannot close over local variables
from the register-phase VM the way an ordinary Lua closure would — the
producer only sees what its own source text and `opts.inputs` give it.

### Declare every determinant as a probe input

§12.7.3 is specific about this: any determinant your module detects has
to be modelled as a probe input, not read ad hoc inside `produce`, so its
fingerprint folds into the probe's value and from there into any
consuming unit's cache key:

- an environment variable → `inputs.env` (or an `envs` native producer);
- a tool → `inputs.tools` — the resolved binary's content hash is *both*
  the probe's value and what re-triggers it on a toolchain change, as in
  `{ tools = { "node", "pnpm" } }` above;
- a file → `inputs.files`;
- an upstream probe → `inputs.requires`.

### A side-effecting probe: `cook_pnpm/probes/pnpm_install.lua`

Not every probe just detects something — one can run a real command as
its side effect. The install probe is keyed on the lockfile's content
hash, depends on the toolchain probe, and its `produce` runs `pnpm
install --frozen-lockfile`:

```lua
function M.ensure_probe_registered(lockfile_path)
    toolchain.ensure_probe_registered()
    local h   = hash_file(lockfile_path)                  -- sha256sum, first 16 hex
    local key = "pnpm:install:" .. h
    if state.registered[key] then return key end
    cook.probe(key, {
        inputs = {
            requires = { toolchain.get_probe_key() },      -- upstream probe
            files    = { lockfile_path },                  -- lockfile content = determinant
            tools    = { "pnpm" },
        },
        produce = [[ local out = cook.sh("pnpm install --frozen-lockfile 2>&1")
                     return { installed = true, output = out } ]],
    })
    state.registered[key] = true
    return key
end
```

Because the key already bakes in the lockfile hash, a changed
`pnpm-lock.yaml` mints a new key and re-runs the install; an unchanged
lockfile hits cache and skips it. Notice a consuming unit never reads
`installed` or `output` back out — it doesn't need the probe's *value* at
all, only the guarantee that a lockfile change invalidates it. That is
precisely the invalidate-only shape `seal` exists for, not `probes`:
`cook_pnpm`'s `M.task` carries this probe as `seal = { snap.install_key }`
([Section 3 above](#3-registering-work-units-with-cookadd_unit),
[Section 6 below](#6-seals-and-sharing-dispositions)).

### Naming the key

Both examples above name their keys `"<module-prefix>:<name>"` —
`"pnpm:toolchain:..."`, `"pnpm:install:..."`. That's a SHOULD, not
incidental style; [Section 7](#7-probe-key-naming) covers the naming
rule and why it matters once a key gets built from arbitrary text.

## 5. Reading probe values and dependency outputs

### `cook.probes.get` and the `$<key>` desugaring

The sanctioned way to read a probe's value is `cook.probes.get(key)`,
which on the execute-phase VM reads that run's probe-value store. A
`$<key>` or `$<key.field>` placeholder in a command string desugars to
exactly this read (§12.7.4, `#mods.authoring.reads`) — so your module can
consume a probe either textually, inside a `command` string, or
programmatically, inside a `>{ … }` body. Pick whichever shape the unit
already needs; the underlying read is the same.

`cook_pnpm/tasks.lua`'s `command_for` is the textual form. It builds a
command against a `.pnpm` field selector rather than a hardcoded path:

```lua
local function command_for(pkg, task_name)
    toolchain.ensure_probe_registered()
    local key = toolchain.get_probe_key()          -- e.g. "pnpm:toolchain:pnpm-9"
    -- $<pnpm:toolchain:...pnpm> is replaced at execute time with the absolute pnpm binary path.
    return "$<" .. key .. ".pnpm> --filter " .. pkg.name .. " run " .. task_name
end
```

`.pnpm` selects the `pnpm` field out of the toolchain probe's produced
table (the same shape `produce_body` returns in
[Section 4](#4-registering-probes)) and resolves it to the absolute
binary path at execute time. The key in that placeholder is the same key
`M.task` hand-lists in `probes = { toolchain.get_probe_key() }`: a
`$<key.field>` in a command is captured at register time as a
`cook.probes.get` read (resolved at execute phase), but it does **not**
auto-populate `probes` — a placeholder naming a key the unit doesn't
declare in `probes` is a malformed-placeholder error (§22.5.7). So a
module that builds its own command string, like `M.task`, MUST also list
each consumed key in `probes` (that is the explicit declaration Section 3
requires); the command-string side and the `add_unit`-field side name the
same probe, they don't substitute for each other. (The install probe
`M.task` also carries isn't consumed as data — it's sealed, not read; see
[Section 6](#6-seals-and-sharing-dispositions).)

### Dependency outputs

To read what an upstream recipe produced, use `cook.dep_output` /
`cook.dep_output_list`, or the equivalent `$<NAME>` command-placeholder
surface — both-phase, like the probe reads above (§12.7.4).

### Transitive link info: `cook.export` / `cook.import`

A module publishes a target's transitive-link info with `cook.export`
and a downstream target reads it with `cook.import` — both both-phase
calls (§12.7.4). Reduced from `cook_cc/targets.lua`'s `record_export`:

```lua
local function record_export(name, sources, b, lib_path)
    cook.export(name, {
        includes      = b.export_includes or b.includes,
        system_libs   = b.export_system_libs or {},   -- PRIVATE-by-default
        links         = b.links,
        lib_path      = lib_path or "",
        compile_info  = { sources = sources, includes = b.includes, compiler = ... },
    })
end
-- A downstream target reads this with cook.import(name) to inherit include dirs / link flags.
```

A `cook_cc.lib` target calls `record_export` so anything that links
against it inherits its include dirs and link flags through
`cook.import(name)` without the downstream target having to know or
restate them. The `name` passed to `cook.export` here is the **qualified**
name from `cook.recipe_name()` — the export identity key, distinct from
the **bare** `recipe.name` a maker uses for artifact filenames
([Section 3](#3-registering-work-units-with-cookadd_unit)); in a root
Cookfile with no import prefix the two coincide.

### `cook.probes.set` / `cook.probes.scope` are deprecated

You may still see these register-phase key/value methods in older code,
but they're deprecated; a new module SHOULD use `cook.probe` for a
memoised value instead (§12.7.4).

## 6. Seals and sharing dispositions

`probes` and `seal` are the two `cook.add_unit` fields that fold a probe's
determinant into a unit's cache key (§12.7.2). They are not
interchangeable — which one you reach for depends on *how* the unit uses
the determinant:

- **`probes` — the determinant is consumed as data.** The unit reads the
  probe's value, typically through a `$<key.field>` placeholder or a
  `cook.probes.get` call, so the whole resolved value folds into the
  fingerprint. `cook_cc/cc.lua`'s `M.compile` lists `cc_probe_key` (and
  each `cc:find:<n>` finder probe) in `probes` because the compile command
  is built from the resolved compiler
  ([Section 3](#3-registering-work-units-with-cookadd_unit)).
- **`seal` — the determinant is invalidate-only.** The unit does NOT read
  the value; it only needs the key's canonical value to participate in the
  *shared* cache key that OTHER MACHINES look up when deciding whether they
  can reuse your output. That is a stronger commitment than consuming — and
  §12.7.5 governs exactly what you're allowed to put there.

Both are fields a module's target maker sets directly on `cook.add_unit`.
The trailing `seal <probe>` on a step's cook_mod line (§8.4.3, `#steps.cook-disposition`)
is the *recipe author's* surface for the same thing: codegen lowers it into
this same `add_unit.seal` field, so a recipe author can seal a probe the
module registered without the module hard-coding it.

`cook_pnpm` is the worked example. Its per-package task unit consumes the
toolchain probe as data — the command interpolates the resolved `pnpm`
binary path — but treats the lockfile-hash install probe as an
invalidate-only determinant, so the two go in different fields:

```lua
cook.add_unit({
    inputs   = inputs,
    outputs  = outputs,
    command  = command_for(pkg, task_name) .. " ",
    -- toolchain: consumed as data via $<pnpm:toolchain:...pnpm> (§12.7.4)
    probes   = { toolchain.get_probe_key() },
    -- install: deterministic lockfile-hash determinant, not read → seal (§12.7.5)
    seal     = { snap.install_key },
})
```

`cook_cc` does the same split on its compile and link units: the resolved
compiler and finder probes it consumes as data stay in `probes`, and it also
`seal`s those same resolved determinants (the compiler identity and each
finder's resolved result) so their values fold into the cache key — a
resolved-binary/tool content hash is exactly the deterministic determinant
`seal` is meant for.

### The seal policy: deterministic determinants only

§12.7.5 (`#mods.authoring.seal`) is the load-bearing rule here, and this
guide doesn't restate it beyond the shape you need to recognize it by:
seal ONLY a **deterministic determinant** — a lockfile's content hash, a
resolved toolchain's identity/content hash, something that is a pure
function of declared inputs. Sealing a **nondeterministic** value — a
build timestamp, an embedded absolute temp path, a randomised build ID —
folds that value into the shared cache key, and because the value can't
reproduce across machines, it breaks cross-machine reuse of that key
(§17.1.1, `#exec.cache.single-key`). Get this wrong and the failure mode isn't a
crash — it's a cache that silently stops sharing.

Two more shapes of the same rule worth carrying into your own module:

- **Every sealed determinant MUST be a named probe.** The seal surface
  admits no raw env-var or tool reference — you can't `seal $HOME` or
  `seal cc`. An env var you haven't already wrapped gets folded by
  declaring an `envs` probe over it and sealing that probe by name; a
  toolchain gets folded by sealing a `tools` probe by name (§12.7.5).
- **Don't fold what the author didn't declare.** A module MUST NOT try to
  smuggle a machine-inferred determinant — target triple, libc version,
  locale — into a seal; the engine infers none of these on its own, so if
  it matters to your output, it has to arrive as a probe input the author
  can see (§12.7.5, §12.7.3).

In practice, this is why `cook_pnpm`'s lockfile-keyed install probe and
`cook_cc`'s toolchain probe both look the way they do
([Section 4](#4-registering-probes)): a lockfile content hash and a
resolved-binary content hash are both pure functions of declared inputs, so
both are sound to seal — `cook_pnpm` already seals its install probe, and
`cook_cc`'s toolchain probe is the same shape. Sealing something like a
compiler's self-reported build timestamp would not be.

### Sharing and record: the recipe author's surface

`sharing` (`local` / `pinned` / `shared`) and `record` (surfaced as the
trailing `nondet` cook_mod) are the recipe author's dispositions to set,
not the module's (§22.1, §8.4.3). A module SHOULD
leave both to the author and take the `shared`/reproducible default,
unless the unit it owns is intrinsically local or non-reproducible
(§12.7.2) — in which case hard-coding the disposition is the right call,
not a shortcut around it.

What each disposition means for a unit, briefly — the cache-key and
lookup effect of each is defined at §17.1.3 (`#exec.cache.sharing`) and
§17.1.4 (`#exec.cache.record`), not here:

- **`local`** — local cache only; the unit's result never participates
  in shared/remote lookup.
- **`pinned`** — fetch-only / designated-producer: this machine (or CI)
  is the one that's allowed to produce it: others fetch, they don't
  re-run.
- **`nondet`** (the `record` field) — marks the output intrinsically
  non-reproducible; the cache key is unchanged, but byte-equivalence
  across runs is waived, so a rebuild that doesn't hash-match its own
  prior output isn't treated as a cache failure.

## 7. Probe-key naming

### The `PROBE_SEG` rule

A `$<key.field>` placeholder splits its text on `.` to separate the
probe key from a field selector — so a `.` inside a key you build
yourself is dangerous: the sigil resolver can misread it as the start of
a field selector that was never meant to be there. §12.7.6
(`#mods.authoring.probe-keys`) is the governing rule: a bare probe key is
at most two colon-separated segments (`PROBE_SEG:PROBE_SEG`), and a key
you derive from arbitrary text — a package name, a target label — MUST
be sanitised down to the `PROBE_SEG` character set before you use it as a
key.

"Arbitrary text" is doing real work in that sentence: a package name or
version pin comes from outside your module's control, and it can contain
characters `PROBE_SEG` doesn't allow. `cook_pnpm/toolchain.lua`'s
`sanitize()` exists for exactly this reason — a pin like `"pnpm@9"`
contains `@`, which isn't in the allowed alphabet, so it collapses
anything outside `[A-Za-z0-9_+-]` to `-` before the pin becomes part of a
key:

```lua
local function sanitize(s)
    -- Sigil resolver only accepts [A-Za-z0-9_+-] in probe-key segments. pnpm pins like "pnpm@9"
    -- contain '@' (and the cook_cc-0.6.1 lesson: a '.' in has_header("stdint.h") was mis-parsed as
    -- $<key.field>). Collapse anything outside the allowed alphabet to '-'.
    return (s:gsub("[^A-Za-z0-9_%+%-]", "-"))
end
local function probe_key() return "pnpm:toolchain:" .. sanitize(state.pin_pm or "auto") end
```

The comment isn't hypothetical: `cook_cc` shipped exactly the bug this
guards against. In `cook_cc-0.6.1`, a probe key derived from
`has_header("stdint.h")` carried the header name's `.` straight through
into the key, and the `.` was misread as a `$<key.field>` selector rather
than as part of the key it belonged to. Sanitising the derived segment
before it becomes a key is the fix; treat any key you build from a
name, a version string, or a path the same way, even if it "looks" safe
today.

### Naming convention

Prefer `"<module-prefix>:<name>"` for a key you register yourself —
`cc:zlib`, `pnpm:install:<hash>`, `cc:compiler:auto` are all this shape,
and Sections 3-4 use them throughout. It's a SHOULD, not a hard
requirement, but it buys you two things for free: keys from different
modules can't collide, and a reader can tell which module owns a key at
a glance.

If a spelling you need falls outside `PROBE_SEG` and sanitising it would
lose information you care about, the quoted-string key form is the
escape hatch — you're not limited to the bare `PROBE_SEG:PROBE_SEG` shape
if you spell the key as a quoted string instead (§22.5.2, `#cat.probes.decl`). Reach
for sanitisation first; reach for a quoted key when sanitisation would
make two distinct inputs collide on the same segment.

## 8. Cross-module patterns

None of the six patterns below is specific to `cook_cc` or `cook_pnpm` — they
surfaced building a polyglot dogfood, a small repo that mixes several
toolchains side by side, and each one is a candidate shape for a future
language module (`cook_dotnet`, `cook_rust`, `cook_python`). Two are marked
RULE. Read a RULE here as this guide's own house rule unless it says
otherwise — most of what follows is a candidate for future normative
capture in §12.7, not settled law yet. The one exception is the edge
mechanism below: that half is no longer a candidate, it's already
Standard-normative at §10.6 and §22.8, and the RULE says so where it
applies.

### Contract → codegen

**When it recurs:** a static contract file feeds an offline code generator
that emits source — an OpenAPI, protobuf, GraphQL, or JSON-Schema spec
compiling down to client or server stubs.

Don't make every call site re-derive the `inputs`/`output`/`mkdir`
boilerplate around the generator invocation; give the module one target
maker that owns it:

```lua
function M.codegen.from_spec(spec, generator, out)
    fs.mkdir_p(path.dir(out))
    cook.add_unit({
        inputs  = { spec },
        output  = out,
        probes  = { generator_toolchain_probe_key() },  -- carry the generator's identity, Section 4
        command = generator .. " generate --in " .. spec .. " --out " .. out,
    })
end
```

A call site shrinks to `codegen.from_spec("api.proto", "protoc",
"gen/api.pb.go")` — one line, no repeated `mkdir_p`, no repeated
`inputs`/`output` shape to get wrong at each call. The example carries the
generator's toolchain identity via `probes` because the command is built
from the resolved generator (consumed as data); if instead the generator's
identity were a determinant the unit never reads back, it would belong in
`seal` — the same data-vs-invalidate-only split
[Section 6](#6-seals-and-sharing-dispositions) draws.

### Fixture injection

**When it recurs:** a test command needs an absolute path to a fixture or
golden file another recipe's unit produced, and the test runner forks a
subprocess with a DIFFERENT working directory than the one the test command
itself ran in.

```lua
function M.with_env_from_dep(name, var)
    return var .. '="$(realpath $<' .. name .. '>)" '
end
```

used as a shell prefix, e.g. `M.with_env_from_dep("fixtures:golden",
"GOLDEN_DIR") .. "dotnet test"`. The `realpath` wrapping is the non-obvious
part, and it's required, not defensive: a `$<dep>` placeholder resolves to a
path that is consumer-cwd-relative, and that relative path stops resolving
correctly the moment a tool forks a subprocess with a different cwd —
`dotnet test`'s xunit host is exactly this case. Resolve to an absolute path
with `realpath` before the env var ever reaches the child process.

### Copy into consumer tree

**When it recurs:** codegen output has to cross a package boundary before a
local toolchain will treat it as first-party source — `tsc`'s `rootDir` and
`resolveJsonModule` are the concrete case, but the shape is generic to any
toolchain that resolves modules by directory containment rather than by
explicit reference.

```lua
function M.fs.copy_into(dep_output, dest)
    fs.mkdir_p(path.dir(dest))
    cook.add_unit({ inputs = { dep_output }, output = dest, command = "cp " .. dep_output .. " " .. dest })
end
```

Don't be surprised to reach for this twice even in one small repo — a
generated `.d.ts` copied next to hand-written TypeScript, and a generated
JSON schema copied into a `resolveJsonModule` tree, are two different call
sites of the same pattern, not one call site you can consolidate away.

### Meaningful stamp content — RULE

**When it recurs:** a unit's real result isn't a single file the engine can
hash directly — an install step, a restore step, anything whose result is
"the tool ran successfully over this input set" — so the module marks
completion with a stamp file instead of a content-addressable artifact.

This guide's rule (a candidate for future normative capture, not yet a
Standard MUST): a stamp file's *bytes* must encode the determinants it
proxies — a lockfile hash, resolved tool versions — not a constant. `echo ok
> .stamp` looks harmless, but a constant stamp makes its own dependency edge
structurally unfoldable: nothing in the stamp's content can ever differ, so
the engine can never observe that the thing it proxies changed — and,
symmetrically, can never observe that it DIDN'T, which is the case that
matters for early cutoff (§17.1.1). Encode the real
determinants instead, and a consumer downstream of the stamp stays cached
across a toolchain bump that didn't actually change the proxied result,
instead of treating every bump as a forced rebuild.

The failure mode this guards against was observed directly: a
stale-but-green `esbuild` `dist` — the stamp said "ran successfully," its
content said nothing beyond that, and a consumer trusted a build that a
version bump should have invalidated.

### Name references carry the ordering edge; a shared path is fold-only — RULE

**When it recurs:** every target maker that consumes another recipe's
output — which is to say nearly every target maker in a multi-language
repo.

This is no longer just this guide's rule — the load-bearing half of it is
now NORMATIVE, per §10.6, prohibiting an assumption a prior implementation
tested and found unsound: **a raw path shared
between one unit's output and another unit's input is fold-only.** It
earns cache-key weight — the consuming unit's fingerprint depends on the
shared file's content, via the ordinary `inputs`/`output` fold (§17.1.1)
— and nothing more. §10.6 states it as a MUST: an implementation MUST NOT
infer a cross-recipe ordering edge from path-string equality between an
output and an input. `cook_cc`'s link units are the concrete case: a
link unit folds a linked library's archive path into its own `inputs`
for cache weight (§17.1.1), and that fold, by itself, creates no ordering
edge at all.

The cross-recipe **ordering** edge instead comes from a **NAME
reference**: either the module calling `cook.require_recipe(name)`
(§22.8) at register time — which is how
`cook_cc`'s `links` resolution declares the edge alongside the archive-path
fold, [Section 3 above](#3-registering-work-units-with-cookadd_unit) — or
a `$<name>` name-reference placeholder appearing in a unit's body, which
is also a name reference and does create the edge (§10.6). A bare
artifact path is never enough on its own, however naturally it reads as
"this command takes that file as an argument" — recall the two different
`requires` already distinguished in
[Section 3 above](#3-registering-work-units-with-cookadd_unit): this is
the same distinction, one level down, at the unit body instead of the
recipe header. And critically, there is no declaration-order rule for a
Cookfile author to learn here either: the module declares the edge via
`cook.require_recipe` (or a `$<name>` reference) at the point it resolves
the dependency, regardless of which `recipe` block was written first.

Header deps (`recipe A : B`) are unchanged by any of this: they remain a
whole-recipe ordering FENCE, not a data edge — every unit of `A` waits for
every unit of `B` and it adds zero cache weight of its own (§17.1.1).
Reach for a header dep ONLY for genuine order-without-consumption — a
step that has to run after another for a reason no name reference in
either unit expresses.

### Multi-output declaration vs. stamps

**When it recurs:** a single unit produces more than one output file, and
you have to decide whether to declare them individually or fall back to a
stamp.

The decision rule: declare a multi-output set (`outputs = {...}`, plain
paths or globs) when the emit set is KNOWABLE at register time — `tsc`'s
matched `.js`/`.d.ts` pair for a given input is this case. Fall back to a
stamp (previous pattern, above) only when the emit set genuinely ISN'T
knowable — MSBuild's `bin`/`obj` trees are this case, because the exact
file set a build produces depends on project internals the module has no
register-time visibility into. Prefer the declared set whenever you can
enumerate it: it is more precise for the cache, and it is the honest answer
to "what did this unit actually produce."

---

Per-module specifics — a `rust.bin` target maker's own `cargo`-target-dir
copy plus `nondet` disposition, or a `cook_python` interpreter-and-locked-deps
identity probe — are tracked separately and are out of scope for this guide.

## 9. Testing with the `cook_stub` double

A module's target makers and probe registrations run at register phase,
and nothing about that requires a live engine to exercise in a test — all
a spec needs is something that looks enough like `cook`/`fs`/`path` to
catch what the module calls. That's what `spec/cook_stub.lua` is: a
busted double, one per module, that installs `_G.cook`, `_G.fs`, and
`_G.path` tables whose functions don't do anything an engine would — they
just *record* the call into a table your spec can then inspect. A spec
built this way asserts on the **registration graph** — which probes got
registered with what `opts`, what `add_unit` calls a target maker
produced, what `cook.export` recorded for a downstream target to import —
never on a real build actually running.

Reduced from `cook_pnpm/spec/cook_stub.lua` (itself a pared-down copy of
`cook_cc/spec/cook_stub.lua` — see below):

```lua
-- stub records calls; the spec inspects the recording, not a live engine:
local probe_registrations = {}   -- key -> opts
local added_units         = {}
local recipes             = {}   -- name -> { opts, body_executed }
local export_store        = {}   -- name -> info

_G.cook = {
    probe    = function(key, opts) probe_registrations[key] = opts end,
    add_unit = function(u) added_units[#added_units + 1] = u end,
    recipe   = function(name, opts, body_fn)
        recipes[name] = { opts = opts, body_executed = false }
        body_fn()                          -- runs the target maker's body NOW, register-phase
        recipes[name].body_executed = true
    end,
    export = function(name, info) export_store[name] = info end,
    import = function(name) return export_store[name] end,
    sh     = function(cmd) --[[ pattern-matched fake responses, e.g. `pkg-config --cflags`,
                                 `command -v <tool>`, `sha256sum <path>` ]] end,
}
_G.fs = {
    glob    = function(pattern) return glob_table[pattern] or {} end,
    exists  = function(p) return file_exists_set[p] end,
    mkdir_p = function() end,
}
```

`recipe`'s stub runs `body_fn()` inline rather than deferring it, so the
`cook.add_unit` calls inside a target maker's recipe body land in
`added_units` synchronously — a spec doesn't need to simulate register
phase separately from execute phase to see what a target maker produced.

The stub also exposes a handful of inspectors a spec calls directly,
rather than reaching into the recording tables itself:

- `M.probe_opts(key)` — the `opts` table a given probe key was registered
  with (so a spec can assert on `inputs.tools`, `inputs.files`, or the
  `produce` source string without re-deriving the key's registration).
- `M.added_units()` — the full list of units registered so far, in order.
- `M.recipes()` — the recipe table, name → `{ opts, body_executed }`.
- `M.reset()` — clears every recording table; call it from a `before_each`
  so specs don't leak state into each other.

The stub is **per-module and pared to the surface that module actually
uses** — it is not a shared, general-purpose fake. `cook_pnpm`'s
`cook_stub.lua` is a trimmed copy of `cook_cc`'s: it drops the
`pkg-config` response dispatcher `cook_cc`'s `sh` needs (`cook_pnpm` never
shells out to `pkg-config`) and adds a `glob_table` for `fs.glob`
(`cook_cc`'s stub stubs `glob` to always return `{}`, because `cook_cc`
doesn't register-time-glob the way `cook_pnpm`'s workspace scan does).
When you write a new module's stub, start from whichever of the two is
closer to your module's shape and cut down to what your module actually
calls — don't carry over surface you don't need.

Run the suite either from inside the module directory:

```sh
cd cook_<name> && busted .
```

or from the repo root, naming the module via `MODULE`:

```sh
MODULE=cook_<name> cook spec
```

## 10. Publishing a blessed module

Publishing is governed by §12.7.7 (`#mods.authoring.publishing`): a
blessed module MUST version rockspec revisions monotonically as
`X.Y.Z-R` — bump `R` alone for a repackage (no source change), bump
`X.Y.Z` for any public-surface change; MUST reflect any public-surface
change in the module's Part IV catalogue section (§27, `#cat`) under a
Standard change entry (App. E) before or alongside the code, per the
spec-first rule that governs every language-surface change in this
project; and SHOULD pin its source with a `git+https` URL and omit
`source.dir`. This guide doesn't restate those rules further — see
§12.7.7 for the exact wording.

The mechanics of getting a revision onto `rocks.usecook.com` are owned by
the repo root [`README.md`](../README.md) ("Publishing a module") and by
the `publishing-cook-modules` skill (`.claude/skills/publishing-cook-modules/`),
which automates the bump-and-push and the downstream `cook.toml` pin
bumps in consumers. In outline: author the surface change and bump the
rockspec version → commit and tag `<module>-<ver>` → `cook pack <module>`
(runs `luarocks pack` against the tag) → `cook publish-to-index <module>`
(stages the rockspec + `.src.rock` into the rocks-index checkout and
regenerates its manifest) → `cook publish` from that checkout (pushes to
Gitea + the GitHub mirror; Cloudflare Pages redeploys
`rocks.usecook.com` within a minute or two). Follow the README's numbered
steps or invoke the skill — don't hand-roll the pipeline from this
summary; the README owns the exact commands and the skill owns the
automation.

## 11. New-module checklist

An ordered path through this guide for a new module — `cook_dotnet`,
`cook_rust`, `cook_python`, whatever comes next:

1. Create the module's directory and an `init.lua` that `require`s its
   submodules and returns a single table `M`; add a `version.lua`
   ([Section 2](#2-anatomy-of-a-module-on-disk)).
2. Split submodules by responsibility — toolchain detection, target
   makers, probes, finders each in their own file — not by file size
   ([Section 2](#2-anatomy-of-a-module-on-disk)).
3. Register a probe for every toolchain or environment determinant your
   module detects; name keys `<prefix>:<name>` and sanitise any segment
   you derive from arbitrary text before it becomes part of a key
   ([Section 4](#4-registering-probes), [Section 7](#7-probe-key-naming)).
4. Write target makers that call `cook.add_unit` with real `inputs` and
   `outputs`, carrying every determinant a probe produces into the key —
   via `probes` when the unit reads the value as data, via `seal` when it's
   a deterministic, invalidate-only determinant the unit never reads
   ([Section 3](#3-registering-work-units-with-cookadd_unit),
   [Section 6](#6-seals-and-sharing-dispositions)).
5. Seal only deterministic determinants (§12.7.5); leave the `sharing` and
   `record` dispositions to the recipe author's surface unless the unit you
   own is intrinsically local or non-reproducible
   ([Section 6](#6-seals-and-sharing-dispositions)).
6. Add a `spec/cook_stub.lua` double, pared to your module's own surface,
   and busted specs that assert on the registration graph it records
   ([Section 9 above](#9-testing-with-the-cook_stub-double)).
7. Write the rockspec — `git+https` source, no `source.dir` — and reflect
   the public surface you're adding in the module's Part IV catalogue
   section under a Standard change entry ([Section 10 above](#10-publishing-a-blessed-module),
   §12.7.7).
8. Publish through the pipeline ([Section 10 above](#10-publishing-a-blessed-module)).

If you can get through all eight steps for a new language module using
only this guide and the Standard — without opening `cook_cc` or
`cook_pnpm` source to figure out what to do next — this guide has done
its job. Reading the real modules is still the fastest way to see a
pattern in full; it should never be the only way to find one.
