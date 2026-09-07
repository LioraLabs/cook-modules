#!/bin/sh
set -eu
module_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export COOK_DOTNET_SOURCE="$module_dir"
python3 - <<'PY'
import hashlib, json, os, pathlib, pty, select, shutil, signal, subprocess, tempfile, time
source = pathlib.Path(os.environ['COOK_DOTNET_SOURCE'])
cook = os.environ.get('COOK', 'cook')
native = shutil.which('dotnet')
with tempfile.TemporaryDirectory(prefix='cook-dotnet-run.') as tmp:
    root = pathlib.Path(tmp)
    shutil.copy2(source / 'cook_dotnet.lua', root)
    shutil.copytree(source / 'cook_dotnet', root / 'cook_dotnet')
    proof = root / '.cook/proof'; proof.mkdir(parents=True)
    env = {**os.environ, 'XDG_CACHE_HOME': str(root / '.cook/cache'), 'DOTNET_CLI_HOME': str(root / '.cook/dotnet/home'),
           'NUGET_PACKAGES': str(root / '.cook/dotnet/packages'), 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE': '1', 'DOTNET_NOLOGO': '1'}
    def run(args, name, status=0):
        p = subprocess.run(args, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (proof / (name + '.log')).write_text(p.stdout)
        assert p.returncode == status, name + ': exit ' + str(p.returncode) + '\n' + p.stdout[-6000:]
        return p.stdout
    (root / 'global.json').write_text('{"sdk":{"version":"10.0.111","rollForward":"disable"}}')
    names = ['App', 'Middle', 'Leaf', 'Other']
    for name in names:
        directory = root / name; directory.mkdir()
        properties = '<TargetFrameworks>net8.0;net10.0</TargetFrameworks><OutputType>Exe</OutputType><AssemblyName Condition="&apos;$(TargetFramework)&apos; == &apos;net10.0&apos;">Modern</AssemblyName>' if name == 'App' else ('<TargetFramework>net8.0</TargetFramework><OutputType>Exe</OutputType>' if name == 'Other' else '<TargetFramework>netstandard2.1</TargetFramework>')
        dependency = {'App': 'Middle', 'Middle': 'Leaf'}.get(name)
        refs = '<ItemGroup><ProjectReference Include="../' + dependency + '/' + dependency + '.csproj"/></ItemGroup>' if dependency else ''
        failure = '<Target Name="FailUnselected" BeforeTargets="CoreCompile"><Error Text="UNRELATED_BODY_EXECUTED"/></Target>' if name == 'Other' else ''
        (directory / (name + '.csproj')).write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>' + properties + '</PropertyGroup>' + refs + failure + '</Project>')
    leaf = root / 'Leaf/Code.cs'
    leaf.write_text('public class Leaf { public static string Text => "original"; }')
    (root / 'Middle/Code.cs').write_text('public class Middle { public static string Text => Leaf.Text; }')
    (root / 'Other/Program.cs').write_text('System.Console.WriteLine("other");')
    (root / 'App/Program.cs').write_text('''using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
class Program {
 static int Main(string[] args) {
#if NET10_0
 const string tfm = "net10.0";
#else
 const string tfm = "net8.0";
#endif
#if DEBUG
 const string config = "Debug";
#else
 const string config = "Release";
#endif
 Console.WriteLine("VALUE:" + tfm + ":" + config + ":" + Middle.Text);
 Console.WriteLine("ARGS:" + System.Text.Json.JsonSerializer.Serialize(args));
 File.AppendAllText(".cook/proof/runs", "run\\n");
 if (args.Length > 0 && args[0] == "exit") return 37;
 if (args.Length > 0 && args[0] == "terminal") {
   Console.WriteLine("INPUT_READY");
   Console.WriteLine("INPUT:" + Console.ReadLine());
   var child = Process.Start(new ProcessStartInfo("sleep", "300") { UseShellExecute = false });
   File.WriteAllText(".cook/proof/child", child.Id.ToString());
   Console.WriteLine("CHILD_READY:" + child.Id);
   Thread.Sleep(Timeout.Infinite);
 }
 return 0;
 }
}
''')
    run([native, 'new', 'sln', '-n', 'Graph', '--format', 'sln'], 'solution')
    run([native, 'sln', 'Graph.sln', 'add', *[n + '/' + n + '.csproj' for n in names]], 'add-projects')
    (root / 'Cookfile').write_text('''use cook_dotnet ./cook_dotnet.lua
config
    var.PROJECT = ""
    var.CONFIGURATION = "Debug"
    var.FRAMEWORK = ""
    var.ARGS = "[]"
cook_dotnet.workspace({ solution = "Graph.sln", project = var.PROJECT, configuration = var.CONFIGURATION,
    framework = var.FRAMEWORK, args = cook.json_decode(var.ARGS) })
''')
    bindir = proof / 'bin'; bindir.mkdir()
    wrapper = bindir / 'dotnet'
    wrapper.write_text("#!/usr/bin/env python3\nimport os, sys\nif len(sys.argv) > 1 and sys.argv[1] in ('msbuild', 'sln'):\n    with open(os.environ['DISCOVERY_LOG'], 'a') as log: log.write('query\\n')\nos.execv(os.environ['REAL_DOTNET'], [os.environ['REAL_DOTNET'], *sys.argv[1:]])\n")
    wrapper.chmod(0o755)
    queries = proof / 'queries'; queries.write_text('')
    env.update(PATH=str(bindir) + ':' + env['PATH'], REAL_DOTNET=native, DISCOVERY_LOG=str(queries))
    def command(project='App', framework='net8.0', configuration='Debug', args=(), why=False):
        return [cook] + (['why'] if why else []) + ['dotnet:run', '--set', 'PROJECT=' + project,
            '--set', 'FRAMEWORK=' + framework, '--set', 'CONFIGURATION=' + configuration,
            '--set', 'ARGS=' + json.dumps(args), '--color', 'never']
    run([cook, 'dotnet:build', '--set', 'PROJECT=Leaf', '--color', 'never'], 'library-build-with-unrunnable-selection')
    run([cook, 'why', 'dotnet:build', '--set', 'PROJECT=Leaf', '--color', 'never'], 'library-why-with-unrunnable-selection')
    first = run(command(), 'selected-first')
    assert 'VALUE:net8.0:Debug:original' in first, first
    assert not (root / 'build/dotnet/bin/Other').exists()
    assert not (root / 'build/dotnet/bin/App/debug_net10.0').exists()
    why = run(command(why=True), 'selected-why')
    assert 'dotnet:Other' not in why
    query_count = queries.read_text()
    before = (proof / 'runs').read_text()
    second = run(command(), 'selected-repeat')
    assert (proof / 'runs').read_text() == before + 'run\n', 'application execution was cached'
    assert queries.read_text() == query_count, 'warm run rediscovered graph'
    tracked = [root / p for p in ['build/dotnet/bin/App/debug_net8.0/App.dll',
        'build/dotnet/obj/App/debug_net8.0/ref/App.dll', 'build/dotnet/bin/Middle/debug/Middle.dll']]
    hashes = [hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked]
    old_stat = leaf.stat()
    leaf.write_text('public class Leaf { public static string Text => "modified"; }')
    os.utime(leaf, ns=(old_stat.st_atime_ns, old_stat.st_mtime_ns))
    changed = run(command(), 'private-transitive-edit')
    assert 'VALUE:net8.0:Debug:modified' in changed, changed
    assert hashes == [hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked], 'private change recompiled consumers'
    assert queries.read_text() == query_count, 'private body edit rediscovered graph'
    special = ['space value', '', "single'quote", '$(touch .cook/proof/injected)', '; echo bad', 'line\nbreak']
    out = run(command(args=special), 'quoted-args')
    received = next(line[5:] for line in out.splitlines() if line.startswith('ARGS:'))
    assert json.loads(received) == special and not (proof / 'injected').exists()
    for framework, configuration in [('net10.0', 'Debug'), ('net8.0', 'Release')]:
        out = run(command(framework=framework, configuration=configuration), framework + configuration)
        expected = 'VALUE:' + framework + ':' + configuration + ':modified'
        assert expected in out, out
        run([native, 'build', 'App/App.csproj', '--artifacts-path', str(root / '.cook/native'), '-c', configuration,
             '-f', framework, '--nologo', '-v:q'], 'native-build-' + framework + configuration)
        native_out = run([native, str(root / '.cook/native/bin/App' / (configuration.lower() + '_' + framework) / ('Modern.dll' if framework == 'net10.0' else 'App.dll'))], 'native-run-' + framework + configuration)
        assert expected in native_out
    assert (root / 'build/dotnet/run/App/debug_net10.0/Modern.dll').is_file(), 'switching run selection removed the sibling framework'
    for name, kwargs, expected in [
        ('ambiguous', {'project': '', 'framework': ''}, 'requires PROJECT'),
        ('multitarget', {'framework': ''}, 'requires FRAMEWORK'),
        ('library', {'project': 'Leaf', 'framework': ''}, 'not executable'),
        ('unknown', {'project': 'missing'}, 'choose one of:'),
        ('framework', {'framework': 'net7.0'}, 'net8.0, net10.0')]:
        out = run(command(**kwargs), name, 1)
        assert expected in out, out
    out = run(command(args=['exit']), 'nonzero-exit', 1)
    assert 'exit 37' in out or 'code 37' in out, out
    print('PASS: application exit 37 is reported; Cook returns 1', flush=True)

    # A real controlling terminal proves stdin, foreground Ctrl-C, and descendant ownership.
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(root)
        os.execvpe(cook, command(args=['terminal']), env)
    output = bytearray(); child = None; status = None
    def until(marker, timeout=30):
        deadline = time.monotonic() + timeout
        while marker not in output and time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], .1)
            if ready:
                try: output.extend(os.read(fd, 65536))
                except OSError: break
        assert marker in output, output.decode(errors='replace')
    def alive(child):
        try:
            # A zombie has terminated; its parent/reaper owns the remaining process-table entry.
            return pathlib.Path('/proc/' + str(child) + '/stat').read_text().split(') ', 1)[1][0] != 'Z'
        except FileNotFoundError: return False
    try:
        until(b'INPUT_READY')
        os.write(fd, b'hello terminal\n')
        until(b'INPUT:hello terminal')
        until(b'CHILD_READY:')
        child = int((proof / 'child').read_text())
        assert alive(child)
        os.write(fd, b'\x03')
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            done, result = os.waitpid(pid, os.WNOHANG)
            if done: status = os.waitstatus_to_exitcode(result); break
            time.sleep(.05)
        assert status is not None, 'Cook did not exit after Ctrl-C'
        deadline = time.monotonic() + 5
        while alive(child) and time.monotonic() < deadline: time.sleep(.05)
        assert not alive(child), 'Ctrl-C left descendant alive: ' + str(child)
        assert status != 0, 'Ctrl-C reported success'
        print('PASS: real PTY input; Ctrl-C Cook status=' + str(status) + '; descendant ' + str(child) + ' terminated', flush=True)
    finally:
        (proof / 'terminal.log').write_bytes(output)
        if status is None:
            os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
        if child and alive(child): os.kill(child, signal.SIGKILL)
        os.close(fd)
    print('PASS: selected run, arguments, current transitive bytes, native configuration/framework parity, and diagnostics', flush=True)
PY
