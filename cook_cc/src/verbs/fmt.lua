-- cook_cc.verbs.fmt — `cook cc.fmt`: run clang-format in place over the project's C++ sources
-- domain:  verbs — project-management commands the module registers
-- phase:   register (a verb body is register-phase Lua)
-- effects: cook.chore; runs clang-format, which rewrites source files
-- std:     §22.12, §7.6, §24.1
local report = require("cook_cc.verbs._report")

local VERB = "cc.fmt"

-- Where a C or C++ project keeps the sources a person edits. Not a guess at
-- every layout: a sweep that walked the whole tree would reach build outputs
-- and whatever vendored trees the project keeps beside them. Adding a row is
-- how a project with another convention gets swept; a vendored tree INSIDE one
-- of these is clang-format's own `.clang-format-ignore` to exclude, not this
-- table's, because that file excludes it from every clang-format the project
-- runs and not just from this one.
local DIRS = { "src", "include", "tests" }

-- The two spellings clang-format accepts for a style declaration. Both are
-- checked, because refusing the second would be this verb inventing a rule the
-- tool it drives does not have.
local STYLE_FILES = { ".clang-format", "_clang-format" }

-- The four the `dir` shorthand compiles (§28.3.1's BinOpts table), plus the two
-- kinds of file that never reach a compile command on their own and are exactly
-- the ones a formatter must not skip: headers, and module interface units.
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

-- The clang-format the user means, as `command -v` reports it — an absolute
-- path for anything found on PATH, and whatever was asked for otherwise.
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

-- The swept directories as a diagnostic names them, in the order they are
-- searched. `report.list` sorts, which is right for a set of accepted values
-- and wrong here: this is an itinerary, and reading it back in DIRS order is
-- what lets someone check it against their own layout.
local function dirs_phrase()
    local out = {}
    for _, dir in ipairs(DIRS) do out[#out + 1] = dir .. "/" end
    return table.concat(out, ", ")
end

-- Every source the sweep covers, workspace-absolute and sorted, and which of
-- DIRS actually contributed one.
--
-- One `fs.glob` call per directory over that directory's eight patterns
-- (CS-0079 concatenates the per-pattern blocks in argument order), rather than
-- one call over all twenty-four: the per-directory answer is what lets the
-- success line name the directories the run formatted instead of the ones it
-- looked in, and a header-only library being told about a `tests/` it does not
-- have is the verb describing its own table rather than the user's project. A
-- directory that is not there contributes an empty block rather than an error
-- (§25.8), which is what makes that case ordinary.
--
-- Sorted because the command string is composed from this order, and an
-- unsorted set makes the same project's run differ between machines that
-- differ only in filesystem layout. Not deduplicated: the twenty-four patterns
-- are pairwise disjoint (distinct top-level directory, distinct extension, and
-- the glob is case-sensitive), so a repeat needs a symlink loop, and
-- clang-format is idempotent over one anyway.
local function sources()
    local found, swept = {}, {}
    for _, dir in ipairs(DIRS) do
        local patterns = {}
        for _, ext in ipairs(EXTS) do
            patterns[#patterns + 1] = dir .. "/**/*." .. ext
        end
        local hits = fs.glob(patterns)
        if #hits > 0 then swept[#swept + 1] = dir .. "/" end
        for _, hit in ipairs(hits) do found[#found + 1] = hit end
    end
    table.sort(found)
    return found, swept
end

-- The style declaration this project makes, or nil.
--
-- Checked before anything runs, because "no declaration" is the destructive
-- case rather than a quiet one: `-style=file` with nothing to find falls back
-- to LLVM's defaults, so an existing project that never opted into clang-format
-- would have its whole tree reflowed to a style nobody chose, successfully and
-- silently. This verb formats to the style a project declares; it does not pick
-- one for it.
--
-- Only the project's own root is checked, and clang-format searches parent
-- directories too, so a workspace nested under a repository-wide config is
-- refused here even though the tool would have found one. That is deliberate:
-- reading files above the project root is what the sandbox exists to prevent
-- (§25.10), and re-implementing the tool's upward search would be a second
-- opinion about it. The refusal names the one-line file that says "inherit",
-- which is the project declaring the same thing explicitly.
local function style()
    for _, name in ipairs(STYLE_FILES) do
        if fs.exists(name) then return name end
    end
    return nil
end

-- The body. Separated from `register` so it is reachable from a spec without a
-- dispatch.
function M.run()
    -- Every refusal happens before the first file is rewritten, and in the
    -- order a person would ask the questions: can I run the tool, is there
    -- anything to run it over, and do I know what to format it to.
    local clang_format = binary()
    local files, swept = sources()
    if #files == 0 then
        -- Sweeping nothing and reporting success is the failure this catches: a
        -- project whose sources live somewhere else would get a run that
        -- formatted no file and said nothing to suggest it had not.
        report.fail(VERB, "no C or C++ sources found under " .. dirs_phrase(),
            "cc.fmt formats what a project keeps in those directories; move the sources there, "
            .. "or format the others yourself with " .. clang_format)
    end
    if not style() then
        report.fail(VERB, "no .clang-format in this project",
            "cc.fmt formats to the style a project declares and will not pick one for it; write one with "
            .. "`" .. clang_format .. " --style=llvm --dump-config > .clang-format`, "
            .. "or a single line `BasedOnStyle: InheritParentConfig` to take a repository-wide one")
    end

    -- `-fallback-style=none` is the guarantee behind `-style=file`: with no
    -- style found, clang-format leaves every file exactly as it was instead of
    -- reflowing it to LLVM's defaults. The refusal above means a sweep should
    -- never reach that state — this is what makes "never a style nobody chose"
    -- a property of the command rather than of the check in front of it.
    local prefix = quoted(clang_format) .. " -style=file -fallback-style=none -i"
    local suffix = " 2>&1 || echo " .. FAILED
    -- Both ends of the composed command count against the budget, so the
    -- accounting starts at what a batch costs before its first path.
    local overhead = #prefix + #suffix
    local batch, size = {}, overhead
    local function flush()
        if #batch == 0 then return end
        local ok, out = pcall(cook.sh, prefix .. " " .. table.concat(batch, " ") .. suffix)
        out = ok and (out or "") or nil
        if out and not out:find(FAILED, 1, true) then
            -- Anything it said while succeeding. §24.1 (CS-0188) makes the
            -- engine attribute a command's stderr to the unit that ran it, and
            -- folding stderr into stdout takes that job over — so dropping this
            -- would re-introduce the vanished-warnings bug that section was
            -- written to fix, in the one place the user cannot see around it.
            for line in out:gmatch("([^\n]+)") do report.emit(line) end
            batch, size = {}, overhead
            return
        end
        -- A raise here is the engine's or the shell's rather than the
        -- formatter's, since the composed command cannot exit non-zero; either
        -- way, re-raising it verbatim would put every path in the batch into
        -- the diagnostic. What is owed is the attribution and clang-format's
        -- own first line, which is the one that names the file and the column.
        local detail
        if out then
            for line in out:gmatch("([^\n]+)") do
                if line ~= FAILED then detail = line; break end
            end
        end
        report.fail(VERB, "clang-format failed",
            detail or "a malformed .clang-format is the usual cause")
    end
    for _, file in ipairs(files) do
        local argument = quoted(file)
        -- A batch of one is sent whatever it costs: a single path longer than
        -- the budget cannot be split, and refusing it here would be this verb
        -- declining to format a file for a reason of its own.
        if #batch > 0 and size + 1 + #argument > BATCH_BYTES then flush() end
        batch[#batch + 1] = argument
        size = size + 1 + #argument
    end
    flush()

    report.did("ran", ("clang-format over %d %s in %s")
        :format(#files, #files == 1 and "file" or "files", table.concat(swept, ", ")))
    -- No `suggest`. Every other verb ends with the command that makes sense
    -- next, and nothing follows from "your sources are formatted": the user was
    -- mid-something before they typed this, and a made-up target name would be
    -- noise in the one place this module reserves for guidance.
end

-- §22.12: called during cook_cc's own chunk evaluation, never later.
--
-- It takes no parameters, and §7.6 (CS-0218) is what makes that safe: a chore
-- body is invoked only when the chore is the register pass's dispatch target or
-- is reachable from one, so a formatter that takes no arguments still cannot run
-- during a build of something else. This verb was that rule's motivating
-- example. An optional trailing path could be added later without breaking a
-- single existing invocation, which is the reason it is not here now: the
-- reversible choice is the smaller one.
function M.register()
    cook.chore(VERB, {
        origin = "cook_cc.verbs.fmt",
        __params = {},
    }, function()
        M.run()
    end)
end

return M
