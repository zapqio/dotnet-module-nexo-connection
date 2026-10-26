#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a private Connection NuGet and module set for any supplied nexo SDK.
.DESCRIPTION
    The Connection package version identifies its source/API, not the SDK. Each
    source/SDK/toolchain combination has an isolated feed, restore cache and output.
    Nothing in Modules, Config or the service is changed by this script.
.PARAMETER ConnectionSource
    Source directory or ZIP for the installed Connection version. Otherwise uses
    nexo-source.zip from ConnectionZip, or the installed DLL's Git commit on GitHub.
.PARAMETER ModulesConfig
    JSON with modules: [{ packageName, sourcePath (or sourceUrl + sha256), project }].
    Defaults to Config\nexo-build-sources.json. Paths are relative to that file.
.PARAMETER FunctionsOnly
    Internal entry point for the installers; declares helpers without building.
#>
[CmdletBinding()]
param(
    [string]$RunnerDir = 'C:\zapqio\runner',
    [string]$SdkDir,
    [string]$ConnectionZip,
    [string]$ConnectionSource,
    [string]$ModulesConfig,
    [string]$OutputRoot,
    [ValidateSet('pl', 'en', 'de')][string]$Language = 'pl',
    [switch]$FunctionsOnly,
    [string]$InspectAssembly
)

$script:NexoBuildScript = $PSCommandPath

function Resolve-NexoPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-NexoHash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-NexoTextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-NexoChildPath([string]$Root, [string]$Relative) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':')) { throw "Expected a relative path: $Relative" }
    $full = [IO.Path]::GetFullPath((Join-Path $rootFull $Relative))
    if (-not $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes $rootFull : $Relative" }
    # Refuse junctions/symlinks in existing ancestors as well as in the leaf.
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point is not supported: $cursor" }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}

function Remove-NexoWork([string]$Root, [string]$Path) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove $full" }
    [void](Get-NexoChildPath $rootFull $full.Substring($rootFull.Length + 1))
    if (Test-Path -LiteralPath $full) {
        if (Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw "Refusing recursive removal through a reparse point: $full" }
        [IO.Directory]::Delete($full, $true)
    }
}

function Write-NexoJson([string]$Path, $Value) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding $false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Expand-NexoZip([string]$Path, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            $target = Get-NexoChildPath $Destination $entry.FullName
            if (-not $entry.Name) { continue }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
        }
    }
    finally { $zip.Dispose() }
}

function Copy-NexoSource([string]$Source, [string]$Destination) {
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if ($item.Name -in '.git', '.vs', '.idea', '.codex', '.agents', 'bin', 'obj', 'artifacts') { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Source contains a reparse point: $($item.FullName)" }
        $target = Get-NexoChildPath $Destination $item.Name
        if ($item.PSIsContainer) { Copy-NexoSource $item.FullName $target }
        else { [IO.File]::Copy($item.FullName, $target, $false) }
    }
}

function Get-NexoTreeHash([string]$Root) {
    $prefix = $Root.TrimEnd('\') + '\'
    $lines = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($prefix.Length).Replace('\', '/') + ':' + (Get-NexoHash $_.FullName)
    })
    return Get-NexoTextHash ($lines -join "`n")
}

function Get-NexoDotnet([string]$Work) {
    $dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $dotnet) {
        $sdks = @(& $dotnet --list-sdks)
        if ($LASTEXITCODE -eq 0 -and ($sdks | Where-Object { $_ -match '^(8|9|[1-9][0-9])\.\d+\.\d+ ' })) { return $dotnet }
    }
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Install the system .NET SDK 8 or later as administrator before updating nexo.' }
    $metadata = Invoke-RestMethod 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json'
    $release = $metadata.releases | Where-Object { $_.sdk.version -eq $metadata.'latest-sdk' } | Select-Object -First 1
    $asset = $release.sdk.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -like '*.exe' } | Select-Object -First 1
    if (-not $asset -or $asset.hash -notmatch '^[a-fA-F0-9]{128}$' -or $asset.url -notlike 'https://*') { throw 'Invalid .NET SDK installer metadata.' }
    $installer = Join-Path $Work 'dotnet-sdk.exe'
    Invoke-WebRequest $asset.url -OutFile $installer -UseBasicParsing
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA512).Hash -ne $asset.hash) { throw 'The .NET SDK installer checksum does not match.' }
    $process = Start-Process $installer -ArgumentList '/install', '/quiet', '/norestart' -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) { throw "The .NET SDK installer exited with $($process.ExitCode)." }
    $sdks = @(& $dotnet --list-sdks)
    if ($LASTEXITCODE -ne 0 -or -not ($sdks | Where-Object { $_ -match '^8\.\d+\.\d+ ' })) { throw 'The .NET SDK is unavailable after installation.' }
    return $dotnet
}

