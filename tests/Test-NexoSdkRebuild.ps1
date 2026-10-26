#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][string]$SdkDir,
    [Parameter(Mandatory = $true)][string]$ConnectionDll,
    [string]$PreviousSdkDir
)
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$builder = Join-Path $repository 'build-nexo-set.ps1'
$updater = Join-Path $repository 'update-nexo-sdk.ps1'
. (& $builder -FunctionsOnly)
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Temp\nexo-sdk-rebuild-' + [guid]::NewGuid().ToString('N'))
$runner = Join-Path $root 'runner with spaces'
$modules = Join-Path $runner 'Modules'
[void][IO.Directory]::CreateDirectory($modules)
[IO.File]::WriteAllText((Join-Path $runner 'Zapqio.Runner.exe'), 'Fixture; never executed.')
$service = 'NexoRebuildFixture_' + [guid]::NewGuid().ToString('N')
Assert (-not (Get-Service -Name $service -ErrorAction SilentlyContinue)) 'Fixture must not target a real service.'
$ConnectionDll = Resolve-NexoPath $ConnectionDll
$SdkDir = Resolve-NexoPath $SdkDir
$version = ([Diagnostics.FileVersionInfo]::GetVersionInfo($ConnectionDll).ProductVersion -split '\+')[0]
$inputDirectory = Join-Path $root 'input'
[void][IO.Directory]::CreateDirectory($inputDirectory)
[IO.File]::Copy($ConnectionDll, (Join-Path $inputDirectory 'Nexo.Connection.dll'))
[IO.File]::WriteAllText((Join-Path $inputDirectory '##Dll'), 'Nexo.Connection.dll')
[IO.File]::WriteAllText((Join-Path $inputDirectory '##Shared'), 'shared')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$inputZip = Join-Path $modules 'Nexo.Connection.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($inputDirectory, $inputZip)
$initialHash = Get-NexoHash $inputZip
$source = Join-Path $root 'connection source'
Copy-NexoSource $repository $source
$consumer = Join-Path $root 'consumer source'
[void][IO.Directory]::CreateDirectory($consumer)
$project = @"
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0-windows</TargetFramework><UseWPF>true</UseWPF><PlatformTarget>x64</PlatformTarget></PropertyGroup><ItemGroup><PackageReference Include="Zapqio.Nexo.Connection" Version="[$version]" ExcludeAssets="runtime" /><PackageReference Include="Zapqio.Runner.Module.Core" Version="[1.2.0]" ExcludeAssets="runtime" /></ItemGroup><Target Name="Marker" AfterTargets="Publish"><WriteLinesToFile File="`$(PublishDir)##Dll" Lines="Consumer.dll" Overwrite="true" /></Target></Project>
"@
[IO.File]::WriteAllText((Join-Path $consumer 'Consumer.csproj'), $project)
[IO.File]::WriteAllText((Join-Path $consumer 'Consumer.cs'), 'using Nexo; using InsERT.Moria.Uzytkownicy; public class Consumer { public string Read(NexoClient client) => client.Uchwyt.PodajObiektTypu<IZalogowanyUzytkownik>().Dane.Sygnatura; }')
$config = Join-Path $runner 'Config\nexo-build-sources.json'
Write-NexoJson $config @{ modules = @(@{ packageName = 'Consumer'; sourcePath = $consumer; project = 'Consumer.csproj' }) }
$parameters = @{ RunnerDir = $runner; SdkDir = $SdkDir; ConnectionZip = $inputZip; ConnectionSource = $source; ModulesConfig = $config; Language = 'en' }
$manifest = & $builder @parameters
$set = Read-NexoSet $manifest
Assert ($set.connectionVersion -eq $version) 'SDK rebuild changed the Connection package version.'
Assert ($set.sdkVersion -eq ([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $SdkDir 'InsERT.Moria.Sfera.dll')).ProductVersion -split '\+')[0]) 'Incorrect SDK version.'
Assert ('Consumer' -in $set.modules) 'Consumer was not rebuilt.'
Assert ((Get-NexoHash $inputZip) -eq $initialHash) 'Preparation changed installed modules.'
$manifestAgain = & $builder @parameters
Assert ($manifestAgain -eq $manifest) 'Identical inputs did not reuse the validated set.'
$metadata = Get-NexoAssemblyMetadata (Join-Path $set.Root 'Output\Connection\Nexo.Connection.dll')
$expectedModel = [Reflection.AssemblyName]::GetAssemblyName((Join-Path $SdkDir 'InsERT.Moria.ModelDanych.dll')).FullName
Assert ($expectedModel -in $metadata.references) 'Connection still references the previous ModelDanych identity.'
$cacheDll = Join-Path $set.Root "Packages\zapqio.nexo.connection\$version\lib\net8.0-windows7.0\Nexo.Connection.dll"
Assert ((Get-NexoHash $cacheDll) -eq (Get-NexoHash (Join-Path $set.Root 'Output\Connection\Nexo.Connection.dll'))) 'Restore reused the wrong same-version NuGet.'
Write-Host 'PASS Connection and consumer rebuilt with unchanged PackageReference; exact SDK identity; isolated NuGet; cache reuse'

