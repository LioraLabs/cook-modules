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

## 4. Registering probes

## 5. Reading probe values and dependency outputs

## 6. Seals and sharing dispositions

## 7. Probe-key naming

## 8. Cross-module patterns

## 9. Testing with the `cook_stub` double

## 10. Publishing a blessed module

## 11. New-module checklist
