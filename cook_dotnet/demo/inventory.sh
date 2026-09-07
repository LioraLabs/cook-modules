#!/bin/sh
set -eu
module_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export COOK_DOTNET_SOURCE="$module_dir"
python3 - <<'PY'
import json, os, pathlib, shutil, subprocess, tempfile, zipfile
source = pathlib.Path(os.environ['COOK_DOTNET_SOURCE'])
cook, native = os.environ.get('COOK', 'cook'), shutil.which('dotnet')
export = os.environ.get('COOK_DOTNET_PROOF_DIR')
with tempfile.TemporaryDirectory(prefix='cook-dotnet-inventory.') as temporary:
    root = pathlib.Path(temporary)
    proof = root / '.cook/proof'; proof.mkdir(parents=True)
    for relative in ['cook_dotnet.lua', 'cook_dotnet/discovery.lua']:
        path = root / relative; path.parent.mkdir(exist_ok=True)
        baseline = os.environ.get('COOK_DOTNET_INVENTORY_BASELINE')
        path.write_bytes(subprocess.check_output(['git', 'show', baseline + ':cook_dotnet/' + relative], cwd=source) if baseline else (source / relative).read_bytes())
    env = {**os.environ, 'XDG_CACHE_HOME': str(root / '.cook/cache'), 'DOTNET_CLI_HOME': str(root / '.cook/dotnet/home'),
        'NUGET_PACKAGES': str(root / '.cook/dotnet/packages'), 'DOTNET_NOLOGO': '1', 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE': '1'}
    observer = proof / 'commands.jsonl'; observer.write_text('')
    wrapper = proof / 'bin'; wrapper.mkdir()
    (wrapper / 'dotnet').write_text('#!/usr/bin/env python3\nimport os,sys,json\nwith open(os.environ["SDK_OBSERVER"],"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\nos.execv(os.environ["REAL_DOTNET"],[os.environ["REAL_DOTNET"],*sys.argv[1:]])\n')
    (wrapper / 'dotnet').chmod(0o755)
    env.update(PATH=str(wrapper) + ':' + env['PATH'], SDK_OBSERVER=str(observer), REAL_DOTNET=native)
    def calls(): return [json.loads(line) for line in observer.read_text().splitlines()]
    def run(args, name, refresh=None, contains=None):
        start = len(calls())
        result = subprocess.run(args, cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (proof / (name + '.log')).write_text(result.stdout)
        if export: shutil.copytree(proof, export, dirs_exist_ok=True)
        assert result.returncode == 0, name + '\n' + result.stdout
        native_queries = [c for c in calls()[start:] if c[0] == 'msbuild']
        if refresh is not None: assert bool(native_queries) == refresh, (name, native_queries, result.stdout)
        if contains is not None: assert contains in result.stdout, (name, result.stdout)
        return result.stdout
    def check(name, refresh, contains=None):
        return run([cook, 'dotnet:run', '--color', 'never'], name, refresh, contains)
    (root / 'global.json').write_text('{"sdk":{"version":"10.0.111","rollForward":"disable"}}')
    (root / 'Cookfile').write_text('use cook_dotnet ./cook_dotnet.lua\ncook_dotnet.workspace({ solution = "App/App.csproj", project = "App" })\n')
    for name in ['App', 'custom', 'empty', 'literal', 'frontend/output']:
        (root / name).mkdir(parents=True)
    project = root / 'App/App.csproj'
    project.write_text('''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup><ItemGroup><Compile Include="../custom/**/*.source"/><Content Include="../empty/**/*.blob" CopyToOutputDirectory="PreserveNewest"/><None Include="../literal/missing.data"/></ItemGroup></Project>''')
    (root / 'App/Program.cs').write_text('System.Console.WriteLine("TYPES=" + string.Join(",", System.Linq.Enumerable.OrderBy(System.Linq.Enumerable.Select(System.Linq.Enumerable.Where(System.Reflection.Assembly.GetExecutingAssembly().GetTypes(), t => !t.Name.StartsWith("<")), t => t.Name), n => n)));')
    # Generated NuGet imports from an ordinary native restore are not authored conditions.
    run([native, 'restore', 'App/App.csproj'], 'native-default-restore')
    check('cold', True, 'TYPES=Program')
    check('warm', False, 'TYPES=Program')
    frontend = root / 'frontend/output/first.js'; frontend.write_text('first')
    check('frontend-add', False)
    frontend.rename(frontend.with_name('second.js'))
    check('frontend-rename', False)
    frontend.with_name('second.js').unlink()
    check('frontend-remove', False)
    added = root / 'App/Added.cs'; added.write_text('class Added {}')
    check('source-add', True, 'TYPES=Added,Program')
    # Returning to a previously seen membership may restore that graph without a native query.
    added.unlink(); check('source-remove', None, 'TYPES=Program')
    custom = root / 'custom/deep/Custom.source'; custom.parent.mkdir(); custom.write_text('class Custom {}')
    check('custom-empty-glob-add', True, 'TYPES=Custom,Program')
    custom.unlink(); check('custom-remove', None, 'TYPES=Program')
    content = root / 'empty/nested/asset.blob'; content.parent.mkdir(); content.write_text('native-content')
    check('content-empty-glob-add', True)
    assert any(p.read_text() == 'native-content' for p in (root / 'build/dotnet/bin/App').rglob('asset.blob'))
    content.unlink(); check('content-remove', None)
    assert not list((root / 'build/dotnet/bin/App').rglob('asset.blob'))
    literal = root / 'literal/missing.data'; literal.write_text('now present')
    check('missing-literal-add', True); literal.unlink(); check('literal-remove', None)
    # Authored conditional imports can depend on files outside every currently evaluated glob.
    (root / 'Directory.Build.props').write_text('''<Project><Import Project="conditional.props" Condition="Exists('conditional.props')"/></Project>''')
    check('conditional-import-declaration', True)
    (root / 'conditional.props').write_text('''<Project><ItemGroup><Compile Include="$(MSBuildThisFileDirectory)hidden/**/*.odd" Condition="Exists('$(MSBuildThisFileDirectory)activate')"/></ItemGroup></Project>''')
    (root / 'hidden').mkdir(); (root / 'hidden/Hidden.odd').write_text('class Hidden {}')
    check('conditional-import-add', True, 'TYPES=Program')
    (root / 'activate').write_text('yes'); check('condition-activation', True, 'TYPES=Hidden,Program')
    (root / 'activate').unlink(); check('condition-deactivation', None, 'TYPES=Program')
    (root / 'Directory.Build.props').unlink(); (root / 'conditional.props').unlink()
    (root / 'dynamic').mkdir()
    project.write_text(project.read_text().replace('</Project>', "<ItemGroup><Compile Include=\"$([System.IO.Directory]::GetFiles('$(MSBuildThisFileDirectory)../dynamic', '*.source'))\"/></ItemGroup></Project>"))
    check('dynamic-declaration', True, 'TYPES=Program')
    (root / 'dynamic/Dynamic.source').write_text('class Dynamic {}')
    check('dynamic-add', True, 'TYPES=Dynamic,Program')
    (root / 'Library').mkdir(); (root / 'Library/Library.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>')
    (root / 'Library/Class.cs').write_text('public class Library {}')
    project.write_text(project.read_text().replace('</Project>', '<ItemGroup><ProjectReference Include="../Library/Library.csproj"/></ItemGroup></Project>'))
    check('project-add', True)
    assert (root / 'build/dotnet/bin/Library/debug/Library.dll').is_file()
    # Native wildcard imports may use arbitrary extensions outside every item glob.
    (root / 'rules').mkdir(); (root / 'rule-source').mkdir()
    project.write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup><Import Project="../rules/*.rules"/></Project>')
    check('import-glob-cold', True, 'TYPES=Program')
    (root / 'rules/included.rules').write_text('<Project><ItemGroup><Compile Include="$(MSBuildThisFileDirectory)../rule-source/*.rulecode"/></ItemGroup></Project>')
    (root / 'rule-source/Imported.rulecode').write_text('class Imported {}')
    check('import-glob-add', True, 'TYPES=Imported,Program')
    # A native glob rooted above configured root still intersects that root.
    (root / 'backend/App').mkdir(parents=True)
    (root / 'backend/App/App.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup><ItemGroup><Compile Include="../../**/*.ancestral"/></ItemGroup></Project>')
    shutil.copy2(root / 'App/Program.cs', root / 'backend/App/Program.cs')
    (root / 'RootCookfile').write_text('use cook_dotnet ./cook_dotnet.lua\ncook_dotnet.workspace({ solution = "backend/App/App.csproj", root = "backend", project = "App", artifacts = "build/intersection" })\n')
    scoped = [cook, '--file', 'RootCookfile', 'dotnet:run', '--color', 'never']
    run(scoped, 'ancestor-root-cold', True, 'TYPES=Program')
    (root / 'backend/shared').mkdir(); (root / 'backend/shared/Ancestor.ancestral').write_text('class Ancestor {}')
    run(scoped, 'ancestor-root-add', True, 'TYPES=Ancestor,Program')
    # NuGet build props are authored input rules, not generated restore wrappers.
    feed = root / '.cook/feed'; feed.mkdir()
    with zipfile.ZipFile(feed / 'inventorywitness.1.0.0.nupkg', 'w') as package:
        package.writestr('InventoryWitness.nuspec', '<package><metadata><id>InventoryWitness</id><version>1.0.0</version><authors>proof</authors><description>proof</description></metadata></package>')
        package.writestr('build/InventoryWitness.props', '''<Project><ItemGroup><Compile Include="$(MSBuildProjectDirectory)/../package-generated/*.cs" Condition="Exists('$(MSBuildProjectDirectory)/../package-activate')"/></ItemGroup></Project>''')
    (root / 'NuGet.config').write_text('<configuration><packageSources><clear/><add key="proof" value=".cook/feed"/><add key="nuget" value="https://api.nuget.org/v3/index.json"/></packageSources></configuration>')
    (root / 'PackageApp').mkdir(); (root / 'package-generated').mkdir()
    (root / 'PackageApp/PackageApp.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup><ItemGroup><PackageReference Include="InventoryWitness" Version="1.0.0"/></ItemGroup></Project>')
    shutil.copy2(root / 'App/Program.cs', root / 'PackageApp/Program.cs')
    (root / 'PackageCookfile').write_text('use cook_dotnet ./cook_dotnet.lua\ncook_dotnet.workspace({ solution = "PackageApp/PackageApp.csproj", project = "PackageApp", artifacts = "build/package" })\n')
    package_command = [cook, '--file', 'PackageCookfile', 'dotnet:run', '--color', 'never']
    with tempfile.TemporaryDirectory(prefix='cook-package-cache.') as external_cache:
        for sdk, cache in [('10.0.111', str(root / '.cook/dotnet/packages')), ('8.0.424', external_cache)]:
            (root / 'global.json').write_text(json.dumps({'sdk': {'version': sdk, 'rollForward': 'disable'}}))
            previous_cache = env['NUGET_PACKAGES']; env['NUGET_PACKAGES'] = cache
            try:
                run([native, 'restore', 'PackageApp/PackageApp.csproj'], 'package-native-restore-' + sdk)
            finally:
                env['NUGET_PACKAGES'] = previous_cache
            run(package_command, 'package-cold-' + sdk, True, 'TYPES=Program')
            run(package_command, 'package-warm-' + sdk, False, 'TYPES=Program')
            (root / 'package-activate').write_text('yes')
            hidden = root / 'package-generated/Hidden.cs'; hidden.write_text('class Hidden {}')
            native_items = run([native, 'msbuild', 'PackageApp/PackageApp.csproj', '-nologo', '-getItem:Compile'], 'package-native-items-' + sdk)
            assert 'Hidden.cs' in native_items, native_items
            run(package_command, 'package-activated-' + sdk, True, 'TYPES=Hidden,Program')
            (root / 'package-activate').unlink(); hidden.unlink()
            run(package_command, 'package-deactivated-' + sdk, None, 'TYPES=Program')
    # Relevance collection must leave the graph's established boundary diagnostic intact.
    with tempfile.TemporaryDirectory(prefix='cook-dotnet-outside.') as outside:
        reference = pathlib.Path(outside) / 'Outside.csproj'; reference.write_text('<invalid')
        project.write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup><ItemGroup><ProjectReference Include="' + str(reference) + '"/></ItemGroup></Project>')
        result = subprocess.run([cook, 'menu', '--color', 'never'], cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (proof / 'outside-reference.log').write_text(result.stdout)
        if export: shutil.copytree(proof, export, dirs_exist_ok=True)
        assert result.returncode != 0 and 'project reference outside the Cook workspace' in result.stdout, result.stdout
    print('PASS: unrelated frontend membership cached; native source/custom/empty/literal/conditional/project membership refreshed')
PY
