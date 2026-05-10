# cook_smoke

Phase 3 acceptance fixture for SHI-176. Published to `rocks.usecook.com`
so cook's modules-install pipeline has a real rock to exercise end-to-end.

This rock is **not stable**. It exposes one function (`cook_smoke.value()`
returns 42) and exists solely to validate that:

- `cook modules install cook_smoke` resolves against `rocks.usecook.com`.
- The resulting `cook_modules/share/lua/5.4/cook_smoke.lua` loads via
  the §7 (CS-0062) runtime resolution.
- `cook.lock` round-trips with `cook_smoke` pinned at the published version.

Do not import `cook_smoke` from a real Cookfile. It will be deleted or
rewritten without notice.

## Publishing

From the repo root:

```sh
git tag cook_smoke-0.1.0-1
git push origin cook_smoke-0.1.0-1
cook --set MODULE=cook_smoke pack
cook --set MODULE=cook_smoke publish-to-index
# then cd ~/dev/cook-rocks && cook publish
```
