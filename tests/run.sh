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
expect ok clean-format dotnet format "$dir/Sample.csproj" --verify-no-changes
if [[ -f $dir/packages.lock.json ]]; then pass lock-file; else fail lock-file; fi

# Naming: a private instance field must be camelCase (IDE1006)
dir=$(sample naming)
sed -i 's/count/Count/g' "$dir/Counter.cs"
expect fail:IDE1006 naming-rule dotnet format "$dir/Sample.csproj" style --verify-no-changes

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
expect ok editorconfig-overrides dotnet format "$dir/Sample.csproj" style --verify-no-changes

echo
if (( failures )); then echo "$failures check(s) failed"; exit 1; fi
echo "All checks passed"
