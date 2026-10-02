# Zapqio.Nexo.Connection

Shared InsERT nexo connection for [Zapqio Runner](https://github.com/zapqio/dotnet-runner)
modules. Provides `Nexo.NexoClient`, connection settings and SDK build references.

## Reference from a module

```xml
<PropertyGroup>
  <TargetFramework>net8.0-windows</TargetFramework>
  <UseWPF>true</UseWPF>
  <PlatformTarget>x64</PlatformTarget>
  <nexoSdkBinPath>C:\nexoSDK_61.1.0.9431\Bin\</nexoSdkBinPath>
</PropertyGroup>
<ItemGroup>
  <PackageReference Include="Zapqio.Runner.Module.Core" Version="1.2.0" ExcludeAssets="runtime" />
  <PackageReference Include="Zapqio.Nexo.Connection" Version="1.1.3" ExcludeAssets="runtime" />
</ItemGroup>
```

The SDK must be available separately on the machine that compiles the module.
With no overrides, the package uses `C:\nexoSDK_61.1.0.9431\Bin\`. Set
`NexoSdkVersion` in your project to use `C:\nexoSDK_<version>\Bin\`, or set
`nexoSdkBinPath` to an existing SDK `Bin` directory anywhere on disk. An explicit
path takes precedence over the version-derived path; the trailing slash is optional.
Both settings can also be supplied in `Directory.Build.props` or through `-p:`.

A build without the required SDK files fails with `ZNEXO001` and the missing path.
Restore does not download the InsERT SDK. For source builds on a runner, prepare
the SDK with `install-nexo.ps1 -BuildTools`; CI prepares its SDK before publish.

This NuGet package
contains our connection library and build references; it does not contain InsERT DLLs.

At runtime, the runner needs `Nexo.Connection.zip`, `Nexo.Sdk.zip` for the client's
nexo version, and connection settings. Keep the Connection package and runtime ZIP
on the same release. `ExcludeAssets="runtime"` lets consumer modules use the shared
runtime installation instead of shipping their own copy.

See the [installation instructions](https://github.com/zapqio/dotnet-module-nexo-connection)
for SDK setup and runner configuration.

## License

The Zapqio code in this package is licensed under Apache-2.0; see `LICENSE`.
InsERT software and SDK components remain subject to their own licenses.
