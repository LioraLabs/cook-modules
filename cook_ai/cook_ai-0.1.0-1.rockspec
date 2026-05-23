package = "cook_ai"
version = "0.1.0-1"
source = {
   url = "git+https://github.com/lioralabs/cook-modules.git",
   tag = "cook_ai-0.1.0-1",
}
description = {
   summary  = "Cook blessed module: prompt-driven LLM target maker",
   detailed = [[
cook_ai 0.1 ships a single primitive — `cook_ai.prompt({...})` — that fans out
one cache-aware `cook.add_unit` per matched input. Provider config goes through
`cook_ai.provider({...})`. The same primitive serves translation,
summarisation, classification, and structured extraction by varying the
`system` prompt and `response_format` field; cook_ai does not ship named
target makers for each task.

This v0.1 supports the Anthropic provider only. Provider plumbing is laid out
so v0.2 can add OpenAI / Gemini / Bedrock without changing the
`cook_ai.prompt` surface. Streaming, embeddings, and the Anthropic batched
API are deferred to v0.2.

Cache key on each emitted unit is the hash of (input file content + resolved
system prompt + resolved user message + model id + response_format). Bumping
the configured model invalidates every consuming unit via the
`ai:provider:<provider>:<model>` probe value.
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
     ["cook_ai"]                       = "cook_ai/init.lua",
     ["cook_ai.state"]                 = "cook_ai/state.lua",
     ["cook_ai.provider"]              = "cook_ai/provider.lua",
     ["cook_ai.prompt"]                = "cook_ai/prompt.lua",
     ["cook_ai.cli"]                   = "cook_ai/cli.lua",
     ["cook_ai.client.anthropic"]      = "cook_ai/client/anthropic.lua",
     ["cook_ai.probes.model"]          = "cook_ai/probes/model.lua",
   },
   install = {
     bin = {
       cook_ai_call = "cook_ai/bin/cook_ai_call.lua",
     },
   },
}
