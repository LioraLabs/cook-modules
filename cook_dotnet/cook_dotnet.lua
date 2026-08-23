local M = { name = "cook_dotnet" }
local discovery = require("cook_dotnet.discovery")
local probe_registered = false

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
    if probe_registered then return "dotnet:toolchain" end
    cook.probe("dotnet:toolchain", {
        inputs = { tools = { "dotnet" } },
        produce = [[
            local dotnet = cook.sh("command -v dotnet 2>/dev/null"):match("^(%S+)")
            if not dotnet then error("[cook_dotnet] dotnet not on PATH") end
            return { dotnet = dotnet }
        ]],
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
    local probe = ensure_toolchain()

    -- ponytail: shared CLI/NuGet caches; split per SDK only if dotnet proves they conflict.
    local command = "rm -rf -- " .. quote(artifacts)
        .. ' && DOTNET_CLI_HOME="$(pwd)/.cook/dotnet/home"'
        .. ' NUGET_PACKAGES="$(pwd)/.cook/dotnet/packages"'
        .. " DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 "
        .. '"$<' .. probe .. '.dotnet>" build ' .. quote(opts.project)
        .. " --artifacts-path " .. quote(artifacts)
        .. " --configuration " .. quote(opts.configuration or "Debug")
    if opts.framework then command = command .. " --framework " .. quote(opts.framework) end

    -- Cleanup lives inside the cached unit: misses start fresh; hits skip it.
    cook.add_unit({
        inputs = inputs,
        outputs = { artifacts .. "/**" },
        command = command,
        probes = { probe },
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
            references[#references + 1] = path
        end
    end
    table.sort(references)
    return {
        path = project,
        name = props.MSBuildProjectName,
        framework = props.TargetFramework,
        frameworks = props.TargetFrameworks,
        output_type = props.OutputType,
        target_file = props.TargetFileName,
        files = files,
        references = references,
    }
end

local function read_manifest(pathname)
    local chunk, err = load(fs.read(pathname), "@" .. pathname, "t", {})
    if not chunk then error("[cook_dotnet.workspace] invalid discovery manifest: " .. tostring(err), 2) end
    local ok, value = pcall(chunk)
    if not ok or type(value) ~= "table" or type(value.projects) ~= "table" then
        error("[cook_dotnet.workspace] invalid discovery manifest: " .. tostring(value), 2)
    end
    return value
end

local function recipe_segment(name)
    return (name:gsub("[^A-Za-z0-9_+-]", "-"))
end

local function mint_graph(opts, mode, context_files)
    local artifact = cook.materialize("dotnet:discover")
    local manifest = read_manifest(artifact)
    local artifacts, configuration = opts.artifacts, opts.configuration
    local context = {}
    for _, file in ipairs(context_files) do
        local base = file:match("([^/]+)$") or file
        if base == "Directory.Build.props" or base == "Directory.Build.targets"
            or base == "Directory.Packages.props" or base == "global.json"
            or base == "NuGet.config" or base == "packages.lock.json" or base == ".editorconfig"
        then context[file] = true end
    end

    local projects = {}
    for _, entry in ipairs(manifest.projects) do
        local info = discover_project(entry.path, entry.value)
        projects[info.path] = info
    end

    local by_name = {}
    for _, project in pairs(projects) do
        project.recipe = "dotnet:" .. recipe_segment(project.name)
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
        for _, reference in ipairs(project.references) do visit(reference) end
        visiting[pathname], visited[pathname] = nil, true
        ordered[#ordered + 1] = project
    end
    local paths = {}; for path in pairs(projects) do paths[#paths + 1] = path end; table.sort(paths)
    for _, path in ipairs(paths) do visit(path) end

    for _, project in ipairs(ordered) do
        local requires, inputs, input_set = {}, {}, {}
        local function add_input(file)
            if not input_set[file] then input_set[file], inputs[#inputs + 1] = true, file end
        end
        for file in pairs(project.files) do add_input(file) end
        for file in pairs(context) do add_input(file) end
        local project_dir = directory(project.path)
        for _, file in ipairs(cook.resolve_gather({ join(project_dir, "**") }, {
            join(project_dir, "bin/**"), join(project_dir, "obj/**"),
            join(project_dir, "**/bin/**"), join(project_dir, "**/obj/**"),
            join(project_dir, ".git/**"), join(project_dir, ".cook/**"), artifacts .. "/**",
        })) do add_input(file) end
        for _, reference in ipairs(project.references) do
            local dependency = projects[reference]
            requires[#requires + 1] = dependency.recipe
            add_input(artifacts .. "/obj/" .. dependency.name .. "/**/ref/*.dll")
        end
        table.sort(inputs); table.sort(requires)
        local bin = artifacts .. "/bin/" .. project.name
        local obj = artifacts .. "/obj/" .. project.name
        local environment = 'DOTNET_CLI_HOME="$(pwd)/.cook/dotnet/home"'
            .. ' NUGET_PACKAGES="$(pwd)/.cook/dotnet/packages"'
            .. " DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 "
        local command = "rm -rf -- " .. quote(bin) .. " " .. quote(obj)
            .. " && " .. environment .. '"$<dotnet:toolchain.dotnet>" restore ' .. quote(project.path)
            .. " --artifacts-path " .. quote(artifacts)
            .. " -p:RestoreRecursive=false --verbosity quiet"
            .. " && " .. environment .. '"$<dotnet:toolchain.dotnet>" build ' .. quote(project.path)
            .. " --artifacts-path " .. quote(artifacts)
            .. " --configuration " .. quote(configuration)
            .. " --no-restore --no-dependencies -p:UseCommonOutputDirectory=true"
        cook.recipe(project.recipe, { requires = requires, origin = "cook_dotnet.workspace" }, function()
            cook.add_unit({
                inputs = inputs,
                outputs = { bin .. "/**", obj .. "/**" },
                command = command,
                probes = { "dotnet:toolchain" },
            })
            cook.export(project.recipe, {
                project = project.path,
                name = project.name,
                framework = project.framework,
                frameworks = project.frameworks,
                artifacts = artifacts,
                outputs = { bin .. "/**", obj .. "/**" },
            })
        end)
    end

    local executables = {}
    local function transitive(project, seen, result)
        if seen[project.path] then return end
        seen[project.path] = true
        for _, reference in ipairs(project.references) do transitive(projects[reference], seen, result) end
        result[#result + 1] = project
    end
    for _, project in ipairs(ordered) do
        if (project.output_type == "Exe" or project.output_type == "WinExe")
            and project.framework ~= "" and project.frameworks == "" and project.target_file ~= ""
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
                    command = '"$<dotnet:toolchain.dotnet>" ' .. quote(run_dir .. "/" .. project.target_file),
                    probes = { "dotnet:toolchain" },
                    cache = false,
                    sharing = "local",
                })
            end)
            executables[#executables + 1] = run_recipe
        end
    end

    local roots = {}; for _, project in ipairs(ordered) do roots[#roots + 1] = project.recipe end
    table.sort(roots)
    if mode == "run" then
        if #executables ~= 1 then error("[cook_dotnet.workspace] dotnet:run requires exactly one single-target executable; found "
            .. #executables, 2) end
        cook.require_recipe(executables[1])
    else
        for _, root in ipairs(roots) do cook.require_recipe(root) end
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
    local artifacts = opts.artifacts or "build/dotnet"
    check_relative("artifacts", artifacts)
    local configuration = opts.configuration or "Debug"
    if type(configuration) ~= "string" or configuration == "" then
        error("[cook_dotnet.workspace] configuration must be a non-empty string", 2)
    end

    ensure_toolchain()
    local inputs = cook.resolve_gather({ solution, "**/*.csproj", "**/*.props", "**/*.targets",
        "**/global.json", "**/NuGet.config", "**/nuget.config", "**/packages.lock.json", "**/.editorconfig" },
        { "**/bin/**", "**/obj/**", ".git/**", ".cook/**", artifacts .. "/**" })
    local manifest = artifacts .. "/discovery.lua"
    cook.recipe("dotnet:discover", { origin = "cook_dotnet.workspace" }, function()
        cook.add_unit({
            inputs = inputs,
            output = manifest,
            lua_code = discovery.code(solution, manifest, configuration),
            probes = { "dotnet:toolchain" },
        })
    end)
    local settings = { artifacts = artifacts, configuration = configuration }
    cook.recipe("dotnet:build", { origin = "cook_dotnet.workspace" }, function()
        mint_graph(settings, "build", inputs)
    end)
    cook.recipe("dotnet:run", { origin = "cook_dotnet.workspace" }, function()
        mint_graph(settings, "run", inputs)
    end)
    return { "dotnet:build", "dotnet:run" }
end

return M
