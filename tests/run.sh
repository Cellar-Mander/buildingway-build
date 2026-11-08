#!/usr/bin/env bash
# Checks a packed Buildingway.Build against tests/Sample: the clean sample builds and passes
# dotnet format, and each kind of rule the SDK carries fails when broken.
# Usage: tests/run.sh <folder with the .nupkg> <version>
set -euo pipefail

# NuGet needs a native path; Git Bash on Windows gives /d/... unless asked for -W
feed=$(cd "$1" && { pwd -W 2>/dev/null || pwd; })
version=$2
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# A private package cache, so a re-packed 0.0.0-dev is never served stale
export NUGET_PACKAGES=$work/packages
failures=0

# Copies the sample to $work/<name> with a feed and SDK pin for the package under test
sample() {
  local dir=$work/$1
  cp -r "$here/Sample" "$dir"
  cat > "$dir/global.json" <<JSON
{ "msbuild-sdks": { "Buildingway.Build": "$version" } }
JSON
  cat > "$dir/nuget.config" <<XML
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
    <add key="local" value="$feed" />
  </packageSources>
</configuration>
XML
  echo "$dir"
}

# fmt <dir> [subcommand]: dotnet format --verify-no-changes, run from inside the sample. Given a
# path from Git Bash on Windows, dotnet format fails to match it to the loaded project, skips every
# file and reports success, so it only gets the project's file name.
fmt() { local dir=$1; shift; (cd "$dir" && dotnet format Sample.csproj "$@" --verify-no-changes); }

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

# expect <ok|fail:<pattern>> <name> <command...>: runs the command and checks its result. A
# failure only counts if its output matches the pattern, so an unrelated error can't pass a check.
expect() {
  local want=$1 name=$2; shift 2
  local log=$work/$name.log got=ok
  "$@" > "$log" 2>&1 || got=fail
  if [[ $want == ok && $got == ok ]] ||
     { [[ $want == fail:* && $got == fail ]] && grep -q -- "${want#fail:}" "$log"; }; then
    pass "$name"
  else
    fail "$name (wanted $want, got $got)"; cat "$log"
  fi
}

dir=$(sample clean)
expect ok clean-build dotnet build "$dir" --nologo
expect ok clean-format fmt "$dir"
if [[ -f $dir/packages.lock.json ]]; then pass lock-file; else fail lock-file; fi

# Naming: a private instance field must be camelCase (IDE1006)
dir=$(sample naming)
sed -i 's/count/Count/g' "$dir/Counter.cs"
expect fail:IDE1006 naming-rule fmt "$dir" style

# No brace or indent checks: those rules match dotnet format's defaults, so such a check would
# pass without the SDK too. The naming rules above are the part a missing .globalconfig breaks.

# A compiler warning (CS0168, unused variable) fails the build...
dir=$(sample warning)
sed -i 's/^        lock (Gate)$/        int unused;\n        lock (Gate)/' "$dir/Counter.cs"
expect fail:'error CS0168' warning-is-error dotnet build "$dir" --nologo
# ...unless the project opts out, which the SDK's defaults allow
sed -i 's|<Nullable>enable</Nullable>|&\n    <TreatWarningsAsErrors>false</TreatWarningsAsErrors>|' "$dir/Sample.csproj"
expect ok project-overrides dotnet build "$dir" --nologo

# A local .editorconfig overrides the shared rules (the per-repo escape hatch)
dir=$(sample override)
sed -i 's/count/Count/g' "$dir/Counter.cs"
printf 'root = true\n\n[*.cs]\ndotnet_naming_rule.instance_fields_camel.severity = none\n' > "$dir/.editorconfig"
expect ok editorconfig-overrides fmt "$dir" style

# member <dir> <line...>: adds lines inside the sample's Counter class, before its closing brace
member() {
  local dir=$1; shift
  sed -i '$ d' "$dir/Counter.cs"
  printf '%s\n' "$@" '}' >> "$dir/Counter.cs"
}

# Banned APIs (RS0030): backtracking regex and Thread.Sleep fail the build...
dir=$(sample regex)
member "$dir" '    public static bool Match(string s) => System.Text.RegularExpressions.Regex.IsMatch(s, "a+");'
expect fail:'error RS0030' banned-regex dotnet build "$dir" --nologo
# ...but not in a test project, which reads only its own fixtures
sed -i 's|<Nullable>enable</Nullable>|&\n    <IsTestProject>true</IsTestProject>|' "$dir/Sample.csproj"
expect ok test-project-exempt dotnet build "$dir" --nologo

dir=$(sample generated-regex)
sed -i 's/^public class Counter$/public partial class Counter/' "$dir/Counter.cs"
member "$dir" '    [System.Text.RegularExpressions.GeneratedRegex("a+")]' '    private static partial System.Text.RegularExpressions.Regex Pattern();'
expect fail:'error RS0030' banned-generated-regex dotnet build "$dir" --nologo

# A non-backtracking regex is allowed once the ban is suppressed with a reason
dir=$(sample non-backtracking)
member "$dir" '#pragma warning disable RS0030 // NonBacktracking: linear in the input' \
  '    private static readonly System.Text.RegularExpressions.Regex Pattern = new("a+", System.Text.RegularExpressions.RegexOptions.NonBacktracking);' \
  '#pragma warning restore RS0030'
expect ok non-backtracking-allowed dotnet build "$dir" --nologo

dir=$(sample sleep)
member "$dir" '    public static void Pause() => System.Threading.Thread.Sleep(10);'
expect fail:'error RS0030' banned-sleep dotnet build "$dir" --nologo

# Blocking on a task (VSTHRD002)
dir=$(sample blocking-wait)
member "$dir" '    public static int Wait(System.Threading.Tasks.Task<int> task) => task.Result;'
expect fail:'error VSTHRD002' blocking-wait dotnet build "$dir" --nologo

# A disposable field in a class that isn't disposable (IDISP006), as a window or hook left undisposed
dir=$(sample undisposed)
member "$dir" '    private readonly System.IO.FileStream stream = System.IO.File.OpenRead("counter.bin");' '    public long Length => stream.Length;'
expect fail:'error IDISP006' undisposed-field dotnet build "$dir" --nologo

# Rules the .globalconfig turns off stay off: an async method without the Async suffix (VSTHRD200)
dir=$(sample tuned-off)
member "$dir" '    public static async System.Threading.Tasks.Task Yield() => await System.Threading.Tasks.Task.Yield();'
expect ok tuned-rules-off dotnet build "$dir" --nologo

echo
if (( failures )); then echo "$failures check(s) failed"; exit 1; fi
echo "All checks passed"
