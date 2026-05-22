-- Workspace bootstrap.
--
-- Parses pnpm-workspace.yaml, then per-package package.json files,
-- builds an in-memory graph keyed on package name, and registers the
-- toolchain + install probes.
--
-- The bootstrap result is cached on a per-VM state table so subsequent
-- pnpm.task / pnpm.run calls can read the graph without re-parsing.

local toolchain    = require("cook_pnpm.toolchain")
local pkg_json     = require("cook_pnpm.probes.package_json")
local install_prb  = require("cook_pnpm.probes.pnpm_install")

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

local function expand_globs(globs, root)
    local dirs = {}
    for _, g in ipairs(globs) do
        local pattern = root .. "/" .. g .. "/package.json"
        for _, m in ipairs(fs.glob(pattern)) do
            local dir = m:match("^(.+)/package.json$")
            if dir then dirs[#dirs + 1] = dir end
        end
    end
    table.sort(dirs)
    return dirs
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

    local globs
    if type(opts.packages) == "table" then
        globs = opts.packages
    else
        globs = read_workspace_yaml(root .. "/pnpm-workspace.yaml")
    end

    local dirs = expand_globs(globs, root)
    if #dirs == 0 then
        error("[pnpm.workspace] no packages matched globs: "
              .. table.concat(globs, ", "), 2)
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
