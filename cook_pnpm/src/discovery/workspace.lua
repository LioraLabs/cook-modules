-- cook_pnpm.discovery.workspace — parses the pnpm workspace into a package graph and registers the install probe
-- domain:  discovery — registers probes (workspace facts, tool finders); facts in, no work units
-- effects: cook.probe (via discovery.probes.pnpm_install), fs.read / fs.glob / fs.exists
--
-- Workspace bootstrap.
--
-- `packages:` entries may be positive globs or `!`-prefixed EXCLUSIONS, and
-- both forms are honoured (0.7). pnpm applies exclusions to the fully
-- expanded directory set, so list order carries no meaning — `!examples/blog-*`
-- subtracts whether it appears before or after `examples/*`. Exclusions match
-- the root-relative package DIRECTORY, never the glob strings.
--
-- Getting this wrong was silent: entries were previously anchored as positive
-- patterns ("./!examples/blog-*/package.json"), which matches nothing, so the
-- exclusion never fired and cook minted `<pkg>:<task>` recipes for packages
-- pnpm does not consider part of the workspace — 40 of them on
-- refinedev/refine. The same `!`-corrupted-by-anchoring shape the 0.5 inputs
-- surface was hardened against; the difference is that here `!` is valid pnpm
-- syntax to honour, not to reject.
--
-- Parses pnpm-workspace.yaml, then per-package package.json files,
-- builds an in-memory graph keyed on package name, and registers the
-- toolchain + install probes.
--
-- The bootstrap result is cached on a per-VM state table so subsequent
-- pnpm.task / pnpm.run calls can read the graph without re-parsing.

local toolchain    = require("cook_pnpm.toolchain")
local pkg_json     = require("cook_pnpm.discovery.probes.package_json")
local install_prb  = require("cook_pnpm.discovery.probes.pnpm_install")
-- Cross-domain require: units.globs is pure path/glob infrastructure with no
-- domain allegiance (it registers nothing), and duplicating a glob matcher
-- here would be worse than the layering wrinkle. No cycle — globs requires
-- nothing.
local globs        = require("cook_pnpm.units.globs")

local M = {}

local state = {
    root_dir   = nil,
    packages   = nil,        -- list of WorkspaceInfo
    by_name    = nil,        -- name -> WorkspaceInfo
    install_key = nil,
}

