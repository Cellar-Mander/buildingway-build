# buildingway-build

`Buildingway.Build` is an MSBuild project SDK with the build settings and code style every
Dalamud plugin repo shares, so a repo needs no `Directory.Build.props` or `.editorconfig` of its own.

| Setting | Value |
|---|---|
| `TreatWarningsAsErrors` | `true`: any compiler or analyzer warning fails the build |
| `RestorePackagesWithLockFile` | `true`: restores are reproducible (`packages.lock.json`) |
| Code style | [`Buildingway.globalconfig`](Buildingway.Build/Sdk/Buildingway.globalconfig): 4-space indent, LF, Allman braces, `var`, and naming rules (private fields camelCase; private statics, consts and events PascalCase, events prefixed `On`) that `dotnet format` enforces |
| Analyzers | Build-time only, so nothing ships with the plugin. [BannedApiAnalyzers](https://github.com/dotnet/roslyn-analyzers/blob/main/src/Microsoft.CodeAnalysis.BannedApiAnalyzers/BannedApiAnalyzers.Help.md) bans what [`BannedSymbols.txt`](Buildingway.Build/Sdk/BannedSymbols.txt) lists: `Regex` and `[GeneratedRegex]`, since backtracking can take exponential time on untrusted text, and `Thread.Sleep`, which freezes the game on its threads. Test projects are exempt. [VS Threading analyzers](https://microsoft.github.io/vs-threading/analyzers/) catch blocking waits on tasks, `async void` and unobserved tasks. [IDisposableAnalyzers](https://github.com/DotNetAnalyzers/IDisposableAnalyzers) catch disposables, such as windows and hooks, that are never disposed. The `.globalconfig` turns off the rules from these that fired only on correct code |

A project can still set either property in its own csproj (a `Directory.Build.props` can't, as it
is read before the SDK), and a local `.editorconfig` overrides any code style or analyzer rule.

A non-backtracking regex is allowed where the ban is suppressed with the reason, e.g.
`#pragma warning disable RS0030 // NonBacktracking: linear in the input` before
`new Regex(pattern, RegexOptions.NonBacktracking)`. Do the same for a deliberate blocking wait
(VSTHRD002), such as flushing a file during `Dispose`.

The SDK only adds checks: warnings as errors, analyzers, banned APIs, code style and the lock-file
setting. Anything that changes the build output belongs in the project, not here. That is what
lets the official Dalamud plugin repo's (D17) build skip the SDK and still build the same plugin.

## Using it in a plugin repo

1. Import the SDK first and last in the body of the Dalamud plugin project and of every project
   it references, directly or not, skipped when `IsPlogonBuild` is `True`. Plogon, which runs
   D17's builds offline and so can't fetch this SDK from GitHub Packages, sets it:

   ```xml
   <Project Sdk="Dalamud.NET.Sdk/15.0.0">
     <Import Project="Sdk.props" Sdk="Buildingway.Build" Condition="'$(IsPlogonBuild)' != 'True'" />
     ...
     <Import Project="Sdk.targets" Sdk="Buildingway.Build" Condition="'$(IsPlogonBuild)' != 'True'" />
   </Project>
   ```

   Only projects outside the plugin's references, such as tests, can use
   `<Sdk Name="Buildingway.Build" />` after their main SDK instead. buildingway-ci's
   [`plogon-build.yml`](https://github.com/Cellar-Mander/buildingway-ci/blob/main/.github/workflows/plogon-build.yml)
   checks in CI that D17 can build the plugin.

2. Pin its version in `global.json` at the repo root. Dependabot's `nuget` updater bumps
   `msbuild-sdks` entries like other packages:

   ```json
   {
     "msbuild-sdks": {
       "Buildingway.Build": "0.1.0"
     }
   }
   ```

3. The package is on this owner's GitHub Packages feed, which asks for a token even for public
   packages, so set up the `buildingway` source and a `read:packages` token as in
   [buildingway-tools' README](https://github.com/Cellar-Mander/buildingway-tools#using-it-in-a-plugin-repo).
   Its `Buildingway.*` source mapping already covers this package. Unlike the tool, the SDK is
   needed to load any project, so **every build, format and IDE load needs the token**, and so
   does every CI job that builds. In the package's settings, under "Manage Actions access", give
   each plugin repo Read access, for its workflows and Dependabot.

`dotnet format` only sees the code style through a restored project; `--folder` mode ignores it.

## Developing

```bash
dotnet pack Buildingway.Build -c Release -o pack
tests/run.sh pack 0.0.0-dev
```

`tests/run.sh` builds and formats `tests/Sample` with the packed SDK, then breaks each kind of
rule in a copy and checks that it fails. It uses a private package cache, so a re-packed
`0.0.0-dev` is never served stale.

## Releasing

Push a tag `v<semver>` (e.g. `v0.1.0`); the Release workflow tests, packs that version, pushes
it to GitHub Packages with `github.token` and attaches the `.nupkg` to a GitHub release.
