local M = {}

local query_items = "ProjectReference,Compile,Content,EmbeddedResource,None,AdditionalFiles,"
    .. "Analyzer,EditorConfigFiles,RazorComponent"

function M.code(solution, output, configuration)
    return ([=[
local solution, output, configuration, query_items = %q, %q, %q, %q
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
local function encode(value)
    if type(value) == "string" then return string.format("%%q", value) end
    if type(value) ~= "table" then return tostring(value) end
    local keys = {}; for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = { "{" }
    for _, key in ipairs(keys) do
        out[#out + 1] = "[" .. encode(key) .. "]=" .. encode(value[key]) .. ","
    end
    out[#out + 1] = "}"; return table.concat(out)
end

local cwd = trim(cook.sh("pwd"))
local tool = cook.probes.get("dotnet:toolchain")
local env = "DOTNET_CLI_HOME=" .. quote(cwd .. "/.cook/dotnet/home")
    .. " NUGET_PACKAGES=" .. quote(cwd .. "/.cook/dotnet/packages")
    .. " DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 DOTNET_CLI_UI_LANGUAGE=en "
fs.mkdir_p(directory(output))
local query_output = output .. ".query"
local function dotnet(args)
    cook.sh(env .. quote(tool.dotnet) .. args .. " > " .. quote(query_output))
    local value = fs.read(query_output); fs.remove(query_output); return value
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
            .. " -getProperty:MSBuildProjectName,TargetFramework,TargetFrameworks,OutputType,TargetFileName,MSBuildAllProjects"
            .. " -getItem:" .. query_items)
        local value = cook.json_decode(raw)
        local props, compact = value.Properties or {}, { Properties = {}, Items = {} }
        for _, name in ipairs({ "MSBuildProjectName", "TargetFramework", "TargetFrameworks",
            "OutputType", "TargetFileName" }) do compact.Properties[name] = props[name] end
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
                        compact.Items[kind][#compact.Items[kind] + 1] = { FullPath = path }
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
fs.write(output, "return " .. encode({ configuration = configuration, projects = projects }) .. "\n")
]=]):format(solution, output, configuration, query_items)
end

return M
