# buildingway-build

`Buildingway.Build` is an MSBuild project SDK with the build settings and code style every
Dalamud plugin repo shares, so a repo needs no `Directory.Build.props` or `.editorconfig` of its own.

| Setting | Value |
|---|---|
| `TreatWarningsAsErrors` | `true`: any compiler or analyzer warning fails the build |
| `RestorePackagesWithLockFile` | `true`: restores are reproducible (`packages.lock.json`) |
| Code style | [`Buildingway.globalconfig`](Buildingway.Build/Sdk/Buildingway.globalconfig): 4-space indent, LF, Allman braces, `var`, and naming rules (private fields camelCase; private statics, consts and events PascalCase, events prefixed `On`) that `dotnet format` enforces |

A project can still set either property in its own csproj (a `Directory.Build.props` can't, as it
is read before the SDK), and a local `.editorconfig` overrides any code style rule.

## Using it in a plugin repo

1. Add the SDK to every project, after its main SDK:

   ```xml
   <Project Sdk="Dalamud.NET.Sdk/15.0.0">
     <Sdk Name="Buildingway.Build" />
   ```

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
