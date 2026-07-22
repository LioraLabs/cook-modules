package = "cook_cc"
version = "0.17.0-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_cc-0.17.0-1",
}
description = {
   summary  = "Cook C-family (C + C++) native build module",
   detailed = [[
      0.17.0 (CS-0161) drops cook.require_recipe from the link-dependency
      path in favour of cook.dep_order. A target's `links` only ever needed
      require_recipe for its register-order guarantee — forcing each linked
      recipe's body so resolve_links can read its export. The whole-recipe
      ordering edge that came with it made every compile in the target queue
      behind the linked library's ARCHIVE, an artifact no compile reads, so
      C++ builds executed as sequential per-recipe waves. cook.import now
      forces the referent's body itself, so there is no declare_link_deps step
      at all: transitive.resolve_links walks each linked name, imports it, and
      the import forces. Unknown-recipe validation rides the same call.
      cc.archive / cc.link take a dep_recipes list and call cook.dep_order
      immediately before their own add_unit, so the ordering edge lands on that
      unit alone. Requires an engine where cook.import forces inside a recipe
      body and cook.dep_order records a per-unit edge. Compile commands
      and unit inputs are unchanged, so cache keys are unaffected and a
      settled tree stays fully cached across the upgrade. Measured on the
      dhewm3 dogfood repo (32 cores): renderer-wide header sweep 4.74s ->
      2.50s wall; full cold rebuild 17.5s -> 12.4s, CPU 1937% -> 2845%.

      0.16.0: remodels the source to a more disciplened DDD style

      0.15.2: registers the compile fan-out inside one cook.step_group.
      Bare cook.add_unit calls are sequential per Standard §15.1, so
      compile_all's per-source loop chained N compile units into a depth-N
      line and wide C++ builds compiled one TU at a time regardless of
      --jobs. One step group now wraps the loop (bin, lib, and shared all
      route through compile_all); the archive/link units registered
      afterwards stay bare, so the §15.1 barrier still orders
      all-compiles -> archive -> link. Unit inputs and commands are
      unchanged: cache keys are unaffected and a settled tree stays fully
      cached across the upgrade. Measured on the dhewm3 dogfood repo
      (32 cores): renderer-wide header sweep 33.6s -> 5.4s wall.

      0.15.1: adding join_path

      0.15.0 (CS-0158) seals real toolchain IDENTITY. The
      cc:compiler:<override-or-auto> probe value previously carried driver
      NAMES only ({ cxx = "g++", cc = "gcc" }) — a deliberate workaround for
      the engine folding resolved paths into tools-probe values (fixed
      engine-side by CS-0157). Names under-key: gcc 13 and gcc 14 produced
      IDENTICAL unit keys, so a compiler upgrade re-ran the probe but
      produced the same value and stale objects were reused, including from
      the shared store across machines with different compilers. The value
      now folds the CHOSEN drivers' canonical identities via the engine's
      cook.tools.id (content-hash of the resolved binary, never its path):
      { cxx, cc, cxx_id, cc_id }. Choice logic is unchanged; sealing units
      re-key once on upgrade to 0.15.0. Requires a cook release with
      cook.tools.id (CS-0158). Sharing semantics after the fix: two
      machines share compile artifacts exactly when toolchain BYTES match
      (containers, same distro, nix) — the honest condition.

      0.14.0 is a HARD BREAK: `cook_cc.compile_commands()` is now a TOP-LEVEL
      call (like `cc.uses`/`cc.toolchain`/`cc.config_header`); the recipe-body
      form is removed. It queues a run-once post-register finalizer via the
      engine's `cook.on_register_complete` hook (Standard §22.9, CS-0149; this
      module change is CS-0151) that snapshots the COMPLETE known-target set
      after every recipe body has registered and then writes
      `compile_commands.json` — complete by construction, including targets
      outside any single link closure (the disconnected-plugin case, e.g.
      dhewm3's base/d3xp, which the old dep-ordered recipe form silently
      dropped). Repeat top-level calls are idempotent (one finalizer, one write
      per registration pass). The DB is regenerated on every cook run's
      register phase. No support recipe is minted — there is nothing left for a
      `cook compile-commands` invocation to do. Calling it from inside a recipe
      body now raises `[cc.compile_commands] compile_commands() is a top-level
      call since 0.14.0; ...` loudly at register time. Migration for 0.13.x
      callers: delete the `recipe compile-commands : <target>` wrapper recipe
      (and its ordering dep) and hoist a bare `cook_cc.compile_commands()` call
      to top level. `modules` table: UNCHANGED (no new files).

      0.13.0 is a HARD BREAK: the target makers become STEP CONTRIBUTORS.
      cc.bin/lib/shared/headers now take a single `opts` table and drop the
      leading `name` parameter — the recipe identity comes from the enclosing
      user `recipe` block, so every maker call MUST run inside a `recipe`
      body (`recipe app \n cook_cc.bin({ sources = {...} })`) instead of
      minting its own recipe. Dependency discovery moves out of the maker
      too: `cook_cc.uses(...)` registers `cc:find:<name>` probes at
      top-level register phase, and a maker's `needs` list is now
      REFERENCE-ONLY — it wires sigils for probes already declared by
      `uses()` and errors loudly ("add cook_cc.uses(\"name\") at top level")
      if a referenced name was never declared. `cook_cc.config_header`
      moves out of `defaults` and becomes its own top-level call,
      `cook_cc.config_header({ from = ..., to = ..., vars = ... })`, which
      mints one origin-annotated (`origin = "cook_cc.config_header"`)
      support recipe per call instead of accumulating on the toolchain
      defaults object. Finally, `merge_requires` is deleted outright: link
      ordering between recipes is now declared explicitly with
      `cook.require_recipe`, and a link unit folds its dependency archives
      into its own inputs rather than relying on an implicit requires-merge
      helper. None of cc.compile/archive/link, cc.find/find_or_error/
      register_finder, or cc.checks.* change shape. Callers migrating from
      0.12.x must: (1) drop the `name` argument from every cc.bin/lib/
      shared/headers call and move each call inside its own `recipe NAME`
      block, (2) hoist every `needs` entry into a top-level `cc.uses(...)`
      call before the recipe that references it, (3) move any
      `defaults({ config_header = {...} })` entry to a standalone
      `cc.config_header({...})` call before the first cc target, and
      (4) replace any reliance on merge_requires link-ordering with an
      explicit `cook.require_recipe` declaration.

      0.12.0 migrates cook.cache.get -> cook.probes.get (v1.0 rename,
      CS-0136) and adopts the §12.7.5 seal policy: compile and link
      units seal their resolved, deterministic toolchain
      (cc:compiler:<override>) and finder (cc:find:<name>) determinants
      as explicit named-probe cache-key inputs, so the cross-machine
      cache keys on the resolved build identity rather than only the
      command text.

      Blessed Cook module for C and C++ native builds. Provides step-
      contributor target makers (cc.bin/lib/shared/headers), called inside a
      user `recipe` body and referencing a `needs` list of names declared
      up front via `cc.uses(...)` for system-library discovery, low-level primitives
      (cc.compile/archive/link), multi-strategy package discovery
      (cc.find with project / curated / pkg-config / cmake-compat / bare-probe stages),
      project-scoped finder registration (cc.register_finder), a raising
      find convenience (cc.find_or_error), transitive link propagation
      including macOS frameworks, and compile_commands.json generation.

      0.11.0 makes config_header a declarable property of the toolchain.
      Pre-0.11 callers wrote
            local cfg = cc.config_header(template, output, vars)
            cc.lib("foo", { sources = {...}, requires = { cfg } })
      and restated `requires = { cfg }` on every cc target whose sources
      could #include the generated header. With 0.11 the form is

            cc.defaults({
                defines  = { ... },
                includes = { ... },
                config_header = {
                    from = "config.h.in",
                    to   = "build/config.h",
                    vars = { ... },
                },
            })

      and every subsequent cc.bin/lib/shared/headers picks up the
      synthesised recipe as a transitive `requires` automatically.
      The output's directory is also auto-joined to defaults.includes,
      so consumers can `#include "config.h"` without restating the
      build dir on each target. Repeated `defaults({ config_header = ... })`
      calls accumulate (supports projects with version.h + config.h +
      buildinfo.h shapes). The pre-existing standalone
      `cc.config_header(template, output, vars)` returning a recipe
      name is unchanged for callers who still want an explicit handle.
      M.headers now uses merge_requires for parity with cc.bin/lib/shared
      (no observable change when defaults.config_header is unset).
      Locked by `spec/toolchain_config_header_spec.lua` and
      `spec/targets_implicit_config_header_spec.lua`. Forcing example:
      dhewm3-cook — the Cookfile carried one `local cfg = ...`
      binding plus nine `requires = { cfg }` repeats which all collapse
      to a single `config_header = { ... }` field in cc.defaults.

      0.10.2 fixes curated:libcurl with the same shape as 0.10.1's
      sdl2 fix. Pre-0.10.2 the libcurl finder called
      `curl-config --cflags --libs` and stuffed the combined output
      into `payload.libs`. On systems where curl-config --cflags is
      empty (Arch/Debian default), the combined output is `\n-lcurl\n`;
      after trailing-whitespace strip the libs field retained a LEADING
      newline. The sigil $<cc:find:libcurl.libs> then injected that
      newline into the link command, splitting it across /bin/sh -c
      lines and breaking the build. Forcing example: dhewm3-cook bring-up
      — the resulting link command had `\n-lcurl -lz` and bash
      tried to execute `-lcurl` as a command. The fix queries --cflags
      and --libs separately. Locked by `spec/finders/libcurl_spec.lua
      "0.10.2 follow-up"`. No surface change; pure bug fix.

      0.10.1 fixes curated:sdl2 cflags propagation. Pre-0.10.1 the
      finder called `sdl2-config --cflags --libs` in one shot and
      stuffed the combined output into `payload.libs`, leaving
      `payload.cflags = ""`. Downstream compiles that relied on the
      `$<cc:find:sdl2.cflags>` sigil (needs-driven include propagation,
      Standard §28.3.14) silently missed SDL2's include path. The fix
      queries `--cflags` and `--libs` separately and stores them split.
      Locked by `spec/finders/sdl2_spec.lua "CS-0084 follow-up"`.
      No surface change; pure bug fix.

      0.10.0 (CS-0084, surface v0.8) adds an optional `output` field to
      cc.shared. When present the implementation uses it verbatim as
      the shared-library link path and records it as the recipe's
      lib_path export, so transitive consumers see the actual artifact
      location. When absent, the default `build/lib/lib<name>.so`
      behaviour of v0.7 is unchanged. The forcing example is plugin
      shapes where the host runtime loads the library by a fixed
      filename and directory (e.g., the dhewm3 engine plugin layout
      `build/bin/base.so` consumed via `dlopen`). Authors
      targeting Windows MUST author `.dll`; macOS authors `.dylib` or
      `.so` as their loader expects. Implementation MUST NOT inject a
      `lib` prefix or replace the suffix when `output` is provided.

      0.9.0 (CS-0083 Phase 1) hoists cook.probe registration out of
      the cook.recipe deferred body in every target maker. After
      this change cc.bin/lib/shared/headers call
      toolchain.ensure_probe_registered() and register_needs(opts.needs)
      at top-level register-phase, BEFORE the cook.recipe(...)
      closure. Probes are now session-scoped facts registered before
      any recipe body runs, which lets sibling recipes consume
      cc:find:<n> via cook.add_unit({ probes = {...} }) without
      tripping the cross-recipe edge-wiring bug W13. No surface
      change — cc.bin/lib/shared/headers callers are unchanged.
      Phase 2 (a future cook release) will reject body-scope
      cook.probe outright; cook_cc 0.9.0-1 forward-compatible with
      that release.

      0.8.0 (CS-0080) introduces PRIVATE/PUBLIC propagation through
      links. Bare `defines`, `system_libs`, `frameworks`, and
      `extra_ldflags` on cc.bin/lib/shared/headers options now stay
      PRIVATE — used by the target itself, not propagated. The new
      `export_defines`, `export_system_libs`, `export_frameworks`,
      `export_extra_ldflags` fields are the explicit-public
      counterparts and propagate to consumers via cook.export.
      `export_includes` retains its existing fall-back to `includes`
      (the sole backcompat carve-out). Specified normatively at §28.4
      of the Cook Standard (surface v0.7).

      Migration: every Cookfile that puts bare `defines`/`system_libs`/
      `frameworks`/`extra_ldflags` on a cc.lib and expects consumers
      that `links =` it to inherit those values must rename the field
      to `export_*`. cc.bin's bare fields are unchanged in observable
      behavior because bins are end-of-chain (no downstream consumer).

      0.7.1 fixes a worker-VM crash exposed by 0.7.0 + the cook-engine
      probe-prune fix. The bare-probe and cmake-compat finder modules
      registered their upstream probes (`cc:linker-search-dirs` /
      `cc:cmake-driver`) at module top-level on require, which raised
      "register-only API called from execute-phase Lua" (Standard
      §22.5.2) when `cmake_strategy` / `bare_strategy` / curated finders
      re-required the modules from inside a probe produce body on the
      worker VM. Registration is now performed by explicit
      `ensure_probe_registered()` calls from
      `cook_cc.finder.register_find_probe` during the register phase;
      the modules' top-levels are side-effect-free.

      0.7.0 aligned the module with the unified register-phase model
      introduced by CS-0077 (SHI-222). Two breaking changes:

      1. cc.config_header now wraps its cook.add_unit in a synthesised
         cook.recipe("__cc_config_header__<safe>", ...) and returns the
         synthesised recipe name instead of the output path. The new
         register_cookfile pipeline keeps body_slot=None during top-level
         register-block execution, so cook.add_unit at top level errors
         "called outside a recipe body". Wrapping in cook.recipe mirrors
         every other target-maker in cc.targets and gives the caller a
         recipe name they can declare a `requires` against:

             local cfg = cc.config_header(template, output, vars)
             cc.bin("game", { sources = {...}, requires = { cfg } })

         Callers that previously used the return value as a file path
         must migrate.

      2. cc.bin/lib/shared accept a new `opts.requires` field that
         merges with `opts.links` to populate the recipe's `requires`
         set. `opts.links` continues to carry the cc-level link graph;
         `opts.requires` is the escape hatch for non-link dependencies
         (e.g. a synthetic recipe produced by cc.config_header whose
         output is a generated header on the include path). cc.headers
         also accepts `opts.requires` for symmetry; pre-0.7.0 it always
         received an empty `requires`.

      0.6.1 fixes a probe-key sigil-resolver collision: check probe
      names containing '.' (notably has_header("stdint.h")) were being
      mis-parsed as $<key.field> shape by the engine sigil resolver,
      which splits at the first '.' after the colon section. Names
      are now sanitised to [A-Za-z0-9_+-] (no dot) before embedding
      in probe keys. Applies to all seven cc.checks.* kinds.

      0.6.0 (CS-0076) adds the cc.checks.* feature-test namespace
      (has_header / has_function / has_define / sizeof / endian /
      has_compile_flag / has_link_flag) and cc.config_header for
      CMake-compatible @VAR@ / #cmakedefine / #cmakedefine01
      substitution. Both are layered on the cook.probe substrate
      introduced in 0.5.0 (CS-0075). Check probes use the key shape
      cc:check:<kind>:<name>:<short-fp>; the config_header renderer
      ships vendored alongside the module and is located at register
      time via package.searchpath.

      Specified normatively at §28 of the Cook Standard (v0.6) and
      §13.3 / §22.6 (v0.13, CS-0077) for the register-phase contract.
   ]],
   homepage   = "https://github.com/lioralabs/cook-modules",
   license    = "MIT",
   maintainer = "Liora Labs <code@lioralabs.dev>",
}
dependencies = {
   "lua >= 5.4",
   "lua-cjson ~> 2.1",
   "lpeg ~> 1.0",
}
build = {
   type    = "builtin",
   modules = {
     ["cook_cc"]                                      = "cook_cc/init.lua",
     ["cook_cc.codegen.compile_db"]                   = "cook_cc/src/codegen/compile_db.lua",
     ["cook_cc.codegen.config_header"]                = "cook_cc/src/codegen/config_header.lua",
     ["cook_cc.codegen.config_header_renderer"]       = "cook_cc/src/codegen/config_header_renderer.lua",
     ["cook_cc.discovery._check_helpers"]             = "cook_cc/src/discovery/_check_helpers.lua",
     ["cook_cc.discovery._probe_helpers"]             = "cook_cc/src/discovery/_probe_helpers.lua",
     ["cook_cc.discovery.checks"]                     = "cook_cc/src/discovery/checks.lua",
     ["cook_cc.discovery.finder"]                     = "cook_cc/src/discovery/finder.lua",
     ["cook_cc.discovery.finders.bare_probe"]         = "cook_cc/src/discovery/finders/bare_probe.lua",
     ["cook_cc.discovery.finders.cmake_compat"]       = "cook_cc/src/discovery/finders/cmake_compat.lua",
     ["cook_cc.discovery.finders.cmake_compat.hints"] = "cook_cc/src/discovery/finders/cmake_compat/hints.lua",
     ["cook_cc.discovery.finders.gl"]                 = "cook_cc/src/discovery/finders/gl.lua",
     ["cook_cc.discovery.finders.header_probe"]       = "cook_cc/src/discovery/finders/header_probe.lua",
     ["cook_cc.discovery.finders.init"]               = "cook_cc/src/discovery/finders/init.lua",
     ["cook_cc.discovery.finders.libcurl"]            = "cook_cc/src/discovery/finders/libcurl.lua",
     ["cook_cc.discovery.finders.openal"]             = "cook_cc/src/discovery/finders/openal.lua",
     ["cook_cc.discovery.finders.pkg_config"]         = "cook_cc/src/discovery/finders/pkg_config.lua",
     ["cook_cc.discovery.finders.raylib"]             = "cook_cc/src/discovery/finders/raylib.lua",
     ["cook_cc.discovery.finders.sdl2"]               = "cook_cc/src/discovery/finders/sdl2.lua",
     ["cook_cc.discovery.finders.threads"]            = "cook_cc/src/discovery/finders/threads.lua",
     ["cook_cc.discovery.finders.tool_config"]        = "cook_cc/src/discovery/finders/tool_config.lua",
     ["cook_cc.discovery.finders.zlib"]               = "cook_cc/src/discovery/finders/zlib.lua",
     ["cook_cc.toolchain.init"]                       = "cook_cc/src/toolchain/init.lua",
     ["cook_cc.toolchain.version"]                    = "cook_cc/src/toolchain/version.lua",
     ["cook_cc.units.cc"]                             = "cook_cc/src/units/cc.lua",
     ["cook_cc.units.targets"]                        = "cook_cc/src/units/targets.lua",
     ["cook_cc.units.transitive"]                     = "cook_cc/src/units/transitive.lua",
   },
}
