#!/bin/sh
set -eu
module_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
graph_dir=$(mktemp -d "${TMPDIR:-/tmp}/cook-dotnet-graph.XXXXXX")
trap 'result=$?; if [ "$result" -ne 0 ]; then tail -n 30 "$graph_dir"/.cook/proof/*.log; fi; rm -rf -- "$graph_dir"' EXIT
cp "$module_dir/cook_dotnet.lua" "$graph_dir/"
cp -R "$module_dir/cook_dotnet" "$graph_dir/"
cd "$graph_dir"
mkdir -p .cook/proof
export XDG_CACHE_HOME="$graph_dir/.cook/cache"
export DOTNET_CLI_HOME="$graph_dir/.cook/native-home" DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1
cook=${COOK:-cook}
mkdir App Lib Eight Standard Gen
cat > Cookfile <<'EOF'
use cook_dotnet ./cook_dotnet.lua
cook_dotnet.workspace({ solution = "App/App.csproj", configuration = "Debug" })
EOF
cat > App/App.csproj <<'EOF'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType></PropertyGroup><ItemGroup><ProjectReference Include="../Lib/Lib.csproj" /></ItemGroup></Project>
EOF
cat > App/Program.cs <<'EOF'
System.Console.WriteLine(Library.Text);
System.Console.WriteLine(typeof(Library).GetProperty("Added") == null ? "absent" : "present");
#if !DEBUG
System.Console.WriteLine(Library.Released);
#endif
EOF
cat > Lib/Lib.csproj <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
<PropertyGroup><TargetFrameworks>netstandard2.1;net8.0</TargetFrameworks><EnableDefaultCompileItems>false</EnableDefaultCompileItems><EnableDefaultNoneItems>false</EnableDefaultNoneItems></PropertyGroup>
<ItemGroup><Compile Include="Common*.cs" /></ItemGroup>
<ItemGroup Condition="'$(TargetFramework)' == 'net8.0'"><Compile Include="Eight.cs" /><ProjectReference Include="../Eight/Eight.csproj" /></ItemGroup>
<ItemGroup Condition="'$(TargetFramework)' == 'netstandard2.1'"><Compile Include="Standard.cs" /><ProjectReference Include="../Standard/Standard.csproj" /></ItemGroup>
<ItemGroup Condition="'$(Configuration)' == 'Release'"><Compile Include="Release.cs" /></ItemGroup>
</Project>
EOF
for name in Eight Standard; do
cat > "$name/$name.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>netstandard2.1</TargetFramework></PropertyGroup></Project>
EOF
printf 'public class %sDependency { public static string Text => "%s"; }\n' "$name" "$name" > "$name/Code.cs"
done
printf 'public partial class Library { public static string Text => EightDependency.Text + "-eight"; }\n' > Lib/Eight.cs
printf 'public partial class Library { public static string Text => StandardDependency.Text + "-standard"; }\n' > Lib/Standard.cs
printf 'public partial class Library {}\n' > Lib/Common.cs
printf 'public partial class Library { public static int Released => 1; }\n' > Lib/Release.cs
# The native SDK chooses net8.0 for the net10.0 caller, not the other inner build.
dotnet build App/App.csproj --artifacts-path "$graph_dir/native" --verbosity quiet > .cook/proof/native.log
native=$(dotnet "$graph_dir/native/bin/App/debug/App.dll")
[ "$native" = "$(printf 'Eight-eight\nabsent')" ]
"$cook" dotnet:build --color never -v > .cook/proof/cold.log 2>&1 || { cat .cook/proof/cold.log; exit 1; }
"$cook" dotnet:run --color never --replay-logs > .cook/proof/run.log 2>&1
printf '%s\n' "$native" | while IFS= read -r line; do grep -Fq "$line" .cook/proof/run.log; done
# Record exact ownership boundaries: a sibling build must not rewrite these files.
find build/dotnet/obj/Lib/debug_net8.0 build/dotnet/bin/Lib/debug_net8.0 -type f -exec stat --format='%n %y' {} \; | sort > .cook/proof/sibling-before.txt
find build/dotnet/obj/Lib -maxdepth 1 -type f -exec stat --format='%n %y' {} \; | sort > .cook/proof/restore-before.txt
# Framework-conditioned source edits must rebuild only their owning inner build.
printf '\n// changed standard implementation\n' >> Lib/Standard.cs
"$cook" dotnet:build --color never -v > .cook/proof/standard-edit.log 2>&1
grep -q 'dotnet:Lib:tfm-6e6574382e30.*cached' .cook/proof/standard-edit.log
grep -q 'dotnet:Lib:tfm-6e65747374616e64617264322e31.*rebuild' .cook/proof/standard-edit.log
grep -q 'dotnet:App.*cached' .cook/proof/standard-edit.log
grep -q 'cook materialize cook_dotnet.graph restored' .cook/proof/standard-edit.log
find build/dotnet/obj/Lib/debug_net8.0 build/dotnet/bin/Lib/debug_net8.0 -type f -exec stat --format='%n %y' {} \; | sort > .cook/proof/sibling-after.txt
find build/dotnet/obj/Lib -maxdepth 1 -type f -exec stat --format='%n %y' {} \; | sort > .cook/proof/restore-after.txt
cmp .cook/proof/sibling-before.txt .cook/proof/sibling-after.txt
cmp .cook/proof/restore-before.txt .cook/proof/restore-after.txt
# Excluded source changes are not determinants of a Debug build.
printf '\n// release only\n' >> Lib/Release.cs
"$cook" dotnet:build --color never -v > .cook/proof/excluded.log 2>&1
grep -q 'dotnet:Lib:tfm-6e6574382e30.*cached' .cook/proof/excluded.log
grep -q 'dotnet:Lib:tfm-6e65747374616e64617264322e31.*cached' .cook/proof/excluded.log
# Normal implementation changes leave consumers cached but update runnable output.
sed -i 's/\"-eight\"/\"-private\"/' Lib/Eight.cs
"$cook" dotnet:build --color never -v > .cook/proof/private.log 2>&1
grep -q 'dotnet:App.*cached' .cook/proof/private.log
grep -q 'cook materialize cook_dotnet.graph restored' .cook/proof/private.log
"$cook" dotnet:run --color never --replay-logs > .cook/proof/private-run.log 2>&1
grep -q Eight-private .cook/proof/private-run.log
# netstandard does not emit reference assemblies by default; its public API must still key consumers.
sed -i 's/ }$/ public static int AddedApi => 1; }/' Eight/Code.cs
"$cook" dotnet:build --color never -v > .cook/proof/dependency-public.log 2>&1
grep -q 'dotnet:Lib:tfm-6e6574382e30.*rebuild' .cook/proof/dependency-public.log
grep -q 'dotnet:App.*cached' .cook/proof/dependency-public.log
sed -i 's/\"Eight\"/\"Eight-private\"/' Eight/Code.cs
"$cook" dotnet:build --color never -v > .cook/proof/dependency-private.log 2>&1
grep -q 'dotnet:Lib:tfm-6e6574382e30.*cached' .cook/proof/dependency-private.log
grep -q 'dotnet:App.*cached' .cook/proof/dependency-private.log
"$cook" dotnet:run --color never --replay-logs > .cook/proof/dependency-private-run.log 2>&1
grep -q Eight-private-private .cook/proof/dependency-private-run.log
# Default SDK Compile globs also discover added and removed files with unchanged project XML.
sha256sum build/dotnet/obj/Eight/debug/ref/Eight.dll > .cook/proof/default-ref-before.txt
printf 'public class DefaultGlobAdded {}\n' > Eight/Added.cs
"$cook" dotnet:build --color never -v > .cook/proof/default-added.log 2>&1
grep -q 'dotnet:Lib:tfm-6e6574382e30.*rebuild' .cook/proof/default-added.log
rm Eight/Added.cs
"$cook" dotnet:build --color never -v > .cook/proof/default-removed.log 2>&1
sha256sum build/dotnet/obj/Eight/debug/ref/Eight.dll > .cook/proof/default-ref-after.txt
cmp .cook/proof/default-ref-before.txt .cook/proof/default-ref-after.txt
# New and removed wildcard items must refresh discovery without changing csproj.
printf 'public partial class Library { public static int Added => 7; }\n' > Lib/CommonAdded.cs
"$cook" dotnet:build --color never -v > .cook/proof/added.log 2>&1
grep -q 'dotnet:App.*rebuild' .cook/proof/added.log
"$cook" dotnet:run --color never --replay-logs > .cook/proof/added-run.log 2>&1
grep -q present .cook/proof/added-run.log
rm Lib/CommonAdded.cs
"$cook" dotnet:build --color never -v > .cook/proof/removed.log 2>&1
grep -q 'cook materialize cook_dotnet.graph' .cook/proof/removed.log
"$cook" dotnet:run --color never --replay-logs > .cook/proof/removed-run.log 2>&1
grep -q absent .cook/proof/removed-run.log
# Restore metadata has an owner and can be recovered independently of inner builds.
rm build/dotnet/obj/Lib/project.assets.json
"$cook" dotnet:build --color never -v > .cook/proof/restore-recover.log 2>&1
test -s build/dotnet/obj/Lib/project.assets.json
# Native and Cook Release builds must both evaluate the additional Compile item.
sed -i 's/configuration = "Debug"/configuration = "Release"/' Cookfile
dotnet build App/App.csproj --configuration Release --artifacts-path "$graph_dir/native" --verbosity quiet > .cook/proof/native-release.log
"$cook" dotnet:build --color never -v > .cook/proof/release.log 2>&1
"$cook" dotnet:run --color never --replay-logs > .cook/proof/release-run.log 2>&1
grep -q "$(dotnet "$graph_dir/native/bin/App/release/App.dll")" .cook/proof/release-run.log
sed -i 's/Released => 1/Released => 2/' Lib/Release.cs
"$cook" dotnet:build --color never -v > .cook/proof/release-edit.log 2>&1
grep -q 'dotnet:Lib:tfm-6e6574382e30.*rebuild' .cook/proof/release-edit.log
grep -q 'dotnet:Lib:tfm-6e65747374616e64617264322e31.*rebuild' .cook/proof/release-edit.log
# A real Roslyn generator references the SDK's own assemblies, requiring no packages.
cat > Gen/Gen.csproj <<'EOF'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup><ItemGroup>
<Reference Include="Microsoft.CodeAnalysis"><HintPath>$(MSBuildSDKsPath)/../Roslyn/bincore/Microsoft.CodeAnalysis.dll</HintPath><Private>false</Private></Reference>
<Reference Include="Microsoft.CodeAnalysis.CSharp"><HintPath>$(MSBuildSDKsPath)/../Roslyn/bincore/Microsoft.CodeAnalysis.CSharp.dll</HintPath><Private>false</Private></Reference>
</ItemGroup></Project>
EOF
cat > Gen/Generator.cs <<'EOF'
using Microsoft.CodeAnalysis;
[Generator] public class Generator : ISourceGenerator {
    public void Initialize(GeneratorInitializationContext context) {}
    public void Execute(GeneratorExecutionContext context) {
        context.AddSource("Generated.g.cs", "public static class Generated { public static string Text => \"generated-one\"; }");
    }
}
EOF
sed -i 's@</ItemGroup>@<ProjectReference Include="../Gen/Gen.csproj" OutputItemType="Analyzer" ReferenceOutputAssembly="false" /></ItemGroup>@' App/App.csproj
printf '\nSystem.Console.WriteLine(Generated.Text);\n' >> App/Program.cs
"$cook" dotnet:build --color never -v > .cook/proof/generator.log 2>&1
sha256sum build/dotnet/obj/Gen/release/ref/Gen.dll > .cook/proof/generator-ref-before.txt
sed -i 's/generated-one/generated-two/' Gen/Generator.cs
"$cook" dotnet:build --color never -v > .cook/proof/generator-edit.log 2>&1
grep -q 'dotnet:App.*rebuild' .cook/proof/generator-edit.log
grep -q 'cook materialize cook_dotnet.graph restored' .cook/proof/generator-edit.log
sha256sum build/dotnet/obj/Gen/release/ref/Gen.dll > .cook/proof/generator-ref-after.txt
cmp .cook/proof/generator-ref-before.txt .cook/proof/generator-ref-after.txt
"$cook" dotnet:run --color never --replay-logs > .cook/proof/generator-run.log 2>&1
grep -q generated-two .cook/proof/generator-run.log
dotnet build App/App.csproj --configuration Release --artifacts-path "$graph_dir/native" --verbosity quiet > .cook/proof/native-generator.log
dotnet "$graph_dir/native/bin/App/release/App.dll" > .cook/proof/native-output.txt
while IFS= read -r line; do grep -Fq "$line" .cook/proof/generator-run.log; done < .cook/proof/native-output.txt
# The same evaluated-project/reference query works on the supported SDK 8 toolchain.
printf '{"sdk":{"version":"8.0.424","rollForward":"disable"}}\n' > global.json
sed -i 's/net10.0/net8.0/' App/App.csproj Gen/Gen.csproj
"$cook" dotnet:build --color never -v > .cook/proof/sdk8.log 2>&1
"$cook" dotnet:run --color never --replay-logs > .cook/proof/sdk8-run.log 2>&1
grep -q generated-two .cook/proof/sdk8-run.log
dotnet build App/App.csproj --configuration Release --artifacts-path "$graph_dir/native8" --verbosity quiet > .cook/proof/native8.log
dotnet "$graph_dir/native8/bin/App/release/App.dll" > .cook/proof/native8-output.txt
while IFS= read -r line; do grep -Fq "$line" .cook/proof/sdk8-run.log; done < .cook/proof/native8-output.txt
echo 'cook_dotnet evaluated graph passed'
