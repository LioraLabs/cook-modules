-- cook_cc.verbs._report — the one message shape every cc.* verb speaks in
-- domain:  verbs — project-management commands the module registers
-- effects: writes to stdout; raises
-- std:     §22.12
--
-- Five verbs written by five authors will otherwise invent five diagnostic
-- shapes, and a user who has just learned to read one of them gets no help
-- from the other four. Everything a verb says to a human goes through here.
local M = {}

-- The sink. `print` in production; a spec replaces it to capture output.
-- Assigned rather than called through a wrapper so that replacing it is the
-- whole of the test seam — there is nothing else to arrange.
M.emit = print

-- Raise a user-facing diagnostic. Never returns.
--
-- `error(msg, 0)` deliberately: level 1 would prepend the Lua chunk and line
-- of THIS file, which names a file inside the installed module tree. That is
-- the module's source position, not the user's, and printing it invites them
-- to go and look at it. The verb name is the attribution that helps.
function M.fail(verb, message, hint)
    local text = verb .. ": " .. message
    if hint then
        text = text .. "\n  " .. hint
    end
    error(text, 0)
end

-- One line of "what I just did": `  created  src/math/math.cpp`.
--
-- The action column is fixed-width so a run of them reads as a column of
-- actions and a column of subjects rather than as ragged prose.
function M.did(action, subject)
    M.emit(string.format("  %-7s  %s", action, subject))
end

-- The command the user most likely wants next, after a blank line.
function M.suggest(command)
    M.emit("")
    M.emit("  try: cook " .. command)
end

return M
