#Requires -Version 5.1
# Offline tests: no SDK download, SQL, service changes or installed runner required.
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$builder = Join-Path $repository 'build-nexo-set.ps1'
$RunnerDir = 'Must not be overwritten by importing helpers'
$SdkDir = 'Must not be overwritten'
$Language = 'de'
. (& $builder -FunctionsOnly)
if ($RunnerDir -ne 'Must not be overwritten by importing helpers' -or $SdkDir -ne 'Must not be overwritten' -or $Language -ne 'de') { throw 'Import changed caller parameters.' }
$root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Temp\nexo-set-safety-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert $failed $Message
}

foreach ($relative in '..\outside', 'sub\..\..\outside', 'C:\outside', '/outside', 'file:stream') {
    Expect-Failure { Get-NexoChildPath $root $relative } "Accepted escaping path $relative"
}
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path $root 'escape.zip'
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    $writer = New-Object IO.StreamWriter($zip.CreateEntry('../outside.txt').Open())
    try { $writer.Write('must not escape') } finally { $writer.Dispose() }
}
finally { $zip.Dispose() }
Expect-Failure { Expand-NexoZip $zipPath (Join-Path $root 'extract') } 'Archive traversal was accepted.'
Assert (-not (Test-Path -LiteralPath (Join-Path $root 'outside.txt'))) 'Archive escaped destination.'

$jsonPath = Join-Path $root 'roundtrip.json'
$password = 'test":  two spaces { }'
Write-NexoJson $jsonPath @{ password = $password; sdkVersion = '64.0.0.10000' }
Write-NexoJson $jsonPath @{ password = $password; sdkVersion = '63.1.2.9999' }
$json = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert ($json.password -ceq $password -and $json.sdkVersion -eq '63.1.2.9999') 'Atomic JSON changed values.'

$runner = Join-Path $root 'runner'
$backupRoot = Join-Path $runner 'Build\NexoTransactions\fixture'
$modules = Join-Path $runner 'Modules'
[void][IO.Directory]::CreateDirectory($backupRoot)
[void][IO.Directory]::CreateDirectory($modules)
$old = Join-Path $backupRoot '0.bak'
$target = Join-Path $modules 'Nexo.Connection.zip'
$added = Join-Path $modules 'New.zip'
[IO.File]::WriteAllText($old, 'old complete package')
[IO.File]::WriteAllText($target, 'partially replaced package')
[IO.File]::WriteAllText($added, 'new package')
$journalPath = Join-Path $runner 'Build\nexo-update-journal.json'
Write-NexoJson $journalPath @{ phase = 'switching'; files = @(@{ path = 'Modules/Nexo.Connection.zip'; existed = $true; backup = 'fixture/0.bak'; sha256 = (Get-NexoHash $old) }, @{ path = 'Modules/New.zip'; existed = $false }) }
Restore-NexoTransaction $runner
Assert ([IO.File]::ReadAllText($target) -eq 'old complete package') 'Rollback did not restore the old package.'
Assert (-not (Test-Path -LiteralPath $added)) 'Rollback kept a newly added package.'
Restore-NexoTransaction $runner
Assert ((Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json).phase -eq 'rolledBack') 'Recovery was not idempotent.'

# A damaged backup must not overwrite installed files.
Write-NexoJson $journalPath @{ phase = 'switching'; files = @(@{ path = 'Modules/Nexo.Connection.zip'; existed = $true; backup = 'fixture/0.bak'; sha256 = ('0' * 64) }) }
Expect-Failure { Restore-NexoTransaction $runner } 'Damaged backup was accepted.'
Assert ([IO.File]::ReadAllText($target) -eq 'old complete package') 'Failed recovery changed the package.'

# Validate root package names before ever forming a destination path.
$manifestPath = Join-Path $root 'nexo-set.json'
Write-NexoJson $manifestPath @{ schemaVersion = 1; id = ('a' * 64); modules = @('Nexo.Connection', 'Nexo.Sdk', '../bad'); files = @(@{ path = 'roundtrip.json'; sha256 = (Get-NexoHash $jsonPath) }); connectionPackage = 'roundtrip.json'; sdkBin = 'sdk' }
Expect-Failure { Read-NexoSet $manifestPath } 'Invalid package name was accepted.'

