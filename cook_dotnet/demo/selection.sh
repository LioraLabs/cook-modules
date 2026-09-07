#!/bin/sh
set -eu
module_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export COOK_DOTNET_SOURCE="$module_dir"
python3 - <<'PY'
import hashlib, os, pathlib, shutil, subprocess, tempfile
source = pathlib.Path(os.environ['COOK_DOTNET_SOURCE'])
cook = os.environ.get('COOK', 'cook')
native = shutil.which('dotnet')
with tempfile.TemporaryDirectory(prefix='cook-dotnet-selection.') as tmp:
    root = pathlib.Path(tmp)
    shutil.copy2(source / 'cook_dotnet.lua', root)
    shutil.copytree(source / 'cook_dotnet', root / 'cook_dotnet')
    proof = root / '.cook/proof'; proof.mkdir(parents=True)
    env = {**os.environ, 'XDG_CACHE_HOME': str(root / '.cook/cache'), 'DOTNET_CLI_HOME': str(root / '.cook/dotnet/home'),
           'NUGET_PACKAGES': str(root / '.cook/dotnet/packages'), 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE': '1', 'DOTNET_NOLOGO': '1'}
    def run(args, name, success=True):
        p = subprocess.run(args, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (proof / (name + '.log')).write_text(p.stdout)
        assert (p.returncode == 0) == success, name + '\n' + p.stdout[-6000:]
        return p.stdout
    (root / 'global.json').write_text('{"sdk":{"version":"10.0.111","rollForward":"disable"}}')
    names = ['App', 'Lib', 'ReleaseLib', 'Other', 'Bad']
    for name in names:
        directory = root / name; directory.mkdir()
        properties = '<TargetFrameworks>net8.0;net10.0</TargetFrameworks><OutputType>Exe</OutputType><EnableDefaultCompileItems>false</EnableDefaultCompileItems>' if name == 'App' else '<TargetFramework>netstandard2.1</TargetFramework>'
        items = '''<ItemGroup><Compile Include="Program.cs"/><Compile Include="Debug.cs" Condition="'$(Configuration)' != 'Release'"/><Compile Include="Release.cs" Condition="'$(Configuration)' == 'Release'"/><ProjectReference Include="../Lib/Lib.csproj" Condition="'$(Configuration)' != 'Release'"/><ProjectReference Include="../ReleaseLib/ReleaseLib.csproj" Condition="'$(Configuration)' == 'Release'"/></ItemGroup>''' if name == 'App' else ''
        target = '''<Target Name="FailUnselected" BeforeTargets="CoreCompile"><Error Condition="!Exists('$(MSBuildProjectDirectory)/allow')" Text="UNRELATED_BODY_EXECUTED"/></Target>''' if name == 'Bad' else ''
        (directory / (name + '.csproj')).write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>' + properties + '</PropertyGroup>' + items + target + '</Project>')
        if name != 'App': (directory / 'Code.cs').write_text('public class ' + ('Library' if name in ['Lib', 'ReleaseLib'] else name) + ' { public static string Text => "' + name + '"; }')
    (root / 'App/Program.cs').write_text('System.Console.WriteLine(Label.Text + ":" + Library.Text);')
    (root / 'App/Debug.cs').write_text('public class Label { public static string Text => "debug"; }')
    (root / 'App/Release.cs').write_text('public class Label { public static string Text => "release"; }')
    run([native, 'new', 'sln', '-n', 'Graph', '--format', 'sln'], 'solution')
    run([native, 'sln', 'Graph.sln', 'add', *[n + '/' + n + '.csproj' for n in names]], 'add-projects')
    (root / 'Cookfile').write_text('''use cook_dotnet ./cook_dotnet.lua
config
    var.PROJECT = ""
    var.CONFIGURATION = "Debug"
    var.FRAMEWORK = ""
cook_dotnet.workspace({ solution = "Graph.sln", project = var.PROJECT, configuration = var.CONFIGURATION, framework = var.FRAMEWORK })
''')
    bindir = proof / 'bin'; bindir.mkdir()
    wrapper = bindir / 'dotnet'
    wrapper.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
if len(sys.argv) > 1 and sys.argv[1] in ('msbuild', 'sln'):
    with open(os.environ['DISCOVERY_LOG'], 'a') as log: log.write('query\\n')
sys.exit(subprocess.run([os.environ['REAL_DOTNET'], *sys.argv[1:]]).returncode)
''')
    wrapper.chmod(0o755)
    queries = proof / 'queries'; queries.write_text('')
    env.update(PATH=str(bindir) + ':' + env['PATH'], REAL_DOTNET=native, DISCOVERY_LOG=str(queries))
    def build(project='', framework='', configuration='Debug', name='build', success=True, why=False):
        args = [cook] + (['why'] if why else []) + ['dotnet:build', '--set', 'PROJECT=' + project,
                '--set', 'FRAMEWORK=' + framework, '--set', 'CONFIGURATION=' + configuration, '--color', 'never']
        return run(args, name, success)
    build('App', 'net8.0', name='selected-first')
    assert not (root / 'build/dotnet/bin/Other').exists()
    assert not (root / 'build/dotnet/bin/App/debug_net10.0').exists()
    count = queries.read_text()
    why = build('App', 'net8.0', name='selected-why', why=True)
    assert 'dotnet:Other' not in why and 'dotnet:Bad' not in why
    build('Other', name='other')
    build('App/./App.csproj', name='all-selected-frameworks')
    assert (root / 'build/dotnet/bin/App/debug_net10.0/App.dll').is_file()
    assert queries.read_text() == count, 'project/framework selection rediscovered the graph'
    (root / 'Bad/allow').write_text('allow explicit whole build')
    build(name='whole')
    siblings = [root / p for p in ['build/dotnet/bin/Other/debug/Other.dll', 'build/dotnet/bin/Bad/debug/Bad.dll', 'build/dotnet/bin/App/debug_net10.0/App.dll', 'build/dotnet/obj/App/debug_net10.0/ref/App.dll', 'build/dotnet/obj/Other/debug/ref/Other.dll', 'build/dotnet/obj/Other/project.assets.json']]
    before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in siblings}
    count = queries.read_text()
    build('App', 'net8.0', name='narrow-after-whole')
    assert all(p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest() == before[str(p)] for p in siblings), 'selection swept or changed unselected outputs'
    assert queries.read_text() == count, 'warm narrowing rediscovered the graph'
    for configuration, dependency in [('Debug', 'Lib'), ('Release', 'ReleaseLib'), ('Custom', 'Lib')]:
        build('App', 'net8.0', configuration, name='configuration-' + configuration)
        run([native, 'build', 'App/App.csproj', '--configuration', configuration, '--framework', 'net8.0', '--artifacts-path', str(root / '.cook/native'), '--verbosity', 'quiet'], 'native-' + configuration)
        projected = proof / 'run'; shutil.rmtree(projected, ignore_errors=True)
        shutil.copytree(root / ('build/dotnet/bin/App/' + configuration.lower() + '_net8.0'), projected)
        shutil.copytree(root / ('build/dotnet/bin/' + dependency + '/' + configuration.lower()), projected, dirs_exist_ok=True)
        actual = run([native, str(projected / 'App.dll')], 'actual-' + configuration)
        expected = run([native, str(root / ('.cook/native/bin/App/' + configuration.lower() + '_net8.0/App.dll'))], 'expected-' + configuration)
        assert actual == expected, 'selected assembly behavior differs from native MSBuild'
    assert 'choose one of:' in build('Unknown', name='unknown', success=False)
    assert 'choose one of:' in build('App', 'net9.0', name='unknown-framework', success=False)
    assert 'framework requires a project' in build('', 'net8.0', name='missing-project', success=False)
    for folder in ['First', 'Second']:
        (root / folder).mkdir()
        (root / folder / 'Same.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>')
        run([native, 'sln', 'Graph.sln', 'add', folder + '/Same.csproj'], 'add-' + folder)
    error = build('App', 'net8.0', name='ambiguous', success=False)
    assert 'First/Same.csproj' in error and 'Second/Same.csproj' in error and 'same recipe' in error
print('cook_dotnet selected build/why passed; native outputs, warm discovery and sibling ownership preserved')
PY
