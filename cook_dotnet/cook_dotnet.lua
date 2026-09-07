local M = { name = "cook_dotnet" }
local discovery = require("cook_dotnet.discovery")
local probe_registered = false
local tool_registered = false

local function quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function test_options(opts)
    local filter = opts.test_filter == nil and "" or opts.test_filter
    if type(filter) ~= "string" or filter:find("%z") then
        return nil, "test_filter must be a string without NUL bytes"
    end
    local args = opts.test_args == nil and {} or opts.test_args
    if type(args) ~= "table" then return nil, "test_args must be a list of strings" end
    local count, quoted = 0, {}
    for key, value in pairs(args) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(value) ~= "string"
            or value:find("%z") then
            return nil, "test_args must be a contiguous list of strings without NUL bytes"
        end
        count = count + 1
    end
    for i = 1, count do
        if args[i] == nil then return nil, "test_args must be a contiguous list of strings" end
        quoted[#quoted + 1] = " " .. quote(args[i])
    end
    return (filter ~= "" and " " .. quote("--TestCaseFilter:" .. filter) or "") .. table.concat(quoted)
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
                framework = item.NearestTargetFramework,
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

local function project_recipe(project, framework)
    local name = "dotnet:" .. recipe_segment(project.name)
    return #target_frameworks(project) > 1 and name .. ":" .. framework_segment(framework) or name
end

local function mint_graph(opts, mode, context_files, graph, target)
    local project_selector = target and target.project or opts.project
    local framework_selector = target and target.framework or opts.framework
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
        info.builds = {}
        for framework, value in pairs(entry.builds or {}) do
            info.builds[framework] = discover_project(entry.path, value)
        end
        local only
        for _, build in pairs(info.builds) do
            if only then only = nil; break end
            only = build
        end
        if only then info.target_file, info.output_type = only.target_file, only.output_type end
        projects[info.path] = info
    end

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
        if next(project.builds) then
            for _, build in pairs(project.builds) do
                for _, reference in ipairs(build.references) do visit(reference.path) end
            end
        else
            for _, reference in ipairs(project.references) do visit(reference.path) end
        end
        visiting[pathname], visited[pathname] = nil, true
        ordered[#ordered + 1] = project
    end
    local paths = {}; for path in pairs(projects) do paths[#paths + 1] = path end; table.sort(paths)
    for _, path in ipairs(paths) do visit(path) end

    local function recipe_for(project, framework)
        for _, candidate in ipairs(project.framework_list) do
            if candidate == framework then
                return project_recipe(project, candidate)
            end
        end
        error("[cook_dotnet.workspace] project '" .. project.path
            .. "' does not target framework '" .. framework .. "'", 2)
    end

    local selected, selected_projects = {}, {}
    local function select(project, framework)
        local key = recipe_for(project, framework)
        if selected[key] then return end
        selected[key], selected_projects[project.path] = true, true
        local build = project.builds[framework] or project
        for _, reference in ipairs(build.references) do
            local dependency = projects[reference.path]
            select(dependency, reference.framework or (#dependency.framework_list == 1
                and dependency.framework_list[1] or framework))
        end
    end
    local function reject_run(message)
        cook.add_unit({ command = "echo " .. quote("[cook_dotnet.workspace] " .. message) .. " >&2; exit 1",
            cache = false, sharing = "local" })
    end
    local chosen
    local executable_choices = {}
    for _, project in ipairs(ordered) do
        for _, framework in ipairs(project.framework_list) do
            local build = project.builds[framework] or project
            if (build.output_type == "Exe" or build.output_type == "WinExe")
                and framework ~= "" and build.target_file ~= "" then
                executable_choices[#executable_choices + 1] = { project = project, framework = framework }
            end
        end
    end
    if mode == "run" and project_selector == "" then
        local applications, names = {}, {}
        for _, candidate in ipairs(executable_choices) do
            if not applications[candidate.project.path] then
                applications[candidate.project.path] = candidate.project
                names[#names + 1] = candidate.project.name .. " (" .. candidate.project.path .. ")"
                chosen = candidate.project
            end
        end
        if #names ~= 1 then
            table.sort(names)
            return reject_run("dotnet:run requires PROJECT; found " .. #names
                .. " executable projects; choose one of: " .. table.concat(names, ", "))
        end
    end
    if project_selector ~= "" then
        local choices = {}
        for _, project in ipairs(ordered) do
            choices[#choices + 1] = project.name .. " (" .. project.path .. ")"
            if project_selector == project.name or normalize(project_selector) == project.path then
                if chosen then error("[cook_dotnet.workspace] ambiguous project '" .. project_selector
                    .. "': '" .. chosen.path .. "' and '" .. project.path .. "'", 2) end
                chosen = project
            end
        end
        if not chosen then
            table.sort(choices)
            error("[cook_dotnet.workspace] unknown project '" .. project_selector
                .. "'; choose one of: " .. table.concat(choices, ", "), 2)
        end
    end
    local run_framework
    if mode == "run" then
        if framework_selector == "" and #chosen.framework_list ~= 1 then
            return reject_run("dotnet:run requires FRAMEWORK for '" .. chosen.path
                .. "'; choose one of: " .. table.concat(chosen.framework_list, ", "))
        end
        run_framework = framework_selector ~= "" and framework_selector or chosen.framework_list[1]
    end
    if chosen then
        if framework_selector ~= "" then
            local found = false
            for _, framework in ipairs(chosen.framework_list) do
                if framework == framework_selector then found = true end
            end
            if not found then error("[cook_dotnet.workspace] project '" .. chosen.path
                .. "' does not target framework '" .. framework_selector .. "'; choose one of: "
                .. table.concat(chosen.framework_list, ", "), 2) end
            select(chosen, framework_selector)
        else
            for _, framework in ipairs(chosen.framework_list) do select(chosen, framework) end
        end
    else
        for _, project in ipairs(ordered) do
            for _, framework in ipairs(project.framework_list) do select(project, framework) end
        end
    end

    local function output_suffix(project, framework)
        return "/" .. configuration:lower()
            .. ((project.frameworks or "") ~= "" and "_" .. framework or "")
    end

    local environment = 'DOTNET_CLI_HOME="$(pwd)/.cook/dotnet/home"'
        .. ' NUGET_PACKAGES="$(pwd)/.cook/dotnet/packages"'
        .. " DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 "
    local function restore_command(project, locked)
        return environment .. '"$<dotnet:tool.dotnet.path>" restore ' .. quote(project.path)
            .. " --artifacts-path " .. quote(artifacts)
            .. " -p:RestoreRecursive=false -p:Configuration=" .. quote(configuration)
            .. (locked and " --use-lock-file --locked-mode" or "")
            .. web_workaround(project, graph.toolchain) .. " --verbosity quiet"
    end

    local roots, aggregate_outputs, restore_roots = {}, {}, {}
    for _, project in ipairs(ordered) do
      local restore_recipe = "__dotnet:restore:" .. recipe_segment(project.name)
      local restore_dir = artifacts .. "/obj/" .. project.name
      -- Malformed assets/props can prevent native restore itself from evaluating.
      -- Clear only this restore unit's files on a miss, retaining framework directories.
      local command = "mkdir -p -- " .. quote(restore_dir)
          .. " && find " .. quote(restore_dir) .. " -mindepth 1 -maxdepth 1 ! -type d -delete && "
          .. restore_command(project, context[join(directory(project.path), "packages.lock.json")])
      -- NuGet metadata embeds checkout paths; do not fetch it from another workspace.
      local restore_outputs = { artifacts .. "/obj/" .. project.name .. "/*" }
      cook.recipe(restore_recipe, { origin = "cook_dotnet.workspace" }, function()
          cook.add_unit({ inputs = context_files, outputs = restore_outputs, command = command, sharing = "local",
              probes = { "dotnet:tool", "dotnet:toolchain" }, seal = { "dotnet:toolchain" } })
      end)
      if selected_projects[project.path] then
          aggregate_outputs[#aggregate_outputs + 1] = restore_outputs[1]
          restore_roots[#restore_roots + 1] = restore_recipe
      end
      for _, framework in ipairs(project.framework_list) do
        local build = project.builds[framework] or project
        local requires, inputs, input_set = {}, {}, {}
        local function add_input(file)
            if not input_set[file] then input_set[file], inputs[#inputs + 1] = true, file end
        end
        for file in pairs(build.files) do add_input(file) end
        add_input(restore_outputs[1])
        for _, file in ipairs(project_context(project, context)) do add_input(file) end
        for _, reference in ipairs(build.references) do
            local dependency = projects[reference.path]
            local dependency_framework = reference.framework or (#dependency.framework_list == 1
                and dependency.framework_list[1] or framework)
            requires[#requires + 1] = recipe_for(dependency, dependency_framework)
            local suffix = output_suffix(dependency, dependency_framework)
            if reference.generator then
                add_input(artifacts .. "/bin/" .. dependency.name .. suffix .. "/**")
            else
                add_input(artifacts .. "/obj/" .. dependency.name .. suffix .. "/ref/*.dll")
            end
        end
        requires[#requires + 1] = restore_recipe
        table.sort(inputs); table.sort(requires)
        local suffix = output_suffix(project, framework)
        local bin = artifacts .. "/bin/" .. project.name .. suffix
        local obj = artifacts .. "/obj/" .. project.name .. suffix
        -- Force SDK-tracked compiler outputs, retaining restore and unaffected framework outputs.
        -- SDK 8 cannot clean removed CopyLocal files outside the project directory.
        -- Reset only this compile unit's bin output; keep restore and compiler state.
        local command = "rm -rf -- " .. quote(bin) .. " && "
            .. environment .. '"$<dotnet:tool.dotnet.path>" build ' .. quote(project.path)
            .. " --artifacts-path " .. quote(artifacts)
            .. " --configuration " .. quote(configuration)
            .. " --no-restore --no-dependencies --no-incremental -p:ProduceReferenceAssembly=true"
            -- SDK 8 and 10 track CopyLocal files differently; sharing their clean ledger
            -- can make SDK 8 delete DLLs it just copied during an SDK 10 -> 8 Rebuild.
            .. " -p:CleanFile=" .. quote("cook-" .. graph.toolchain.sdk .. ".FileListAbsolute.txt")
            .. web_workaround(project, graph.toolchain)
        if framework ~= "" then command = command .. " --framework " .. quote(framework) end
        local project_recipe = recipe_for(project, framework)
        if selected[project_recipe] then
            roots[#roots + 1] = project_recipe
            aggregate_outputs[#aggregate_outputs + 1] = bin .. "/**"
            aggregate_outputs[#aggregate_outputs + 1] = obj .. "/**"
        end
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
                framework = framework,
                frameworks = project.frameworks,
                artifacts = artifacts,
                outputs = { bin .. "/**", obj .. "/**" },
            })
        end)
      end
    end

    local run_recipe
    local function transitive(project, framework, seen, result)
        local key = recipe_for(project, framework)
        if seen[key] then return end
        seen[key] = true
        local build = project.builds[framework] or project
        for _, reference in ipairs(build.references) do
            if not reference.generator then
                local dependency = projects[reference.path]
                transitive(dependency, reference.framework or (#dependency.framework_list == 1
                    and dependency.framework_list[1] or framework), seen, result)
            end
        end
        result[#result + 1] = { project = project, framework = framework }
    end
    local function execution_body(project, framework, kind)
        local build = project.builds[framework] or project
        local closure = {}; transitive(project, framework, {}, closure)
        local run_dir = artifacts .. "/" .. kind .. "/" .. project.name .. output_suffix(project, framework)
        local projection_inputs, copy = {}, { "rm -rf -- " .. quote(run_dir), "mkdir -p -- " .. quote(run_dir) }
        -- Copy each dependency's current output last, after consumers that may carry older copies.
        for i = #closure, 1, -1 do
            local dependency = closure[i]
            local source = artifacts .. "/bin/" .. dependency.project.name
                .. output_suffix(dependency.project, dependency.framework)
            projection_inputs[#projection_inputs + 1] = source .. "/**"
            copy[#copy + 1] = "cp -a " .. quote(source .. "/.") .. " " .. quote(run_dir .. "/")
        end
        return function()
            local arguments, problem = opts.arguments
            if kind == "test" then
                arguments, problem = test_options(opts)
                if not arguments then return reject_run(problem) end
            end
            cook.add_unit({
                inputs = projection_inputs,
                outputs = { run_dir .. "/**" },
                command = table.concat(copy, " && "),
            })
            local command = 'exec "$<dotnet:tool.dotnet.path>" ' .. quote(run_dir .. "/" .. build.target_file)
                .. arguments
            if kind == "test" then
                local results = artifacts .. "/test-results/" .. project.name .. output_suffix(project, framework)
                command = "echo " .. quote("[cook_dotnet.test] " .. project.path .. " (" .. configuration
                    .. ", " .. framework .. ")") .. " && " .. environment
                    .. '"$<dotnet:tool.dotnet.path>" vstest ' .. quote(run_dir .. "/" .. build.target_file)
                    .. " " .. quote("--logger:trx") .. " " .. quote("--ResultsDirectory:" .. results) .. arguments
            end
            cook.add_unit({
                inputs = { run_dir .. "/" .. build.target_file },
                command = command,
                probes = { "dotnet:tool", "dotnet:toolchain" },
                seal = { "dotnet:toolchain" },
                interactive = true,
                cache = false,
                sharing = "local",
            })
        end
    end
    for _, candidate in ipairs(executable_choices) do
        local name = recipe_for(candidate.project, candidate.framework) .. ":run"
        cook.recipe(name, { requires = { recipe_for(candidate.project, candidate.framework) }, origin = "cook_dotnet.workspace" },
            execution_body(candidate.project, candidate.framework, "run"))
        if candidate.project == chosen and candidate.framework == run_framework then run_recipe = name end
    end

    table.sort(roots)
    if mode == "test-execute" then
        cook.require_recipe(recipe_for(chosen, framework_selector))
        execution_body(chosen, framework_selector, "test")()
    elseif mode == "test-restore" then
        for _, name in ipairs(restore_roots) do cook.require_recipe(name) end
    elseif mode == "test" then
        local _, problem = test_options(opts)
        if problem then return reject_run(problem) end
        local commands = { "set -eu", cook.child_command("__dotnet:test:restore"), "found=0" }
        for _, project in ipairs(ordered) do
            if not chosen or project == chosen then
                for _, framework in ipairs(project.framework_list) do
                    if framework_selector == "" or framework_selector == framework then
                        local query = environment .. quote(assert(cook.tools.id("dotnet"), "dotnet not on PATH").path) .. ' msbuild ' .. quote(project.path)
                            .. " -nologo -p:Configuration=" .. quote(configuration)
                            .. ' -p:UseArtifactsOutput=true -p:ArtifactsPath="$(pwd)/"' .. quote(artifacts)
                            .. " -p:TargetFramework=" .. quote(framework) .. " -getProperty:IsTestProject"
                        commands[#commands + 1] = "identity=$(" .. query
                            .. ") || { status=$?; printf '%s\\n' \"$identity\" >&2; exit \"$status\"; }"
                        commands[#commands + 1] = 'case "$identity" in [Tt][Rr][Uu][Ee]) '
                            .. cook.child_command(recipe_for(project, framework) .. ":test")
                            .. '; found=1 ;; [Ff][Aa][Ll][Ss][Ee]|"") ;; *) echo '
                            .. quote("[cook_dotnet.test] invalid IsTestProject for " .. project.path .. " (" .. framework .. "): ")
                            .. '"$identity" >&2; exit 1 ;; esac'
                    end
                end
            end
        end
        commands[#commands + 1] = '[ "$found" = 1 ] || { echo '
            .. quote("[cook_dotnet.test] no test projects matched the selected project/framework") .. ' >&2; exit 1; }'
        cook.add_unit({ command = table.concat(commands, "\n"), cache = false, interactive = true, sharing = "local" })
    elseif mode == "run" then
        if not run_recipe then
            local choices = {}
            for _, candidate in ipairs(executable_choices) do
                choices[#choices + 1] = candidate.project.name .. " (" .. candidate.framework .. ")"
            end
            return reject_run("selected project/framework is not executable; choose one of: "
                .. table.concat(choices, ", "))
        end
        cook.require_recipe(run_recipe)
    else
        for _, root in ipairs(roots) do cook.require_recipe(root) end
        table.sort(aggregate_outputs)
        cook.step_group(function() cook.passthrough(aggregate_outputs) end)
    end
end

local test_workspace
cook.chore("dotnet.test", { origin = "cook_dotnet.workspace" }, function()
    if not test_workspace then
        cook.add_unit({ command = "echo '[cook_dotnet.test] call cook_dotnet.workspace first' >&2; exit 1",
            cache = false, interactive = true })
        return
    end
    test_workspace()
end)

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

    local project = opts.project == nil and "" or opts.project
    local framework = opts.framework == nil and "" or opts.framework
    if type(project) ~= "string" or type(framework) ~= "string" then
        error("[cook_dotnet.workspace] project and framework must be strings", 2)
    end
    if project ~= "" then check_relative("project", project:gsub("\\", "/")) end
    if framework ~= "" and project == "" then
        error("[cook_dotnet.workspace] framework requires a project; set PROJECT and FRAMEWORK together", 2)
    end

    local args = opts.args == nil and {} or opts.args
    if type(args) ~= "table" then error("[cook_dotnet.workspace] args must be a list of strings", 2) end
    local count, arguments = 0, {}
    for key, value in pairs(args) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(value) ~= "string" then
            error("[cook_dotnet.workspace] args must be a list of strings", 2)
        end
        count = count + 1
    end
    for i = 1, count do
        if args[i] == nil then error("[cook_dotnet.workspace] args must be a contiguous list of strings", 2) end
        if args[i]:find("%z") then error("[cook_dotnet.workspace] args cannot contain NUL bytes", 2) end
        arguments[i] = " " .. quote(args[i])
    end

    ensure_toolchain()
    local graph_inputs = cook.resolve_gather(workspace_globs(root, solution, false),
        { "**/bin/**", "**/obj/**", ".git/**", ".cook/**", artifacts .. "/**" })
    local inputs = cook.resolve_gather(workspace_globs(root, solution, true),
        { "**/bin/**", "**/obj/**", ".git/**", ".cook/**", artifacts .. "/**" })
    -- Membership refreshes SDK evaluation; source bytes key only the builds that consume them.
    local inventory = cook.resolve_gather({ root == "." and "**" or root .. "/**" },
        { "**/bin/**", "**/obj/**", ".git/**", ".cook/**", artifacts .. "/**" })
    table.sort(inventory)
    local graph = cook.materialize("graph", { files = graph_inputs, tools = { "dotnet" }, seals = { "dotnet:toolchain" } },
        discovery.producer(solution, configuration, inventory))
    local settings = { artifacts = artifacts, configuration = configuration, root = root,
        project = project, framework = framework, arguments = table.concat(arguments),
        test_filter = opts.test_filter, test_args = opts.test_args }
    test_workspace = function() mint_graph(settings, "test", inputs, graph) end
    -- Register only the new test names here. Their build/projection bodies remain deferred.
    local test_names = {}
    for _, entry in ipairs(graph.projects) do
        local info = discover_project(entry.path, entry.value)
        local frameworks = target_frameworks(info)
        if #frameworks == 0 then frameworks[1] = "" end
        for _, framework in ipairs(frameworks) do
            local name = project_recipe(info, framework) .. ":test"
            if test_names[name] then
                error("[cook_dotnet.workspace] projects '" .. test_names[name] .. "' and '"
                    .. entry.path .. "' map to the same recipe '" .. name .. "'", 2)
            end
            test_names[name] = entry.path
            cook.recipe(name, { origin = "cook_dotnet.workspace" }, function()
                mint_graph(settings, "test-execute", inputs, graph, { project = entry.path, framework = framework })
            end)
        end
    end
    cook.recipe("dotnet:build", { origin = "cook_dotnet.workspace" }, function()
        mint_graph(settings, "build", inputs, graph)
    end)
    cook.recipe("dotnet:run", { origin = "cook_dotnet.workspace" }, function()
        mint_graph(settings, "run", inputs, graph)
    end)
    cook.recipe("__dotnet:test:restore", { origin = "cook_dotnet.workspace" }, function()
        mint_graph(settings, "test-restore", inputs, graph)
    end)
    cook.recipe("dotnet:test", { requires = { "dotnet.test" }, origin = "cook_dotnet.workspace" }, function() end)
    return { "dotnet:build", "dotnet:run", "dotnet:test" }
end

return M
