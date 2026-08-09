Offers the project-management commands (`cook cc.add …`) that edit the user's own sources and Cookfile.

Everything else in `cook_cc` runs because a Cookfile asked for a build. A verb
runs because a person typed it, and it writes files they will read afterwards.
That is the whole distinction this directory exists to keep.

## Layout

```
verbs/
  init.lua      the registry: VERBS list + the phase guard
  _project.lua  shared, read-only: where the Cookfile is, what it declares, which target is which kind
  _report.lua   shared: the one shape every verb's errors and success lines take
  new.lua       cc.new
  add.lua       cc.add
```

One file per verb, named for the verb. Shared helpers are underscore-prefixed
privates, as in `discovery/_probe_helpers.lua`.

## Adding a verb

1. Write `verbs/<verb>.lua` exporting `M.run(...)` (the body, callable from a
   spec without a dispatch) and `M.register()` (the `cook.chore` call).
2. Add its module name to `VERBS` in `init.lua`.
3. Add its `["cook_cc.verbs.<verb>"]` row to `build.modules` in the next
   rockspec.

`register()` looks like this, and the three metadata pieces are all
load-bearing:

```lua
function M.register()
    cook.chore("cc.link", {
        origin = "cook_cc.verbs.link",         -- `cook menu` attribution
        __params = {                            -- positional only; there are no flags
            { kind = "required", name = "target" },
            { kind = "variadic_plus", name = "libs" },
        },
    }, function(params)
        M.run(params.target, params.libs)
    end)
end
```

- **The name MUST be `cc.`-prefixed** (§22.12). The engine checks the prefix
  against the registering module's own identity; `cook_cc` may use `cc` or
  `cook_cc` and nothing else.
- **Registration only happens inside cook_cc's own chunk.** `cook_cc/init.lua`
  calls `require("cook_cc.verbs").register()` before its `return`. A chore
  registered later — from a function the module returned — is rejected, because
  the identity the prefix is checked against is only exact while the chunk runs.
  That identity is a single value the loader sets on entry and clears on exit,
  not a stack, so a plain `require` of a sibling file (what this directory does)
  keeps it and a `cook.load_module` of another cook module from inside one of
  these files would silently lose it. Do not load cook modules from `verbs/`.
- **The body takes ONE table**, not one argument per parameter. Param kinds are
  `required`, `defaulted_string`, `defaulted_lua`, `variadic_plus`,
  `variadic_star` (§7.1.1); required ones must precede defaulted ones and a
  variadic must be last.
- **The body only runs when asked for** (§7.6, CS-0218): when the chore is the
  dispatch target or is reachable from one. A verb will not fire during an
  unrelated build, so it does not need to guard against that.

## Shared helpers

`_project.lua` — read-only, and every call takes the calling verb's name so the
diagnostic can say who refused:

| Call | Answers |
|---|---|
| `project.cookfile(verb)` | `"Cookfile"`, or fails when there is none |
| `project.declarations(verb)` | every top-level `recipe`/`chore`, as `{ name, keyword, line }`, in file order |
| `project.declared(verb, name)` | the declaration that already owns `name`, or nil |
| `project.targets(verb)` | `name -> { kind, callee }` for recipes calling a cook_cc maker |
| `project.check_name(verb, name)` | fails unless `name` is a legal undotted declaration name |
| `project.alias(verb)` | the local this Cookfile binds cook_cc as — what a GENERATED call must say |
| `project.edit(verb, what, fn, …)` | runs a `cook.cookfile.*` call, re-raising its failure in the verb's voice |
| `project.KINDS` | the set of target-maker kinds: `bin`, `lib`, `shared`, `headers` |

`alias` is the one that is easy to skip and wrong to skip. Reading the Cookfile
tolerantly and then writing `cook_cc.lib(...)` into it regardless is the worst
of the two: a project that patched the module with the path form (§27.1.2) gets
an appended call to a global it never bound.

`edit` exists because `cook.cookfile.*` raises on its own terms — an
unparseable Cookfile arrives as `cook.cookfile.find_call: /abs/path/…`, which is
a fine message from the engine and the wrong shape from a verb. It is the one
way a verb bypasses `_report` without meaning to.