local function read_workspace_yaml(path)
    if not fs.exists(path) then
        error("[pnpm.workspace] no pnpm-workspace.yaml at " .. path
              .. " — pnpm requires this file to declare workspaces.", 2)
    end
    local raw = fs.read(path)
    local packages = {}
    -- Minimal YAML: we accept the canonical pnpm shape, a top-level
    -- `packages:` list of glob strings. Anything more exotic (anchors,
    -- multi-key documents) is out of scope for the rough draft; pnpm
    -- itself only uses this shape in practice.
    local in_packages = false
    for line in raw:gmatch("[^\r\n]+") do
        if line:match("^packages%s*:") then
            in_packages = true
        elseif in_packages then
            local g = line:match("^%s*%-%s*[\"']?([^\"'#]+)[\"']?%s*$")
            if g then
                g = g:gsub("%s+$", "")
                if g ~= "" then packages[#packages + 1] = g end
            elseif line:match("^%S") then
                in_packages = false
            end
        end
    end
    if #packages == 0 then
        error("[pnpm.workspace] pnpm-workspace.yaml at " .. path
              .. " declares no `packages:` globs.", 2)
    end
    return packages
end

-- Split a pnpm `packages:` list into positive globs and `!` exclusions.
-- pnpm applies exclusions to the whole expanded set regardless of where they
-- appear in the list, so order carries no meaning here.
local function partition(entries)
    local includes, excludes = {}, {}
    for _, g in ipairs(entries) do
        if g:sub(1, 1) == "!" then
            excludes[#excludes + 1] = g:sub(2)
        else
            includes[#includes + 1] = g
        end
    end
    return includes, excludes
end

-- Expand the positive globs to package directories, then SUBTRACT anything
-- matching an exclusion. Exclusions are directory patterns relative to the
-- workspace root (`examples/blog-*`, `documentation`), matched against the
-- root-relative form of each matched dir — not against the glob strings.
-- Returns the surviving dirs plus how many matched BEFORE subtraction, so
-- the caller can tell "globs matched nothing" from "exclusions ate
-- everything".
local function expand_globs(includes, excludes, root)
    local pats = {}
    for _, g in ipairs(excludes) do
        pats[#pats + 1] = globs.glob_to_pattern(g)
    end
    local function excluded(dir)
        local rel = globs.workdir_rel(dir, root)
        for _, p in ipairs(pats) do
            if rel:match(p) then return true end
        end
        return false
    end

    local dirs, matched = {}, 0
    for _, g in ipairs(includes) do
        local pattern = root .. "/" .. g .. "/package.json"
        for _, m in ipairs(fs.glob(pattern)) do
            local dir = m:match("^(.+)/package.json$")
            if dir then
                matched = matched + 1
                if not excluded(dir) then dirs[#dirs + 1] = dir end
            end
        end
    end
    table.sort(dirs)
    return dirs, matched
end

local function topo_sort(packages, by_name)
    -- Standard DFS-based topological sort. Cycle detection raises with
    -- the offending package chain so users can find the loop fast.
    local order, visiting, visited = {}, {}, {}
    local function visit(node, chain)
        if visited[node.name] then return end
        if visiting[node.name] then
            error("[pnpm.workspace] dependency cycle detected: "
                  .. table.concat(chain, " -> ") .. " -> " .. node.name, 3)
        end
        visiting[node.name] = true
        for _, dep_name in ipairs(node.workspace_deps) do
            local dep = by_name[dep_name]
            if dep then
                chain[#chain + 1] = node.name
                visit(dep, chain)
                chain[#chain] = nil
            end
        end
        visiting[node.name] = nil
        visited[node.name] = true
        order[#order + 1] = node
    end
    for _, p in ipairs(packages) do visit(p, {}) end
    return order
end

local function collect_workspace_deps(pkg, by_name)
    local deps = {}
    for _, src in ipairs({ "dependencies", "devDependencies", "peerDependencies" }) do
        for dep_name in pairs(pkg[src]) do
            if by_name[dep_name] then deps[#deps + 1] = dep_name end
        end
    end
    return deps
end

function M.bootstrap(opts)
    opts = opts or {}
    local root = opts.root or "."

    if opts.node then toolchain.set({ node = opts.node }) end
    if opts.pm   then toolchain.set({ pm   = opts.pm   }) end

    local entries
    if type(opts.packages) == "table" then
        entries = opts.packages
    elseif not fs.exists(root .. "/pnpm-workspace.yaml")
           and fs.exists(root .. "/package.json") then
        -- Single-package repo (0.8): pnpm without a pnpm-workspace.yaml is
        -- a workspace of ONE — the root package.json. The `solo` flag on
        -- the entry propagates to naming (unprefixed recipe names: `build`,
        -- not `<pkg>:build`) and commands (no `--filter <pkg>`, which has
        -- no workspace to filter).
        local pkg = pkg_json.read(root .. "/package.json")
        local entry = {
            name = pkg.name,
            dir  = root,
            package = pkg,
            workspace_deps = {},
            solo = true,
        }
        state.root_dir    = root
        state.packages    = { entry }
        state.by_name     = { [entry.name] = entry }
        state.install_key = install_prb.ensure_probe_registered(root .. "/pnpm-lock.yaml")
        return {
            packages    = state.packages,
            install_key = state.install_key,
        }
    else
        entries = read_workspace_yaml(root .. "/pnpm-workspace.yaml")
    end
    -- `!` exclusions are honoured on both sources: pnpm-workspace.yaml and
    -- an explicit workspace{packages={...}} list.
    local includes, excludes = partition(entries)
    if #includes == 0 then
        error("[pnpm.workspace] the package list declares only `!` exclusions "
              .. "and no positive globs: " .. table.concat(entries, ", "), 2)
    end

    local dirs, matched = expand_globs(includes, excludes, root)
    if #dirs == 0 then
        if matched > 0 then
            error("[pnpm.workspace] all " .. matched .. " matched package(s) "
                  .. "were removed by `!` exclusions ("
                  .. table.concat(excludes, ", ") .. ")", 2)
        end
        error("[pnpm.workspace] no packages matched globs: "
              .. table.concat(includes, ", "), 2)
    end

    local packages = {}
    local by_name  = {}
    for _, dir in ipairs(dirs) do
        local pkg = pkg_json.read(dir .. "/package.json")
        local entry = {
            name = pkg.name,
            dir  = dir,
            package = pkg,
            workspace_deps = {},     -- filled in second pass
        }
        if by_name[entry.name] then
            error("[pnpm.workspace] duplicate package name '" .. entry.name
                  .. "' (dirs: " .. by_name[entry.name].dir
                  .. ", " .. entry.dir .. ")", 2)
        end
        packages[#packages + 1] = entry
        by_name[entry.name] = entry
    end

    for _, entry in ipairs(packages) do
        entry.workspace_deps = collect_workspace_deps(entry.package, by_name)
    end

    local ordered = topo_sort(packages, by_name)

    state.root_dir   = root
    state.packages   = ordered
    state.by_name    = by_name
    state.install_key = install_prb.ensure_probe_registered(root .. "/pnpm-lock.yaml")

    return {
        packages    = ordered,
        install_key = state.install_key,
    }
end

function M.list()
    if not state.packages then
        error("[pnpm.workspace] pnpm.workspaces() called before pnpm.workspace(...).", 2)
    end
    return state.packages
end

function M.lookup(name)
    if not state.by_name then return nil end
    return state.by_name[name]
end

function M.snapshot()
    return state
end

function M.reset()
    state.root_dir   = nil
    state.packages   = nil
    state.by_name    = nil
    state.install_key = nil
end

return M
