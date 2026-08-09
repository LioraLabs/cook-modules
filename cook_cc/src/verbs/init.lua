-- cook_cc.verbs — the registry: every project-management chore cook_cc offers, registered in one place
-- domain:  verbs — project-management commands the module registers
-- phase:   register (chores can only be registered on the register-phase VM)
-- effects: cook.chore
-- std:     §22.12
--
-- Adding a verb is adding one line here and one file next to this one. The
-- registry exists so that `cook_cc/init.lua` has a single call to make and so
-- the phase guard below is written once rather than in each verb.
local M = {}

-- Registration order is the order `cook menu` will tend to show them in;
-- keep it the order a user meets them in, not alphabetical.
local VERBS = {
    "cook_cc.verbs.add",
    "cook_cc.verbs.link",
}

-- Register every verb, if this VM can hold chores.
--
-- MUST be called from cook_cc's own top-level chunk. §22.12 checks a chore's
-- namespace prefix against the identity of the module currently being
-- evaluated, and that identity is exact only while that chunk is running: a
-- call made later, from a function the module returned, is rejected outright.
--
-- The guard is not defensive style. `cook_cc` is loaded on the execute-phase
-- VM as well as the register-phase one, and the execute VM's `cook` table has
-- no `chore` (nor `cookfile`) — there are no chores to register there. Without
-- this early return, every execute-phase load of cook_cc dies on a nil call,
-- which is to say every build.
function M.register()
    if type(cook) ~= "table" or type(cook.chore) ~= "function" then return end
    for _, mod in ipairs(VERBS) do
        require(mod).register()
    end
end

return M
