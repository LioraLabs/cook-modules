---
name: publishing-cook-modules
description: Use when publishing or republishing a Cook blessed module (cook_cc, cook_smoke, cook_cpp, cook_rust, cook_pnpm, cook_ai, etc.) to rocks.usecook.com, when adding a new rockspec revision to any cook-modules subdir, or when bumping downstream `cook.toml` pins for a consumer (cook OSS examples, dhewm3-cook) after a module revision lands.
---

# Publishing Cook blessed modules

## Overview

A blessed Cook module (cook_cc, cook_smoke, …) is a Lua rock published to `https://rocks.usecook.com`. The publish pipeline spans three locations:

| Where | What | Remotes |
|---|---|---|
| `~/dev/cook-modules` | Source-of-truth monorepo. One subdir per module. **The `cook publish` chore lives here.** | `origin` = Gitea NAS, `github` = LioraLabs/cook-modules |
| `~/dev/cook-rocks` | Rendered static rock index: `manifest-5.4`, `manifest`, `*.rockspec`, `*.src.rock`, `index.html` | `origin` = Gitea NAS, `github` = LioraLabs/cook-rocks-index |
| Cloudflare Pages | Serves the GitHub mirror of `cook-rocks-index` at `https://rocks.usecook.com` | — |

The Cookfile in `cook-modules` orchestrates a tag-and-push in repo 1 + manifest regen + commit + force-pushed orphan snapshot in repo 2. Cloudflare picks up the GitHub force-push automatically (~1 minute).

## When to use

- Bumping any blessed module to a new rockspec revision (e.g. `0.8.0-1 → 0.9.0-1`).
- Hot-patching a published module (e.g. `0.6.0-1 → 0.6.1-1`).
- Publishing a brand-new module subdir for the first time.
- Bumping downstream `cook.toml` pins in `~/dev/cook/examples/*/` or `~/dev/dhewm3-cook/` after a publish.

Do **not** use this for the Cook CLI release pipeline — that lives elsewhere (`cook release` chore in the cook OSS repo).

## Quick reference

```bash
# From ~/dev/cook-modules, after committing module changes + a new rockspec:
MODULE=cook_cc VERSION=0.9.0-1 cook publish

# Piecewise helpers if the full chore fails partway:
MODULE=cook_cc VERSION=0.9.0-1 cook pack              # just luarocks pack
MODULE=cook_cc VERSION=0.9.0-1 cook publish-to-index  # copy + make-manifest, no commit
cook spec                                              # busted .   (MODULE defaults to cook_cc)
```

Verify after publish (Cloudflare needs ~1 min):

```bash
curl -sf https://rocks.usecook.com/cook_cc-0.9.0-1.rockspec | head -3
curl -sf https://rocks.usecook.com/manifest-5.4 | grep '"0.9.0-1"'
curl -sfI https://rocks.usecook.com/cook_cc-0.9.0-1.src.rock | head -1   # HTTP/2 200
```

## End-to-end workflow

### 1. Edit the module source

Module sources live under `~/dev/cook-modules/<module>/`. For cook_cc that's a flat-ish Lua tree:

```
cook_cc/
  init.lua                 # require entry
  targets.lua              # cc.bin / lib / shared / headers
  cc.lua                   # cc.compile / archive / link
  finder.lua               # cc.find + strategy dispatch
  finders/*.lua            # per-name finders (gl, sdl2, openal, zlib, libcurl, …)
  toolchain.lua, transitive.lua, checks.lua, config_header.lua, …
  spec/*.lua               # busted specs + stub
  cook_cc-<X.Y.Z>-<R>.rockspec  # one per published revision
```

Edit whatever needs editing.

### 2. Run the spec suite

```bash
cd ~/dev/cook-modules/<module> && busted .
```

cook_cc's suite runs in ~140ms for 200+ tests. Add specs when you change behavior — `spec/cook_stub.lua` provides `cook.*` / `fs.*` / `path.*` globals so the module can be exercised without a running engine.

