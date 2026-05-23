package = "cook_ai"
version = "0.2.0-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_ai-0.2.0-1",
}
description = {
   summary  = "Cook blessed module: prompt-driven LLM helper for recipe-embedded use",
   detailed = [[
cook_ai 0.2 — recipe-embedded `cook_ai.prompt({system, user, ...})` for use
inside `cook ... using >{}` blocks. cook_ai becomes a small Lua library
the user calls from inside a normal cook step; all structural work (input
globbing, output-path computation, per-ingredient fan-out, cache-key
participation) lives in the cook recipe DSL.

This release pairs with the cook-lang `cook (LUA_EXPR) using ...` feature
(Cook Standard §8.4.3) which makes per-ingredient output paths writable as
Lua expressions.

Surface (anthropic provider only in 0.2):

  cook_ai.provider({ provider, model, api_key, max_retries?, timeout_s?,
                     base_url? })  -- top-level, captures config + writes
                                       cook.env.COOK_AI_* for cache tracking
  cook_ai.prompt({ system, user, model?, max_tokens?, temperature?,
                   response_format?, tools? }) -> response_text
                                    -- execute-phase only, synchronous

Cache participation rides on cook's env-var auto-cache (Standard §17.1) +
the using-block body-text hash + ingredient content hashes. Bumping
`env.COOK_AI_MODEL` in a config block invalidates every cook_ai.prompt-
bearing unit.

Replaces cook_ai 0.1.0-1 / 0.1.0-2 (which stay published as exploratory
drafts; their surface — name=/inputs=/output=/user-callback — was found
to feel grafted-on rather than first-class in cook's recipe DSL).

Deferred to v0.3:
  - cook_ai.embed (separate primitive, vector output, different endpoint)
  - OpenAI / Gemini / Bedrock providers (plumbed; not implemented)
  - Anthropic Message Batches (batched-API cost win for cold builds)
  - Streaming responses
  - Cost telemetry / budgeting
]],
   homepage = "https://github.com/lioralabs/cook-modules",
   license  = "MIT",
}
dependencies = {
   "lua >= 5.4",
   "lua-cjson ~> 2.1",
}
build = {
   type = "builtin",
   modules = {
     ["cook_ai"]                  = "cook_ai/init.lua",
     ["cook_ai.state"]            = "cook_ai/state.lua",
     ["cook_ai.provider"]         = "cook_ai/provider.lua",
     ["cook_ai.prompt"]           = "cook_ai/prompt.lua",
     ["cook_ai.client.anthropic"] = "cook_ai/client/anthropic.lua",
   },
   -- No bin install in 0.2: cook_ai.prompt runs in-process during the
   -- using-block's execute-phase Lua, not via a shelled-out script.
}
