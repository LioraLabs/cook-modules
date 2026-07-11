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
instead is a set of functions — **target makers** — that a recipe body
calls to register work on your behalf. A target maker runs at register
phase too, so it may call the register-phase API (`cook.add_unit`,
`cook.step_group`, `cook.recipe`, `cook.probe`). Anything a module records
for later — a `>{ … }` body carried on a unit — runs at **execute phase**
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

A module doesn't register work when it loads — it exposes a **target
maker**: a function a recipe body calls, which registers a recipe and,
inside that recipe's body, one or more units via `cook.add_unit`
(§12.7.1). Reduced from `cook_pnpm/tasks.lua`'s `M.task`:

```lua
function M.task(task_name, opts)
    local requires = resolve_depends_on(pkg, opts.depends_on, by_name)   -- recipe-level order deps
    local inputs   = expand_globs_in_dir(opts.inputs,  pkg.dir)
    local outputs  = anchor_outputs(opts.outputs, pkg.dir)
    inputs[#inputs + 1] = pkg.dir .. "/package.json"

    cook.recipe(pkg.name .. ":" .. task_name, { requires = requires }, function()
        cook.add_unit({
            inputs   = inputs,
            outputs  = outputs,
            command  = command_for(pkg, task_name) .. " ",
            probes   = { toolchain.get_probe_key(), snap.install_key },  -- carry determinants
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

Every unit you register through a target maker has to hold up its end of
§12.7.2 (`#mods.authoring.units`):

- MUST declare a unit's real file inputs in `inputs` and its real outputs
  in `output`/`outputs`, so the cache keys on content instead of an
  under-declared surface (§12.7.2).
- MUST carry any determinant a probe produces into the unit's key via
  `seal` or `probes` — never by interpolating a probe's value into the
  command at register time in a form the cache can't observe (§12.7.2).
  See [Section 6 below](#6-seals-and-sharing-dispositions) for where
  `cook_cc` and `cook_pnpm` stand on `seal` today.
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

`consulted_env_keys`, `file_refs`, `member`, `step_kind`, and the
`sharing`/`seal`/`record` disposition trio are normally emitted by
codegen from surface syntax, not hand-written — `cook.add_unit` accepts
each directly under the same field-typing discipline, but you'll rarely
set them yourself from module code. And, again: the legacy `requires`
probe-spelling on `add_unit` is rejected — reach for `probes`.

### `discovered_inputs`: folding in a depfile

A compiler often can't tell you which headers it will read until it
actually runs — but it can write that list out as a side effect.
`discovered_inputs` lets a unit fold those paths into its key
retroactively instead of your module trying to predict them. Reduced
from `cook_cc/cc.lua`'s `M.compile`:

```lua
function M.compile(source, opts)
    toolchain.ensure_probe_registered()
    local cc_probe_key = toolchain.get_probe_key()      -- e.g. "cc:toolchain:g++"
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

## 5. Reading probe values and dependency outputs

## 6. Seals and sharing dispositions

## 7. Probe-key naming

## 8. Cross-module patterns

## 9. Testing with the `cook_stub` double

## 10. Publishing a blessed module

## 11. New-module checklist
