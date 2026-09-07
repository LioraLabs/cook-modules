local M = {}

local query_items = "ProjectReference,Compile,Content,EmbeddedResource,None,AdditionalFiles,"
    .. "Analyzer,EditorConfigFiles,RazorComponent"

function M.toolchain_producer()
    return [[
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local tool = cook.tools.id("dotnet")
if not tool then error("[cook_dotnet] dotnet not on PATH") end
local dotnet = tool.path
local sdk = trim(cook.sh(quote(dotnet) .. " --version 2>/dev/null"))
if sdk == "" then error("[cook_dotnet] dotnet did not report an SDK version") end
local base = trim(cook.sh(quote(dotnet) .. " --info 2>/dev/null"):match("Base Path:%s*([^\r\n]+)") or "")
local root = base:match("^(.*)/sdk/[^/]+/?$")
if not root then error("[cook_dotnet] dotnet did not report its selected SDK path") end
local function ref_pack(name)
    local path = root .. "/packs/" .. name
    local versions = trim(cook.sh("if [ -d " .. quote(path) .. " ]; then for v in " .. quote(path)
        .. "/*; do [ ! -d \"$v\" ] || basename \"$v\"; done | LC_ALL=C sort; fi"))
    local digest = trim(cook.sh("if [ -d " .. quote(path) .. " ]; then cd " .. quote(path)
        .. " && find . -type f -exec openssl dgst -sha256 {} + | LC_ALL=C sort"
        .. " | openssl dgst -sha256; fi"))
    return { versions = versions, digest = digest ~= "" and digest or "<missing>" }
end
return {
    dotnet_id = tool.hash,
    sdk = sdk,
    netcore_ref = ref_pack("Microsoft.NETCore.App.Ref"),
    aspnetcore_ref = ref_pack("Microsoft.AspNetCore.App.Ref"),
}
]]
end