function Invoke-Updater([string]$Name, [string[]]$Extra = @(), [switch]$ExpectFailure) {
    $log = Join-Path $root ($Name + '.log')
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $updater -RunnerDir $runner -SdkDir $SdkDir -ConnectionSource $source -ModulesConfig $config -ServiceName $service -NoRestart -Language en @Extra *> $log
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    if (($ExpectFailure -and $code -eq 0) -or (-not $ExpectFailure -and $code -ne 0)) { throw "Unexpected updater exit $code; log: $log" }
    return [IO.File]::ReadAllText($log)
}
[void](Invoke-Updater 'prepare' @('-PrepareOnly'))
Assert ((Get-NexoHash $inputZip) -eq $initialHash -and -not (Test-Path -LiteralPath (Join-Path $runner 'nexo-build.json'))) 'PrepareOnly activated files.'
[void](Invoke-Updater 'activate')
$active = Get-Content -LiteralPath (Join-Path $runner 'nexo-build.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert ($active.setId -eq $set.id) 'Unexpected active set.'
foreach ($name in $set.modules) { Assert ((Get-NexoHash (Join-Path $modules ($name + '.zip'))) -eq (Get-NexoHash (Join-Path $set.Root ('Modules\' + $name + '.zip')))) "Wrong installed $name" }
[xml]$props = Get-Content -LiteralPath (Join-Path $runner 'Deployments\Directory.Build.props') -Raw -Encoding UTF8
Assert ($props.Project.PropertyGroup.RestorePackagesPath -eq (Join-Path $set.Root 'Packages')) 'Build environment does not isolate same-version variants.'
Write-Host 'PASS preparation and transactional activation without a real service'

# Further upgrades must work from the source embedded in the installed ZIP,
# without the one-time ConnectionSource migration parameter.
$embeddedParameters = $parameters.Clone()
$embeddedParameters.Remove('ConnectionSource')
$embeddedManifest = & $builder @embeddedParameters
Assert ($embeddedManifest -eq $manifest) 'Embedded source changed the profile or needs a source checkout.'
Write-Host 'PASS installed source snapshot supports future updates without ConnectionSource'

# Standalone build setup must automatically preserve the private variant.
$setupLog = Join-Path $root 'setup-again.log'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repository 'install-nexo-build.ps1') -InstallDir $runner -ServiceName $service -NoRestart -Language en *> $setupLog
Assert ($LASTEXITCODE -eq 0) "Standalone setup failed: $setupLog"

# Web-managed packages must never be replaced behind the deployment journal.
$statePath = Join-Path $runner 'Deployments\state.json'
Write-NexoJson $statePath @{ installed = @(@{ manifest = @{ packageName = 'Consumer' } }) }
$before = Get-NexoHash $inputZip
$blocked = Invoke-Updater 'managed-blocked' @() -ExpectFailure
Assert ($blocked.Contains('Web-managed')) 'Missing Web-managed module diagnostic.'
Assert ((Get-NexoHash $inputZip) -eq $before) 'Managed-module rejection changed installed files.'
[IO.File]::Delete($statePath)

# An installed ZIP referencing InsERT cannot be silently left at the old SDK.
$unregistered = Join-Path $modules 'Unregistered.zip'
[IO.File]::Copy((Join-Path $set.Root 'Modules\Consumer.zip'), $unregistered)
try {
    $blocked = Invoke-Updater 'unregistered-blocked' @() -ExpectFailure
    Assert ($blocked.Contains('Register source for Unregistered')) 'Unregistered consumer was not detected.'
    Assert ((Get-NexoHash $inputZip) -eq $before) 'Unregistered-consumer rejection changed installed files.'
}
finally { [IO.File]::Delete($unregistered) }

# Missing source fails before touching the active set.
$savedConfig = [IO.File]::ReadAllText($config)
Write-NexoJson $config @{ modules = @(@{ packageName = 'Consumer'; sourcePath = (Join-Path $root 'absent'); project = 'Consumer.csproj' }) }
[void](Invoke-Updater 'missing-source' @() -ExpectFailure)
Assert ((Get-NexoHash $inputZip) -eq $before) 'Missing source changed installed files.'
[IO.File]::WriteAllText($config, $savedConfig)
Write-Host 'PASS active local NuGet retained; Web-managed modules protected; missing-source failure preserves installation'

# A consumer API/compilation failure must keep the current complete set active.
$consumerCode = Join-Path $consumer 'Consumer.cs'
$savedCode = [IO.File]::ReadAllText($consumerCode)
try {
    [IO.File]::WriteAllText($consumerCode, '#error SDK upgrade fixture: incompatible consumer')
    $failedBuild = Invoke-Updater 'consumer-build-failed' @() -ExpectFailure
    Assert ($failedBuild.Contains('dotnet publish failed')) 'Expected a consumer compilation failure.'
    Assert ((Get-NexoHash $inputZip) -eq $before) 'Failed consumer compilation changed installed files.'
    $stillActive = Get-Content -LiteralPath (Join-Path $runner 'nexo-build.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($stillActive.setId -eq $set.id) 'Failed consumer compilation changed the active profile.'
}
finally { [IO.File]::WriteAllText($consumerCode, $savedCode) }
Write-Host 'PASS consumer compilation failure preserves the active SDK and Connection'

if ($PreviousSdkDir) {
    $parameters.Remove('ConnectionSource')
    $parameters.SdkDir = Resolve-NexoPath $PreviousSdkDir
    $previousManifest = & $builder @parameters
    $previous = Read-NexoSet $previousManifest
    Assert ($previous.id -ne $set.id -and $previous.connectionVersion -eq $version -and $previous.sdkVersion -ne $set.sdkVersion) 'SDK change must create another profile without changing the package version.'
    Assert ((Get-NexoHash $inputZip) -eq $before) 'Preparing another SDK changed the active set.'
    Write-Host 'PASS second SDK uses another profile/cache with the same Connection version'
}
Write-NexoJson (Join-Path $root 'result.json') @{ runner = $runner; manifest = $manifest; version = $version; sdkVersion = $set.sdkVersion; liveServiceModified = $false }
Write-Host "RESULT $root"
