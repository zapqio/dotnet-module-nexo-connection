#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$Configuration = 'Release',
    [string]$AssetsFile
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$Project = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Project)
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
$files = @{}
$projects = @{}
$pending = New-Object 'Collections.Generic.Queue[string]'
$pending.Enqueue($Project)
$packageRoots = @()
if ($AssetsFile -and (Test-Path -LiteralPath $AssetsFile)) {
    $assets = Get-Content -LiteralPath $AssetsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $packageRoots = @($assets.packageFolders.PSObject.Properties.Name)
}

function Is-GeneratedOrPrivate([string]$Path) {
    return $Path -match '(?i)[\\/](bin|obj|\.git|\.vs|\.codex|\.agents|artifacts|Config)[\\/]' -or
        [IO.Path]::GetFileName($Path) -match '(?i)^(\.env.*|nuget\.config|appsettings.*\.json|nexo-module-source\.(zip|json))$' -or
        [IO.Path]::GetExtension($Path) -in '.pfx', '.snk', '.user', '.log', '.binlog'
}

function Add-SourceFile([string]$Path, [switch]$Required) {
    $full = [IO.Path]::GetFullPath($Path)
    if (Is-GeneratedOrPrivate $full) {
        if ($Required) { throw "Required source is in an excluded directory or contains private configuration: $full" }
        return
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        if ($Required) { throw "Missing build input: $full" }
        return
    }
    $cursor = $full
    while ($cursor) {
        if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Source cannot contain links: $cursor" }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $files[$full] = $true
}

while ($pending.Count) {
    $current = [IO.Path]::GetFullPath($pending.Dequeue())
    if ($projects.ContainsKey($current)) { continue }
    $projects[$current] = $true
    Add-SourceFile $current -Required
    # Evaluation only: does not execute Publish or recursively invoke this target.
    $query = & $dotnet msbuild $current -nologo "-p:Configuration=$Configuration" '-getProperty:NuGetPackageRoot' '-getItem:Compile,EmbeddedResource,Content,None,AdditionalFiles,Page,ApplicationDefinition,Resource,ProjectReference,NexoSourceInclude' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Cannot evaluate source inputs of $current : $($query -join [Environment]::NewLine)" }
    $evaluated = ($query -join [Environment]::NewLine) | ConvertFrom-Json
    foreach ($reference in $evaluated.Items.ProjectReference) { $pending.Enqueue($reference.FullPath) }
    foreach ($kind in 'Compile', 'EmbeddedResource', 'Content', 'None', 'AdditionalFiles', 'Page', 'ApplicationDefinition', 'Resource', 'NexoSourceInclude') {
        foreach ($item in $evaluated.Items.$kind) {
            if ($item.FullPath) { Add-SourceFile $item.FullPath -Required:($kind -eq 'NexoSourceInclude') }
        }
    }
    # Only user imports are copied. Framework/NuGet targets are restored normally;
    # the runner's machine-specific SDK/cache configuration must not be frozen.
    # MSBuildAllProjects does not include every import on recent SDKs. The
    # preprocessed project records the actual imported files, including custom
    # Directory.Build.props/targets and Directory.Packages.props from ancestors.
    $preprocessed = Join-Path $OutputDirectory ('imports-' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        $preprocessLog = & $dotnet msbuild $current -nologo "-p:Configuration=$Configuration" "-preprocess:$preprocessed" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Cannot inspect imports of $current : $($preprocessLog -join [Environment]::NewLine)" }
        [xml]$expandedProject = [IO.File]::ReadAllText($preprocessed)
        $imports = @($expandedProject.SelectNodes('//comment()') | ForEach-Object {
            # Only MSBuild's import boundary comments identify build inputs;
            # a path mentioned in an ordinary project comment is not an input.
            if ($_.Value -match '(?s)^\s*={5,}.*<Import\s') {
                foreach ($line in ($_.Value -split '\r?\n')) {
                    $candidate = $line.Trim()
                    if ($candidate -match '^[A-Za-z]:\\[^<>*?"|]+$' -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $candidate }
                }
            }
        } | Select-Object -Unique)
    }
    finally { if ([IO.File]::Exists($preprocessed)) { [IO.File]::Delete($preprocessed) } }
    foreach ($import in $imports) {
        if (-not $import -or -not (Test-Path -LiteralPath $import -PathType Leaf)) { continue }
        $full = [IO.Path]::GetFullPath($import)
        if ($full.StartsWith((Split-Path $dotnet -Parent) + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $inPackages = @($packageRoots + @($evaluated.Properties.NuGetPackageRoot) | Where-Object { $_ -and $full.StartsWith($_.TrimEnd('\', '/') + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if ($inPackages -or (Is-GeneratedOrPrivate $full)) { continue }
        if ($full -ne $current) {
            $text = [IO.File]::ReadAllText($full)
            if ($text.Contains('Label="ZapqioNexoBuild"')) { continue }
            Add-SourceFile $full -Required
        }
    }
}

# Keep relative links and ProjectReference paths intact, including sibling projects.
$sourceRoot = Split-Path $Project -Parent
foreach ($file in $files.Keys) {
    while (-not $file.StartsWith($sourceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $parent = [IO.Path]::GetDirectoryName($sourceRoot)
        if (-not $parent -or $parent -eq [IO.Path]::GetPathRoot($parent)) { throw 'Source inputs must share a directory below the drive root. Move linked projects/files into a common source directory.' }
        $sourceRoot = $parent
    }
}
$relativeProject = $Project.Substring($sourceRoot.TrimEnd('\').Length + 1).Replace('\', '/')
$archivePath = Join-Path $OutputDirectory 'nexo-module-source.zip'
$temporary = $archivePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
try {
    $archive = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in @($files.Keys | Sort-Object)) {
            $relative = $file.Substring($sourceRoot.TrimEnd('\').Length + 1).Replace('\', '/')
            $entry = $archive.CreateEntry($relative)
            $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $sourceStream = [IO.File]::OpenRead($file)
            $entryStream = $entry.Open()
            try { $sourceStream.CopyTo($entryStream) }
            finally { $entryStream.Dispose(); $sourceStream.Dispose() }
        }
    }
    finally { $archive.Dispose() }
    if ([IO.File]::Exists($archivePath)) { [IO.File]::Replace($temporary, $archivePath, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $archivePath) }
    # dotnet/MSBuild started by PowerShell 7 can pass its PSModulePath to this
    # Windows PowerShell 5.1 child, where Get-FileHash is then unavailable.
    # Use the framework directly so publishing does not depend on module loading.
    $hashStream = [IO.File]::OpenRead($archivePath)
    try {
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $sourceHash = [BitConverter]::ToString($hasher.ComputeHash($hashStream)).Replace('-', '').ToLowerInvariant() }
        finally { $hasher.Dispose() }
    }
    finally { $hashStream.Dispose() }
    $metadata = [ordered]@{ schemaVersion = 1; project = $relativeProject; sha256 = $sourceHash }
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'nexo-module-source.json'), ($metadata | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    Write-Host "Packed nexo module source: $relativeProject ($($files.Count) files)"
}
finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
