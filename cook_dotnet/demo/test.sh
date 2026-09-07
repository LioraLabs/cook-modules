#!/bin/sh
set -eu
module_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export COOK_DOTNET_SOURCE="$module_dir"
python3 - <<'PY'
import hashlib, json, os, pathlib, shutil, subprocess, tempfile, xml.etree.ElementTree as ET
source = pathlib.Path(os.environ['COOK_DOTNET_SOURCE'])
cook, native = os.environ.get('COOK', 'cook'), shutil.which('dotnet')
with tempfile.TemporaryDirectory(prefix='cook-dotnet-test.') as tmp:
    root = pathlib.Path(tmp)
    proof = root / '.cook/proof'; proof.mkdir(parents=True)
    shutil.copy2(source / 'cook_dotnet.lua', root)
    shutil.copytree(source / 'cook_dotnet', root / 'cook_dotnet')
    packages = root / '.cook/dotnet/packages'
    seed = os.environ.get('COOK_DOTNET_TEST_PACKAGES')
    if seed: shutil.copytree(seed, packages)
    env = {**os.environ, 'XDG_CACHE_HOME': str(root / '.cook/cache'),
        'DOTNET_CLI_HOME': str(root / '.cook/dotnet/home'), 'NUGET_PACKAGES': str(packages),
        'DOTNET_NOLOGO': '1', 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE': '1'}
    def run(args, name, status=0, cwd=None):
        p = subprocess.run(args, cwd=cwd or root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (proof / (name + '.log')).write_text(p.stdout)
        assert p.returncode == status, name + ': exit ' + str(p.returncode) + '\n' + p.stdout
        return p.stdout
    (root / 'global.json').write_text('{"sdk":{"version":"10.0.111","rollForward":"disable"}}')
    (root / 'Directory.Build.props').write_text('<Project><PropertyGroup><NuGetAudit>false</NuGetAudit></PropertyGroup></Project>')
    names = ['Tests', 'Second', 'Leaf', 'Other']
    for name in names:
        directory = root / name; directory.mkdir()
        props = '<TargetFrameworks>net8.0;net10.0</TargetFrameworks>' if name == 'Tests' else '<TargetFramework>net8.0</TargetFramework>'
        refs = ''
        if name in ['Tests', 'Second']:
            refs = '<ItemGroup><PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.12.0"/><PackageReference Include="xunit" Version="2.9.2"/><PackageReference Include="xunit.runner.visualstudio" Version="2.8.2"/><ProjectReference Include="../Leaf/Leaf.csproj"/></ItemGroup>'
        if name == 'Other':
            props += '<OutputType>Exe</OutputType>'
            refs = '<Target Name="FailUnselected" BeforeTargets="CoreCompile"><Error Text="UNRELATED_BODY_EXECUTED"/></Target>'
        (directory / (name + '.csproj')).write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>' + props + '</PropertyGroup>' + refs + '</Project>')
    leaf = root / 'Leaf/Code.cs'
    leaf.write_text('public class Leaf { public static string Value() => "original"; }')
    (root / 'Other/Program.cs').write_text('System.Console.WriteLine("other");')
    for name in ['Tests', 'Second']:
        (root / name / 'Tests.cs').write_text('''using Xunit;
public class NativeTests {
 [Fact] public void Pass() { Assert.Equal(System.Environment.GetEnvironmentVariable("EXPECTED_VALUE"), Leaf.Value()); }
 [Fact] public void Fail() { Assert.True(false, "EXPECTED_NATIVE_FAILURE"); }
}
''')
    env['EXPECTED_VALUE'] = 'original'
    run([native, 'new', 'sln', '-n', 'Tests', '--format', 'sln'], 'solution')
    run([native, 'sln', 'Tests.sln', 'add', *[n + '/' + n + '.csproj' for n in names]], 'add')
    # No authored IsTestProject: the Test SDK supplies it only through restored imports.
    clean = run([native, 'msbuild', 'Tests/Tests.csproj', '-nologo', '-p:TargetFramework=net8.0', '-getProperty:IsTestProject'], 'clean-identity')
    assert clean.strip() == '', clean
    (root / 'Cookfile').write_text('''use cook_dotnet ./cook_dotnet.lua
config
    var.PROJECT = ""
    var.CONFIGURATION = "Debug"
    var.FRAMEWORK = ""
    var.TEST_FILTER = "FullyQualifiedName~Pass"
    var.TEST_ARGS = "[]"
cook_dotnet.workspace({ solution = "Tests.sln", project = var.PROJECT, configuration = var.CONFIGURATION,
    framework = var.FRAMEWORK, test_filter = var.TEST_FILTER, test_args = cook.json_decode(var.TEST_ARGS) })
''')
    wrapper = proof / 'bin'; wrapper.mkdir()
    observer = proof / 'commands.jsonl'; observer.write_text('')
    (wrapper / 'dotnet').write_text('#!/usr/bin/env python3\nimport os,sys,json\nwith open(os.environ["SDK_OBSERVER"],"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\nif "-getProperty:IsTestProject" in sys.argv and os.environ.get("IDENTITY_FAULT"):\n print("malformed identity" if os.environ["IDENTITY_FAULT"] == "malformed" else "NATIVE_QUERY_FAILED"); sys.exit(0 if os.environ["IDENTITY_FAULT"] == "malformed" else 17)\nos.execv(os.environ["REAL_DOTNET"],[os.environ["REAL_DOTNET"],*sys.argv[1:]])\n')
    (wrapper / 'dotnet').chmod(0o755)
    env.update(PATH=str(wrapper) + ':' + env['PATH'], SDK_OBSERVER=str(observer), REAL_DOTNET=native)
    def calls(): return [json.loads(line) for line in observer.read_text().splitlines()]
    def command(project='', framework='', config='Debug', test_filter='FullyQualifiedName~Pass', args=()):
        return [cook, 'dotnet:test', '--set', 'PROJECT=' + project, '--set', 'FRAMEWORK=' + framework,
            '--set', 'CONFIGURATION=' + config, '--set', 'TEST_FILTER=' + test_filter,
            '--set', 'TEST_ARGS=' + json.dumps(args), '--color', 'never']
    menu = run([cook, 'menu', '--color', 'never'], 'menu-cold')
    assert not [c for c in calls() if c[0] in ['restore', 'build', 'vstest'] or '-getProperty:IsTestProject' in c]
    run([cook, 'dotnet:Second:test', '--color', 'never'], 'direct-cold')
    assert 'dotnet:Second:test' in menu
    first = run(command(), 'all-clean')
    assert len([c for c in calls() if c[0] == 'vstest']) == 4, first
    assert sorted(c[1] for c in calls() if c[0] == 'restore') == sorted(n + '/' + n + '.csproj' for n in names)
    assert sorted(c[1] for c in calls() if c[0] == 'build') == ['Leaf/Leaf.csproj', 'Second/Second.csproj', 'Tests/Tests.csproj', 'Tests/Tests.csproj']
    start = len(calls())
    run([cook, 'dotnet:Second:test', '--color', 'never'], 'direct-warm')
    assert not [c for c in calls()[start:] if c[0] in ['restore', 'build']]
    assert len([c for c in calls()[start:] if c[0] == 'vstest']) == 1
    assert not (root / 'build/dotnet/bin/Other').exists(), 'unrelated application compiled'
    start = len(calls())
    run(command(), 'all-warm')
    warm = calls()[start:]
    assert len([c for c in warm if c[0] == 'vstest']) == 3, warm
    assert not [c for c in warm if c[0] in ['restore', 'build']], warm
    assert len([c for c in warm if '-getProperty:IsTestProject' in c]) == 5, warm
    # Generic test discovers the same selected native suite, once per project/framework.
    start = len(calls())
    generic = run([cook, 'test', '--no-publish', '--color', 'never'], 'generic-all')
    assert len([c for c in calls()[start:] if c[0] == 'vstest']) == 3, generic
    assert not [c for c in calls()[start:] if c[0] in ['restore', 'build']], generic
    selected = command('Tests', 'net8.0', test_filter='FullyQualifiedName~Fail')
    selected[1] = 'test'; start = len(calls())
    generic_failure = run(selected, 'generic-failure', 1)
    assert 'EXPECTED_NATIVE_FAILURE' in generic_failure, generic_failure
    assert len([c for c in calls()[start:] if c[0] == 'vstest']) == 1, generic_failure
    # The test consumer stays compiled at its public-reference key; execution gets current Leaf bytes.
    consumer_files = [root / 'build/dotnet/bin/Tests/debug_net8.0/Tests.dll', root / 'build/dotnet/obj/Tests/debug_net8.0/ref/Tests.dll']
    consumer_hashes = [hashlib.sha256(p.read_bytes()).hexdigest() for p in consumer_files]
    leaf.write_text('public class Leaf { public static string Value() => "changed"; }')
    env['EXPECTED_VALUE'] = 'changed'; start = len(calls())
    selected = command('Tests', 'net8.0'); selected[1] = 'test'
    edited = run(selected, 'private-edit')
    builds = [c for c in calls()[start:] if c[0] == 'build']
    assert len(builds) == 1 and builds[0][1] == 'Leaf/Leaf.csproj', (builds, edited)
    assert consumer_hashes == [hashlib.sha256(p.read_bytes()).hexdigest() for p in consumer_files]
    assert len([c for c in calls()[start:] if '-getProperty:IsTestProject' in c]) == 1
    failed = run(command('Tests', 'net8.0', test_filter='FullyQualifiedName~Fail'), 'failure', 1)
    assert 'EXPECTED_NATIVE_FAILURE' in failed and 'Tests' in failed and 'net8.0' in failed, failed
    run(command('Second', args=['--logger:console;verbosity=minimal']), 'second')
    run(command('Tests', 'net10.0', 'Release'), 'release')
    run(command('Tests', 'net8.0'), 'debug-return')
    no_tests = run(command('Leaf'), 'not-a-test', 1)
    assert 'no test projects' in no_tests.lower(), no_tests
    bad_arg = run(command('Tests', 'net8.0', args=['--not-a-vstest-option:literal;$(touch injected)', '']), 'bad-runner-args', 1)
    assert not (root / 'injected').exists(), 'runner args were evaluated by shell'
    observed = [c for c in calls() if c[0] == 'vstest'][-1]
    assert '--not-a-vstest-option:literal;$(touch injected)' in observed and '' in observed, observed
    assert 'Tests' in bad_arg and 'net8.0' in bad_arg
    results = list((root / 'build/dotnet/test-results').rglob('*.trx'))
    assert len(results) >= 3, results
    outcomes = [n.attrib['outcome'] for path in results for n in ET.parse(path).getroot().iter() if n.tag.endswith('UnitTestResult')]
    assert 'Passed' in outcomes and 'Failed' in outcomes, outcomes
    for fault in ['malformed', 'failure']:
        env['IDENTITY_FAULT'] = fault; start = len(calls())
        diagnostic = run(command('Tests', 'net8.0'), 'identity-' + fault, 1)
        assert not [c for c in calls()[start:] if c[0] == 'vstest']
        assert ('invalid IsTestProject' if fault == 'malformed' else 'NATIVE_QUERY_FAILED') in diagnostic, diagnostic
    del env['IDENTITY_FAULT']
    start = len(calls())
    for prefix in [[], ['why']]:
        run([cook, *prefix, 'dotnet:build', '--set', 'PROJECT=Leaf', '--set', 'TEST_ARGS={"bad":true}', '--color', 'never'], 'unrelated-' + str(len(prefix)))
    assert not [c for c in calls()[start:] if '-getProperty:IsTestProject' in c or c[0] == 'vstest']
    # Literal workspace options must survive child invocations without guessed --set variables.
    (root / 'LiteralCookfile').write_text('use cook_dotnet ./cook_dotnet.lua\ncook_dotnet.workspace({ solution = "Tests.sln", project = "Second", configuration = "Debug", framework = "net8.0", test_filter = "FullyQualifiedName~Pass" })\n')
    start = len(calls())
    run([cook, '--file', 'LiteralCookfile', 'dotnet:test', '--no-publish', '--color', 'never'], 'literal-options')
    assert len([c for c in calls()[start:] if '-getProperty:IsTestProject' in c]) == 1
    assert len([c for c in calls()[start:] if c[0] == 'vstest']) == 1
    second_project = root / 'Second/Second.csproj'
    second_project.write_text(second_project.read_text().replace('<PropertyGroup>', '<PropertyGroup><IsTestProject>TrUe</IsTestProject>', 1))
    mixed = run([native, 'msbuild', 'Second/Second.csproj', '-nologo', '-p:UseArtifactsOutput=true',
        '-p:ArtifactsPath=' + str(root / 'build/dotnet'), '-p:TargetFramework=net8.0', '-getProperty:IsTestProject'], 'mixed-native-identity')
    assert mixed.strip() == 'TrUe', mixed
    run(command('Second'), 'mixed-case-test')
    # Native MSBuild and VSTest build/run the same selected configuration and implementation.
    run([native, 'build', 'Tests/Tests.csproj', '--configuration', 'Release', '--framework', 'net10.0', '--artifacts-path', str(proof / 'native')], 'native-build')
    native_run = run([native, 'vstest', str(proof / 'native/bin/Tests/release_net10.0/Tests.dll'), '--TestCaseFilter:FullyQualifiedName~Pass', '--logger:trx', '--ResultsDirectory:' + str(proof / 'native-results')], 'native-run')
    assert 'Passed:' in native_run
    # Exercise the SDK 8 runner itself, not merely net8.0 under the SDK 10 runner.
    (root / 'global.json').write_text('{"sdk":{"version":"8.0.424","rollForward":"disable"}}')
    (root / 'SDK8Cookfile').write_text('use cook_dotnet ./cook_dotnet.lua\ncook_dotnet.workspace({ solution = "Second/Second.csproj", project = "Second", test_filter = "FullyQualifiedName~Pass" })\n')
    sdk8 = run([cook, '--file', 'SDK8Cookfile', 'dotnet:test', '--color', 'never'], 'sdk8-test')
    assert 'VSTest version 17.' in sdk8, sdk8
    run([native, 'build', 'Second/Second.csproj', '--artifacts-path', str(proof / 'native8')], 'sdk8-native-build')
    native8 = run([native, 'vstest', str(proof / 'native8/bin/Second/debug/Second.dll'),
        '--TestCaseFilter:FullyQualifiedName~Pass', '--logger:trx', '--ResultsDirectory:' + str(proof / 'native8-results')], 'sdk8-native-run')
    assert 'Passed:' in native8 and 'VSTest version 17.' in native8, native8
    # Repeat the transition: retained cleanup metadata must not delete fresh CopyLocal DLLs.
    for sdk in ['10.0.111', '8.0.424']:
        (root / 'global.json').write_text(json.dumps({'sdk': {'version': sdk, 'rollForward': 'disable'}}))
        run([cook, '--file', 'SDK8Cookfile', 'dotnet:test', '--color', 'never'], 'sdk-return-' + sdk)
        assert (root / 'build/dotnet/bin/Second/debug/Microsoft.VisualStudio.CodeCoverage.Shim.dll').is_file()
        start = len(calls())
        run([cook, '--file', 'SDK8Cookfile', 'dotnet:test', '--color', 'never'], 'sdk-warm-' + sdk)
        assert not [c for c in calls()[start:] if c[0] in ['restore', 'build']]
        assert len([c for c in calls()[start:] if c[0] == 'vstest']) == 1
    # SDK 8 also works in a checkout with no prior build state.
    fresh = proof / 'fresh-sdk8'; fresh.mkdir()
    for name in ['Second', 'Leaf', 'cook_dotnet']:
        shutil.copytree(root / name, fresh / name)
    for name in ['cook_dotnet.lua', 'SDK8Cookfile', 'global.json', 'Directory.Build.props']:
        shutil.copy2(root / name, fresh / name)
    fresh_project = fresh / 'Second/Second.csproj'
    fresh_project.write_text(fresh_project.read_text().replace('<IsTestProject>TrUe</IsTestProject>', ''))
    identity = run([native, 'msbuild', 'Second/Second.csproj', '-nologo', '-getProperty:IsTestProject'], 'sdk8-fresh-before-restore', cwd=fresh)
    assert not identity.strip(), identity
    run([cook, '--file', 'SDK8Cookfile', 'dotnet:test', '--color', 'never'], 'sdk8-fresh', cwd=fresh)
    # SDK 8's native centralized output leaves removed CopyLocal files behind.
    # Cook's owned bin and execution projection must instead contain only current dependencies.
    second_project.write_text(second_project.read_text().replace('<ProjectReference Include="../Leaf/Leaf.csproj"/>', ''))
    for path in (root / 'Second').glob('*.cs'):
        path.write_text(path.read_text().replace('Leaf.Value()', '"changed"'))
    run([cook, '--file', 'SDK8Cookfile', 'dotnet:test', '--color', 'never'], 'sdk8-remove-reference')
    assert not (root / 'build/dotnet/bin/Second/debug/Leaf.dll').exists()
    assert not (root / 'build/dotnet/test/Second/debug/Leaf.dll').exists()
    run([native, 'build', 'Second/Second.csproj', '--no-incremental', '--artifacts-path', str(proof / 'native8')], 'sdk8-native-remove')
    print('SDK8 native removed-reference DLL retained:', (proof / 'native8/bin/Second/debug/Leaf.dll').exists())
    print('PASS: SDK8/10 package-only native identity; selected/all tests; warm restore/build reuse; current private bytes; native filter/failure/TRX and argument fidelity')
PY
