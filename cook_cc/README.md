# cook_cc

Cook C-family (C + C++) native build module. Provides declarative target
makers (`cc.bin` / `cc.lib` / `cc.shared` / `cc.headers`), low-level
primitives (`cc.compile` / `cc.archive` / `cc.link`), pkg-config discovery
(`cc.find`), transitive link propagation, and compile_commands.json
generation.

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
use cook_cc as cc

config
    cc.toolchain({ standard = "c++17", warnings = "strict" })

recipe app
    cc.bin("app", { sources = { "src/main.cpp" } })
```

## Development

```sh
luarocks install --local busted
cd cook_cc && busted .
```

or from the cook-modules root:

```sh
MODULE=cook_cc cook spec
```
