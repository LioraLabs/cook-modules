#!/bin/sh
set -eu
module_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export COOK_DOTNET_SOURCE="$module_dir"
python3 - "$@" <<'PY'
import json, os, pathlib, shutil, statistics, subprocess, sys, tempfile, time

source = pathlib.Path(os.environ['COOK_DOTNET_SOURCE'])
cook = os.environ.get('COOK', 'cook')
flags = set(sys.argv[1:])
assert flags <= {'--matrix-only', '--benchmark-only', '--fresh-timestamps'}, 'unknown proof option'
if '--fresh-timestamps' in flags:
    print('Diagnostic run: artificial timestamps disabled; this is not the full recovery gate.', flush=True)
def stamp(path, timestamp):
    if '--fresh-timestamps' not in flags:
        os.utime(path, (timestamp, timestamp))
with tempfile.TemporaryDirectory(prefix='cook-dotnet-recovery.') as temporary:
    root = pathlib.Path(temporary)
    def fixture(name, baseline=False):
        path = root / name
        for directory in ('App', 'Lib', '.cook/proof'):
            (path / directory).mkdir(parents=True, exist_ok=True)
        for relative in ('cook_dotnet.lua', 'cook_dotnet/discovery.lua'):
            target = path / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if baseline:
                target.write_bytes(subprocess.check_output(['git', 'show', '9a92715:cook_dotnet/' + relative], cwd=source))
            else:
                shutil.copyfile(source / relative, target)
        (path / 'global.json').write_text('{"sdk":{"version":"10.0.111","rollForward":"disable"}}\n')
        (path / 'Cookfile').write_text('use cook_dotnet ./cook_dotnet.lua\ncook_dotnet.workspace({ solution = "App/App.csproj", configuration = "Debug" })\n')
        (path / 'App/App.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup><ItemGroup><ProjectReference Include="../Lib/Lib.csproj" /></ItemGroup></Project>\n')
        (path / 'Lib/Lib.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup><ItemGroup><None Include="data.txt" CopyToOutputDirectory="PreserveNewest" /></ItemGroup></Project>\n')
        (path / 'Lib/data.txt').write_text('resource-first\n')
        (path / 'App/Program.cs').write_text('System.Console.WriteLine(Message.Text + \" \" + Message.Mode);\n')
        edit(path, 'initial')
        return path
    def edit(path, value, old_time=False):
        target = path / 'Lib/Message.cs'
        target.write_text('public static class Message { public static string Text => "' + value + '";\n#if DEBUG\npublic static string Mode => "Debug";\n#else\npublic static string Mode => "Release";\n#endif\n}\n')
        if old_time:
            stamp(target, 946684800)
    def run(path, args, expected=0):
        env = {**os.environ, 'DOTNET_CLI_HOME': str(path / '.cook/home'),
               'NUGET_PACKAGES': str(path / '.cook/packages'), 'DOTNET_NOLOGO': '1',
               'DOTNET_SKIP_FIRST_TIME_EXPERIENCE': '1', 'XDG_CACHE_HOME': str(path / '.cook/cache')}
        result = subprocess.run(args, cwd=path, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (path / '.cook/proof/last.log').write_text(result.stdout)
        if (result.returncode == 0) != (expected == 0):
            raise AssertionError(f'{args}: exit {result.returncode}\n{result.stdout}')
        return result.stdout
    def build_run(path, native=False, value=None, shared=True):
        if native:
            run(path, ['dotnet', 'build', 'App/App.csproj', '--artifacts-path', 'build/dotnet', '--verbosity', 'quiet'])
            output = run(path, ['dotnet', 'build/dotnet/bin/App/debug/App.dll'])
        else:
            flags = [] if shared else ['--no-publish']
            built = run(path, [cook, 'dotnet:build', '--color', 'never'] + flags)
            (path / '.cook/proof/build.log').write_text(built)
            output = run(path, [cook, 'dotnet:run', '--color', 'never'] + flags)
        if value is not None:
            details = (path / '.cook/proof/build.log').read_text() if not native else ''
            assert value in output, f'wrong runtime bytes: expected {value}\n{details}\n{output}'
        return output
    if '--matrix-only' not in flags:
        variants = [(fixture('before', True), False), (fixture('candidate'), False), (fixture('native'), True)]
        timings = {}
        for path, native in variants:
            build_run(path, native, 'initial', shared=True)
            samples = []
            for number in range(5):
                start = time.perf_counter()
                value = 'private-edit-' + str(number)
                edit(path, value)
                build_run(path, native, value, shared=True)
                samples.append(time.perf_counter() - start)
            timings[path.name] = {'median_seconds': statistics.median(samples), 'range_seconds': [min(samples), max(samples)], 'samples': samples}
        print(json.dumps(timings, indent=2), flush=True)
        if '--benchmark-only' in flags:
            sys.exit(0)
        candidate = variants[1][0]
    else:
        candidate = fixture('candidate')
        build_run(candidate, value='initial')
    assets = candidate / 'build/dotnet/obj/Lib/project.assets.json'
    retained = (assets.stat().st_ino, assets.stat().st_mtime_ns, assets.read_bytes())
    edit(candidate, 'old-timestamp-current-content', old_time=True)
    build_run(candidate, value='old-timestamp-current-content')
    assert retained == (assets.stat().st_ino, assets.stat().st_mtime_ns, assets.read_bytes()), 'private edit discarded unchanged restore assets'
    # Old timestamps must not preserve stale copied resources or compiled code.
    (candidate / 'Lib/data.txt').write_text('resource-current\n')
    stamp(candidate / 'Lib/data.txt', 946684800)
    build_run(candidate, value='old-timestamp-current-content')
    assert (candidate / 'build/dotnet/run/App/debug/data.txt').read_text() == 'resource-current\n'
    edit(candidate, 'temporary-edit', old_time=True)
    build_run(candidate, value='temporary-edit')
    edit(candidate, 'old-timestamp-current-content', old_time=True)
    build_run(candidate, value='old-timestamp-current-content')
    # Real branch changes; force old mtimes after checkout to exclude timestamp luck.
    run(candidate, ['git', 'init', '-q'])
    run(candidate, ['git', 'add', 'App', 'Lib', 'global.json', 'Cookfile'])
    identity = ['git', '-c', 'user.name=Cook Proof', '-c', 'user.email=cook-proof@example.invalid']
    run(candidate, identity + ['commit', '-qm', 'initial fixture'])
    original_branch = run(candidate, ['git', 'branch', '--show-current']).strip()
    run(candidate, ['git', 'checkout', '-qb', 'alternate'])
    edit(candidate, 'alternate-branch', old_time=True)
    run(candidate, ['git', 'add', 'Lib/Message.cs'])
    run(candidate, identity + ['commit', '-qm', 'alternate fixture'])
    build_run(candidate, value='alternate-branch')
    run(candidate, ['git', 'checkout', '-q', original_branch])
    stamp(candidate / 'Lib/Message.cs', 946684800)
    build_run(candidate, value='old-timestamp-current-content')
    # Configuration switches select current runtime bytes without manual cleanup.
    cookfile = candidate / 'Cookfile'
    cookfile.write_text(cookfile.read_text().replace('Debug', 'Release'))
    build_run(candidate, value='old-timestamp-current-content Release')
    cookfile.write_text(cookfile.read_text().replace('Release', 'Debug'))
    build_run(candidate, value='old-timestamp-current-content Debug')
    # Shared-cache recovery validates corrupt and missing owned outputs.
    for relative in ('bin/Lib/debug/Lib.dll', 'obj/Lib/debug/Lib.dll', 'obj/Lib/project.assets.json', 'obj/Lib/Lib.csproj.nuget.g.props', 'run/App/debug/Lib.dll'):
        target = candidate / 'build/dotnet' / relative
        target.write_bytes(b'corrupt')
        stamp(target, 4102444800)
        build_run(candidate, value='old-timestamp-current-content Debug')
        target.unlink()
        build_run(candidate, value='old-timestamp-current-content Debug')
    # A failed compiler invocation must not poison the next successful build.
    (candidate / 'Lib/Message.cs').write_text('this is invalid C#')
    run(candidate, [cook, 'dotnet:build', '--no-publish', '--color', 'never'], expected=1)
    edit(candidate, 'recovered-after-failure', old_time=True)
    build_run(candidate, value='recovered-after-failure')
    # Removed and renamed references leave no stale library in the runnable projection.
    app_project = candidate / 'App/App.csproj'
    original_project = app_project.read_text()
    original_program = (candidate / 'App/Program.cs').read_text()
    app_project.write_text(original_project.replace('<ProjectReference Include="../Lib/Lib.csproj" />', ''))
    (candidate / 'App/Program.cs').write_text('System.Console.WriteLine("no-dependency");\n')
    build_run(candidate, value='no-dependency')
    assert not (candidate / 'build/dotnet/run/App/debug/Lib.dll').exists(), 'removed dependency remained runnable'
    app_project.write_text(original_project.replace('../Lib/Lib.csproj', '../Renamed/Renamed.csproj'))
    (candidate / 'Lib').rename(candidate / 'Renamed')
    (candidate / 'Renamed/Lib.csproj').rename(candidate / 'Renamed/Renamed.csproj')
    (candidate / 'App/Program.cs').write_text(original_program)
    build_run(candidate, value='recovered-after-failure')
    assert not (candidate / 'build/dotnet/run/App/debug/Lib.dll').exists(), 'renamed dependency remained runnable'
    assert (candidate / 'build/dotnet/run/App/debug/Renamed.dll').is_file()
    # Locked restore is explicit and remains authoritative after dependency changes.
    run(candidate, ['dotnet', 'restore', 'App/App.csproj', '--use-lock-file', '--force-evaluate', '--artifacts-path', '.cook/lock-restore'])
    build_run(candidate, value='recovered-after-failure')
    lock = candidate / 'App/packages.lock.json'
    lock_bytes = lock.read_bytes()
    lock.write_text('{"version":1,"dependencies":{"net8.0":{}}}')
    run(candidate, [cook, 'dotnet:build', '--no-publish', '--color', 'never'], expected=1)
    lock.write_bytes(lock_bytes)
    build_run(candidate, value='recovered-after-failure')
    # A publish-off workspace must recover even without a shared artifact rescue.
    local = fixture('publish-off')
    build_run(local, value='initial', shared=False)
    edit(local, 'local-current-content', old_time=True)
    build_run(local, value='local-current-content', shared=False)
    (local / 'build/dotnet/bin/Lib/debug/Lib.dll').write_bytes(b'corrupt')
    (local / 'build/dotnet/obj/Lib/debug/Lib.dll').unlink()
    build_run(local, value='local-current-content', shared=False)
    # Shared compilation artifacts must remain sound after the original checkout disappears.
    shared = fixture('shared-original')
    build_run(shared, value='initial', shared=True)
    moved = root / 'shared-fresh'
    shutil.copytree(shared, moved, ignore=shutil.ignore_patterns('.cook', 'build', '.git'))
    (moved / '.cook/proof').mkdir(parents=True)
    shutil.move(shared / '.cook/cache', moved / '.cook/cache')
    shutil.rmtree(shared)
    build_run(moved, value='initial', shared=True)
    assert str(moved) in (moved / 'build/dotnet/obj/Lib/project.assets.json').read_text(), 'restore metadata reused an old checkout path'
    edit(moved, 'fresh-checkout-current-content', old_time=True)
    build_run(moved, value='fresh-checkout-current-content', shared=True)
    print('cook_dotnet recovery passed', flush=True)
PY