If the module has no `spec/` directory (cook_smoke, cook_ai, the four 0.0.x stub rocks), skip this step — they're sub-specced today and a `busted .` invocation will find nothing to run. The pre-publish smoke in step 3 is the next safety net.

### 3. Smoke-test against a real cook example BEFORE bumping the rockspec

Pre-publish there's nothing on `rocks.usecook.com` yet — swap your local sources into an installed `cook_modules/`:

```bash
cp -r ~/dev/cook-modules/cook_cc/* \
      ~/dev/cook/examples/cpp-project/cook_modules/share/lua/5.4/cook_cc/
cd ~/dev/cook/examples/cpp-project && rm -rf build .cook
cook build
```

(Pick a representative example — `cpp-project` exercises `cc.lib` + `cc.bin` + transitive includes + tests. `sdl3-game` adds external `cc.find` for SDL3.)

For modules without an obvious consumer in `~/dev/cook/examples/` (cook_smoke, cook_ai, stub rocks), skip this step or graft the module into the smallest example you trust. Note in the publish commit that pre-publish smoke was skipped so reviewers know.

If clean, restore the example:

```bash
cd ~/dev/cook/examples/cpp-project && rm -rf cook_modules && cook modules install
# (Fallback if `cook modules install` UX trips:)
luarocks install --tree cook_modules --server https://rocks.usecook.com cook_cc <old-version>
```

### 4. Create the new rockspec

Each version gets its own rockspec checked into the monorepo:

```bash
cd ~/dev/cook-modules/cook_cc
cp cook_cc-0.8.0-1.rockspec cook_cc-0.9.0-1.rockspec
```

Edit three things in the new file:

1. `version = "0.9.0-1"` (was `"0.8.0-1"`).
2. `source.tag = "cook_cc-0.9.0-1"` (the publish chore creates this tag in step 6).
3. `description.detailed` — prepend a paragraph for the new version (newest-first; previous entries stay below). Match the 6-space indent of the surrounding paragraphs and the blank-line inter-paragraph separator.

Do **not** touch `build.modules` unless you actually added/removed/renamed files. Sanity check:

```bash
diff <(sed -n '/^build = {/,/^}$/p' cook_cc-0.8.0-1.rockspec) \
     <(sed -n '/^build = {/,/^}$/p' cook_cc-0.9.0-1.rockspec)
# Expected: empty
```

Validate the rockspec parses:

```bash
luarocks lint cook_cc-0.9.0-1.rockspec
# Length warnings on description.detailed are cosmetic. Errors are real.
```

### 5. Commit in cook-modules

Suggested commit split (TDD shape — one commit per logical change is fine; collapsing into a single commit is also fine):

```
<sha>  <module>/spec: assert <new contract> (failing)    # if you wrote a failing spec first
<sha>  <module>: <the refactor / feature / fix>
<sha>  <module>: <X.Y.Z>-<R> rockspec
```

The publish chore doesn't care about commit shape — only that the tree is clean.

### 6. Pre-flight: both repos must be clean

```bash
cd ~/dev/cook-modules && git status --short
cd ~/dev/cook-rocks  && git status --short
```

Both must be empty. The chore doesn't have a hard pre-flight check — the failure mode is that `git push origin main` rejects a non-fast-forward push (if remote moved ahead of local) or `git commit` in cook-rocks runs against an unexpected staging set. Resolve any tracked-but-modified or staged files before running publish. Untracked-only files (`??` lines) are tolerated by the chore but worth a `gitignore` pass anyway.

### 7. Run `cook publish`

```bash
cd ~/dev/cook-modules
MODULE=cook_cc VERSION=0.9.0-1 cook publish
```

What the chore does, in order (read `~/dev/cook-modules/Cookfile` if you want to verify):

