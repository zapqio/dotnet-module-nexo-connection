param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$RuntimeZipPath,
    [Parameter(Mandatory = $true)][string]$SdkBinPath,
    [string]$CorePackagePath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('zapqio-nexo-package-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$feed = Join-Path $testRoot 'feed'
[void][IO.Directory]::CreateDirectory($feed)
Copy-Item -LiteralPath $PackagePath -Destination $feed
if ($CorePackagePath) {
    Copy-Item -LiteralPath $CorePackagePath -Destination $feed
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Read-Entry($Archive, [string]$Name) {
    $entry = $Archive.GetEntry($Name)
    if (-not $entry) {
        throw "Missing archive entry: $Name"
    }

    $reader = [IO.StreamReader]::new($entry.Open())
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

function Get-EntryHash($Archive, [string]$Name) {
    $entry = $Archive.GetEntry($Name)
    if (-not $entry) {
        throw "Missing archive entry: $Name"
    }

    $stream = $entry.Open()
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($hasher.ComputeHash($stream))
    }
    finally {
        $stream.Dispose()
        $hasher.Dispose()
    }
}

$package = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $PackagePath).Path)
$runtime = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $RuntimeZipPath).Path)
try {
    [xml]$manifest = Read-Entry $package 'Zapqio.Nexo.Connection.nuspec'
    $version = $manifest.package.metadata.version
    Assert-Equal $manifest.package.metadata.id 'Zapqio.Nexo.Connection' 'Package ID.'
    Assert-Equal $manifest.package.metadata.license.InnerText 'Apache-2.0' 'Package license.'
    Assert-Equal $manifest.package.metadata.readme 'NUGET.md' 'Package README.'
    $dependencies = @($manifest.package.metadata.dependencies.group.dependency)
    Assert-Equal $dependencies.Count 1 'Dependency count.'
    Assert-Equal $dependencies[0].id 'Zapqio.Runner.Module.Core' 'Core dependency ID.'
    Assert-Equal $dependencies[0].version '1.2.0' 'Core dependency version.'
    [xml]$props = Read-Entry $package 'build/Zapqio.Nexo.Connection.props'
    $defaultVersion = $props.Project.PropertyGroup.NexoSdkVersion.InnerText
    [void](Read-Entry $package 'build/Zapqio.Nexo.Connection.targets')
    [void](Read-Entry $package 'LICENSE')
    [void](Read-Entry $package 'NUGET.md')
    [void](Read-Entry $runtime 'LICENSE')
    [void](Read-Entry $runtime 'update-nexo-sdk.ps1')
    Assert-Equal (Read-Entry $runtime '##Dll').Trim() 'Nexo.Connection.dll' 'Runtime DLL marker.'
    Assert-Equal (Read-Entry $runtime '##Shared').Trim() 'shared' 'Shared module marker.'
    Assert-Equal (Get-EntryHash $package 'lib/net8.0-windows7.0/Nexo.Connection.dll') (Get-EntryHash $runtime 'Nexo.Connection.dll') 'NuGet and runtime DLL hashes.'
    foreach ($archive in @($package, $runtime)) {
        $dllNames = @($archive.Entries | Where-Object { $_.Name -like '*.dll' } | ForEach-Object { $_.Name })
        Assert-Equal $dllNames.Count 1 'Only the Connection DLL may be distributed.'
        Assert-Equal $dllNames[0] 'Nexo.Connection.dll' 'Unexpected DLL in archive.'
    }

    $dllPath = Join-Path $testRoot 'Nexo.Connection.dll'
    [IO.Compression.ZipFileExtensions]::ExtractToFile($runtime.GetEntry('Nexo.Connection.dll'), $dllPath)
    Assert-Equal ([Reflection.AssemblyName]::GetAssemblyName($dllPath).Version.ToString()) '1.0.0.0' 'Assembly identity.'
    Assert-Equal (([Diagnostics.FileVersionInfo]::GetVersionInfo($dllPath).ProductVersion -split '\+')[0]) $version 'DLL product version.'
}
finally {
    $package.Dispose()
    $runtime.Dispose()
}

$publicSource = '<add key="nuget.org" value="https://api.nuget.org/v3/index.json"/>'
if ($CorePackagePath) {
    $publicSource = ''
}

$config = '<configuration><packageSources><clear/><add key="prepared-package" value="feed"/>' + $publicSource + '</packageSources><config><add key="globalPackagesFolder" value="packages"/></config></configuration>'
[IO.File]::WriteAllText((Join-Path $testRoot 'NuGet.Config'), $config)

function Invoke-Dotnet([string]$Name, [string[]]$Arguments, [switch]$ExpectFailure) {
    $log = Join-Path $testRoot ($Name + '.log')
    & dotnet @Arguments *> $log
    $exitCode = $LASTEXITCODE
    $text = [IO.File]::ReadAllText($log)
    if ($ExpectFailure) {
        if ($exitCode -eq 0) {
            throw "Expected failure: $Name. Log: $log"
        }
    }
    elseif ($exitCode -ne 0) {
        throw "dotnet failed: $Name. Log: $log`n$text"
    }

    return $text
}

