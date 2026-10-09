# Zapqio.Nexo.Connection

Shared InsERT nexo connection for [Zapqio Runner](https://github.com/zapqio/dotnet-runner)
modules. Provides `Nexo.NexoClient`, connection settings and SDK build references.

## Usage

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

The InsERT nexo SDK is **not** included and must be installed on the build machine.
By default it is expected in `C:\nexoSDK_61.1.0.9431\Bin\`. Override with
`NexoSdkVersion` (→ `C:\nexoSDK_<version>\Bin\`) or `nexoSdkBinPath` (any directory,
takes precedence). A missing SDK fails the build with `ZNEXO001`.

At runtime the runner provides `Nexo.Connection.zip` and `Nexo.Sdk.zip`, hence
`ExcludeAssets="runtime"`. See the [repository](https://github.com/zapqio/dotnet-module-nexo-connection)
for runner installation.

## License

Apache-2.0. InsERT software and SDK components remain subject to their own licenses.
