#Requires -Version 5.1
# Offline regression: a panel module using only Connection survives an SDK/key
# change without sources. Real compiled references exercise the metadata check.
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (& (Join-Path $repository 'build-nexo-set.ps1') -FunctionsOnly)
$root = Join-Path ([IO.Path]::GetTempPath()) ('nexo-consumers-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
Add-Type -AssemblyName System.IO.Compression.FileSystem
$dotnet = Get-NexoDotnet $root
$sdkVersion = (& $dotnet --version | Select-Object -Last 1)
$compiler = Join-Path (Split-Path $dotnet -Parent) ("sdk\$sdkVersion\Roslyn\bincore\csc.dll")
if (-not (Test-Path -LiteralPath $compiler)) { throw "Missing C# compiler: $compiler" }

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Expect-Failure([scriptblock]$Action, [string]$Expected) {
    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert ($message -and $message.Contains($Expected)) "Expected '$Expected', got '$message'."
}

function Compile-Fixture([string]$Path, [string]$Code, [string[]]$References = @(), [string]$Key = '') {
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    $source = $Path + '.cs'
    [IO.File]::WriteAllText($source, $Code)
    # Compile offline against the local framework. Roslyn can sign without the
    # legacy compiler's dependency on the Windows crypto key store.
    $arguments = @($compiler, '/nologo', '/noconfig', '/nostdlib+', '/target:library', ('/out:' + $Path), ('/reference:' + [object].Assembly.Location))
    foreach ($reference in $References) { $arguments += '/reference:' + $reference }
    if ($Key) { $arguments += '/keyfile:' + $Key }
    $arguments += $source
    $output = & $dotnet @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
}

function New-FixtureZip([string]$Path, [string[]]$Files) {
    $content = Join-Path $root ('zip-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($content)
    foreach ($file in $Files) { [IO.File]::Copy($file, (Join-Path $content ([IO.Path]::GetFileName($file)))) }
    [IO.File]::WriteAllText((Join-Path $content '##Dll'), [IO.Path]::GetFileName($Files[0]))
    [IO.Compression.ZipFile]::CreateFromDirectory($content, $Path)
}

$runner = Join-Path $root 'runner'
$modules = Join-Path $runner 'Modules'
$prepared = Join-Path $root 'prepared'
$work = Join-Path $root 'inspect'
$sdkBin = Join-Path $prepared 'Sdk\Bin'
foreach ($directory in @($modules, $work, $sdkBin, (Join-Path $prepared 'Modules'), (Join-Path $prepared 'Output\Connection'))) {
    [void][IO.Directory]::CreateDirectory($directory)
}

# Two ModelDanych DLLs have the same AssemblyVersion and different signing keys,
# matching the kind of identity change between real SDK 61 and SDK 62.
$modelCode = '[assembly:System.Reflection.AssemblyVersion("1.0.0.0")] namespace InsERT.Fixture { public class Model { public static string Read() { return "sdk"; } } }'
$oldModel = Join-Path $root 'old\InsERT.Moria.ModelDanych.dll'
$newModel = Join-Path $sdkBin 'InsERT.Moria.ModelDanych.dll'
foreach ($model in @($oldModel, $newModel)) {
    $key = Join-Path $root ([guid]::NewGuid().ToString('N') + '.snk')
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 1024
    $rsa.PersistKeyInCsp = $false
    try { [IO.File]::WriteAllBytes($key, $rsa.ExportCspBlob($true)) } finally { $rsa.Dispose() }
    Compile-Fixture $model $modelCode @() $key
}
Assert ([Reflection.AssemblyName]::GetAssemblyName($oldModel).FullName -ne [Reflection.AssemblyName]::GetAssemblyName($newModel).FullName) 'Fixture SDK identities did not differ.'

$connectionCode = '[assembly:System.Reflection.AssemblyVersion("1.0.0.0")] namespace Nexo { public class NexoClient { public string SdkVersion { get { return InsERT.Fixture.Model.Read(); } } } }'
$oldConnection = Join-Path $root 'old\Nexo.Connection.dll'
$newConnection = Join-Path $prepared 'Output\Connection\Nexo.Connection.dll'
Compile-Fixture $oldConnection $connectionCode @($oldModel)
Compile-Fixture $newConnection $connectionCode @($newModel)
New-FixtureZip (Join-Path $modules 'Nexo.Connection.zip') @($oldConnection)
New-FixtureZip (Join-Path $modules 'Nexo.Sdk.zip') @($oldModel)
New-FixtureZip (Join-Path $prepared 'Modules\Nexo.Connection.zip') @($newConnection)
New-FixtureZip (Join-Path $prepared 'Modules\Nexo.Sdk.zip') @($newModel)
foreach ($helper in 'build-nexo-set.ps1', 'update-nexo-sdk.ps1') {
    [IO.File]::WriteAllText((Join-Path $prepared ('Output\Connection\' + $helper)), '# Test fixture')
}
[IO.File]::WriteAllText((Join-Path $prepared 'Output\Connection\install-nexo-build.ps1'), 'exit 0')
$set = [pscustomobject]@{ Root = $prepared; ManifestPath = (Join-Path $prepared 'nexo-set.json'); id = ('c' * 64); modules = @('Nexo.Sdk', 'Nexo.Connection'); sdkBin = 'Sdk/Bin'; sdkVersion = '62.0.0.9537'; connectionVersion = '1.1.3' }

$bonyDll = Join-Path $root 'consumer\DlaKobiet.Bony.dll'
Compile-Fixture $bonyDll 'public class Bony { public string Read(Nexo.NexoClient client) { return client.SdkVersion; } }' @($oldConnection)
$metadata = Get-NexoAssemblyMetadata $bonyDll
Assert (@($metadata.references | Where-Object { $_ -like 'Nexo.Connection,*' }).Count -eq 1) 'Fixture must reference Connection.'
Assert (@($metadata.references | Where-Object { $_ -like 'InsERT.*' }).Count -eq 0) 'Connection-only fixture unexpectedly references SDK.'
$bonyZip = Join-Path $modules 'DlaKobiet.Bony.zip'
New-FixtureZip $bonyZip @($bonyDll)
$bonyHash = Get-NexoHash $bonyZip
$statePath = Join-Path $runner 'Deployments\state.json'
Write-NexoJson $statePath @{ version = 1; installed = @(@{ manifest = @{ packageName = 'DlaKobiet.Bony'; contentKind = 'DotnetSource'; deploymentId = [guid]::NewGuid().ToString() }; zipSha256 = $bonyHash }) }
$stateHash = Get-NexoHash $statePath
$checked = @(Test-NexoInstalledConsumers $runner $set $work)
Assert ($checked.Count -eq 1 -and $checked[0].packageName -eq 'DlaKobiet.Bony') 'Consumer snapshot is incorrect.'
Install-NexoSet $runner $set 'NexoConsumerFixture_NotAService' 'en' -InstalledConsumers $checked
Assert ((Get-NexoHash $bonyZip) -eq $bonyHash) 'Connection-only module was changed.'
Assert ((Get-NexoHash $statePath) -eq $stateHash) 'Panel deployment state was changed.'
foreach ($name in 'Nexo.Sdk', 'Nexo.Connection') {
    Assert ((Get-NexoHash (Join-Path $modules ($name + '.zip'))) -eq (Get-NexoHash (Join-Path $prepared ('Modules\' + $name + '.zip')))) "New $name was not installed."
}
Write-Host 'PASS SDK signing-key change with unchanged Connection-only panel module, no sources, no deployment journal changes'

$directCode = 'public class DirectConsumer { public string Read() { return InsERT.Fixture.Model.Read(); } }'
$directDll = Join-Path $root 'compatible\Direct.Consumer.dll'
Compile-Fixture $directDll $directCode @($newModel)
$directZip = Join-Path $modules 'Direct.Consumer.zip'
New-FixtureZip $directZip @($directDll)
Assert (@(Test-NexoInstalledConsumers $runner $set $work).Count -eq 2) 'A matching direct SDK reference was rejected.'
[IO.File]::Delete($directZip)

$oldDirectDll = Join-Path $root 'incompatible\Direct.Consumer.dll'
Compile-Fixture $oldDirectDll $directCode @($oldModel)
New-FixtureZip $directZip @($oldDirectDll)
Expect-Failure { Test-NexoInstalledConsumers $runner $set $work } 'Module Direct.Consumer has an incompatible assembly reference'
[IO.File]::Delete($directZip)

$otherConnection = Join-Path $root 'other-version\Nexo.Connection.dll'
Compile-Fixture $otherConnection ($connectionCode.Replace('1.0.0.0', '2.0.0.0')) @($newModel)
$otherConsumer = Join-Path $root 'other-version\Other.Consumer.dll'
Compile-Fixture $otherConsumer 'public class Other { public string Read(Nexo.NexoClient client) { return client.SdkVersion; } }' @($otherConnection)
$otherZip = Join-Path $modules 'Other.Consumer.zip'
New-FixtureZip $otherZip @($otherConsumer)
Expect-Failure { Test-NexoInstalledConsumers $runner $set $work } 'Module Other.Consumer has an incompatible assembly reference'
[IO.File]::Delete($otherZip)

$privateZip = Join-Path $modules 'Private.Copy.zip'
New-FixtureZip $privateZip @($oldConnection)
Expect-Failure { Test-NexoInstalledConsumers $runner $set $work } 'Module Private.Copy contains its own shared library'
[IO.File]::Delete($privateZip)
New-FixtureZip $privateZip @($oldModel)
Expect-Failure { Test-NexoInstalledConsumers $runner $set $work } 'Module Private.Copy contains its own shared library'
[IO.File]::Delete($privateZip)
Write-Host 'PASS matching direct SDK references allowed; mismatched SDK/Connection identities and private shared DLLs rejected'

# A completed panel deployment between preflight and activation must not bypass
# the check. Both inventory changes and same-name content changes are detected.
$activeHash = Get-NexoHash (Join-Path $runner 'nexo-build.json')
New-FixtureZip $otherZip @($otherConsumer)
Expect-Failure { Install-NexoSet $runner $set 'NexoConsumerFixture_NotAService' 'en' -InstalledConsumers $checked } 'Installed modules changed after validation'
[IO.File]::Delete($otherZip)
$changedZip = Join-Path $root 'changed-bony.zip'
New-FixtureZip $changedZip @($otherConsumer)
[IO.File]::Copy($changedZip, $bonyZip, $true)
Expect-Failure { Install-NexoSet $runner $set 'NexoConsumerFixture_NotAService' 'en' -InstalledConsumers $checked } 'Module DlaKobiet.Bony changed after validation'
Assert ((Get-NexoHash (Join-Path $runner 'nexo-build.json')) -eq $activeHash) 'Rejected activation changed the active set.'
Assert ((Get-NexoHash $statePath) -eq $stateHash) 'Rejected activation changed Web state.'
Write-Host 'PASS concurrent module changes prevent activation'
Write-Host "Fixtures: $root"