function Invoke-NexoDotnet([string]$Dotnet, [string]$WorkingDirectory, [string[]]$Arguments) {
    Push-Location -LiteralPath $WorkingDirectory
    $oldToken = $env:ZAPQIO_TOKEN
    $log = Join-Path $WorkingDirectory ('dotnet-' + $Arguments[0] + '.log')
    try {
        $env:ZAPQIO_TOKEN = $null
        # Windows PowerShell 5.1 does not escape a trailing backslash before the
        # closing quote of a spaced native argument. SDK paths need no suffix.
        & $Dotnet @Arguments *> $log
        if ($LASTEXITCODE -ne 0) {
            Get-Content -LiteralPath $log -Tail 40 | Out-Host
            throw "dotnet $($Arguments[0]) failed ($LASTEXITCODE). Build log: $log"
        }
        Write-Host "dotnet $($Arguments[0]): OK ($log)"
    }
    finally { $env:ZAPQIO_TOKEN = $oldToken; Pop-Location }
}

function Write-NexoNuGetConfig([string]$Path, [string]$Cache, [string]$Feed) {
    $cacheXml = [Security.SecurityElement]::Escape($Cache)
    $local = ''
    $mapping = ''
    if ($Feed) {
        $feedXml = [Security.SecurityElement]::Escape($Feed)
        $local = '<add key="NexoSdkVariant" value="' + $feedXml + '" />'
        $mapping = '<packageSourceMapping><clear /><packageSource key="nuget.org"><package pattern="*" /></packageSource><packageSource key="NexoSdkVariant"><package pattern="Zapqio.Nexo.Connection" /></packageSource></packageSourceMapping>'
    }
    [IO.File]::WriteAllText($Path, @"
<configuration><packageSources><clear /><add key="nuget.org" value="https://api.nuget.org/v3/index.json" />$local</packageSources>$mapping<fallbackPackageFolders><clear /></fallbackPackageFolders><config><add key="globalPackagesFolder" value="$cacheXml" /></config></configuration>
"@, (New-Object Text.UTF8Encoding $false))
}

function Get-NexoAssemblyMetadata([string]$Path) {
    # Reflection-only inspection runs in a fresh process: same-name old/new DLLs
    # cannot contaminate each other's reflection cache. No SDK code is executed.
    $json = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:NexoBuildScript -InspectAssembly $Path
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect assembly $Path" }
    return ($json | ConvertFrom-Json)
}

function Test-NexoReferences([string]$Dll, [string]$SdkBin, [string]$ConnectionDll, $Metadata = $null) {
    if (-not $Metadata) { $Metadata = Get-NexoAssemblyMetadata $Dll }
    if ($Metadata.native) { return }
    foreach ($reference in $Metadata.references) {
        $name = New-Object Reflection.AssemblyName $reference
        if ($name.Name -like 'InsERT.*') { $target = Join-Path $SdkBin ($name.Name + '.dll') }
        elseif ($name.Name -eq 'Nexo.Connection') { $target = $ConnectionDll }
        else { continue }
        if (-not $target -or -not (Test-Path -LiteralPath $target)) { throw "Missing reference of $Dll : $reference" }
        $actual = [Reflection.AssemblyName]::GetAssemblyName($target).FullName
        if ($actual -ne $reference) { throw "Assembly identity mismatch in $Dll : expected $reference; found $actual" }
    }
}

function Read-NexoSet([string]$ManifestPath) {
    $manifestFull = Resolve-NexoPath $ManifestPath
    $root = Split-Path -Path $manifestFull -Parent
    $set = Get-Content -LiteralPath $manifestFull -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($set.schemaVersion -ne 1 -or $set.id -notmatch '^[a-f0-9]{64}$' -or -not $set.files) { throw "Invalid nexo set manifest: $manifestFull" }
    $moduleNames = @()
    foreach ($name in $set.modules) {
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $name.Contains('..') -or $name -in $moduleNames) { throw "Invalid nexo set module name: $name" }
        $moduleNames += $name
    }
    if ('Nexo.Connection' -notin $moduleNames -or 'Nexo.Sdk' -notin $moduleNames) { throw 'Incomplete nexo set module list.' }
    $recordedPaths = @()
    foreach ($file in $set.files) {
        if ($file.path -in $recordedPaths) { throw "Duplicate nexo set file: $($file.path)" }
        $recordedPaths += $file.path
        $path = Get-NexoChildPath $root $file.path
        if ($file.sha256 -notmatch '^[a-f0-9]{64}$' -or -not (Test-Path -LiteralPath $path) -or (Get-NexoHash $path) -ne $file.sha256) { throw "Incomplete or modified nexo set: $path" }
    }
    $required = @($moduleNames | ForEach-Object { 'Modules/' + $_ + '.zip' }) + @($set.connectionPackage, 'nexo-source.zip', ($set.sdkBin + '/InsERT.Moria.Sfera.dll'))
    $required += @('build-nexo-set.ps1', 'install-nexo-build.ps1', 'update-nexo-sdk.ps1') | ForEach-Object { 'Output/Connection/' + $_ }
    foreach ($relative in $required) {
        if ($relative -notin $recordedPaths) { throw "Missing nexo set checksum: $relative" }
    }
    foreach ($relative in @($set.connectionPackage, $set.sdkBin)) { [void](Get-NexoChildPath $root $relative) }
    $set | Add-Member -NotePropertyName Root -NotePropertyValue $root -Force
    $set | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $manifestFull -Force
    return $set
}

