local M = { name = "cook_dotnet" }
local discovery = require("cook_dotnet.discovery")
local probe_registered = false
local tool_registered = false

local function quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function directory(pathname)
    return pathname:match("^(.*)/[^/]+$") or "."
end

local function join(root, child)
    return root == "." and child or root .. "/" .. child
end

local function normalize(pathname)
    local absolute = pathname:sub(1, 1) == "/"
    local parts = {}
    for part in pathname:gsub("\\", "/"):gmatch("[^/]+") do
        if part == ".." then table.remove(parts)
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return (absolute and "/" or "") .. table.concat(parts, "/")
end

local function ensure_toolchain()
    if not tool_registered then
        cook.probe("dotnet:tool", {
            inputs = { tools = { "dotnet" } },
            produce = "@tools-identity",
        })
        tool_registered = true
    end
    if probe_registered then return "dotnet:toolchain" end
    cook.probe("dotnet:toolchain", {
        inputs = { tools = { "dotnet" } },
        produce = discovery.toolchain_producer(),
    })
    probe_registered = true
    return "dotnet:toolchain"
end

local function check_relative(name, value, allow_dot)
    local unsafe = type(value) ~= "string" or value == "" or value:sub(1, 1) == "/"
        or (value == "." and not allow_dot)
    if not unsafe then
        for segment in value:gmatch("[^/]+") do
            if segment == ".." then unsafe = true; break end
        end
    end
    if unsafe then
        error("[cook_dotnet] " .. name .. " must be a non-root relative path", 3)
    end
end

function M.init() end

