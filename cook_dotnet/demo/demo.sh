#!/bin/sh
set -eu

module_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
demo_dir=$(mktemp -d "${TMPDIR:-/tmp}/cook-dotnet-demo.XXXXXX")
trap 'rm -rf -- "$demo_dir"' EXIT

cp "$module_dir/cook_dotnet.lua" "$demo_dir/"
cp -R "$module_dir/cook_dotnet" "$demo_dir/"
cp -R "$module_dir/demo/." "$demo_dir/"
cd "$demo_dir"
mkdir -p .cook/proof
export XDG_CACHE_HOME="$demo_dir/.cook/cache"
export DOTNET_CLI_HOME="$demo_dir/.cook/dotnet/home" NUGET_PACKAGES="$demo_dir/.cook/dotnet/packages"
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1

run() {
    log=$1; shift
    status=0
    cook "$@" > "$log" 2>&1 || status=$?
    cat "$log"
    return "$status"
}

nonce=$(date +%s%N)
sed -i "s/v1/baseline-$nonce/" Lib/Message.cs

echo "== cold graph build =="
cook dotnet:build --color never

echo "== unchanged graph: materializer restore without MSBuild =="
run .cook/proof/warm.log dotnet:build --color never -v
grep -q "cook materialize cook_dotnet.graph restored" .cook/proof/warm.log

echo "== project change: graph materializer invalidates =="
printf '\n<!-- discovery-%s -->\n' "$nonce" >> Lib/Lib.csproj
run .cook/proof/discovery-change.log dotnet:build --color never -v
grep -q "cook materialize cook_dotnet.graph ran" .cook/proof/discovery-change.log

echo "== private implementation change: App stays cached =="
sed -i "s/baseline-$nonce/private-$nonce/" Lib/Message.cs
run .cook/proof/private.log dotnet:build --color never -v
grep -q "dotnet:App.*cached" .cook/proof/private.log

echo "== projected app uses the new library without recompiling App =="
run .cook/proof/private-run.log dotnet:run --color never --replay-logs
grep -q "hello private-$nonce" .cook/proof/private-run.log

echo "== public API change: App rebuilds =="
sed -i '/public static string Text/a\    public static int Version => 2;' Lib/Message.cs
run .cook/proof/public.log dotnet:build --color never -v
grep -q "dotnet:App.*rebuild" .cook/proof/public.log

echo "== runnable projection after propagation =="
run .cook/proof/run.log dotnet:run --color never --replay-logs
grep -q "hello private-$nonce" .cook/proof/run.log

echo "== configuration change: discovery key and conditional graph change =="
cp App/packages.lock.json .cook/proof/debug-lock.json
dotnet restore App/App.csproj -p:Configuration=Release --use-lock-file --force-evaluate \
    --artifacts-path .cook/fixture-restore --verbosity quiet
sed -i 's/configuration = "Debug"/configuration = "Release"/' Cookfile
run .cook/proof/release.log dotnet:build --color never -v
grep -q "cook materialize cook_dotnet.graph ran" .cook/proof/release.log
grep -q "dotnet:ReleaseOnly" .cook/proof/release.log
cp .cook/proof/debug-lock.json App/packages.lock.json
sed -i 's/configuration = "Release"/configuration = "Debug"/' Cookfile
run .cook/proof/debug.log dotnet:build --color never -v
grep -q "cook materialize cook_dotnet.graph restored" .cook/proof/debug.log
if grep -q "dotnet:ReleaseOnly" .cook/proof/debug.log; then exit 1; fi

echo "cook_dotnet demo passed"