function Get-NexoSourceSnapshot($Spec, [string]$BaseDir, [string]$Destination, [string]$Work) {
    if ($Spec.sourcePath) {
        $path = if ([IO.Path]::IsPathRooted($Spec.sourcePath)) { Resolve-NexoPath $Spec.sourcePath } else { Resolve-NexoPath (Join-Path $BaseDir $Spec.sourcePath) }
    }
    elseif ($Spec.sourceUrl) {
        if ($Spec.sourceUrl -notlike 'https://*' -or $Spec.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Remote module source requires HTTPS and a SHA256 checksum.' }
        $path = Join-Path $Work ([guid]::NewGuid().ToString('N') + '.zip')
        Invoke-WebRequest $Spec.sourceUrl -OutFile $path -UseBasicParsing
        if ((Get-NexoHash $path) -ne $Spec.sha256) { throw 'Source archive checksum mismatch.' }
    }
    else { throw 'Source requires sourcePath or sourceUrl + sha256.' }
    if (Test-Path -LiteralPath $path -PathType Container) { Copy-NexoSource $path $Destination }
    else { Expand-NexoZip $path $Destination }
}

function Copy-NexoAtomic([string]$Source, [string]$Destination) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
    $temporary = $Destination + '.' + [guid]::NewGuid().ToString('N') + '.new'
    try {
        [IO.File]::Copy($Source, $temporary)
        if ([IO.File]::Exists($Destination)) { [IO.File]::Replace($temporary, $Destination, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Destination) }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Restore-NexoTransaction([string]$RunnerDir, [switch]$DeploymentLockHeld) {
    $journalPath = Get-NexoChildPath $RunnerDir 'Build/nexo-update-journal.json'
    if (-not (Test-Path -LiteralPath $journalPath)) { return }
    $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($journal.phase -ne 'switching') { return }
    $recoveryLock = $null
    try {
        if (-not $DeploymentLockHeld) {
            $deployments = Get-NexoChildPath $RunnerDir 'Deployments'
            [void][IO.Directory]::CreateDirectory($deployments)
            $recoveryLock = [IO.File]::Open((Join-Path $deployments 'state.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        # Validate every backup before restoring any file.
        foreach ($file in $journal.files) {
            if ($file.path.Contains('..') -or $file.path -notmatch '^(Modules/[A-Za-z0-9][A-Za-z0-9._-]*\.zip|Deployments/(NuGet.Config|Directory.Build.props)|nexo-(sdk|build)\.json|(update-nexo-sdk|install-nexo-build|build-nexo-set)\.ps1)$') { throw 'Invalid SDK update journal target.' }
            $target = Get-NexoChildPath $RunnerDir $file.path
            if ($file.existed) {
                $backup = Get-NexoChildPath (Join-Path $RunnerDir 'Build/NexoTransactions') $file.backup
                if ((Get-NexoHash $backup) -ne $file.sha256) { throw "Damaged SDK update backup: $backup" }
            }
        }
        foreach ($file in $journal.files) {
            $target = Get-NexoChildPath $RunnerDir $file.path
            if ($file.existed) { Copy-NexoAtomic (Get-NexoChildPath (Join-Path $RunnerDir 'Build/NexoTransactions') $file.backup) $target }
            elseif ([IO.File]::Exists($target)) { [IO.File]::Delete($target) }
        }
        $journal.phase = 'rolledBack'
        Write-NexoJson $journalPath $journal
        Write-Host 'Restored the previous nexo files after an interrupted or failed activation.'
    }
    finally { if ($recoveryLock) { $recoveryLock.Dispose() } }
}

function Test-NexoInstalledConsumers([string]$RunnerDir, $Set, [string]$Work) {
    # A reference to the stable Connection API does not require rebuilding the
    # consumer. Inspect actual assembly references, including direct SDK uses.
    $connectionRoot = Get-NexoChildPath $Work ('inspect-connection-' + [guid]::NewGuid().ToString('N'))
    Expand-NexoZip (Get-NexoChildPath $Set.Root 'Modules/Nexo.Connection.zip') $connectionRoot
    $connectionDll = Join-Path $connectionRoot 'Nexo.Connection.dll'
    $sdkBin = Get-NexoChildPath $Set.Root $Set.sdkBin
    foreach ($zipFile in Get-ChildItem -LiteralPath (Join-Path $RunnerDir 'Modules') -Filter '*.zip' -File) {
        if ($zipFile.BaseName -in $Set.modules) { continue }
        $hash = Get-NexoHash $zipFile.FullName
        $destination = Get-NexoChildPath $Work ('inspect-' + [guid]::NewGuid().ToString('N'))
        Expand-NexoZip $zipFile.FullName $destination
        foreach ($dll in Get-ChildItem -LiteralPath $destination -Filter '*.dll' -File) {
            $metadata = Get-NexoAssemblyMetadata $dll.FullName
            if (-not $metadata.native -and ($metadata.identity -like 'InsERT.*' -or $metadata.identity -like 'Nexo.Connection,*')) {
                throw "Module $($zipFile.BaseName) contains its own shared library $($dll.Name). Rebuild and redeploy it without private Connection/InsERT libraries before updating SDK. Prepared set: $($Set.ManifestPath)"
            }
            try {
                Test-NexoReferences $dll.FullName $sdkBin $connectionDll $metadata
            }
            catch {
                throw "Module $($zipFile.BaseName) has an incompatible assembly reference for SDK $($Set.sdkVersion). Rebuild and redeploy it against the target SDK, or register its sources in Config\nexo-build-sources.json for a local rebuild. $($_.Exception.Message) Prepared set: $($Set.ManifestPath)"
            }
        }
        if ((Get-NexoHash $zipFile.FullName) -ne $hash) { throw "Module $($zipFile.BaseName) changed during validation. Retry the SDK update." }
        [pscustomobject]@{ packageName = $zipFile.BaseName; sha256 = $hash }
    }
}

function Install-NexoSet([string]$RunnerDir, $Set, [string]$ServiceName, [string]$Language, [object[]]$InstalledConsumers = $null) {
    $deploymentLock = $null
    $journalPath = Get-NexoChildPath $RunnerDir 'Build/nexo-update-journal.json'
    $deployments = Get-NexoChildPath $RunnerDir 'Deployments'
    [void][IO.Directory]::CreateDirectory($deployments)
    try {
        # Coordinate with an unchanged runner. Never rewrite its deployment journal
        # or silently invalidate a Web-managed module's recorded artifact hash.
        $deploymentLock = [IO.File]::Open((Join-Path $deployments 'state.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $statePath = Join-Path $deployments 'state.json'
        if (Test-Path -LiteralPath $statePath) {
            $deploymentState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($deploymentState.batch.phase -in 'Requested', 'Approved', 'Preparing', 'Switching', 'Loading') { throw 'A runner deployment is in progress. Retry the SDK update after it finishes.' }
            foreach ($installed in $deploymentState.installed) {
                if ($installed.manifest.packageName -in $Set.modules) { throw "Module $($installed.manifest.packageName) is Web-managed. Deploy the prepared artifacts through Web. Set: $($Set.ManifestPath)" }
            }
        }
        Restore-NexoTransaction $RunnerDir -DeploymentLockHeld
        if ($PSBoundParameters.ContainsKey('InstalledConsumers')) {
            # A panel deployment may have finished after validation. Recheck the
            # unchanged ZIPs under its lock before activating the shared runtime.
            $currentConsumers = @(Get-ChildItem -LiteralPath (Join-Path $RunnerDir 'Modules') -Filter '*.zip' -File | Where-Object { $_.BaseName -notin $Set.modules })
            if ($currentConsumers.Count -ne @($InstalledConsumers).Count) { throw 'Installed modules changed after validation. Retry the SDK update.' }
            foreach ($zipFile in $currentConsumers) {
                $checked = @($InstalledConsumers | Where-Object { $_.packageName -eq $zipFile.BaseName })
                if ($checked.Count -ne 1 -or (Get-NexoHash $zipFile.FullName) -ne $checked[0].sha256) { throw "Module $($zipFile.BaseName) changed after validation. Retry the SDK update." }
            }
        }
        $transaction = [guid]::NewGuid().ToString('N')
        $backupRoot = Get-NexoChildPath $RunnerDir ('Build/NexoTransactions/' + $transaction)
        [void][IO.Directory]::CreateDirectory($backupRoot)
        $targets = @($Set.modules | ForEach-Object { 'Modules/' + $_ + '.zip' }) + @('Deployments/NuGet.Config', 'Deployments/Directory.Build.props', 'nexo-build.json', 'nexo-sdk.json', 'update-nexo-sdk.ps1', 'install-nexo-build.ps1', 'build-nexo-set.ps1')
        $files = @()
        foreach ($relative in $targets) {
            $target = Get-NexoChildPath $RunnerDir $relative
            $exists = Test-Path -LiteralPath $target -PathType Leaf
            $backupName = $files.Count.ToString() + '.bak'
            $hash = $null
            if ($exists) {
                [IO.File]::Copy($target, (Join-Path $backupRoot $backupName))
                $hash = Get-NexoHash (Join-Path $backupRoot $backupName)
            }
            $files += @{ path = $relative; existed = [bool]$exists; backup = ($transaction + '/' + $backupName); sha256 = $hash }
        }
        Write-NexoJson $journalPath @{ schemaVersion = 1; phase = 'switching'; setId = $Set.id; files = $files }
        try {
            foreach ($name in $Set.modules) { Copy-NexoAtomic (Get-NexoChildPath $Set.Root ('Modules/' + $name + '.zip')) (Get-NexoChildPath $RunnerDir ('Modules/' + $name + '.zip')) }
            $tools = Join-Path $Set.Root 'Output/Connection'
            foreach ($helper in 'build-nexo-set.ps1', 'install-nexo-build.ps1', 'update-nexo-sdk.ps1') { Copy-NexoAtomic (Join-Path $tools $helper) (Get-NexoChildPath $RunnerDir $helper) }
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $tools 'install-nexo-build.ps1') -InstallDir $RunnerDir -ServiceName $ServiceName -SetManifestPath $Set.ManifestPath -FilesOnly -NoRestart -Language $Language | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Applying the nexo build configuration failed.' }
            Write-NexoJson (Join-Path $RunnerDir 'nexo-build.json') @{ schemaVersion = 1; setId = $Set.id; manifestPath = $Set.ManifestPath; sdkVersion = $Set.sdkVersion; connectionVersion = $Set.connectionVersion }
            Write-NexoJson (Join-Path $RunnerDir 'nexo-sdk.json') @{ version = $Set.sdkVersion; setId = $Set.id; at = (Get-Date).ToString('o') }
            # Persist completion before restart. A restart failure is reported separately:
            # these files are a complete, validated set, never half an SDK update.
            Write-NexoJson $journalPath @{ schemaVersion = 1; phase = 'installed'; setId = $Set.id; files = $files }
        }
        catch {
            Restore-NexoTransaction $RunnerDir -DeploymentLockHeld
            throw
        }
    }
    finally { if ($deploymentLock) { $deploymentLock.Dispose() } }
}

if ($FunctionsOnly) {
    # Return declarations, not a dot-sourced parameter block (which would reset
    # the caller's RunnerDir, SdkDir and Language to this script's defaults).
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$errors)
    $definitions = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text })
    $definitions += '$script:NexoBuildScript = ''' + $PSCommandPath.Replace("'", "''") + ''''
    return [scriptblock]::Create(($definitions -join [Environment]::NewLine))
}
$ErrorActionPreference = 'Stop'
if ($InspectAssembly) {
    try {
        $assembly = [Reflection.Assembly]::ReflectionOnlyLoad([IO.File]::ReadAllBytes((Resolve-NexoPath $InspectAssembly)))
        @{ identity = $assembly.FullName; references = @($assembly.GetReferencedAssemblies() | ForEach-Object { $_.FullName }); native = $false } | ConvertTo-Json -Compress
    }
    catch [BadImageFormatException] { @{ native = $true } | ConvertTo-Json -Compress }
    return
}

if (-not $SdkDir) { throw 'Provide -SdkDir with the extracted target SDK Bin directory.' }
$RunnerDir = (Resolve-NexoPath $RunnerDir).TrimEnd('\')
$SdkDir = Resolve-NexoPath $SdkDir
if (-not $ConnectionZip) { $ConnectionZip = Join-Path $RunnerDir 'Modules\Nexo.Connection.zip' }
$ConnectionZip = Resolve-NexoPath $ConnectionZip
if (-not $ModulesConfig) { $ModulesConfig = Join-Path $RunnerDir 'Config\nexo-build-sources.json' }
$ModulesConfig = Resolve-NexoPath $ModulesConfig
if (-not $OutputRoot) { $OutputRoot = Join-Path $RunnerDir 'Build\NexoSets' }
$OutputRoot = Resolve-NexoPath $OutputRoot
[void][IO.Directory]::CreateDirectory($OutputRoot)
$work = Get-NexoChildPath $OutputRoot ('prepare-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$buildLock = $null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $sfera = Join-Path $SdkDir 'InsERT.Moria.Sfera.dll'
    $sdkVersion = ([Diagnostics.FileVersionInfo]::GetVersionInfo($sfera).ProductVersion -split '\+')[0]
    if ($sdkVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "Invalid SDK product version: $sdkVersion" }
    $sdkFiles = @(Get-ChildItem -LiteralPath $SdkDir -File | Where-Object { $_.Extension -in '.dll', '.pak' } | Sort-Object Name)
    $sdkHash = Get-NexoTextHash ((@($sdkFiles | ForEach-Object { $_.Name + ':' + (Get-NexoHash $_.FullName) })) -join "`n")
    $inputZip = Join-Path $work 'installed'
    Expand-NexoZip $ConnectionZip $inputZip
    $installedDll = Join-Path $inputZip 'Nexo.Connection.dll'
    $product = [Diagnostics.FileVersionInfo]::GetVersionInfo($installedDll).ProductVersion
    $connectionVersion = ($product -split '\+')[0]
    if ($connectionVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid Connection version: $connectionVersion" }
    $config = if (Test-Path -LiteralPath $ModulesConfig) { Get-Content -LiteralPath $ModulesConfig -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{ modules = @() } }
    $source = Join-Path $work 'connection-source'
    if ($ConnectionSource) {
        Get-NexoSourceSnapshot ([pscustomobject]@{ sourcePath = (Resolve-NexoPath $ConnectionSource) }) $RunnerDir $source $work
    }
    elseif ($config.connection) {
        Get-NexoSourceSnapshot $config.connection (Split-Path $ModulesConfig -Parent) $source $work
    }
    elseif (Test-Path -LiteralPath (Join-Path $inputZip 'nexo-source.zip')) {
        Expand-NexoZip (Join-Path $inputZip 'nexo-source.zip') $source
    }
    else {
        # Migration of existing releases: use their embedded commit, never main.
        $commit = ($product -split '\+', 2)[1]
        if ($commit -notmatch '^[a-fA-F0-9]{40}$') { throw 'Connection ZIP has no source snapshot or full Git commit. Provide -ConnectionSource once.' }
        $archive = Join-Path $work 'connection-source.zip'
        Invoke-WebRequest "https://codeload.github.com/zapqio/dotnet-module-nexo-connection/zip/$commit" -OutFile $archive -UseBasicParsing
        $unpack = Join-Path $work 'github'
        Expand-NexoZip $archive $unpack
        $roots = @(Get-ChildItem -LiteralPath $unpack -Directory)
        if ($roots.Count -ne 1) { throw 'Unexpected Connection source archive layout.' }
        Copy-NexoSource $roots[0].FullName $source
    }
    [xml]$projectXml = Get-Content -LiteralPath (Join-Path $source 'Nexo.Connection.csproj') -Raw -Encoding UTF8
    $sourceVersion = [string]$projectXml.SelectSingleNode('/Project/PropertyGroup/Version').InnerText
    if ($sourceVersion -ne $connectionVersion) { throw "Connection source version $sourceVersion differs from installed $connectionVersion." }
    $sourceHash = Get-NexoTreeHash $source
    $moduleSources = @()
    $names = @('Nexo.Sdk', 'Nexo.Connection')
    foreach ($module in $config.modules) {
        if ($module.packageName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $module.packageName -in $names -or $module.packageName.Contains('..')) { throw "Invalid or duplicate packageName: $($module.packageName)" }
        $names += $module.packageName
        $moduleSource = Join-Path $work $module.packageName
        Get-NexoSourceSnapshot $module (Split-Path $ModulesConfig -Parent) $moduleSource $work
        $moduleProject = Get-NexoChildPath $moduleSource $module.project
        if (-not (Test-Path -LiteralPath $moduleProject -PathType Leaf) -or [IO.Path]::GetExtension($moduleProject) -ne '.csproj') { throw "Invalid module project: $moduleProject" }
        $moduleSources += [pscustomobject]@{ name = $module.packageName; source = $moduleSource; project = $module.project; sourceHash = (Get-NexoTreeHash $moduleSource) }
    }
    $dotnet = Get-NexoDotnet $work
    Push-Location $work
    try { $toolchain = (& $dotnet --version | Select-Object -Last 1); if ($LASTEXITCODE -ne 0) { throw 'Cannot determine .NET SDK version.' } }
    finally { Pop-Location }
    $toolHash = Get-NexoTextHash ((@('build-nexo-set.ps1', 'install-nexo-build.ps1', 'update-nexo-sdk.ps1') | ForEach-Object { $_ + ':' + (Get-NexoHash (Join-Path $PSScriptRoot $_)) }) -join "`n")
    $keyParts = @($sourceHash, $sdkHash, $toolchain, $toolHash) + @($moduleSources | ForEach-Object { $_.name + ':' + $_.project + ':' + $_.sourceHash })
    $id = Get-NexoTextHash ($keyParts -join "`n")
    $profile = Get-NexoChildPath $OutputRoot $id
    $buildLock = [IO.File]::Open(($profile + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $manifestPath = Join-Path $profile 'nexo-set.json'
    if (Test-Path -LiteralPath $manifestPath) {
        [void](Read-NexoSet $manifestPath)
        Write-Host "Connection $connectionVersion / SDK $sdkVersion : cached set $id"
        return $manifestPath
    }
    if (Test-Path -LiteralPath $profile) { Remove-NexoWork $OutputRoot $profile }
    [void][IO.Directory]::CreateDirectory($profile)
    $sdkBin = Join-Path $profile 'Sdk\Bin'
    $feed = Join-Path $profile 'Feed'
    $cache = Join-Path $profile 'Packages'
    $modules = Join-Path $profile 'Modules'
    foreach ($dir in @($sdkBin, $feed, $cache, $modules)) { [void][IO.Directory]::CreateDirectory($dir) }
    foreach ($file in $sdkFiles) { [IO.File]::Copy($file.FullName, (Join-Path $sdkBin $file.Name)) }
    $sourceArchive = Join-Path $profile 'nexo-source.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($source, $sourceArchive)
    $connectionBuild = Join-Path $profile 'Source\Connection'
    Copy-NexoSource $source $connectionBuild
    $restoreConfig = Join-Path $profile 'Connection.NuGet.Config'
    Write-NexoNuGetConfig $restoreConfig $cache ''
    $publish = Join-Path $profile 'Output\Connection'
    Write-Host "Connection $connectionVersion / SDK $sdkVersion : building $id"
    Invoke-NexoDotnet $dotnet $connectionBuild @('publish', 'Nexo.Connection.csproj', '-c', 'Release', '-o', $publish, '--nologo', '-v', 'minimal', "-p:nexoSdkBinPath=$sdkBin", "-p:NexoSdkVersion=$sdkVersion", '-p:NexoSdkCopyLocal=false', '-p:GeneratePackageOnBuild=true', "-p:PackageOutputPath=$feed", "-p:RestorePackagesPath=$cache", "-p:RestoreConfigFile=$restoreConfig", "-p:SourceRevisionId=$sourceHash")
    $packagePath = Join-Path $feed "Zapqio.Nexo.Connection.$connectionVersion.nupkg"
    $connectionDll = Join-Path $publish 'Nexo.Connection.dll'
    if (-not (Test-Path -LiteralPath $packagePath) -or -not (Test-Path -LiteralPath $connectionDll)) { throw 'Connection build did not produce the DLL and NuGet package.' }
    Test-NexoReferences $connectionDll $sdkBin $connectionDll
    $package = [IO.Compression.ZipFile]::Open($packagePath, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $dllEntry = $package.GetEntry('lib/net8.0-windows7.0/Nexo.Connection.dll')
        if (-not $dllEntry) { throw 'Connection NuGet has no net8.0-windows7.0 reference.' }
        $reference = Join-Path $work 'reference.dll'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($dllEntry, $reference)
        if ((Get-NexoHash $reference) -ne (Get-NexoHash $connectionDll)) { throw 'Built Connection ZIP and NuGet DLLs differ.' }
        $propsEntry = $package.GetEntry('build/Zapqio.Nexo.Connection.props')
        $reader = New-Object IO.StreamReader($propsEntry.Open())
        try { [xml]$variantProps = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $variantProps.SelectSingleNode('/Project/PropertyGroup/NexoSdkVersion').InnerText = $sdkVersion
        $propsEntry.Delete()
        $writer = New-Object IO.StreamWriter($package.CreateEntry('build/Zapqio.Nexo.Connection.props').Open())
        try { $writer.Write($variantProps.OuterXml) } finally { $writer.Dispose() }
    }
    finally { $package.Dispose() }
    # Carry the exact source and current updater with every locally rebuilt ZIP.
    [IO.File]::Copy($sourceArchive, (Join-Path $publish 'nexo-source.zip'), $true)
    foreach ($helper in 'build-nexo-set.ps1', 'install-nexo-build.ps1', 'update-nexo-sdk.ps1') {
        $helperPath = Join-Path $PSScriptRoot $helper
        if (-not (Test-Path -LiteralPath $helperPath)) { throw "Missing updater helper: $helperPath" }
        [IO.File]::Copy($helperPath, (Join-Path $publish $helper), $true)
    }
    [IO.File]::WriteAllText((Join-Path $publish '##Dll'), 'Nexo.Connection.dll')
    [IO.File]::WriteAllText((Join-Path $publish '##Shared'), 'shared')
    if (Get-ChildItem -LiteralPath $publish -Filter 'InsERT.*.dll') { throw 'Connection ZIP must not contain its own InsERT SDK.' }
    [IO.Compression.ZipFile]::CreateFromDirectory($publish, (Join-Path $modules 'Nexo.Connection.zip'))
    [IO.File]::WriteAllText((Join-Path $sdkBin '##Dll'), '')
    [IO.File]::WriteAllText((Join-Path $sdkBin '##Shared'), 'shared')
    $variantConfig = Join-Path $profile 'NuGet.Config'
    Write-NexoNuGetConfig $variantConfig $cache $feed
    foreach ($module in $moduleSources) {
        $moduleBuild = Join-Path $profile ('Source\' + $module.name)
        Copy-NexoSource $module.source $moduleBuild
        $moduleOutput = Join-Path $profile ('Output\' + $module.name)
        Invoke-NexoDotnet $dotnet $moduleBuild @('publish', $module.project, '-c', 'Release', '-o', $moduleOutput, '--nologo', '-v', 'minimal', "-p:nexoSdkBinPath=$sdkBin", "-p:NexoSdkVersion=$sdkVersion", '-p:NexoSdkCopyLocal=false', "-p:RestorePackagesPath=$cache", "-p:RestoreConfigFile=$variantConfig")
        if (-not (Test-Path -LiteralPath (Join-Path $moduleOutput '##Dll'))) { throw "Module $($module.name) has no ##Dll marker." }
        if ((Get-ChildItem -LiteralPath $moduleOutput -Filter 'InsERT.*.dll') -or (Test-Path -LiteralPath (Join-Path $moduleOutput 'Nexo.Connection.dll'))) { throw "Module $($module.name) contains private shared dependencies." }
        foreach ($dll in Get-ChildItem -LiteralPath $moduleOutput -Filter '*.dll') { Test-NexoReferences $dll.FullName $sdkBin $connectionDll }
        [IO.Compression.ZipFile]::CreateFromDirectory($moduleOutput, (Join-Path $modules ($module.name + '.zip')))
    }
    # A compile probe also checks that restore selected our private DLL, even when
    # a public package with exactly the same ID/version is already cached elsewhere.
    $probe = Join-Path $profile 'Probe'
    [void][IO.Directory]::CreateDirectory($probe)
    [IO.File]::WriteAllText((Join-Path $probe 'Probe.csproj'), "<Project Sdk=`"Microsoft.NET.Sdk`"><PropertyGroup><TargetFramework>net8.0-windows</TargetFramework><UseWPF>true</UseWPF><PlatformTarget>x64</PlatformTarget></PropertyGroup><ItemGroup><PackageReference Include=`"Zapqio.Nexo.Connection`" Version=`"[$connectionVersion]`" ExcludeAssets=`"runtime`" /><PackageReference Include=`"Zapqio.Runner.Module.Core`" Version=`"[1.2.0]`" ExcludeAssets=`"runtime`" /></ItemGroup></Project>")
    [IO.File]::WriteAllText((Join-Path $probe 'Probe.cs'), 'using Nexo; using InsERT.Moria.Uzytkownicy; public class Probe { public string Read(NexoClient client) => client.Uchwyt.PodajObiektTypu<IZalogowanyUzytkownik>().Dane.Sygnatura; }')
    Invoke-NexoDotnet $dotnet $probe @('build', 'Probe.csproj', '-c', 'Release', '--nologo', '-v', 'minimal', "-p:nexoSdkBinPath=$sdkBin", "-p:RestorePackagesPath=$cache", "-p:RestoreConfigFile=$variantConfig")
    $restored = Join-Path $cache "zapqio.nexo.connection\$connectionVersion\lib\net8.0-windows7.0\Nexo.Connection.dll"
    if ((Get-NexoHash $restored) -ne (Get-NexoHash $connectionDll)) { throw 'Restore selected a different Connection DLL.' }
    [IO.Compression.ZipFile]::CreateFromDirectory($sdkBin, (Join-Path $modules 'Nexo.Sdk.zip'))
    $files = @()
    foreach ($dir in @($modules, $feed, $sdkBin)) {
        foreach ($file in Get-ChildItem -LiteralPath $dir -File) { $files += @{ path = $file.FullName.Substring($profile.Length + 1).Replace('\', '/'); sha256 = (Get-NexoHash $file.FullName) } }
    }
    $files += @{ path = 'nexo-source.zip'; sha256 = (Get-NexoHash $sourceArchive) }
    foreach ($helper in 'build-nexo-set.ps1', 'install-nexo-build.ps1', 'update-nexo-sdk.ps1') {
        $files += @{ path = ('Output/Connection/' + $helper); sha256 = (Get-NexoHash (Join-Path $publish $helper)) }
    }
    $manifest = [ordered]@{ schemaVersion = 1; id = $id; connectionVersion = $connectionVersion; connectionSourceSha256 = $sourceHash; sdkVersion = $sdkVersion; sdkSha256 = $sdkHash; toolchain = $toolchain; connectionPackage = ('Feed/' + [IO.Path]::GetFileName($packagePath)); sdkBin = 'Sdk/Bin'; modules = @($names); sources = @($moduleSources | Select-Object name, project, sourceHash); files = $files; createdAt = (Get-Date).ToString('o') }
    Write-NexoJson $manifestPath $manifest
    Write-Host "Connection $connectionVersion / SDK $sdkVersion : ready"
    return $manifestPath
}
finally {
    if ($buildLock) { $buildLock.Dispose() }
    Remove-NexoWork $OutputRoot $work
}
