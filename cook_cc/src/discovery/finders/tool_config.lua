-- cook_cc.discovery.finders.tool_config — runs <tool>-config style commands via cook.sh and returns trimmed stdout
-- domain:  discovery — registers probes (dependency finders, feature checks); facts in, no work units
-- effects: pure
local M = {}

-- Runs `<tool> <args>` via cook.sh; returns trimmed stdout on success, nil on error.
function M.try(tool, args)
    local cmd = tool .. " " .. args
    local ok, out = pcall(cook.sh, cmd)
    if not ok then return nil end
    return (out or ""):gsub("%s+$", "")
end

return M
