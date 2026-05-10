# cook_ai

**Stub rock for the cook AI/LLM module.** Real implementation tracked in [SHI-192](https://linear.app/shiny-guru/issue/SHI-192).

This rock currently exposes only `cook_ai.placeholder()`, which raises an error pointing at the real-implementation ticket. It exists to reserve the `cook_ai` name on `rocks.usecook.com` and to exercise the publish pipeline at multi-rock scale (SHI-176 Phase 4).

When SHI-192 ships, replace this directory's contents with the real implementation and bump the rock version to `0.1.0-1` (or higher). The Gitea Actions publish CI on tag push handles the rest.
