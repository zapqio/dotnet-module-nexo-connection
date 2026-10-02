param(
    [Parameter(Mandatory = $true)][string]$ConnectionZip,
    [Parameter(Mandatory = $true)][string]$SdkZip
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$dotnet = Join-Path $env:ProgramFiles 'dotnet/dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet)) {
    throw 'Install the system .NET SDK 8 or later before running this test.'
}

$sdks = @(& $dotnet --list-sdks)
if ($LASTEXITCODE -ne 0 -or -not ($sdks | Where-Object { $_ -match '^(8|9|[1-9][0-9])\.\d+\.\d+ ' })) {
    throw 'This test requires a preinstalled .NET SDK 8 or later; it must not install system tools.'
}

$setup = Join-Path $PSScriptRoot '../install-nexo-build.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('zapqio-build-setup-test-' + [guid]::NewGuid().ToString('N'))
$installDir = Join-Path $testRoot 'runner with spaces'
$modules = Join-Path $installDir 'Modules'
[void][IO.Directory]::CreateDirectory($modules)
[IO.File]::WriteAllText((Join-Path $installDir 'Zapqio.Runner.exe'), 'Fixture marker; never executed.')
Copy-Item -LiteralPath $ConnectionZip -Destination (Join-Path $modules 'Nexo.Connection.zip')
Copy-Item -LiteralPath $SdkZip -Destination (Join-Path $modules 'Nexo.Sdk.zip')
$serviceName = 'CodexBuildSetup_' + [guid]::NewGuid().ToString('N')
if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    throw 'The fixture service name must not exist.'
}

$runtime = [IO.Compression.ZipFile]::OpenRead((Join-Path $modules 'Nexo.Connection.zip'))
try {
    $runtimeDll = Join-Path $testRoot 'Nexo.Connection.dll'
    [IO.Compression.ZipFileExtensions]::ExtractToFile($runtime.GetEntry('Nexo.Connection.dll'), $runtimeDll)
}
finally {
    $runtime.Dispose()
}

$version = ([Diagnostics.FileVersionInfo]::GetVersionInfo($runtimeDll).ProductVersion -split '\+')[0]
$runtimeHash = (Get-FileHash -LiteralPath $runtimeDll).Hash

function Invoke-Setup([string]$Name, [string]$LocalPackage = '', [switch]$ExpectFailure) {
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $setup,
                   '-InstallDir', $installDir, '-ServiceName', $serviceName, '-NoRestart')
    if ($LocalPackage) {
        $arguments += @('-ConnectionPackagePath', $LocalPackage)
    }

    $log = Join-Path $testRoot ($Name + '.log')
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & powershell.exe @arguments *> $log
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }

    $logText = [IO.File]::ReadAllText($log)
    if ($ExpectFailure) {
        if ($exitCode -eq 0) {
            throw "Expected setup to reject invalid input: $Name"
        }
    }
    elseif ($exitCode -ne 0) {
        throw "Setup failed: $Name. Log: $log`n$logText"
    }

    return $logText
}

[void](Invoke-Setup 'public-packages')
$configPath = Join-Path $installDir 'Deployments/NuGet.Config'
[xml]$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
$sources = @($config.configuration.packageSources.add)
if ($sources.Count -ne 1 -or $sources[0].value -ne 'https://api.nuget.org/v3/index.json') {
    throw 'A default installation must use only nuget.org.'
}

$cache = Join-Path $installDir 'Build/Packages'
foreach ($idAndVersion in @('zapqio.runner.module.core/1.2.0', "zapqio.nexo.connection/$version")) {
    $metadata = Get-Content -LiteralPath (Join-Path $cache ($idAndVersion + '/.nupkg.metadata')) -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($metadata.source -ne 'https://api.nuget.org/v3/index.json') {
        throw "Package did not come from nuget.org: $idAndVersion"
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $cache 'zapqio.runner.module.core/1.2.0/lib/net10.0/Zapqio.Runner.Module.Core.dll'))) {
    throw 'Expected the complete public Core package, including net10.0.'
}

if (Test-Path -LiteralPath (Join-Path $installDir 'Build/NuGet')) {
    throw 'A default installation must not create a local NuGet feed.'
}

$publicPackage = Join-Path $cache "zapqio.nexo.connection/$version/zapqio.nexo.connection.$version.nupkg"
$publicDll = Join-Path $cache "zapqio.nexo.connection/$version/lib/net8.0-windows7.0/Nexo.Connection.dll"
if ((Get-FileHash -LiteralPath $publicDll).Hash -ne $runtimeHash) {
    throw 'The public Connection package must match the installed ZIP.'
}

[xml]$props = Get-Content -LiteralPath (Join-Path $installDir 'Deployments/Directory.Build.props') -Raw -Encoding UTF8
$sdkPath = $props.Project.PropertyGroup.nexoSdkBinPath.InnerText
Write-Host 'PASS new installation: public Core and Connection, SDK extraction and probe build'

[void](Invoke-Setup 'explicit-local-package' $publicPackage)
[xml]$localConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
$overrideSource = @($localConfig.configuration.packageSources.add | Where-Object { $_.key -eq 'ZapqioConnectionOverride' })
$localCache = ($localConfig.configuration.config.add | Where-Object { $_.key -eq 'globalPackagesFolder' }).value
if ($overrideSource.Count -ne 1 -or $localCache -eq $cache) {
    throw 'A local override must have an isolated source and cache.'
}

$localMetadata = Get-Content -LiteralPath (Join-Path $localCache "zapqio.nexo.connection/$version/.nupkg.metadata") -Raw -Encoding UTF8 | ConvertFrom-Json
if ($localMetadata.source -ne $overrideSource[0].value) {
    throw 'Source mapping must select the explicit local Connection package.'
}

$coreMetadata = Get-Content -LiteralPath (Join-Path $localCache 'zapqio.runner.module.core/1.2.0/.nupkg.metadata') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($coreMetadata.source -ne 'https://api.nuget.org/v3/index.json') {
    throw 'Core must still come from nuget.org when Connection is supplied locally.'
}

Write-Host 'PASS explicit local Connection: isolated cache, public Core'
$configHash = (Get-FileHash -LiteralPath $configPath).Hash
$badPackage = Join-Path $testRoot 'mismatched-connection.nupkg'
Copy-Item -LiteralPath $publicPackage -Destination $badPackage
$archive = [IO.Compression.ZipFile]::Open($badPackage, [IO.Compression.ZipArchiveMode]::Update)
try {
    $entryName = 'lib/net8.0-windows7.0/Nexo.Connection.dll'
    $archive.GetEntry($entryName).Delete()
    $entry = $archive.CreateEntry($entryName)
    $writer = [IO.StreamWriter]::new($entry.Open())
    try {
        $writer.Write('Intentionally invalid DLL; setup must reject it before compilation.')
    }
    finally {
        $writer.Dispose()
    }
}
finally {
    $archive.Dispose()
}

$failure = Invoke-Setup 'mismatched-dll' $badPackage -ExpectFailure
if ($failure -notmatch 'DLL w NuGet rozni sie' -or (Get-FileHash -LiteralPath $configPath).Hash -ne $configHash) {
    throw 'A mismatched DLL must be rejected before modifying the build configuration.'
}

Write-Host 'PASS mismatched DLL rejected'
$result = [pscustomobject]@{ TestRoot = $testRoot; InstallDir = $installDir; SdkPath = $sdkPath; Version = $version; LiveServiceModified = $false }
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'result.json') -Encoding UTF8
Write-Host ('RESULT ' + ($result | ConvertTo-Json -Compress))
