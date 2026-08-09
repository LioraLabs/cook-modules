-- cook_cc.verbs._report — the one message shape every cc.* verb speaks in
-- domain:  verbs — project-management commands the module registers
-- phase:   register (a verb body is register-phase Lua)
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
--
-- Nothing stops a verb calling `print` directly, so `registry_spec` fails the
-- suite if one does. A guard that only exists in prose is a guard four agents
-- will each discover the hard way.
M.emit = print

-- The verbs' shared vocabulary of actions, and the reason `did` can align a
-- column at all: the width is the longest word here, so adding an action is
-- adding a row and nothing else.
--
-- A closed list rather than a free string is the point. An unlisted action
-- would silently sit a character out of column, which is exactly the drift
-- this module exists to prevent, and it is a module-author mistake that this
-- module's own author should hear about rather than the user.
M.ACTIONS = { "created", "updated", "removed", "skipped", "ran" }

local ACTION_WIDTH = 0
local KNOWN_ACTION = {}
for _, a in ipairs(M.ACTIONS) do
    KNOWN_ACTION[a] = true
    if #a > ACTION_WIDTH then ACTION_WIDTH = #a end
end

-- Raise a user-facing diagnostic. Never returns.
--
-- `error(msg, 0)` deliberately: level 1 would prepend the Lua chunk and line
-- of THIS file, which names a file inside the installed module tree. That is
-- the module's source position, not the user's, and printing it invites them
-- to go and look at it. The verb name is the attribution that helps.
--
-- Only `fail` takes `verb`, because only `fail` says it. A `did` line names
-- the file it wrote and a `suggest` line names the command to run next; a
-- verb name in either would be noise, and the user already knows what they
-- typed. The asymmetry is the interface, not an oversight.
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
    if not KNOWN_ACTION[action] then
        error("cook_cc.verbs._report: unknown action '" .. tostring(action)
            .. "'; add it to report.ACTIONS so every verb's output stays in one column", 2)
    end
    M.emit(string.format("  %-" .. ACTION_WIDTH .. "s  %s", action, subject))
end

-- The command the user most likely wants next, after a blank line.
function M.suggest(command)
    M.emit("")
    M.emit("  try: cook " .. command)
end

-- A set of names as a diagnostic renders them: sorted, comma-separated.
--
-- Sorted because the input is usually a Lua table's keys, whose `pairs` order
-- differs between runs — a refusal that prints "accepted kinds: lib, bin" one
-- time and "bin, lib" the next is a diff in someone's terminal transcript for
-- no reason, in the module whose job is uniform output.
function M.list(items)
    local sorted = {}
    for _, item in ipairs(items) do sorted[#sorted + 1] = item end
    table.sort(sorted)
    return table.concat(sorted, ", ")
end

-- One line of "what the project now says", after the `did` lines and before
-- the `suggest`: `  game links += math, sound, util`.
--
-- `did` cannot carry it. A verb that edits a field INSIDE a module call has
-- only `updated  Cookfile` to point at, which is true and says nothing about
-- what changed in there — and the whole reason to echo is so the user does not
-- have to open the file to find out. Uncolumned on purpose: it is a sentence
-- about the project, not another row in the actions table.
function M.state(text)
    M.emit("  " .. text)
end

return M
