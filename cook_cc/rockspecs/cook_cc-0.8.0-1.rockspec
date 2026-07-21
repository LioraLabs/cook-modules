package = "cook_cc"
version = "0.8.0-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_cc-0.8.0-1",
}
description = {
   summary  = "Cook C-family (C + C++) native build module",
   detailed = [[
      Blessed Cook module for C and C++ native builds. Provides declarative
      target makers (cc.bin/lib/shared/headers) accepting a `needs` list for
      declarative system-library discovery, low-level primitives
      (cc.compile/archive/link), multi-strategy package discovery
      (cc.find with project / curated / pkg-config / cmake-compat / bare-probe stages),
      project-scoped finder registration (cc.register_finder), a raising
      find convenience (cc.find_or_error), transitive link propagation
      including macOS frameworks, and compile_commands.json generation.

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
     ["cook_cc"]                              = "cook_cc/init.lua",
     ["cook_cc.toolchain"]                    = "cook_cc/toolchain.lua",
     ["cook_cc.cc"]                           = "cook_cc/cc.lua",
     ["cook_cc.targets"]                      = "cook_cc/targets.lua",
     ["cook_cc.finder"]                       = "cook_cc/finder.lua",
     ["cook_cc.compile_db"]                   = "cook_cc/compile_db.lua",
     ["cook_cc.transitive"]                   = "cook_cc/transitive.lua",
     ["cook_cc.version"]                      = "cook_cc/version.lua",
     ["cook_cc._probe_helpers"]               = "cook_cc/_probe_helpers.lua",
     ["cook_cc._check_helpers"]               = "cook_cc/_check_helpers.lua",
     ["cook_cc.checks"]                       = "cook_cc/checks.lua",
     ["cook_cc.config_header"]                = "cook_cc/config_header.lua",
     ["cook_cc.config_header_renderer"]       = "cook_cc/config_header_renderer.lua",
     ["cook_cc.finders"]                      = "cook_cc/finders/init.lua",
     ["cook_cc.finders.pkg_config"]           = "cook_cc/finders/pkg_config.lua",
     ["cook_cc.finders.bare_probe"]           = "cook_cc/finders/bare_probe.lua",
     ["cook_cc.finders.cmake_compat"]         = "cook_cc/finders/cmake_compat.lua",
     ["cook_cc.finders.cmake_compat.hints"]   = "cook_cc/finders/cmake_compat/hints.lua",
     ["cook_cc.finders.header_probe"]         = "cook_cc/finders/header_probe.lua",
     ["cook_cc.finders.tool_config"]          = "cook_cc/finders/tool_config.lua",
     ["cook_cc.finders.raylib"]               = "cook_cc/finders/raylib.lua",
     ["cook_cc.finders.sdl2"]                 = "cook_cc/finders/sdl2.lua",
     ["cook_cc.finders.openal"]               = "cook_cc/finders/openal.lua",
     ["cook_cc.finders.gl"]                   = "cook_cc/finders/gl.lua",
     ["cook_cc.finders.threads"]              = "cook_cc/finders/threads.lua",
     ["cook_cc.finders.zlib"]                 = "cook_cc/finders/zlib.lua",
     ["cook_cc.finders.libcurl"]              = "cook_cc/finders/libcurl.lua",
   },
}
