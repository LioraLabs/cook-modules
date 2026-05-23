local M = {}

-- Registers (idempotently) a probe-value `ai:provider:<provider>:<model>` that
-- resolves to the model id. Cook re-hashes consumers whenever the probe value
-- changes, so bumping the configured model invalidates every downstream unit.
function M.register(provider_name, model)
    local key = "ai:provider:" .. provider_name .. ":" .. model
    cook.probe(key, {
        inputs = {
            env = { "COOK_AI_MODEL_SCHEMA_VERSION" },
        },
        produce = function()
            return {
                value = model,
                schema_version = os.getenv("COOK_AI_MODEL_SCHEMA_VERSION") or "1",
            }
        end,
    })
    return key
end

return M
