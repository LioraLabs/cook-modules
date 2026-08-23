# cook_rust

`cook_rust` turns one Cargo manifest into one portable Cook seal. Cargo remains
the build scheduler; the module only derives the determinants needed to share
the output of commands such as `wasm-pack build` safely.

```cook
use cook_rust

cook_rust.project("crates/web/Cargo.toml")

recipe wasm
    seal rust:project
    cook "packages/wasm/**" {
        wasm-pack build crates/web --out-dir packages/wasm
    }
```

`rust:project` includes every reachable local/path package under Cargo's
all-features graph, active ancestor and Cargo-home configuration, rustup
override files and environment, and the content identities of the PATH-selected
Cargo, configured compiler wrappers, and active toolchain's real `cargo` and
`rustc` binaries. Configuration
and environment values are represented only by hashes; credentials are never
serialized into the probe value.
Registry and git dependency source trees are not included. Local package directories are tracked conservatively, excluding
their `target/` and `.git/` directories.

Only one project may be registered per Cookfile. Build scripts that read
undeclared files outside reachable local packages must be sealed separately.
Local dependencies and active configuration outside the Cook workspace are
rejected with an actionable error because Cook cannot track those files safely.
