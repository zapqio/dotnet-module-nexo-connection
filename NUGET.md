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
  <PackageReference Include="Zapqio.Nexo.Connection" Version="1.1.3" ExcludeAssets="runtime" />
</ItemGroup>
```

Target .NET 8 and x64: InsERT libraries do not load on .NET 9+. Your module ZIP should contain only
your own DLL. On the runner, Core comes with the runner, `NexoClient` from `Nexo.Connection.zip`
and the SDK from `Nexo.Sdk.zip`. Use the NuGet package and `Nexo.Connection.zip` from the same release.

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
`install-nexo.ps1 -BuildTools` prepares the SDK for builds.

Runner installation and configuration: [repository README](https://github.com/zapqio/dotnet-module-nexo-connection).

## License

The Zapqio code in this package is licensed under Apache-2.0; see `LICENSE`.
InsERT software and SDK components remain subject to their own licenses.
