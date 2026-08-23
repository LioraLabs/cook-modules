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
local runtimes = cook.sh(quote(dotnet) .. " --list-runtimes 2>/dev/null")
local base = trim(cook.sh(quote(dotnet) .. " --info 2>/dev/null"):match("Base Path:%s*([^\r\n]+)") or "")
local root = base:match("^(.*)/sdk/[^/]+/?$")
if not root then error("[cook_dotnet] dotnet did not report its selected SDK path") end
local function runtime(name)
    return runtimes:match(name:gsub("%.", "%%.") .. "%s+([^%s]+)") or "<missing>"
end
local function ref_pack(name, version)
    if version == "<missing>" then return version end
    local path = root .. "/packs/" .. name .. "/" .. version
    local found = trim(cook.sh("if [ -d " .. quote(path) .. " ]; then printf %s " .. quote(version) .. "; fi; true"))
    return found == version and name .. "@" .. version or "<missing>"
end
return {
    dotnet_id = tool.hash,
    sdk = sdk,
    netcore_ref = ref_pack("Microsoft.NETCore.App.Ref", runtime("Microsoft.NETCore.App")),
    aspnetcore_ref = ref_pack("Microsoft.AspNetCore.App.Ref", runtime("Microsoft.AspNetCore.App")),
}
]]
end

function M.producer(solution, configuration)
    local code = ([=[
local solution, configuration, query_items = %q, %q, %q
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
while next_index <= #queue do
    local project = normalize(queue[next_index]); next_index = next_index + 1
    if not seen[project] then
        seen[project] = true
        local raw = dotnet(" msbuild " .. quote(project) .. " -nologo"
            .. " -property:Configuration=" .. quote(configuration)
            .. " -getProperty:MSBuildProjectName,TargetFramework,TargetFrameworks,OutputType,TargetFileName,MSBuildAllProjects,UsingMicrosoftNETSdkWeb"
            .. " -getItem:" .. query_items)
        local value = cook.json_decode(raw)
        local props, compact = value.Properties or {}, { Properties = {}, Items = {} }
        for _, name in ipairs({ "MSBuildProjectName", "TargetFramework", "TargetFrameworks",
            "OutputType", "TargetFileName", "UsingMicrosoftNETSdkWeb" }) do compact.Properties[name] = props[name] end
        local imports = {}
        for imported in (props.MSBuildAllProjects or ""):gmatch("[^;]+") do
            local path = relative(imported, cwd)
            if path:sub(1, 1) ~= "/" then imports[#imports + 1] = path end
        end
        compact.Properties.MSBuildAllProjects = table.concat(imports, ";")
        for kind in query_items:gmatch("[^,]+") do
            compact.Items[kind] = {}
            for _, item in ipairs((value.Items or {})[kind] or {}) do
                if item.FullPath then
                    local path = relative(item.FullPath, cwd)
                    if path:sub(1, 1) ~= "/" then
                        local compact_item = { FullPath = path }
                        if kind == "ProjectReference" then
                            compact_item.OutputItemType = item.OutputItemType
                            compact_item.ReferenceOutputAssembly = item.ReferenceOutputAssembly
                        end
                        compact.Items[kind][#compact.Items[kind] + 1] = compact_item
                    end
                end
            end
        end
        projects[#projects + 1] = { path = project, value = compact }
        for _, item in ipairs((value.Items or {}).ProjectReference or {}) do
            if item.FullPath then
                local reference = relative(item.FullPath, cwd)
                if reference:sub(1, 1) == "/" then
                    error("[cook_dotnet.workspace] project reference outside the Cook workspace: " .. item.FullPath)
                end
                if not seen[reference] then queue[#queue + 1] = reference end
            end
        end
    end
end
table.sort(projects, function(a, b) return a.path < b.path end)
local toolchain = (function()
%s
end)()
return { configuration = configuration, toolchain = toolchain, projects = projects }
]=]):format(solution, configuration, query_items, M.toolchain_producer())
    return assert(load(code, "@cook_dotnet.discovery", "t", _ENV))
end

return M
