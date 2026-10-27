# Zapqio.Nexo.Connection

Shared InsERT nexo (Subiekt) connection for [Zapqio Runner](https://github.com/zapqio/dotnet-runner)
modules: one `Nexo.NexoClient` per runner process, injected into your methods, plus build references
to the InsERT nexo SDK.

## Reference from a module

```xml
<PropertyGroup>
  <TargetFramework>net8.0-windows</TargetFramework>
  <UseWPF>true</UseWPF>
  <PlatformTarget>x64</PlatformTarget>
</PropertyGroup>
<ItemGroup>
  <PackageReference Include="Zapqio.Runner.Module.Core" Version="1.2.0" ExcludeAssets="runtime" />
  <PackageReference Include="Zapqio.Nexo.Connection" Version="1.1.4" ExcludeAssets="runtime" />
</ItemGroup>
```

Target .NET 8 and x64: InsERT libraries do not load on .NET 9+. Package the entire publish output,
including `nexo-module-source.zip` and `nexo-module-source.json`. On the runner, Core comes with the runner, `NexoClient` from `Nexo.Connection.zip`
and the SDK from `Nexo.Sdk.zip`. Use the NuGet package and `Nexo.Connection.zip` from the same build
for the target SDK. An SDK upgrade detects modules referencing Connection or InsERT and rebuilds
them from their embedded sources. This also works with modules deployed through Web, preserving
their deployment IDs and commits. Replacing only SDK files can fail even when InsERT's
`AssemblyVersion` is unchanged.

```csharp
using System;
using System.Threading.Tasks;
using InsERT.Moria.Uzytkownicy;
using Nexo;
using Zapqio.Runner.Core;

public class MyMethod(NexoClient client) : IRunnerMethod
{
    public string NameMethod() => "My method";
    public Type InData() => null;
    public Type OutData() => null;

    public Task<string> Run(string data) =>
        Task.FromResult(client.Uchwyt.PodajObiektTypu<IZalogowanyUzytkownik>().Dane.Sygnatura);
}
```

The connection opens on first `Uchwyt` access and is shared by all methods and concurrent jobs.
Missing settings and connection failures throw `NexoConnectionException`.

## InsERT nexo SDK

This package does not contain InsERT DLLs; the SDK must be present on the machine that compiles
the module. The package references `InsERT.Moria.API`, `InsERT.Moria.DaneDomyslne`,
`InsERT.Moria.ModelDanych`, `InsERT.Moria.Sfera`, `InsERT.Mox.Core`, `InsERT.Mox.DataExtensions`,
`InsERT.Mox.EntityFramework.Core` and `InsERT.Mox.EntityFrameworkSupport` (not copied to output) from:

- `C:\nexoSDK_61.1.0.9431\Bin\` by default,
- `C:\nexoSDK_<version>\Bin\` when `NexoSdkVersion` is set,
- any directory set in `nexoSdkBinPath` (takes precedence; trailing slash optional).

Set them in the project, in `Directory.Build.props` or with `-p:`. A missing SDK file fails the build
with `ZNEXO001`; restore does not download the SDK. `NexoSdkCopyLocal=true` copies the SDK libraries
to the output; keep the default `false` for runner packages. On a Zapqio runner,
`install-nexo.ps1` always prepares the SDK for builds.

The SDK updater creates a private Connection package with the **same package version**, plus matching
runtime ZIPs. Each source/SDK combination has a separate local feed and restore cache. Consumer
`PackageReference` entries stay unchanged. Preserve the generated source mapping and
`RestorePackagesPath` when customizing your build configuration; a public package with the same
version may contain a DLL compiled for a different SDK. Private variants are not republished to
nuget.org. Future SDK versions use the same process, provided the source still compiles against them.

Runner installation and configuration: [repository README](https://github.com/zapqio/dotnet-module-nexo-connection).

## Automatic source packaging (1.1.4+)

Once, update the Connection reference to 1.1.4, update the runner's nexo scripts and redeploy each
dependent module through the usual panel workflow. Thereafter no source registration or public
NuGet version bump is needed for SDK changes. Existing ZIPs without sources require this migration;
an assembly can identify dependencies but cannot provide the original source project.
The installer can retain a legacy module without sources only if its assembly references still
match the installed candidate set. This bootstraps the new private NuGet before the panel redeploy.
It never bypasses SDK identity mismatches. Automatic updates require embedded sources by default.

The publish target collects declared source/resources/content, referenced projects and custom
MSBuild imports. For additional build inputs declare `<NexoSourceInclude Include="path" />`.
Keep ProjectReference and linked files below a common source directory. Machine-specific generated
runner settings, bin/obj, NuGet.Config, Config directories, appsettings, .env and private signing keys
are excluded. Review your publish archive for custom secret files. Required generated inputs must
be reproducible by the project; external build tools and private package feeds need configuration
on the runner. `<NexoPackModuleSource>false</NexoPackModuleSource>` opts out and prevents automatic
rebuilding without a separately registered local source. Web-managed modules require embedded sources.

The updater preserves the original source archive across rebuilds, validates assembly identities,
then switches the complete set under the deployment lock. Only installed ZIP checksums change in
deployment state; IDs, source manifests, commits and reports are retained. Compilation failures
leave the old set installed; interrupted activation is recovered on the next updater run.

## License

The Zapqio code in this package is licensed under Apache-2.0; see `LICENSE`.
InsERT software and SDK components remain subject to their own licenses.
