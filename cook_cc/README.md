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

recipe app
    cook_cc.bin({ sources = { "src/main.cpp" }, needs = { "sdl2" } })
```

`toolchain()`, `uses()`, and `config_header()` are top-level calls made
before any recipe. `uses(...)` registers `cc:find:*` probes that a maker's
`needs` list can then reference by name; makers themselves are step
contributors — they take no `name` parameter and must run inside a
`recipe` body, which supplies the recipe identity.

## Development

```sh
luarocks install --local busted
cd cook_cc && busted .
```

or from the cook-modules root:

```sh
MODULE=cook_cc cook spec
```
