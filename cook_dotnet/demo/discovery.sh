#!/bin/sh
set -eu
module_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export COOK_DOTNET_SOURCE="$module_dir"
python3 - "$@" <<'PY'
import os, pathlib, shlex, shutil, subprocess, tempfile
import json, sys
if '--graph-proof' in sys.argv:
    # Real SDK evaluation, with a wrapper that only observes concurrent processes.
    source = pathlib.Path(os.environ['COOK_DOTNET_SOURCE']) / 'cook_dotnet/discovery.lua'
    baseline = subprocess.check_output(['git', 'show', '9b0f642:cook_dotnet/cook_dotnet/discovery.lua'], cwd=source.parent)
    with tempfile.TemporaryDirectory(prefix='cook-dotnet-discovery.') as name:
        root = pathlib.Path(name)
        (root / 'candidate.lua').write_bytes(source.read_bytes())
        (root / 'baseline.lua').write_bytes(baseline)
        (root / 'global.json').write_text('{"sdk":{"version":"8.0.424","rollForward":"disable"}}')
        (root / 'Directory.Build.props').write_text('''<Project><PropertyGroup><DiscoverySawGlobalFramework>$(TargetFramework)</DiscoverySawGlobalFramework></PropertyGroup><ItemGroup Condition="'$(DiscoverySawGlobalFramework)' == 'net8.0'"><Compile Include="$(MSBuildThisFileDirectory)InnerOnly.cs" /></ItemGroup></Project>''')
        (root / 'InnerOnly.cs').write_text('class InnerOnly {}')
        for project in ['App', 'Lib', 'Multi', 'Extra']:
            (root / project).mkdir()
            tfm = '<TargetFrameworks>netstandard2.1;net8.0</TargetFrameworks>' if project == 'Multi' else '<TargetFramework>' + ('netstandard2.1' if project == 'Lib' else 'net8.0') + '</TargetFramework>'
            refs = '''<ItemGroup Condition="'$(Configuration)' == 'Debug'"><ProjectReference Include="../Lib/Lib.csproj" /></ItemGroup>''' if project == 'App' else ''
            (root / project / (project + '.csproj')).write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>' + tfm + '<EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup>' + refs + '</Project>')
        native = shutil.which('dotnet')
        native_env = {**os.environ, 'DOTNET_CLI_HOME': str(root / '.cook/dotnet/home'),
            'NUGET_PACKAGES': str(root / '.cook/dotnet/packages'), 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE': '1', 'DOTNET_NOLOGO': '1'}
        subprocess.run([native, 'new', 'sln', '-n', 'Graph'], cwd=root, env=native_env, check=True, capture_output=True)
        subprocess.run([native, 'sln', 'Graph.sln', 'add', *[p + '/' + p + '.csproj' for p in ['App', 'Lib', 'Multi', 'Extra']]], cwd=root, env=native_env, check=True, capture_output=True)
        counter = root / 'counter'; counter.write_text('0 0')
        wrapper = root / 'sdk wrapper'
        wrapper.write_text('''#!/usr/bin/env python3
import fcntl, os, subprocess, sys
from pathlib import Path
counter = Path(os.environ['SDK_COUNTER'])
def update(delta):
    with counter.open('r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        active, peak = map(int, f.read().split())
        active += delta
        f.seek(0); f.truncate(); f.write(f'{active} {max(active, peak)}'); f.flush()
tracked = 'msbuild' in sys.argv[1:]
if tracked: update(1)
try: result = subprocess.run([os.environ['REAL_DOTNET'], *sys.argv[1:]])
finally:
    if tracked: update(-1)
sys.exit(result.returncode)
''')
        wrapper.chmod(0o755)
        lua = '''
local json = require("cjson")
cook = { tools = { id = function() return {path=os.getenv("SDK_WRAPPER"), hash="same-tool"} end },
    json_decode = json.decode, sh = function(command)
        local pipe = assert(io.popen(command .. " 2>&1", "r"))
        local output = pipe:read("*a")
        if not pipe:close() then error(output, 0) end
        return output
    end }
local discovery = assert(loadfile(os.getenv("DISCOVERY_SOURCE")))()
print(json.encode(discovery.producer("Graph.sln", os.getenv("CONFIGURATION"), {})()))
'''
        cpath = subprocess.check_output(['luarocks', 'path', '--lr-cpath'], text=True).strip()
        env = {**native_env, 'LUA_CPATH': cpath, 'SDK_WRAPPER': str(wrapper), 'SDK_COUNTER': str(counter), 'REAL_DOTNET': native}
        def graph(variant, configuration):
            counter.write_text('0 0')
            p = subprocess.run(['lua5.4', '-'], input=lua, text=True, capture_output=True, cwd=root,
                env={**env, 'DISCOVERY_SOURCE': str(root / (variant + '.lua')), 'CONFIGURATION': configuration})
            assert p.returncode == 0, p.stderr
            return json.loads(p.stdout), int(counter.read_text().split()[1])
        for configuration in ['Debug', 'Release']:
            old, _ = graph('baseline', configuration)
            current, peak = graph('candidate', configuration)
            assert current == old, 'native normalized graph changed'
            assert 1 < peak <= 4, f'expected bounded overlapping native evaluations, observed {peak}'
            projects = {p['path']: p for p in current['projects']}
            app = projects['App/App.csproj']
            assert not app['value']['Items']['Compile']
            assert app['builds']['net8.0']['Items']['Compile'][0]['FullPath'] == 'InnerOnly.cs'
            refs = app['builds']['net8.0']['Items']['ProjectReference']
            if configuration == 'Debug': assert refs[0]['NearestTargetFramework'] == 'netstandard2.1'
            else: assert not refs
            print(configuration + ': native graph identical; global-TFM imports preserved; peak=' + str(peak))
        (root / 'Extra/Extra.csproj').write_text('<Project>broken')
        failed = subprocess.run(['lua5.4', '-'], input=lua, text=True, capture_output=True, cwd=root,
            env={**env, 'DISCOVERY_SOURCE': str(root / 'candidate.lua'), 'CONFIGURATION': 'Debug'})
        assert failed.returncode != 0 and 'MSB4025' in failed.stderr, 'failed batch query must retain native diagnostic'
        print('failed native batch query remains authoritative')
    sys.exit(0)

openssl = shutil.which('openssl')
assert openssl, 'openssl is required'
lua = '''
package.path = os.getenv("COOK_DOTNET_SOURCE") .. "/?.lua;" .. package.path
local function sh(command)
    local pipe = assert(io.popen(command, "r"))
    local result = pipe:read("*a")
    assert(pipe:close(), "command failed: " .. command)
    return result
end
cook = { tools = { id = function() return { path = "/usr/bin/dotnet", hash = "tool-id" } end },
    sh = function(command)
        if command:find(" --version", 1, true) then return "8.0.424" end
        if command:find(" --info", 1, true) then
            return "Base Path: " .. os.getenv("PACK_ROOT") .. "/sdk/8.0.424/"
        end
        return sh(command)
    end }
local result = assert(load(require("cook_dotnet.discovery").toolchain_producer()))()
io.write(table.concat({ result.dotnet_id, result.sdk, result.netcore_ref.versions,
    result.netcore_ref.digest, result.aspnetcore_ref.versions, result.aspnetcore_ref.digest }, string.char(0)))
'''
def reference(root):
    result = {'dotnet_id': 'tool-id', 'sdk': '8.0.424'}
    for name, field in [('Microsoft.NETCore.App.Ref', 'netcore_ref'), ('Microsoft.AspNetCore.App.Ref', 'aspnetcore_ref')]:
        path = shlex.quote(str(root / 'packs' / name))
        versions = f'if [ -d {path} ]; then for v in {path}/*; do [ ! -d "$v" ] || basename "$v"; done | LC_ALL=C sort; fi'
        digest = f'if [ -d {path} ]; then cd {path} && find . -type f -exec openssl dgst -sha256 {{}} \\; | LC_ALL=C sort | openssl dgst -sha256; fi'
        def run(command):
            return subprocess.check_output(['/bin/sh', '-c', command], text=True).strip()
        result[field] = {'versions': run(versions), 'digest': run(digest) or '<missing>'}
    return result
with tempfile.TemporaryDirectory(prefix='cook-dotnet-fingerprint.') as tmp:
    tmp = pathlib.Path(tmp)
    wrappers = tmp / 'bin'; wrappers.mkdir()
    log = tmp / 'openssl-calls'
    wrapper = wrappers / 'openssl'
    wrapper.write_text('#!/bin/sh\nprintf "%s\\n" "$#" >> "$OPENSSL_CALL_LOG"\n'
        'if [ "${FAIL_AGGREGATE:-}" = 1 ] && [ "$#" = 2 ]; then echo "aggregate failed" >&2; exit 7; fi\n'
        'exec ' + shlex.quote(openssl) + ' "$@"\n')
    wrapper.chmod(0o755)
    env = {**os.environ, 'PATH': str(wrappers) + ':' + os.environ['PATH'], 'OPENSSL_CALL_LOG': str(log)}
    def candidate(root):
        log.write_text('')
        fields = subprocess.check_output(['lua5.4', '-'], input=lua, text=True, env={**env, 'PACK_ROOT': str(root)}).split('\0')
        value = {'dotnet_id': fields[0], 'sdk': fields[1], 'netcore_ref': {'versions': fields[2], 'digest': fields[3]},
                 'aspnetcore_ref': {'versions': fields[4], 'digest': fields[5]}}
        return value, log.read_text().splitlines()
    root = tmp / 'sdk root'; root.mkdir()
    for state in ['missing', 'empty', 'files']:
        pack = root / 'packs/Microsoft.NETCore.App.Ref/8.0.30/ref/net8.0'
        if state != 'missing': pack.mkdir(parents=True, exist_ok=True)
        if state == 'files':
            for name in ['normal.dll', 'with space.dll', "quote'file.dll", 'back\\slash.dll', 'line\nbreak.dll', '-option.dll', 'unicodé.dll']:
                (pack / name).write_text('reference bytes: ' + name)
        got, calls = candidate(root)
        assert got == reference(root), (state, got)
        if state == 'files':
            assert len(calls) == 2, f'expected one native batch plus aggregate, got {len(calls)} processes'
            (pack / 'normal.dll').write_text('changed reference bytes')
            changed, _ = candidate(root)
            assert changed != got and changed == reference(root), 'reference content change must change fingerprint'
        print(state + ': exact producer parity')
    installed = pathlib.Path('/usr/share/dotnet')
    assert (installed / 'packs').is_dir(), 'installed SDK packs are required'
    got, calls = candidate(installed)
    assert got == reference(installed), 'installed SDK producer fingerprint changed'
    file_count = sum(1 for p in (installed / 'packs/Microsoft.NETCore.App.Ref').rglob('*') if p.is_file())
    assert len(calls) < file_count, 'installed pack hashing still launches one process per file'
    print(f'installed SDK packs: exact producer parity; {len(calls)} OpenSSL processes for {file_count} NETCore files')
    failed = subprocess.run(['lua5.4', '-'], input=lua, text=True, capture_output=True,
        env={**env, 'PACK_ROOT': str(root), 'FAIL_AGGREGATE': '1'})
    assert failed.returncode != 0 and 'aggregate failed' in failed.stderr, 'failed final digest must not produce a fingerprint'
    print('final digest failure remains authoritative')
print('cook_dotnet fingerprint discovery passed')
PY