`declared` is the duplicate-name check and `cook.cookfile.find_call` cannot
replace it: find_call answers nil both for a recipe that does not exist and for
one that exists without a module call, so a verb keying off it would append a
second `recipe math` and leave the author with a Cookfile that no longer parses.

`_report.lua` — the message shape:

| Call | Produces |
|---|---|
| `report.fail(verb, message, hint?)` | raises `cc.add: message` with the hint on an indented second line |
| `report.did(action, subject)` | `  created  src/math/math.cpp` |
| `report.suggest(command)` | a blank line, then `  try: cook math` |
| `report.list(items)` | a set as a diagnostic renders it: sorted, comma-separated |
| `report.emit` | the sink; `print` in production, replaced by specs |

Say what happened in `did` lines and end with one `suggest`. Refuse through
`fail` and never through a bare `error`, so that no verb invents a second
diagnostic shape — `registry_spec` fails the suite if a verb calls `print`.

`did`'s action must be one of `report.ACTIONS`; an unlisted one raises rather
than sitting a character out of column. Adding an action is adding a row there,
which is also how the column width stays correct.

## Rules a verb follows

- **Check everything before writing anything.** A verb that scaffolds two files
  and then finds the name is taken leaves a mess it cannot undo. Ordering is:
  validate arguments, locate the Cookfile, check for collisions, then write.
- **Never hand-roll a Cookfile edit.** `cook.cookfile.append` and
  `cook.cookfile.splice_field` (§22.13) preserve every byte outside the
  inserted range and fail totally when they cannot find what they were asked
  for. A Cookfile is a program, not a data file: read-and-re-render silently
  destroys comments, field order and non-literal Lua.
- **Entries are rendered by the caller.** `splice_field` inserts `entry`
  verbatim, so pass `'"mathlib"'` — with the quotes — for a string entry.
- **Generate the bare module-call form.** Inside a recipe body it is
  `cook_cc.lib({ … })`, not `>> cook_cc.lib(…)`; CS-0134 reinstated bare
  module-call dispatch and removed `>>` from the language.
- **What you scaffold must build unedited.** That is the milestone's whole
  claim. Prove it end to end, not with specs alone. `cc.add` shipped with an
  `includes = { "include" }` its ticket did not ask for, because without it the
  first `cook math` after `cook cc.add lib math` failed to compile — and only
  the end-to-end run said so.
- **`declared` sees the Cookfile's text, not the register pass.** A name minted
  by a `register` block or another module is invisible to it. That gap is the
  engine's to catch (it raises a collision), and it is the reason these verbs
  refuse rather than merge when they find a name taken.

## Two things found the hard way

**`cook.cookfile` and `cook.chore` are register-phase only, and a surface chore
cannot reach them.** A `chore` block's `>` and `>{ }` steps are execute-phase,
and the execute VM's `cook` table has neither (nor `on_register_complete`, nor
`recipe_name`). A module-registered chore body is register-phase Lua, which is
why these verbs work at all. It is also why `verbs/init.lua` guards on
`type(cook.chore) == "function"`: `cook_cc` is loaded on the execute VM too,
and an unguarded registration kills every build.

**`splice_field` needs the field to already be there.** Verified against a
`cc.add`-generated recipe:

```
cook.cookfile.splice_field: … couldn't find 'links' in the cook_cc.bin call
in recipe 'game' — add "math" to it manually
```

That is §22.13 behaving correctly — failure is total and it will not insert a
field speculatively. But it means `cc.link` (COOK-287) cannot splice into a
target `cc.add` created, because `cc.add` emits no `links` field. The choice is
COOK-287's to make and was deliberately left open here: either `cc.add` starts
emitting `links = { }` on a `bin`, or `cc.link` handles the absent-field case
itself. Do not discover this at the end.

## Testing

`spec/verbs/` mirrors this directory. `spec/cook_stub.lua` models `cook.chore`
(including the namespace rule), `cook.cookfile.*` and a virtual working tree;
`stub.invoke_chore(name, argv)` binds argv against the declared `__params` the
way a real dispatch does, so a spec exercises registration and body together.
`stub.set_file`, `stub.file`, `stub.set_module_call` and `stub.splices` are the
rest of the surface.