1. Asserts `cook_cc/cook_cc-0.9.0-1.rockspec` exists.
2. `git tag -a cook_cc-0.9.0-1 -m "cook_cc-0.9.0-1"` — annotated tag on HEAD.
3. `git push github main cook_cc-0.9.0-1` — pushes `main` + tag to the GitHub mirror **first**. Matters: `luarocks pack` resolves `source.url` against the public git URL, so the tag must be reachable there before packing.
4. `git push origin main cook_cc-0.9.0-1` — pushes to Gitea NAS too.
5. `luarocks pack cook_cc-0.9.0-1.rockspec` (from inside `cook_cc/`) — clones the tag from GitHub, tar+gzips, produces `cook_cc-0.9.0-1.src.rock`.
6. Copies the `.rockspec` + `.src.rock` into `~/dev/cook-rocks/`.
7. `luarocks-admin make-manifest .` in `~/dev/cook-rocks/` — regenerates `manifest`, `manifest-5.4`, `manifest-5.3` (etc.), AND `index.html`. The `mkdir ''` warnings on stderr are cosmetic.
8. Stages the regenerated manifests + the new `.rockspec` + `.src.rock` in `~/dev/cook-rocks/`.
9. `git commit -m "publish: cook_cc-0.9.0-1"`.
10. Invokes cook-rocks's *own* `cook publish` chore (defined in `~/dev/cook-rocks/Cookfile`) — pushes to Gitea (`origin`) and **force-pushes an orphan snapshot to GitHub** (`github`). The orphan snapshot is what Cloudflare Pages serves.

A successful run ends with two lines confirming the GitHub force-push:

```
+ 625fdf1...74ae445 74ae4450a0596a544d9ddbec91db4d89531cf99b -> main (forced update)
Pushed orphan snapshot 74ae4450 (tree of b36f252) to github/main
```

### 8. Verify

```bash
curl -sf https://rocks.usecook.com/cook_cc-0.9.0-1.rockspec | head -3
curl -sf https://rocks.usecook.com/manifest-5.4 | grep '"0.9.0-1"'
curl -sfI https://rocks.usecook.com/cook_cc-0.9.0-1.src.rock | head -1   # HTTP/2 200
```

If the rockspec returns 404, wait another 30s — Cloudflare Pages takes ~1 min to redeploy after the GitHub force-push. If the manifest doesn't list the new version, the publish to cook-rocks didn't land — check `git log ~/dev/cook-rocks/main`.

### 9. Bump downstream consumers

Once published, bump explicit pins. Find them:

```bash
grep -rl --include=cook.toml '<module>' ~/dev/cook ~/dev/dhewm3-cook 2>/dev/null
# e.g. for cook_cc:
grep -rl --include=cook.toml 'cook_cc' ~/dev/cook ~/dev/dhewm3-cook
```

Examples pinning `"*"` get the new version automatically on next `cook modules install` — refresh them anyway as a smoke test.

Refresh + smoke each consumer:

```bash
cd <consumer-dir> && rm -rf cook_modules cook.lock build .cook && cook modules install && cook <recipe>
```

Commit pin bumps + the refreshed `cook.lock` files in the consumer repo (one commit per repo).

## Piecewise debugging chores

If the full `cook publish` chore fails partway through, two helpers in `~/dev/cook-modules/Cookfile` let you bisect:

| Chore | What it does | Use when |
|---|---|---|
| `cook pack` | Just runs `luarocks pack <rockspec>` inside the module dir | The `.src.rock` build fails. Typically: tag not yet on GitHub, `source.dir` set incorrectly, or `source.url` unreachable. |
| `cook publish-to-index` | Copies `.rockspec` + `.src.rock` into `~/dev/cook-rocks/` + regenerates manifest, stops short of committing | You want to inspect the staged index before committing the rocks-index push. |
| `cook spec` | `busted .` in the module dir | Standalone spec run; `MODULE` defaults to `cook_cc`. |

All accept `MODULE=<name> VERSION=<x.y.z>-<r>` env-style.

## Common pitfalls

**Tag-before-pack.** The chore pushes `main` + tag to GitHub *before* running `luarocks pack` because pack clones the public URL at the tag. If GitHub mirror auth is broken, the chore fails at step 3 with a permission error, not at pack — investigate `liora.github.com` ssh access (the `liora.github.com` host alias in `~/.ssh/config` points at the LioraLabs PAT-authenticated identity).