# Exercise the actual activation catch path while its deployment lock is held.
# A stub build-setup script fails after ZIPs/tools have already been switched.
[IO.File]::Delete($journalPath)
$prepared = Join-Path $root 'prepared'
[void][IO.Directory]::CreateDirectory((Join-Path $prepared 'Modules'))
[void][IO.Directory]::CreateDirectory((Join-Path $prepared 'Output\Connection'))
foreach ($name in 'Nexo.Connection', 'Nexo.Sdk') { [IO.File]::WriteAllText((Join-Path $prepared ('Modules\' + $name + '.zip')), 'new candidate') }
foreach ($name in 'build-nexo-set.ps1', 'update-nexo-sdk.ps1') { [IO.File]::WriteAllText((Join-Path $prepared ('Output\Connection\' + $name)), '# fixture') }
[IO.File]::WriteAllText((Join-Path $prepared 'Output\Connection\install-nexo-build.ps1'), 'exit 9')
$set = [pscustomobject]@{ Root = $prepared; ManifestPath = (Join-Path $prepared 'nexo-set.json'); id = ('b' * 64); modules = @('Nexo.Sdk', 'Nexo.Connection') }
Expect-Failure { Install-NexoSet $runner $set 'NexoSafetyFixture_NotAService' 'en' } 'Activation ignored build-setup failure.'
Assert ([IO.File]::ReadAllText($target) -eq 'old complete package') 'Activation failure did not restore the old ZIP.'
Assert (-not (Test-Path -LiteralPath (Join-Path $runner 'Modules\Nexo.Sdk.zip'))) 'Activation failure left a new SDK ZIP.'
Assert (-not (Test-Path -LiteralPath (Join-Path $runner 'build-nexo-set.ps1'))) 'Activation failure left new tools.'
Assert ((Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json).phase -eq 'rolledBack') 'Activation rollback could not acquire its deployment lock.'

# A failed switch of Web-managed modules restores both files and runtime hashes,
# preserving all source identities and unrelated changes to the panel journal.
[IO.File]::WriteAllText((Join-Path $prepared 'Output\Connection\install-nexo-build.ps1'), 'exit 0')
$consumerZip = Join-Path $modules 'Consumer.zip'
[IO.File]::WriteAllText($consumerZip, 'old consumer')
[IO.File]::WriteAllText((Join-Path $prepared 'Modules\Consumer.zip'), 'new consumer')
$statePath = Join-Path $runner 'Deployments\state.json'
$oldHash = Get-NexoHash $consumerZip
Write-NexoJson $statePath @{ version=1; batch=$null; installed=@(@{ manifest=@{ deploymentId='deployment-1'; packageName='Consumer'; commit=('d'*40); files=@(@{path='Consumer.cs'; sha256=('e'*64)}) }; zipSha256=$oldHash }); reports=@(@{message='before'}) }
$original = Read-NexoDeploymentState $runner
$identity = Get-NexoDeploymentFingerprint $original.installed[0]
$set.modules = @('Nexo.Sdk','Nexo.Connection','Consumer')
$set | Add-Member sources @(@{name='Consumer'; sourceHash=('f'*64)})
$inventory = @(Get-ChildItem $modules -Filter '*.zip' | ForEach-Object { @{name=$_.BaseName; sha256=(Get-NexoHash $_.FullName); deployment=$(if ($_.BaseName -eq 'Consumer') { @{deploymentId='deployment-1'; manifestHash=$identity} } else { $null })} })
$plan = @{schemaVersion=1; inventory=$inventory; sources=@(@{name='Consumer'; embedded=$true; sourceHash=('f'*64)})}
Install-NexoSet $runner $set 'NexoSafetyFixture_NotAService' 'en' -Plan $plan
$installedState = Read-NexoDeploymentState $runner
Assert ($installedState.installed[0].zipSha256 -eq (Get-NexoHash $consumerZip)) 'Managed runtime checksum was not updated.'
Assert ((Get-NexoDeploymentFingerprint $installedState.installed[0]) -eq $identity) 'Managed source identity was changed.'
# Simulate process death just before committing the journal. Reports may have
# been appended independently; recovery must not restore a whole stale state.json.
$journal = Get-Content $journalPath -Raw | ConvertFrom-Json
$journal.phase = 'switching'
Write-NexoJson $journalPath $journal
$installedState.reports += [pscustomobject]@{message='after'}
Write-NexoJson $statePath $installedState
Restore-NexoTransaction $runner
$recovered = Read-NexoDeploymentState $runner
Assert ((Get-NexoHash $consumerZip) -eq $oldHash -and $recovered.installed[0].zipSha256 -eq $oldHash) 'Interrupted managed update did not restore files and hash together.'
Assert ($recovered.reports.Count -eq 2 -and $recovered.reports[1].message -eq 'after') 'Recovery overwrote unrelated reports.'
Restore-NexoTransaction $runner
# A newer panel deployment must never be overwritten by recovery.
$journal.phase = 'switching'
Write-NexoJson $journalPath $journal
$recovered.installed[0].manifest.deploymentId = 'new-deployment'
Write-NexoJson $statePath $recovered
Expect-Failure { Restore-NexoTransaction $runner } 'Recovery overwrote a newer deployment.'
Assert ((Read-NexoDeploymentState $runner).installed[0].manifest.deploymentId -eq 'new-deployment') 'New deployment ID was lost.'
$journal.phase = 'rolledBack'
Write-NexoJson $journalPath $journal
foreach ($phase in 'Requested','Approved','Preparing','Switching','Loading') {
    Expect-Failure { Assert-NexoDeploymentIdle ([pscustomobject]@{batch=@{phase=$phase}}) } "Accepted active batch $phase"
}
Write-Host 'PASS paths, archives, activation rollback, managed hash recovery, preserved reports and concurrent deployment protection'
Write-Host "Fixtures: $root"
