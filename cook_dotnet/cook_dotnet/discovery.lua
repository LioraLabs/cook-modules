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

-- ponytail: scan native root subtrees; retain full glob predicates only if intra-project noise becomes costly.
-- MSBuild owns include expansion. Keep its native glob roots, with the old broad
-- inventory when authored imports, conditions, or expressions hide filesystem reads.
function M.inventory_producer(solution, configuration, root, artifacts)
    local project = [=[
<Project>
  <UsingTask TaskName="CookInventory" TaskFactory="RoslynCodeTaskFactory" AssemblyFile="$(MSBuildToolsPath)/Microsoft.Build.Tasks.Core.dll">
    <ParameterGroup>
      <Solution ParameterType="System.String" Required="true" />
      <Configuration ParameterType="System.String" Required="true" />
      <WorkspaceRoot ParameterType="System.String" Required="true" />
      <ScanRoot ParameterType="System.String" Required="true" />
      <Artifacts ParameterType="System.String" Required="true" />
      <Roots ParameterType="Microsoft.Build.Framework.ITaskItem[]" Output="true" />
    </ParameterGroup>
    <Task>
      <Using Namespace="System.Collections" />
      <Using Namespace="System.Collections.Generic" />
      <Using Namespace="System.IO" />
      <Using Namespace="System.Reflection" />
      <Code Type="Fragment" Language="cs"><![CDATA[
        // The factory targets netstandard; the installed MSBuild assembly targets
        // the selected runtime. Reflection bridges that SDK boundary without a helper build.
        var assembly = Assembly.Load("Microsoft.Build");
        var collectionType = assembly.GetType("Microsoft.Build.Evaluation.ProjectCollection");
        var collection = Activator.CreateInstance(collectionType);
        Func<object, string, object> get = (value, name) => value.GetType().GetProperty(name).GetValue(value);
        var roots = new HashSet<string>(StringComparer.Ordinal);
        var pending = new Queue<KeyValuePair<string, string>>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        bool fallback = false;
        Action<string> addRoot = path => {
          path = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
          if (ScanRoot.StartsWith(path + "/", StringComparison.Ordinal)) path = ScanRoot;
          if (path == ScanRoot || path.StartsWith(ScanRoot + "/", StringComparison.Ordinal)) roots.Add(path);
        };
        try {
          if (Solution.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase)) pending.Enqueue(new KeyValuePair<string, string>(Solution, ""));
          else {
            var solutionType = assembly.GetType("Microsoft.Build.Construction.SolutionFile");
            var parsed = solutionType.GetMethod("Parse").Invoke(null, new object[] { Solution });
            foreach (var entry in (IEnumerable)get(parsed, "ProjectsInOrder")) {
              var path = (string)get(entry, "AbsolutePath");
              if (path.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase)) pending.Enqueue(new KeyValuePair<string, string>(path, ""));
            }
          }
          while (pending.Count > 0 && !fallback) {
            var next = pending.Dequeue();
            var path = Path.GetFullPath(next.Key);
            if (!seen.Add(path + "\n" + next.Value)) continue;
            var globals = new Dictionary<string, string> { { "Configuration", Configuration } };
            if (next.Value != "") globals["TargetFramework"] = next.Value;
            var evaluated = collectionType.GetMethod("LoadProject", new[] { typeof(string), typeof(IDictionary<string, string>), typeof(string) })
              .Invoke(collection, new object[] { path, globals, null });
            var type = evaluated.GetType();
            var directory = (string)get(evaluated, "DirectoryPath");
            addRoot(directory);
            var documents = new List<object> { get(evaluated, "Xml") };
            foreach (var imported in (IEnumerable)get(evaluated, "Imports"))
              documents.Add(get(imported, "ImportedProject"));
            var packageFolders = ((string)type.GetMethod("GetPropertyValue").Invoke(evaluated, new object[] { "NuGetPackageFolders" })
                + ";" + (string)type.GetMethod("GetPropertyValue").Invoke(evaluated, new object[] { "NuGetPackageRoot" })).Split(';');
            foreach (var document in documents) {
              var defining = (string)get(document, "FullPath");
              // Package build props are authored inputs, even inside an excluded or external cache.
              bool packageDocument = Array.Exists(packageFolders, folder => folder != ""
                  && defining.StartsWith(Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar) + "/", StringComparison.Ordinal));
              if (!packageDocument && (!defining.StartsWith(WorkspaceRoot + "/", StringComparison.Ordinal)
                  || defining.StartsWith(WorkspaceRoot + "/.cook/", StringComparison.Ordinal)
                  || defining.IndexOf("/obj/", StringComparison.Ordinal) >= 0
                  || defining.IndexOf("/bin/", StringComparison.Ordinal) >= 0
                  || defining.StartsWith(Artifacts + "/", StringComparison.Ordinal))) continue;
              foreach (var element in (IEnumerable)get(document, "AllChildren")) {
                var condition = (string)get(element, "Condition");
                var text = (string)get(element, "OuterElement");
                if ((string)get(element, "ElementName") == "Import" || !string.IsNullOrEmpty(condition)
                    || (text != null && (text.Contains("$(") || text.Contains("@(") || text.Contains("%(")))) { fallback = true; break; }
              }
              if (fallback) break;
            }
            if (fallback) break;
            var globType = assembly.GetType("Microsoft.Build.Globbing.MSBuildGlob");
            foreach (var glob in (IEnumerable)type.GetMethod("GetAllGlobs", Type.EmptyTypes).Invoke(evaluated, null)) {
              foreach (string include in (IEnumerable)get(glob, "IncludeGlobs")) {
                var parsed = globType.GetMethod("Parse", new[] { typeof(string), typeof(string) }).Invoke(null, new object[] { directory, include });
                addRoot((string)get(parsed, "FixedDirectoryPart"));
              }
            }
            foreach (string kind in new[] { "ProjectReference", "Compile", "Content", "EmbeddedResource", "None", "AdditionalFiles", "Analyzer", "EditorConfigFiles", "RazorComponent" }) {
              foreach (var item in (IEnumerable)type.GetMethod("GetItems").Invoke(evaluated, new object[] { kind })) {
                var file = (string)item.GetType().GetMethod("GetMetadataValue").Invoke(item, new object[] { "FullPath" });
                if (file == "") continue;
                addRoot(Path.GetDirectoryName(file));
                // Leave the established graph query to diagnose out-of-workspace references.
                if (kind == "ProjectReference" && file.StartsWith(WorkspaceRoot + "/", StringComparison.Ordinal))
                  pending.Enqueue(new KeyValuePair<string, string>(file, ""));
              }
            }
            if (next.Value == "") {
              var frameworks = (string)type.GetMethod("GetPropertyValue").Invoke(evaluated, new object[] { "TargetFrameworks" });
              if (frameworks == "") frameworks = (string)type.GetMethod("GetPropertyValue").Invoke(evaluated, new object[] { "TargetFramework" });
              foreach (var framework in frameworks.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)) pending.Enqueue(new KeyValuePair<string, string>(path, framework));
            }
          }
        } finally { ((IDisposable)collection).Dispose(); }
        if (fallback) { roots.Clear(); roots.Add(ScanRoot); }
        var result = new List<Microsoft.Build.Framework.ITaskItem>();
        foreach (var path in roots) result.Add(new Microsoft.Build.Utilities.TaskItem(path));
        Roots = result.ToArray();
      ]]></Code>
    </Task>
  </UsingTask>
  <Target Name="CookInventory">
    <CookInventory Solution="$(Solution)" Configuration="$(Configuration)" WorkspaceRoot="$(WorkspaceRoot)" ScanRoot="$(ScanRoot)" Artifacts="$(Artifacts)">
      <Output TaskParameter="Roots" ItemName="CookInventoryRoots" />
    </CookInventory>
  </Target>