function New-Probe([string]$Name, [string]$ProjectProperties = '', [string]$DirectoryProperties = '') {
    $directory = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory($directory)
    $project = Join-Path $directory 'Probe.csproj'
    $xml = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0-windows</TargetFramework>
    <UseWPF>true</UseWPF>
    <PlatformTarget>x64</PlatformTarget>
    <ImplicitUsings>enable</ImplicitUsings>
    $ProjectProperties
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Zapqio.Runner.Module.Core" Version="[1.2.0]" ExcludeAssets="runtime" />
    <PackageReference Include="Zapqio.Nexo.Connection" Version="[$version]" ExcludeAssets="runtime" />
  </ItemGroup>
</Project>
"@
    [IO.File]::WriteAllText($project, $xml)
    if ($DirectoryProperties) {
        [IO.File]::WriteAllText((Join-Path $directory 'Directory.Build.props'), "<Project><PropertyGroup>$DirectoryProperties</PropertyGroup></Project>")
    }

    [IO.File]::WriteAllText((Join-Path $directory 'Probe.cs'), @'
using Nexo;
using Zapqio.Runner.Core;
public class Probe(NexoClient client) : IRunnerMethod
{
    public string NameMethod() => "Package probe";
    public Type InData() => typeof(string);
    public Type OutData() => typeof(string);
    public Task<string> Run(string data) => Task.FromResult(client.Uchwyt.GetType().Name);
}
'@)
    [void](Invoke-Dotnet ($Name + '-restore') @('restore', $project, '--nologo', '-p:NuGetAudit=false'))
    return $project
}

function Check-References([string]$Name, [string]$Project, [string]$ExpectedPath, [string[]]$Properties = @(), [string]$CopyLocal = 'false') {
    $arguments = @('msbuild', $Project, '--nologo', '-getItem:Reference') + $Properties
    $evaluation = Invoke-Dotnet ($Name + '-evaluate') $arguments | ConvertFrom-Json
    $sdkReferences = @($evaluation.Items.Reference | Where-Object { $_.Identity -like 'InsERT.*' })
    Assert-Equal $sdkReferences.Count 8 "$Name reference count."
    foreach ($reference in $sdkReferences) {
        $expected = Join-Path $ExpectedPath ($reference.Identity + '.dll')
        Assert-Equal ([IO.Path]::GetFullPath($reference.HintPath)) ([IO.Path]::GetFullPath($expected)) "$Name SDK reference."
        Assert-Equal $reference.Private $CopyLocal "$Name copy local."
    }

    Write-Host "PASS $Name"
}

$default = New-Probe 'default'
Check-References 'default' $default "C:\nexoSDK_$defaultVersion\Bin"
$testVersion = '99.1.0.1234'
$versionProperty = "<NexoSdkVersion>$testVersion</NexoSdkVersion>"
$projectVersion = New-Probe 'project-version' $versionProperty
Check-References 'project-version' $projectVersion "C:\nexoSDK_$testVersion\Bin"
$directoryVersion = New-Probe 'directory-version' '' $versionProperty
Check-References 'directory-version' $directoryVersion "C:\nexoSDK_$testVersion\Bin"
Check-References 'command-version' $default "C:\nexoSDK_$testVersion\Bin" @("-p:NexoSdkVersion=$testVersion")

$customPath = Join-Path $testRoot 'custom SDK with spaces'
$pathProperty = '<nexoSdkBinPath>' + [Security.SecurityElement]::Escape($customPath) + '</nexoSdkBinPath>'
$projectPath = New-Probe 'project-path' ($versionProperty + $pathProperty)
Check-References 'project-path-precedence' $projectPath $customPath
$directoryPath = New-Probe 'directory-path' '' $pathProperty
Check-References 'directory-path' $directoryPath $customPath
Check-References 'command-path' $default $customPath @("-p:nexoSdkBinPath=$customPath")
$copyLocal = New-Probe 'copy-local' ($pathProperty + '<NexoSdkCopyLocal>true</NexoSdkCopyLocal>')
Check-References 'copy-local' $copyLocal $customPath @() 'true'

$missing = Invoke-Dotnet 'missing-sdk' @('build', $projectPath, '--no-restore', '--nologo') -ExpectFailure
if ($missing -notmatch 'ZNEXO001' -or -not $missing.Contains($customPath)) {
    throw 'Missing SDK must report ZNEXO001 and the requested path.'
}

Write-Host 'PASS missing-sdk'
$realPathProperty = '<nexoSdkBinPath>' + [Security.SecurityElement]::Escape($SdkBinPath.TrimEnd('\', '/')) + '</nexoSdkBinPath>'
$consumer = New-Probe 'consumer' $realPathProperty
$publish = Join-Path $testRoot 'consumer-publish'
[void](Invoke-Dotnet 'consumer-publish' @('publish', $consumer, '--no-restore', '-c', 'Release', '-o', $publish, '--nologo'))
$forbidden = @(Get-ChildItem -LiteralPath $publish -File | Where-Object { $_.Name -like 'InsERT.*' -or $_.Name -in @('Nexo.Connection.dll', 'Zapqio.Runner.Module.Core.dll') })
if ($forbidden.Count -gt 0) {
    throw "Consumer includes shared DLLs: $($forbidden.Name -join ', ')"
}

Write-Host "PASS consumer-publish and archive validation ($version)"
Write-Host "Logs and isolated cache: $testRoot"
