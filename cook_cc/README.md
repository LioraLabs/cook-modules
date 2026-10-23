# cook_cc

Cook C-family (C + C++) native build module. Provides step-contributor
target makers (`cc.bin` / `cc.lib` / `cc.shared` / `cc.headers`) called
inside a `recipe` body, low-level primitives (`cc.compile` / `cc.archive` /
`cc.link`), pkg-config discovery (`cc.find` / top-level `cc.uses`),
transitive link propagation, and compile_commands.json generation.

## Specification

The module's public surface is normatively specified at §9.2 of the Cook
Standard. See `standard/src/content/docs/09-standard-modules.mdx` in the
cook repo.

## Install

In your project's `cook.toml`:

```toml
[modules]
cook_cc = "^0.1"
```

Then `cook modules install`.

## Use

```
use cook_cc

cook_cc.toolchain({ standard = "c++17", warnings = "strict" })
cook_cc.uses("sdl2")
cook_cc.config_header({ from = "config.h.in", to = "build/config.h", vars = { VERSION = "1.0" } })
cook_cc.compile_commands()

recipe app
    cook_cc.bin({ sources = { "src/main.cpp" }, needs = { "sdl2" } })
```

`toolchain()`, `uses()`, and `config_header()` are top-level calls made
before any recipe. `uses(...)` registers `cc:find:*` probes that a maker's
`needs` list can then reference by name; makers themselves are step
contributors — they take no `name` parameter and must run inside a
`recipe` body, which supplies the recipe identity.

`compile_commands()` is top-level too, but it's the temporal mirror of the
other three: `toolchain`/`uses`/`config_header` all run *before* any
target; `compile_commands()` runs *after* all of them, via the
register-completion finalizer (`cook.on_register_complete`). It writes
`compile_commands.json` on every registration pass that actually
dispatches or builds something — there's no recipe to invoke, no name to
depend on. Because the finalizer snapshots the whole registered-target
set rather than walking a dependency graph, the database is complete by
construction, including a target in no `links` closure at all (a
dlopen'd plugin, say).

Compile and link units seal `cc:host:<override-or-auto>`, the chosen
compiler's `-dumpmachine`, so two targets never share an artifact. A
hand-written unit seals the key matching the compiler (`cc:host:auto`
without an override, `cc:host:<override>` with one), and the Cookfile must
also make a cook_cc call that registers it (`toolchain()` or a target maker).

## Project-management verbs

`cook_cc` also registers chores you invoke directly, so a target can be added
without hand-editing anything:

```
cook cc.new             # scaffold a project around the Cookfile that is here
cook cc.add lib math    # src/math/math.cpp + include/math/math.hpp,
                        # and a `recipe math` appended to the Cookfile
cook cc.add bin game    # src/game/main.cpp, and a `recipe game`
cook cc.need sdl2 game  # game's needs = { "sdl2" }, then probe for sdl2 now
cook cc.fmt             # clang-format -i over src/, include/ and tests/
```

`cook cc.new` is the first minute of a C++ project:

```
mkdir game && cd game
cook modules install cook_cc     # writes the Cookfile and its `use cook_cc`
cook cc.new                      # the toolchain call, build/run/test, sources
cook build && cook run
```

It is in-place only — `cook modules install` is what creates a project, since
the `cc.*` chores do not exist until something has loaded `cook_cc`. Around the
Cookfile already there it writes `src/main.cpp`, `include/greet.hpp`, an
assert-based `tests/main.cpp` with no framework to install, a `.clang-format`,
and the managed `.gitignore` sections; into it, the `cook_cc.toolchain` call and
the `build` recipe, `run` chore and `test` recipe. It refuses — writing nothing
— when the Cookfile already declares `build`, `run` or `test`, when it already
configures the toolchain, or when any of those sources exists. `.clang-format`
is left alone rather than refused over: an existing one is the author's
formatting policy.

`cook cc.add <kind> <name>` takes two positional arguments; there are no flags,
because chore parameters are positional only (§7.1.1). It refuses — writing
nothing — on an unknown kind, on a name the Cookfile grammar would reject, on a
name some declaration already owns, and on a `src/<name>/` that already exists.
What it writes compiles and links as generated: `cook <name>` straight after
`cook cc.add` builds the target.

`cook cc.need <dep> <target>` declares an external dependency and then goes and
looks for it, so the answer to "do I have sdl2?" arrives before the first build
rather than as a link error. It makes two edits: `"<dep>"` into the target's
`needs` list — creating the field when the target has none — and, when nothing
has declared that probe yet, a top-level `<cc>.uses("<dep>")`, without which
`needs` is refused at register time. Then it resolves `cc:find:<dep>` on the
spot and reports the version and the strategy that answered, or, on a miss,
every strategy the probe recorded and a hint to install it. A miss is not a
failure: declaring a dependency you have not installed yet is a legitimate
thing to have done, so the edit stands and the command exits 0. Needing the
same dependency twice writes nothing and re-runs the probe, which is the reason
to type it twice.

The target is required. The epic specified an optional trailing target meaning
"the defaults level", and there is no defaults level to mean: `cc.defaults` has
no `needs` key yet. The dependency still comes first, so the optional form can
appear later without changing what any command written today does.

Nothing is fetched and no package manager is involved. The finder chain —
curated, then pkg-config, then cmake, then a bare link probe — resolves
arbitrary names without a curated finder, which is why `cc.need` works for a
dependency `cook_cc` has never heard of.

`cook cc.fmt` takes no arguments: it formats every `.c`, `.cc`, `.cpp`, `.cxx`,
`.h`, `.hpp`, `.cppm` and `.ixx` under `src/`, `include/` and `tests/` in place.
A directory the project does not have is not an error; a sweep that finds
nothing at all is, and so is a project with no `.clang-format` of its own —
`cc.fmt` formats to the style a project declares and will not pick one for it,
which is why a first run in a project that never adopted clang-format refuses
instead of reflowing every file to LLVM's defaults. A single line reading
`BasedOnStyle: InheritParentConfig` is how a project inside a larger repository
declares that it takes the repository's style. To keep a vendored tree under
`src/` out of the sweep, list it in `.clang-format-ignore`, which excludes it
from every clang-format the project runs and not just from this one.
`CLANG_FORMAT` names the binary when the unsuffixed `clang-format` is not the
one you want.

These are module-registered chores (§22.12), so they appear in `cook menu`
attributed to the module that offered them, and their bodies run only when
invoked — never during an unrelated build (§7.6). Where a verb edits the
Cookfile, as `cc.add` does, it goes through the blessed structure-preserving
editor (§22.13), so comments, spacing and field order elsewhere in the file are
left byte-identical; `cc.fmt` edits no Cookfile at all. `cc.link` and `cc.need`
refuse before their first write, so a refused edit leaves the Cookfile exactly
as it found it.

Their source, and the contract for adding another, is `src/verbs/README.md`.

## Development

```sh
luarocks install --local busted
cd cook_cc && busted .
```

or from the cook-modules root:

```sh
MODULE=cook_cc cook spec
```
