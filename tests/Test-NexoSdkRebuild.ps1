#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$SdkDir, [Parameter(Mandatory=$true)][string]$ConnectionDll, [string]$PreviousSdkDir)
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$builder = Join-Path $repository 'build-nexo-set.ps1'
. (& $builder -FunctionsOnly)
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Temp\nexo-sdk-rebuild-' + [guid]::NewGuid().ToString('N'))
$runner = Join-Path $root 'runner with spaces'
$modules = Join-Path $runner 'Modules'
[void][IO.Directory]::CreateDirectory($modules)
[IO.File]::WriteAllText((Join-Path $runner 'Zapqio.Runner.exe'), 'Fixture; never executed.')
$service = 'NexoFixture_' + [guid]::NewGuid().ToString('N')
Assert (-not (Get-Service -Name $service -ErrorAction SilentlyContinue)) 'Fixture must not use a real service.'
$SdkDir = Resolve-NexoPath $SdkDir
$baselineSdk = if ($PreviousSdkDir) { Resolve-NexoPath $PreviousSdkDir } else { $SdkDir }
$ConnectionDll = Resolve-NexoPath $ConnectionDll
$version = ([Diagnostics.FileVersionInfo]::GetVersionInfo($ConnectionDll).ProductVersion -split '\+')[0]
$inputDirectory = Join-Path $root 'input'
[void][IO.Directory]::CreateDirectory($inputDirectory)
[IO.File]::Copy($ConnectionDll, (Join-Path $inputDirectory 'Nexo.Connection.dll'))
[IO.File]::WriteAllText((Join-Path $inputDirectory '##Dll'), 'Nexo.Connection.dll')
[IO.File]::WriteAllText((Join-Path $inputDirectory '##Shared'), 'shared')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$inputZip = Join-Path $modules 'Nexo.Connection.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($inputDirectory, $inputZip)
$source = Join-Path $root 'connection source'
Copy-NexoSource $repository $source
$specs = @()
foreach ($name in 'Consumer', 'Second') {
    $consumer = Join-Path $root ($name + ' source')
    [void][IO.Directory]::CreateDirectory($consumer)
    $xml = '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0-windows</TargetFramework><UseWPF>true</UseWPF><PlatformTarget>x64</PlatformTarget></PropertyGroup><ItemGroup><PackageReference Include="Zapqio.Nexo.Connection" Version="[' + $version + ']" ExcludeAssets="runtime" /><PackageReference Include="Zapqio.Runner.Module.Core" Version="[1.2.0]" ExcludeAssets="runtime" /></ItemGroup><Target Name="Marker" AfterTargets="Publish"><WriteLinesToFile File="$(PublishDir)##Dll" Lines="' + $name + '.dll" Overwrite="true" /></Target></Project>'
    [IO.File]::WriteAllText((Join-Path $consumer ($name + '.csproj')), $xml)
    [IO.File]::WriteAllText((Join-Path $consumer ($name + '.cs')), 'using Nexo; using InsERT.Moria.Uzytkownicy; public class ' + $name + ' { public string Read(NexoClient client) => client.Uchwyt.PodajObiektTypu<IZalogowanyUzytkownik>().Dane.Sygnatura; }')
    $specs += @{ packageName=$name; sourcePath=$consumer; project=($name + '.csproj') }
}
$config = Join-Path $runner 'Config\nexo-build-sources.json'
Write-NexoJson $config @{ modules=$specs }
$initialHash = Get-NexoHash $inputZip
$baseline = Read-NexoSet (& $builder -RunnerDir $runner -SdkDir $baselineSdk -ConnectionSource $source -Language en)
Assert ((Get-NexoHash $inputZip) -eq $initialHash) 'Preparation changed installed files.'
Install-NexoSet $runner $baseline $service 'en'
# No original checkout or manual source registry is available for the upgrade.
[IO.File]::Delete($config)
foreach ($spec in $specs) { Remove-NexoWork $root $spec.sourcePath }
Remove-NexoWork $root $source
$statePath = Join-Path $runner 'Deployments\state.json'
$records = @('Consumer', 'Second' | ForEach-Object {
    @{ manifest=@{ packageName=$_; deploymentId=[guid]::NewGuid().ToString(); repositoryId=17; commit=('a'*40); sequence=4; contentKind='DotnetSource'; files=@(@{ path=($_+'.cs'); sha256=('b'*64) }) }; zipSha256=(Get-NexoHash (Join-Path $modules ($_+'.zip'))) }
})
Write-NexoJson $statePath @{ version=1; installed=$records; batch=$null; latest=@(); packages=@(); reports=@(@{ message='keep report' }) }
$beforeState = Read-NexoDeploymentState $runner
function Update-Fixture($Name, [string[]]$Extra=@(), [switch]$Fail) {
    $log = Join-Path $root ($Name+'.log')
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repository 'update-nexo-sdk.ps1') -RunnerDir $runner -SdkDir $SdkDir -ServiceName $service -NoRestart -Language en @Extra *> $log
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$oldPreference }
    Assert (($Fail -and $code -ne 0) -or (-not $Fail -and $code -eq 0)) "Unexpected updater exit $code; log: $log"
    return [IO.File]::ReadAllText($log)
}
$beforeHash=Get-NexoHash $inputZip
$stateHash=Get-NexoHash $statePath
[void](Update-Fixture 'prepare' @('-PrepareOnly'))
Assert ((Get-NexoHash $inputZip) -eq $beforeHash -and (Get-NexoHash $statePath) -eq $stateHash) 'PrepareOnly activated files/state.'
[void](Update-Fixture 'activate')
$active=Get-Content (Join-Path $runner 'nexo-build.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$set=Read-NexoSet $active.manifestPath
Assert ($set.connectionVersion -eq $version -and @($set.sources).Count -eq 2) 'Wrong version or missing rebuilt modules.'
$expected=[Reflection.AssemblyName]::GetAssemblyName((Join-Path $SdkDir 'InsERT.Moria.ModelDanych.dll')).FullName
foreach ($name in 'Nexo.Connection', 'Consumer', 'Second') {
    $output=Join-Path $root ($name+'-after')
    Expand-NexoZip (Join-Path $modules ($name+'.zip')) $output
    Assert ($expected -in (Get-NexoAssemblyMetadata (Join-Path $output ($name+'.dll'))).references) "$name uses the old SDK identity."
    if ($name -ne 'Nexo.Connection') {
        $oldOutput=Join-Path $baseline.Root ('Output\'+$name)
        Assert ((Get-NexoHash (Join-Path $output 'nexo-module-source.zip')) -eq (Get-NexoHash (Join-Path $oldOutput 'nexo-module-source.zip'))) 'Original source archive changed.'
    }
}
$afterState=Read-NexoDeploymentState $runner
foreach ($record in $afterState.installed) {
    $old=$beforeState.installed | Where-Object { $_.manifest.packageName -eq $record.manifest.packageName }
    Assert ((Get-NexoDeploymentFingerprint $old) -eq (Get-NexoDeploymentFingerprint $record)) 'Deployment identity/source manifest changed.'
    Assert ($record.zipSha256 -eq (Get-NexoHash (Join-Path $modules ($record.manifest.packageName+'.zip')))) 'Panel hash differs from ZIP.'
}
Assert ($afterState.reports[0].message -eq 'keep report') 'Lost reports.'
if ($PreviousSdkDir) { Assert ($baseline.id -ne $set.id -and $baseline.sdkVersion -ne $set.sdkVersion) 'Different SDKs reused the same set.' }
$cacheDll=Join-Path $set.Root "Packages\zapqio.nexo.connection\$version\lib\net8.0-windows7.0\Nexo.Connection.dll"
Assert ((Get-NexoHash $cacheDll) -eq (Get-NexoHash (Join-Path $root 'Nexo.Connection-after\Nexo.Connection.dll'))) 'Wrong same-version NuGet.'
Write-Host 'PASS SDK upgrade: Connection + two panel modules; original source archives, unchanged NuGet version, deployment IDs and commits'
[void](Update-Fixture 'repeat')
Assert ((Get-Content (Join-Path $runner 'nexo-build.json') -Raw -Encoding UTF8 | ConvertFrom-Json).setId -eq $set.id) 'Repeat update missed cache.'
Write-Host 'PASS repeated automatic update without checkouts or source registry'
$work=Join-Path $root 'late-deployment'
[void][IO.Directory]::CreateDirectory($work)
$plan=New-NexoRebuildPlan $runner $work ''
$state=Read-NexoDeploymentState $runner
$state.installed[0].manifest.deploymentId=[guid]::NewGuid().ToString()
Write-NexoJson $statePath $state
$blocked=$false
try { Install-NexoSet $runner $set $service 'en' -Plan $plan } catch { $blocked=$_.Exception.Message.Contains('changed during rebuild') }
Assert $blocked 'Concurrent panel deployment was overwritten.'
Write-NexoJson $statePath $afterState
$stableHash=Get-NexoHash $inputZip
$broken=Join-Path $root 'broken'
Expand-NexoZip (Join-Path $modules 'Consumer.zip') $broken
$brokenSources=Join-Path $root 'broken-source'
$description=Read-NexoModuleSource $broken $brokenSources
[IO.File]::AppendAllText((Join-Path $brokenSources 'Consumer.cs'), ([Environment]::NewLine+'#error incompatible SDK fixture'))
$sourceZip=Join-Path $broken 'nexo-module-source.zip'
[IO.File]::Delete($sourceZip)
[IO.Compression.ZipFile]::CreateFromDirectory($brokenSources,$sourceZip)
$description.sha256=Get-NexoHash $sourceZip
Write-NexoJson (Join-Path $broken 'nexo-module-source.json') $description
$brokenZip=Join-Path $root 'broken.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($broken,$brokenZip)
[IO.File]::Copy($brokenZip,(Join-Path $modules 'Consumer.zip'),$true)
$brokenState=Read-NexoDeploymentState $runner
($brokenState.installed | Where-Object { $_.manifest.packageName -eq 'Consumer' }).zipSha256=Get-NexoHash $brokenZip
Write-NexoJson $statePath $brokenState
$brokenStateHash=Get-NexoHash $statePath
$failure=Update-Fixture 'compile-failure' @() -Fail
Assert ($failure.Contains('dotnet publish failed')) 'Expected a compile failure.'
Assert ((Get-NexoHash $inputZip) -eq $stableHash -and (Get-NexoHash $statePath) -eq $brokenStateHash) 'Failed build changed installed set/state.'
[IO.File]::Copy((Join-Path $set.Root 'Modules\Consumer.zip'),(Join-Path $modules 'Consumer.zip'),$true)
Write-NexoJson $statePath $afterState
Write-Host 'PASS concurrent deployment and compilation failure preserve installed set/state'
Write-NexoJson (Join-Path $root 'result.json') @{ runner=$runner; manifest=$set.ManifestPath; version=$version; sdkVersion=$set.sdkVersion; liveServiceModified=$false }
Write-Host "RESULT $root"