</Project>
]=]
    local code = ([=[
local solution, configuration, root, artifacts, project = %q, %q, %q, %q, %q
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local cwd = cook.sh("pwd"):gsub("%%s+$", "")
local dotnet = assert(cook.tools.id("dotnet"), "[cook_dotnet] dotnet not on PATH").path
local environment = "DOTNET_CLI_HOME=" .. quote(cwd .. "/.cook/dotnet/home")
    .. " NUGET_PACKAGES=" .. quote(cwd .. "/.cook/dotnet/packages")
    .. " DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 DOTNET_CLI_UI_LANGUAGE=en "
local command = 'work=$(mktemp -d); trap \'rm -rf -- "$work"\' EXIT; printf %%s '
    .. quote(project) .. ' >"$work/inventory.proj"; ' .. environment .. quote(dotnet)
    .. ' msbuild "$work/inventory.proj" -nologo -target:CookInventory -getItem:CookInventoryRoots'
    .. " -property:Solution=" .. quote(cwd .. "/" .. solution)
    .. " -property:Configuration=" .. quote(configuration)
    .. " -property:WorkspaceRoot=" .. quote(cwd)
    .. " -property:ScanRoot=" .. quote(root == "." and cwd or cwd .. "/" .. root)
    .. " -property:Artifacts=" .. quote(cwd .. "/" .. artifacts)
local raw = cook.sh(command)
local value = cook.json_decode(raw:match("({.*})%%s*$") or raw)
local roots = {}
for _, item in ipairs(assert(value.Items, "missing native inventory items").CookInventoryRoots or {}) do
    local path = item.Identity
    if path == cwd then roots[#roots + 1] = "."
    elseif path:sub(1, #cwd + 1) == cwd .. "/" then roots[#roots + 1] = path:sub(#cwd + 2) end
end
table.sort(roots)
-- A parent root already covers every child, without duplicating scans.
local compact = {}
for _, path in ipairs(roots) do
    local prior = compact[#compact]
    if not prior or (prior ~= "." and path:sub(1, #prior + 1) ~= prior .. "/") then compact[#compact + 1] = path end
end
return { roots = compact }
]=]):format(solution, configuration, root, artifacts, project)
    return assert(load(code, "@cook_dotnet.inventory", "t", _ENV))
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