function M.producer(solution, configuration, inventory)
    local code = ([=[
local solution, configuration, query_items, inventory = %q, %q, %q, %q
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function trim(s) return (s:gsub("^%%s+", ""):gsub("%%s+$", "")) end
local function normalize(p)
    local absolute, parts = p:sub(1, 1) == "/", {}
    for part in p:gsub("\\", "/"):gmatch("[^/]+") do
        if part == ".." then table.remove(parts) elseif part ~= "." then parts[#parts + 1] = part end
    end
    return (absolute and "/" or "") .. table.concat(parts, "/")
end
local function relative(p, cwd)
    p, cwd = normalize(p), normalize(cwd)
    if p == cwd then return "." end
    if p:sub(1, #cwd + 1) ~= cwd .. "/" then return p end
    return p:sub(#cwd + 2)
end
local function directory(p) return p:match("^(.*)/[^/]+$") or "." end
local function join(root, child) return root == "." and child or root .. "/" .. child end
local cwd = trim(cook.sh("pwd"))
local tool = assert(cook.tools.id("dotnet"), "[cook_dotnet] dotnet not on PATH").path
local env = "DOTNET_CLI_HOME=" .. quote(cwd .. "/.cook/dotnet/home")
    .. " NUGET_PACKAGES=" .. quote(cwd .. "/.cook/dotnet/packages")
    .. " DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 DOTNET_CLI_UI_LANGUAGE=en "
local function dotnet(args)
    return cook.sh(env .. quote(tool) .. args)
end
local function query(args)
    local raw = dotnet(args)
    -- The CLI may prepend a first-use workload notice to successful MSBuild JSON.
    return cook.json_decode(raw:match("({.*})%%s*$") or raw)
end
-- Bound native SDK processes; keep every outer/inner/compatibility evaluation.
local function queries(jobs)
    for first = 1, #jobs, 4 do
        local last = math.min(first + 3, #jobs)
        if first == last then jobs[first].value = query(jobs[first].args) else
            local commands = { "set -eu", "work=$(mktemp -d)",
                "trap 'rm -rf -- \"$work\"' EXIT", "failed=0" }
            for index = first, last do
                commands[#commands + 1] = env .. quote(tool) .. jobs[index].args
                    .. ' >"$work/' .. index .. '" 2>&1 &'
                commands[#commands + 1] = 'pid' .. index .. '=$!'
            end
            for index = first, last do
                commands[#commands + 1] = 'if ! wait "$pid' .. index .. '"; then cat "$work/'
                    .. index .. '" >&2; failed=1; fi'
            end
            commands[#commands + 1] = '[ "$failed" = 0 ] || exit 1'
            for index = first, last do
                commands[#commands + 1] = 'wc -c < "$work/' .. index .. '"; cat "$work/' .. index .. '"'
            end
            local output, offset = cook.sh(table.concat(commands, "\n")), 1
            for index = first, last do
                local line = assert(output:find("\n", offset, true), "missing SDK batch result length")
                local length = assert(tonumber(output:sub(offset, line - 1)), "invalid SDK batch result length")
                local raw = output:sub(line + 1, line + length)
                assert(#raw == length, "truncated SDK batch result")
                jobs[index].value = cook.json_decode(raw:match("({.*})%%s*$") or raw)
                offset = line + length + 1
            end
            assert(offset == #output + 1, "unexpected SDK batch output")
        end
    end
end
local root, queue = directory(solution), {}
if solution:lower():match("%%.csproj$") then queue[1] = solution else
    local listed = dotnet(" sln " .. quote(solution) .. " list")
    for line in listed:gmatch("[^\r\n]+") do
        line = trim(line)
        if line:lower():match("%%.csproj$") then queue[#queue + 1] = join(root, line) end
    end
end
if #queue == 0 then error("[cook_dotnet.workspace] solution contains no .csproj projects") end

local seen, projects, next_index = {}, {}, 1
local properties = "MSBuildProjectName,TargetFramework,TargetFrameworks,OutputType,TargetFileName,MSBuildAllProjects,UsingMicrosoftNETSdkWeb"
local function compact(value, refs)
    local props, compact = value.Properties or {}, { Properties = {}, Items = {} }
    for _, name in ipairs({ "MSBuildProjectName", "TargetFramework", "TargetFrameworks",
        "OutputType", "TargetFileName", "UsingMicrosoftNETSdkWeb" }) do compact.Properties[name] = props[name] end
    local imports = {}
    for imported in (props.MSBuildAllProjects or ""):gmatch("[^;]+") do
        local path = relative(imported, cwd)
        if path:sub(1, 1) ~= "/" then imports[#imports + 1] = path end
    end
    compact.Properties.MSBuildAllProjects = table.concat(imports, ";")
    local selected = {}
    for _, item in ipairs(((refs or {}).Items or {})._MSBuildProjectReferenceExistent or {}) do
        selected[normalize(item.FullPath)] = item.NearestTargetFramework
    end
    for kind in query_items:gmatch("[^,]+") do
        compact.Items[kind] = {}
        for _, item in ipairs((value.Items or {})[kind] or {}) do
            if item.FullPath then
                local path = relative(item.FullPath, cwd)
                if path:sub(1, 1) == "/" and kind == "ProjectReference" then
                    error("[cook_dotnet.workspace] project reference outside the Cook workspace: " .. item.FullPath)
                end
                if path:sub(1, 1) ~= "/" then
                    local compact_item = { FullPath = path }
                    if kind == "ProjectReference" then
                        compact_item.OutputItemType = item.OutputItemType
                        compact_item.ReferenceOutputAssembly = item.ReferenceOutputAssembly
                        compact_item.NearestTargetFramework = selected[normalize(item.FullPath)]
                        if not seen[path] then queue[#queue + 1] = path end
                    end
                    compact.Items[kind][#compact.Items[kind] + 1] = compact_item
                end
            end
        end
    end
    return compact
end
while next_index <= #queue do
    local outer_jobs, entries = {}, {}
    local last = #queue
    while next_index <= last do
        local project = normalize(queue[next_index]); next_index = next_index + 1
        if not seen[project] then
            seen[project] = true
            local command = " msbuild " .. quote(project) .. " -nologo"
                .. " -property:Configuration=" .. quote(configuration)
            local job = { args = command .. " -getProperty:" .. properties .. " -getItem:" .. query_items }
            outer_jobs[#outer_jobs + 1] = job
            entries[#entries + 1] = { path = project, command = command, outer = job, builds = {} }
        end
    end
    queries(outer_jobs)
    local inner_jobs = {}
    for _, entry in ipairs(entries) do
        -- Reject outer references outside the workspace before SDK compatibility work.
        entry.value = compact(entry.outer.value)
        local props = entry.outer.value.Properties or {}
        local frameworks = props.TargetFrameworks or ""
        if frameworks == "" then frameworks = props.TargetFramework or "" end
        for framework in frameworks:gmatch("[^;]+") do
            local args = entry.command .. " -property:TargetFramework=" .. quote(framework)
            local job = { args = args .. " -getProperty:" .. properties .. " -getItem:" .. query_items, command = args }
            entry.builds[framework] = job
            inner_jobs[#inner_jobs + 1] = job
        end
    end
    queries(inner_jobs)
    local reference_jobs = {}
    for _, job in ipairs(inner_jobs) do
        if #((job.value.Items or {}).ProjectReference or {}) > 0 then
            -- DesignTimeBuild only avoids restore for native compatibility selection.
            -- Compile/items above remain ordinary build evaluation.
            job.refs = { args = job.command .. " -property:DesignTimeBuild=true"
                .. " -target:AssignProjectConfiguration,_SplitProjectReferencesByFileExistence,_GetProjectReferenceTargetFrameworkProperties"
                .. " -getItem:_MSBuildProjectReferenceExistent" }
            reference_jobs[#reference_jobs + 1] = job.refs
        end
    end
    queries(reference_jobs)
    for _, entry in ipairs(entries) do
        local builds = {}
        for framework, job in pairs(entry.builds) do
            builds[framework] = compact(job.value, job.refs and job.refs.value)
        end
        projects[#projects + 1] = { path = entry.path, value = entry.value, builds = builds }
    end
end
table.sort(projects, function(a, b) return a.path < b.path end)
local toolchain = (function()
%s
end)()
return { configuration = configuration, toolchain = toolchain, projects = projects }
]=]):format(solution, configuration, query_items, table.concat(inventory or {}, "\n"), M.toolchain_producer())
    return assert(load(code, "@cook_dotnet.discovery", "t", _ENV))
end

return M
