#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][string]$ConnectionDll,
    [Parameter(Mandatory = $true)][string]$SdkDir,
    [Parameter(Mandatory = $true)][string]$CoreDll,
    [switch]$ExpectMismatch
)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Temp\nexo-binding-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
# JIT the actual failing method in .NET 8 without constructing NexoClient or
# opening a SQL connection. Each run has a fresh assembly load context/process.
[IO.File]::WriteAllText((Join-Path $root 'Binding.csproj'), '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0-windows</TargetFramework><UseWPF>true</UseWPF><PlatformTarget>x64</PlatformTarget><ImplicitUsings>enable</ImplicitUsings></PropertyGroup></Project>')
[IO.File]::WriteAllText((Join-Path $root 'NuGet.Config'), '<configuration><packageSources><clear /></packageSources></configuration>')
[IO.File]::WriteAllText((Join-Path $root 'Program.cs'), @'
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.Loader;

try
{
    var connection = Path.GetFullPath(args[0]);
    var sdk = Path.GetFullPath(args[1]);
    var core = Path.GetFullPath(args[2]);
    AppDomain.CurrentDomain.AssemblyResolve += (_, request) =>
    {
        var requested = new AssemblyName(request.Name);
        var path = requested.Name == "Zapqio.Runner.Module.Core"
            ? core : Path.Combine(sdk, requested.Name + ".dll");
        return File.Exists(path) ? Assembly.LoadFrom(path) : null;
    };
    var assembly = Assembly.LoadFrom(connection);
    var method = assembly.GetType("Nexo.WhoAmI", throwOnError: true)!.GetMethod("Run")!;
    RuntimeHelpers.PrepareMethod(method.MethodHandle);
    Console.WriteLine("PASS JIT Nexo.WhoAmI.Run on " + System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription);
    return 0;
}
catch (Exception exception)
{
    Console.Error.WriteLine(exception);
    return 1;
}
'@)
$dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
$log = Join-Path $root 'build.log'
& $dotnet build (Join-Path $root 'Binding.csproj') -c Release --nologo -v quiet *> $log
if ($LASTEXITCODE -ne 0) { throw "Cannot build binding probe: $log" }
$ConnectionDll = (Resolve-Path -LiteralPath $ConnectionDll).Path
$SdkDir = (Resolve-Path -LiteralPath $SdkDir).Path
$CoreDll = (Resolve-Path -LiteralPath $CoreDll).Path
$runLog = Join-Path $root 'binding.log'
$ErrorActionPreference = 'Continue'
& $dotnet (Join-Path $root 'bin\Release\net8.0-windows\Binding.dll') $ConnectionDll $SdkDir $CoreDll *> $runLog
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$result = [IO.File]::ReadAllText($runLog)
if ($ExpectMismatch) {
    if ($code -eq 0 -or $result -notmatch 'FileLoadException|manifest definition does not match') { throw "Expected the original binding failure; log: $runLog" }
    Write-Host 'PASS reproduced the original binding failure with the old Connection DLL'
}
elseif ($code -ne 0) { throw "JIT of WhoAmI.Run failed: $runLog" }
else { Write-Host $result.Trim() }
Write-Host "Log: $runLog"
