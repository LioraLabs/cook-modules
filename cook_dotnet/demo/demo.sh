#!/bin/sh
set -eu

module_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
demo_dir=$(mktemp -d "${TMPDIR:-/tmp}/cook-dotnet-demo.XXXXXX")
trap 'rm -rf -- "$demo_dir"' EXIT

cp "$module_dir/cook_dotnet.lua" "$demo_dir/"
cp -R "$module_dir/cook_dotnet" "$demo_dir/"
cp -R "$module_dir/demo/." "$demo_dir/"
cd "$demo_dir"
export XDG_CACHE_HOME="$demo_dir/cache"

nonce=$(date +%s%N)
sed -i "s/v1/baseline-$nonce/" Lib/Message.cs

echo "== cold graph build =="
cook dotnet:build --color never

echo "== unchanged graph: cache hit =="
cook dotnet:build --color never

echo "== missing discovery manifest: restored without MSBuild =="
mv build/dotnet/discovery.lua "$demo_dir/discovery.saved"
cook dotnet:build --color never -v 2>&1 | tee restore.log
test -f build/dotnet/discovery.lua
if grep -q "dotnet:discover/build/dotnet/discovery.lua.*rebuild" restore.log; then exit 1; fi
rm -f "$demo_dir/discovery.saved"

echo "== project change: discovery invalidates through its recipe input =="
printf '\n<!-- discovery-%s -->\n' "$nonce" >> Lib/Lib.csproj
cook dotnet:build --color never -v 2>&1 | tee discovery-change.log
grep -q "dotnet:discover/build/dotnet/discovery.lua.*rebuild" discovery-change.log

echo "== private implementation change: App stays cached =="
sed -i "s/baseline-$nonce/private-$nonce/" Lib/Message.cs
cook dotnet:build --color never -v 2>&1 | tee private.log
grep -q "dotnet:App.*cached" private.log

echo "== projected app uses the new library without recompiling App =="
cook dotnet:run --color never --replay-logs 2>&1 | tee private-run.log
grep -q "hello private-$nonce" private-run.log

echo "== public API change: App rebuilds =="
sed -i '/public static string Text/a\    public static int Version => 2;' Lib/Message.cs
cook dotnet:build --color never -v 2>&1 | tee public.log
grep -q "dotnet:App.*rebuild" public.log

echo "== runnable projection after propagation =="
cook dotnet:run --color never --replay-logs 2>&1 | tee run.log
grep -q "hello private-$nonce" run.log

echo "== configuration change: discovery key and conditional graph change =="
if grep -q "ReleaseOnly.csproj" build/dotnet/discovery.lua; then exit 1; fi
sed -i 's/configuration = "Debug"/configuration = "Release"/' Cookfile
cook dotnet:build --color never -v 2>&1 | tee release.log
grep -q "dotnet:discover/build/dotnet/discovery.lua.*rebuild" release.log
grep -q "ReleaseOnly.csproj" build/dotnet/discovery.lua
sed -i 's/configuration = "Release"/configuration = "Debug"/' Cookfile
cook dotnet:build --color never -v 2>&1 | tee debug.log
grep -q "dotnet:discover.*1/2 cached" debug.log
if grep -q "ReleaseOnly.csproj" build/dotnet/discovery.lua; then exit 1; fi

echo "cook_dotnet demo passed"