function M.build(opts)
    opts = opts or {}
    local ok, qualified = pcall(cook.recipe_name)
    if not ok then
        error("[cook_dotnet.build] must be called inside a recipe block", 2)
    end
    if type(opts.project) ~= "string" or opts.project == "" then
        error("[cook_dotnet.build] project must be a non-empty .csproj, .sln, or .slnx path", 2)
    end
    local project_lower = opts.project:lower()
    if not project_lower:match("%.csproj$") and not project_lower:match("%.slnx?$") then
        error("[cook_dotnet.build] project must end in .csproj, .sln, or .slnx", 2)
    end

    local root = opts.root or directory(opts.project)
    local artifacts = opts.artifacts or ("build/dotnet/" .. recipe.name)
    check_relative("root", root, true)
    check_relative("artifacts", artifacts)
    if opts.configuration ~= nil and type(opts.configuration) ~= "string" then
        error("[cook_dotnet.build] configuration must be a string", 2)
    end
    if opts.framework ~= nil and type(opts.framework) ~= "string" then
        error("[cook_dotnet.build] framework must be a string", 2)
    end

    local globs = opts.inputs or { join(root, "**") }
    local excludes = {
        join(root, "bin/**"),
        join(root, "obj/**"),
        join(root, ".git/**"),
        join(root, ".cook/**"),
        artifacts .. "/**",
    }
    for _, pattern in ipairs(opts.excludes or {}) do excludes[#excludes + 1] = pattern end
    local inputs = cook.resolve_gather(globs, excludes)
    local lock_glob = project_lower:match("%.csproj$")
        and join(directory(opts.project), "packages.lock.json")
        or join(root, "**/packages.lock.json")
    local locks = cook.resolve_gather({ lock_glob }, {
        join(root, "bin/**"), join(root, "obj/**"), join(root, ".git/**"),
        join(root, ".cook/**"), artifacts .. "/**",
    })
    local seen = {}; for _, input in ipairs(inputs) do seen[input] = true end
    for _, lock in ipairs(locks) do if not seen[lock] then inputs[#inputs + 1], seen[lock] = lock, true end end
    table.sort(inputs)
    local probe = ensure_toolchain()

    -- ponytail: shared CLI/NuGet caches; split per SDK only if dotnet proves they conflict.
    local dotnet = '"$<dotnet:tool.dotnet.path>"'
    local environment = 'DOTNET_CLI_HOME="$(pwd)/.cook/dotnet/home"'
        .. ' NUGET_PACKAGES="$(pwd)/.cook/dotnet/packages"'
        .. " DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 "
    local web = project_lower:match("%.csproj$")
        and (environment .. dotnet .. " msbuild " .. quote(opts.project)
            .. " -nologo -getProperty:UsingMicrosoftNETSdkWeb")
    local command = "rm -rf -- " .. quote(artifacts)
        .. (web and (" && web=$(" .. web .. ")") or " && web=true")
        .. " && if [ \"$web\" = true ]; then prune=-p:AllowMissingPrunePackageData=true; else prune=; fi"
        .. " && " .. environment
        .. dotnet .. " restore " .. quote(opts.project)
        .. " --artifacts-path " .. quote(artifacts)
        .. (#locks > 0 and " --use-lock-file --locked-mode" or "")
        .. " --verbosity quiet $prune"
        .. " && " .. environment
        .. dotnet .. " build " .. quote(opts.project)
        .. " --artifacts-path " .. quote(artifacts)
        .. " --configuration " .. quote(opts.configuration or "Debug")
        .. " --no-restore"
    if opts.framework then command = command .. " --framework " .. quote(opts.framework) end

    -- Cleanup lives inside the cached unit: misses start fresh; hits skip it.
    cook.add_unit({
        inputs = inputs,
        outputs = { artifacts .. "/**" },
        command = command,
        probes = { "dotnet:tool", probe },
        seal = { probe },
    })
    cook.export(qualified, { artifacts = artifacts, outputs = { artifacts .. "/**" } })
end

local function discover_project(project, value)
    local props, items = value.Properties or {}, value.Items or {}
    if not props.MSBuildProjectName or props.MSBuildProjectName == "" then
        error("[cook_dotnet.workspace] MSBuild did not return a project name for '" .. project .. "'", 2)
    end
    local files, references = { [project] = true }, {}
    local project_dir = directory(project)
    local function add_file(pathname)
        local path = normalize(pathname)
        local prefix = project_dir == "." and "" or project_dir .. "/"
        local relative = path:sub(1, #prefix) == prefix and path:sub(#prefix + 1)
        if path:sub(1, 1) ~= "/"
            and not (relative and (relative:match("^bin/") or relative:match("^obj/"))) then
            files[path] = true
        end
    end
    for _, kind in ipairs({ "Compile", "Content", "EmbeddedResource", "None", "AdditionalFiles",
                            "Analyzer", "EditorConfigFiles", "RazorComponent" }) do
        for _, item in ipairs(items[kind] or {}) do
            if item.FullPath then add_file(item.FullPath) end
        end
    end
    for imported in (props.MSBuildAllProjects or ""):gmatch("[^;]+") do
        add_file(imported)
    end
    for _, item in ipairs(items.ProjectReference or {}) do
        if item.FullPath then
            local path = normalize(item.FullPath)
            if path:sub(1, 1) == "/" then
                error("[cook_dotnet.workspace] project reference outside the Cook workspace: "
                    .. item.FullPath, 2)
            end
            references[#references + 1] = {
                path = path,
                generator = item.OutputItemType == "Analyzer"
                    or item.ReferenceOutputAssembly == "false",
            }
        end
    end
    table.sort(references, function(a, b) return a.path < b.path end)
    return {
        path = project,
        name = props.MSBuildProjectName,
        framework = props.TargetFramework,
        frameworks = props.TargetFrameworks,
        output_type = props.OutputType,
        target_file = props.TargetFileName,
        web = props.UsingMicrosoftNETSdkWeb == "true",
        files = files,
        references = references,
    }
end

local function is_ancestor(parent, child)
    return parent == "." or child == parent or child:sub(1, #parent + 1) == parent .. "/"
end

local function workspace_globs(root, solution, locks)
    local prefix = root == "." and "" or root .. "/"
    local globs = { solution,
        prefix .. "**/*.csproj", prefix .. "**/*.props", prefix .. "**/*.targets",
        prefix .. "**/global.json", prefix .. "**/NuGet.config", prefix .. "**/nuget.config",
        prefix .. "**/.editorconfig",
    }
    if locks then globs[#globs + 1] = prefix .. "**/packages.lock.json" end

    local current = "."
    for part in root:gmatch("[^/]+") do
        for _, name in ipairs({ "Directory.Build.props", "Directory.Build.targets",
            "Directory.Packages.props", "global.json", "NuGet.config", "nuget.config", ".editorconfig" }) do
            globs[#globs + 1] = join(current, name)
        end
        current = join(current, part)
    end
    return globs
end

local function project_context(project, context)
    local dir, nearest, inherited = directory(project.path), {}, {}
    for file in pairs(context) do
        local base, parent = file:match("([^/]+)$") or file, directory(file)
        local lower = base:lower()
        if is_ancestor(parent, dir) then
            if lower == "directory.build.props" or lower == "directory.build.targets"
                or lower == "directory.packages.props" or lower == "global.json"
            then
                if not nearest[lower] or #parent > #directory(nearest[lower]) then nearest[lower] = file end
            elseif lower == "nuget.config" or lower == ".editorconfig" then
                inherited[#inherited + 1] = file
            elseif lower == "packages.lock.json" and parent == dir then
                inherited[#inherited + 1] = file
            end
        end
    end
    for _, file in pairs(nearest) do inherited[#inherited + 1] = file end
    return inherited
end

local function recipe_segment(name)
    return (name:gsub("[^A-Za-z0-9_+-]", "-"))
end

local function framework_segment(framework)
    return "tfm-" .. framework:gsub(".", function(byte) return ("%02x"):format(byte:byte()) end)
end

local function target_frameworks(project)
    if project.framework and project.framework ~= "" then return { project.framework } end
    local result = {}
    for framework in (project.frameworks or ""):gmatch("[^;]+") do result[#result + 1] = framework end
    return result
end

local function web_workaround(project, toolchain)
    local function has_pack(pack, framework)
        local major = framework:match("^net(%d+)")
        return major and pack and pack.versions
            and ("\n" .. pack.versions .. "\n"):find("\n" .. major .. "%.[^\n]*\n")
    end
    local frameworks = target_frameworks(project)
    if not project.web then return "" end
    for _, framework in ipairs(frameworks) do
        if framework ~= "" and not has_pack(toolchain.aspnetcore_ref, framework) then
            return " -p:AllowMissingPrunePackageData=true"
        end
    end
    return ""
end

local function mint_graph(opts, mode, context_files, graph)
    local artifacts, configuration, root = opts.artifacts, opts.configuration, opts.root
    local context = {}
    for _, file in ipairs(context_files) do
        local base = file:match("([^/]+)$") or file
        local lower = base:lower()
        if lower == "directory.build.props" or lower == "directory.build.targets"
            or lower == "directory.packages.props" or lower == "global.json"
            or lower == "nuget.config" or lower == "packages.lock.json" or lower == ".editorconfig"
        then context[file] = true end
    end

    local projects = {}
    for _, entry in ipairs(graph.projects) do
        local info = discover_project(entry.path, entry.value)
        if not is_ancestor(root, info.path) then
            error("[cook_dotnet.workspace] MSBuild discovered project '" .. info.path
                .. "' outside root '" .. root .. "'; expand root to include it", 2)
        end
        projects[info.path] = info
    end
    local glob = root == "." and "**" or root .. "/**"
    local workspace_files = cook.resolve_gather({ glob }, {
        "**/bin/**", "**/obj/**", ".git/**", ".cook/**", artifacts .. "/**",
    })

    local by_name = {}
    for _, project in pairs(projects) do
        project.recipe = "dotnet:" .. recipe_segment(project.name)
        project.framework_list = target_frameworks(project)
        if #project.framework_list == 0 then project.framework_list[1] = "" end
        if by_name[project.recipe] and by_name[project.recipe] ~= project.path then
            error("[cook_dotnet.workspace] projects '" .. by_name[project.recipe] .. "' and '"
                .. project.path .. "' map to the same recipe '" .. project.recipe .. "'", 2)
        end
        by_name[project.recipe] = project.path
    end

    local ordered, visiting, visited = {}, {}, {}
    local function visit(pathname)
        if visited[pathname] then return end
        if visiting[pathname] then error("[cook_dotnet.workspace] project-reference cycle at '"
            .. pathname .. "'", 2) end
        local project = projects[pathname]
        if not project then error("[cook_dotnet.workspace] undiscovered project reference '"
            .. pathname .. "'", 2) end
        visiting[pathname] = true
        for _, reference in ipairs(project.references) do visit(reference.path) end
        visiting[pathname], visited[pathname] = nil, true
        ordered[#ordered + 1] = project
    end
    local paths = {}; for path in pairs(projects) do paths[#paths + 1] = path end; table.sort(paths)
    for _, path in ipairs(paths) do visit(path) end

    local function recipe_for(project, framework)
        if #project.framework_list == 1 then return project.recipe end
        for _, candidate in ipairs(project.framework_list) do
            if candidate == framework then return project.recipe .. ":" .. framework_segment(candidate) end
        end
        error("[cook_dotnet.workspace] project '" .. project.path
            .. "' does not target framework '" .. framework .. "'", 2)
    end

    local function output_suffix(project, framework)
        return #project.framework_list > 1
            and "/" .. configuration:lower() .. "_" .. framework or ""
    end

    local roots, aggregate_outputs = {}, {}
    for _, project in ipairs(ordered) do
      for _, framework in ipairs(project.framework_list) do
        local requires, inputs, input_set = {}, {}, {}
        local function add_input(file)
            if not input_set[file] then input_set[file], inputs[#inputs + 1] = true, file end
        end
        for file in pairs(project.files) do add_input(file) end
        for _, file in ipairs(project_context(project, context)) do add_input(file) end
        local project_dir = directory(project.path)
        local prefix = project_dir == "." and "" or project_dir .. "/"
        for _, file in ipairs(workspace_files) do
            if file:sub(1, #prefix) == prefix
                and (file:match("([^/]+)$") ~= "packages.lock.json" or directory(file) == project_dir)
            then add_input(file) end
        end
        for _, reference in ipairs(project.references) do
            local dependency = projects[reference.path]
            local dependency_framework = #dependency.framework_list == 1
                and dependency.framework_list[1] or framework
            requires[#requires + 1] = recipe_for(dependency, dependency_framework)
            local suffix = output_suffix(dependency, dependency_framework)
            if reference.generator then
                add_input(artifacts .. "/bin/" .. dependency.name .. suffix .. "/**")
            else
                add_input(artifacts .. "/obj/" .. dependency.name .. suffix
                    .. (suffix == "" and "/**/ref/*.dll" or "/ref/*.dll"))
            end
        end
        table.sort(inputs); table.sort(requires)
        local locked = input_set[join(project_dir, "packages.lock.json")]
        local suffix = output_suffix(project, framework)
        local bin = artifacts .. "/bin/" .. project.name .. suffix
        local obj = artifacts .. "/obj/" .. project.name .. suffix
        local environment = 'DOTNET_CLI_HOME="$(pwd)/.cook/dotnet/home"'
            .. ' NUGET_PACKAGES="$(pwd)/.cook/dotnet/packages"'
            .. " DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 "
        local command = "rm -rf -- " .. quote(bin) .. " " .. quote(obj)
            .. " && " .. environment .. '"$<dotnet:tool.dotnet.path>" restore ' .. quote(project.path)
            .. " --artifacts-path " .. quote(artifacts)
            .. " -p:RestoreRecursive=false"
            .. (locked and " --use-lock-file --locked-mode" or "")
            .. web_workaround(project, graph.toolchain) .. " --verbosity quiet"
            .. " && " .. environment .. '"$<dotnet:tool.dotnet.path>" build ' .. quote(project.path)
            .. " --artifacts-path " .. quote(artifacts)
            .. " --configuration " .. quote(configuration)
            .. " --no-restore --no-dependencies -p:UseCommonOutputDirectory=true"
            .. web_workaround(project, graph.toolchain)
        if framework ~= "" then command = command .. " --framework " .. quote(framework) end
        local project_recipe = recipe_for(project, framework)
        roots[#roots + 1] = project_recipe
        aggregate_outputs[#aggregate_outputs + 1] = bin .. "/**"
        aggregate_outputs[#aggregate_outputs + 1] = obj .. "/**"
        cook.recipe(project_recipe, { requires = requires, origin = "cook_dotnet.workspace" }, function()
            cook.add_unit({
                inputs = inputs,
                outputs = { bin .. "/**", obj .. "/**" },
                command = command,
                probes = { "dotnet:tool", "dotnet:toolchain" },
                seal = { "dotnet:toolchain" },
            })
            cook.export(project_recipe, {
                project = project.path,
                name = project.name,
                framework = project.framework,
                frameworks = project.frameworks,
                artifacts = artifacts,
                outputs = { bin .. "/**", obj .. "/**" },
            })
        end)
      end
    end

    local executables = {}
    local function transitive(project, seen, result)
        if seen[project.path] then return end
        seen[project.path] = true
        for _, reference in ipairs(project.references) do transitive(projects[reference.path], seen, result) end
        result[#result + 1] = project
    end
    for _, project in ipairs(ordered) do
        if (project.output_type == "Exe" or project.output_type == "WinExe")
            and #project.framework_list == 1 and project.framework_list[1] ~= ""
            and project.target_file ~= ""
        then
            local closure = {}; transitive(project, {}, closure)
            local run_dir = artifacts .. "/run/" .. project.name
            local projection_inputs, copy = {}, { "rm -rf -- " .. quote(run_dir), "mkdir -p -- " .. quote(run_dir) }
            for _, dependency in ipairs(closure) do
                local source = artifacts .. "/bin/" .. dependency.name
                projection_inputs[#projection_inputs + 1] = source .. "/**"
                copy[#copy + 1] = "for d in " .. quote(source) .. "/*; do [ ! -d \"$d\" ] || cp -a \"$d/.\" "
                    .. quote(run_dir .. "/") .. "; done"
            end
            local run_recipe = project.recipe .. ":run"
            cook.recipe(run_recipe, { requires = { project.recipe }, origin = "cook_dotnet.workspace" }, function()
                cook.add_unit({
                    inputs = projection_inputs,
                    outputs = { run_dir .. "/**" },
                    command = table.concat(copy, " && "),
                })
                cook.add_unit({
                    inputs = { run_dir .. "/" .. project.target_file },
                    command = '"$<dotnet:tool.dotnet.path>" ' .. quote(run_dir .. "/" .. project.target_file),
                    probes = { "dotnet:tool", "dotnet:toolchain" },
                    seal = { "dotnet:toolchain" },
                    cache = false,
                    sharing = "local",
                })
            end)
            executables[#executables + 1] = run_recipe
        end
    end

    table.sort(roots)
    if mode == "run" then
        if #executables == 1 then
            cook.require_recipe(executables[1])
        else
            cook.add_unit({
                command = "echo " .. quote("[cook_dotnet.workspace] dotnet:run requires exactly one"
                    .. " single-target executable; found " .. #executables) .. " >&2; exit 1",
                cache = false,
                sharing = "local",
            })
        end
    else
        for _, root in ipairs(roots) do cook.require_recipe(root) end
        table.sort(aggregate_outputs)
        cook.step_group(function() cook.passthrough(aggregate_outputs) end)
    end
end

function M.workspace(opts)
    opts = opts or {}
    if pcall(cook.recipe_name) then error("[cook_dotnet.workspace] must be called at top level", 2) end
    local solution = opts.solution
    if type(solution) ~= "string" or solution == "" then
        error("[cook_dotnet.workspace] solution must be a non-empty .sln, .slnx, or .csproj path", 2)
    end
    local lower = solution:lower()
    if not lower:match("%.csproj$") and not lower:match("%.slnx?$") then
        error("[cook_dotnet.workspace] solution must end in .sln, .slnx, or .csproj", 2)
    end
    check_relative("solution", solution)
    local root = opts.root or "."
    check_relative("root", root, true)
    if not is_ancestor(root, solution) then
        error("[cook_dotnet.workspace] solution must be inside root '" .. root .. "'", 2)
    end
    local artifacts = opts.artifacts or "build/dotnet"
    check_relative("artifacts", artifacts)
    local configuration = opts.configuration or "Debug"
    if type(configuration) ~= "string" or configuration == "" then
        error("[cook_dotnet.workspace] configuration must be a non-empty string", 2)
    end

    ensure_toolchain()
    local graph_inputs = cook.resolve_gather(workspace_globs(root, solution, false),
        { "**/bin/**", "**/obj/**", ".git/**", ".cook/**", artifacts .. "/**" })
    local inputs = cook.resolve_gather(workspace_globs(root, solution, true),
        { "**/bin/**", "**/obj/**", ".git/**", ".cook/**", artifacts .. "/**" })
    local graph = cook.materialize("graph", { files = graph_inputs, tools = { "dotnet" }, seals = { "dotnet:toolchain" } },
        discovery.producer(solution, configuration))
    local settings = { artifacts = artifacts, configuration = configuration, root = root }
    cook.recipe("dotnet:build", { origin = "cook_dotnet.workspace" }, function()
        mint_graph(settings, "build", inputs, graph)
    end)
    cook.recipe("dotnet:run", { origin = "cook_dotnet.workspace" }, function()
        mint_graph(settings, "run", inputs, graph)
    end)
    return { "dotnet:build", "dotnet:run" }
end

return M