**`source.dir` is a trap.** The rockspec uses `git+https://github.com/lioralabs/cook-modules.git` with `tag = "<module>-<version>"`. Do **not** set `source.dir = "<module>"`. luarocks resolves `source.dir` relative to the temp parent (where the clone goes), not the cloned repo root — `dir = "<module>"` fails with `unpack_archive: unrecognized filename extension`. Auto-detect picks `cook-modules` as `source.dir`; the full subpath goes in `build.modules`:

```lua
build = {
  type = "builtin",
  modules = {
    ["cook_cc"]           = "cook_cc/init.lua",
    ["cook_cc.toolchain"] = "cook_cc/toolchain.lua",
    -- …
  },
}
```

**Clean trees only.** Any uncommitted change in either `cook-modules` or `cook-rocks` aborts the chore. Make sure `compile_commands.json`, `build/`, `.cook/`, and stray `CMakeFiles/` are gitignored. The chore does NOT stash or recover — it fails loud.

**Don't `--no-verify` or `COOK_STANDARD_BYPASS=1`.** The publish chore doesn't currently run hooks, but if you're cherry-picking commits into the publish branch, respect any cook-standard pre-commit hook. Cook module changes don't trigger the spec-first hook (that's cook OSS), but other hooks may apply.

**Old cook binary.** The publish chore depends on `cook` features that the system `~/.cargo/bin/cook` may pre-date. If `cook publish` fails with something that looks like a parser error (`bad argument`, `unexpected token`, `unknown command`), rebuild: `cd ~/dev/cook && cargo install --path cli/crates/cook-cli --bin cook --force`.

**`luarocks lint` length warnings.** Cosmetic; the `description.detailed` block accumulates a lot of historical changelog text over time. Ignore length warnings. Take ERROR lines seriously.

**Two-commit cook-rocks publish.** When the chore invokes cook-rocks's `cook publish` (step 10), that chore pushes BOTH the Gitea `origin` push AND the GitHub orphan force-push. The Gitea push is normal; the GitHub orphan keeps the rock-index history flat (Cloudflare Pages serves a single tree, not a history-aware checkout). Don't try to `git push github main` directly in cook-rocks — that would push the full history and break the orphan snapshot pattern.

## Recovering from a bad publish

You cannot un-publish a rock revision — once `0.9.0-1` is at `rocks.usecook.com`, that URL stays addressable forever (or until you manually purge it from cook-rocks history, which breaks anyone who locked to it). Instead:

1. **Hot-patch.** Fix the bug, bump the rockrev (`0.9.0-1 → 0.9.0-2`), publish again. Consumers on `"*"` get the fix automatically; explicit pins need a manual bump. This is how `cook_cc 0.6.0-1 → 0.6.1-1` shipped the sigil-resolver collision fix.
2. **If the rock won't install at all** (truly broken `.src.rock`): delete the rockspec + `.src.rock` from `~/dev/cook-rocks/`, regen the manifest via `luarocks-admin make-manifest .`, commit, and re-run cook-rocks's `cook publish`. The Cloudflare snapshot will drop the bad version on the next force-push. Consumers that already cached the bad rock locally will still have it; bump them off.
3. **Tag in cook-modules is annotated and immutable** by convention. Don't `git tag -d` a published tag.

## Cross-references

- Canonical Cookfile: `~/dev/cook-modules/Cookfile`
- Reference Phase 1 publish: cook_cc 0.9.0-1 (commit `8e98110` in cook-modules; cook-rocks commit `b36f252`; orphan snapshot `74ae4450` on GitHub).
- Memory: `[[project_cook_module_publishing]]` — covers historical context (Phase 3 monorepo decision, bootstrap gotchas, CI history).
- Downstream consumer pattern: see the cook OSS examples' `cook.toml` files for the pin convention (`cook_cc = "X.Y.Z-R"` or `"*"`).
