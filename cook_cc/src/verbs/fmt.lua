-- cook_cc.verbs.fmt — `cook cc.fmt`: run clang-format in place over the project's C++ sources
-- domain:  verbs — project-management commands the module registers
-- phase:   register (a verb body is register-phase Lua)
-- effects: cook.chore; runs clang-format, which rewrites source files
-- std:     §22.12, §7.6, §24.1
local report = require("cook_cc.verbs._report")

local VERB = "cc.fmt"

-- Where a C or C++ project keeps the sources a person edits. Not a guess at
-- every layout: a sweep that walked the whole tree would reformat vendored
-- third-party sources and generated code, which is worse than missing a
-- directory. Adding a row is how a project with another convention gets swept.
local DIRS = { "src", "include", "tests" }

-- The four the `dir` shorthand compiles (§28.3.1.1), plus the two kinds of file
-- that never reach a compile command on their own and are exactly the ones a
-- formatter must not skip: headers, and module interface units.
local EXTS = { "c", "cc", "cpp", "cxx", "h", "hpp", "cppm", "ixx" }

-- How many bytes of command line one clang-format invocation may compose.
--
-- A whole-project sweep is the case this verb exists for, and a large project's
-- paths add up: `ARG_MAX` is around 2 MiB on Linux and 256 KiB on macOS, and
-- the failure when it is exceeded is `argument list too long` from the shell —
-- a message about the verb's plumbing rather than about the user's project.
-- A quarter of the smaller limit leaves room for the environment, which counts
-- against the same budget.
local BATCH_BYTES = 64 * 1024

-- Marks a batch that clang-format refused, on the batch's own output.
--
-- The alternative is to let the non-zero exit raise: `cook.sh` reports one as a
-- Lua error (§24.1), but the output it captured travels inside that error in
-- the engine's own transport encoding, which §24.1 (CS-0215) is explicit is not
-- something to read — it is the implementation's private format, and a module
-- that parsed it would be reading a channel the Standard reserves the right to
-- change. Folding stderr into stdout and swallowing the status brings the same
-- words back through the documented channel instead: the return value.
--
-- What that buys is the difference between "clang-format failed" and
-- ".clang-format:2:18: error: Could not find closing ]!" — a refusal the user
-- can act on without going and reproducing the run by hand.
local FAILED = "__cc_fmt_failed__"

local M = {}

-- One shell argument. Single quotes suppress every expansion sh performs, so
-- the only character needing care is the single quote itself: close, escape,
-- reopen. Paths here come from `fs.glob` and are whatever the user named their
-- directories.
local function quoted(argument)
    return "'" .. argument:gsub("'", "'\\''") .. "'"
end

-- The clang-format the user means, as an absolute path.
--
-- `CLANG_FORMAT` is read by the shell rather than by Lua: `cook.sh` runs under
-- `/bin/sh` with the ambient environment (§24.1), and a distribution that
-- installs `clang-format-18` and no unsuffixed alias is common enough that the
-- alternative is telling that user to symlink something.
--
-- Resolved once, and the resolved path is what runs: the diagnostic then names
-- the binary that actually formatted the sources, and a `PATH` that changes
-- mid-sweep cannot change formatter mid-sweep.
local function binary()
    local ok, out = pcall(cook.sh, 'command -v "${CLANG_FORMAT:-clang-format}" 2>/dev/null')
    local found = ok and out and out:match("^%s*(.-)%s*$") or ""
    if found == "" then
        report.fail(VERB, "clang-format is not on PATH",
            "install it (apt install clang-format, brew install clang-format, pacman -S clang), "
            .. "or set CLANG_FORMAT to the binary you want — a versioned clang-format-18, say")
    end
    return found
end

-- Every source the sweep covers, workspace-absolute and sorted.
--
-- One `fs.glob` call over every pattern (CS-0079), not one per directory: the
-- engine concatenates the per-pattern blocks in argument order, and a directory
-- the project does not have contributes an empty block rather than an error
-- (§25.8), which is what lets a header-only library with no `tests/` sweep
-- cleanly.
--
-- Sorted because the command string is composed from this order, and an
-- unsorted set makes the same project's run differ between machines that
-- differ only in filesystem layout.
-- The swept directories as a diagnostic names them, in the order they are
-- searched. `report.list` sorts, which is right for a set of accepted values
-- and wrong here: this is an itinerary, and reading it back in DIRS order is
-- what lets someone check it against their own layout.
local function dirs_phrase()
    local out = {}
    for _, dir in ipairs(DIRS) do out[#out + 1] = dir .. "/" end
    return table.concat(out, ", ")
end

local function sources()
    local patterns = {}
    for _, dir in ipairs(DIRS) do
        for _, ext in ipairs(EXTS) do
            patterns[#patterns + 1] = dir .. "/**/*." .. ext
        end
    end
    local found = fs.glob(patterns)
    table.sort(found)
    return found
end

-- The body. Separated from `register` so it is reachable from a spec without a
-- dispatch.
function M.run()
    local clang_format = binary()
    local files = sources()
    if #files == 0 then
        -- Sweeping nothing and reporting success is the failure this catches: a
        -- project whose sources live somewhere else would get a run that
        -- formatted no file and said nothing to suggest it had not.
        report.fail(VERB, "no C or C++ sources found under " .. dirs_phrase(),
            "cc.fmt formats what a project keeps in those directories; move the sources there, "
            .. "or format the others yourself with " .. clang_format)
    end

    local prefix = quoted(clang_format) .. " -style=file -i"
    local batch, size = {}, #prefix
    local function flush()
        if #batch == 0 then return end
        local ok, out = pcall(cook.sh,
            prefix .. " " .. table.concat(batch, " ") .. " 2>&1 || echo " .. FAILED)
        if ok and not out:find(FAILED, 1, true) then
            batch, size = {}, #prefix
            return
        end
        -- A raise here is the engine's or the shell's rather than the
        -- formatter's, since the composed command cannot exit non-zero; either
        -- way, re-raising it verbatim would put every path in the batch into
        -- the diagnostic. What is owed is the attribution and clang-format's
        -- own first line, which is the one that names the file and the column.
        local detail
        if ok then
            for line in out:gmatch("([^\n]*)") do
                if line ~= "" and line ~= FAILED then detail = line; break end
            end
        end
        report.fail(VERB, "clang-format failed",
            detail or "a malformed .clang-format is the usual cause")
    end
    for _, file in ipairs(files) do
        local argument = quoted(file)
        if #batch > 0 and size + 1 + #argument > BATCH_BYTES then flush() end
        batch[#batch + 1] = argument
        size = size + 1 + #argument
    end
    flush()

    report.did("ran", ("clang-format over %d %s in %s")
        :format(#files, #files == 1 and "file" or "files", dirs_phrase()))
    -- No `suggest`. Every other verb ends with the command that makes sense
    -- next, and nothing follows from "your sources are formatted": the user was
    -- mid-something before they typed this, and a made-up target name would be
    -- noise in the one place this module reserves for guidance.
end

-- §22.12: called during cook_cc's own chunk evaluation, never later.
--
-- No parameters, which §7.6 (CS-0218) is what makes safe: a chore body is
-- invoked only when the chore is the register pass's dispatch target or is
-- reachable from one, so a paramless formatter cannot run during a build of
-- something else. Before that rule this verb was the motivating example of why
-- it had to exist.
function M.register()
    cook.chore(VERB, {
        origin = "cook_cc.verbs.fmt",
        __params = {},
    }, function()
        M.run()
    end)
end

return M
