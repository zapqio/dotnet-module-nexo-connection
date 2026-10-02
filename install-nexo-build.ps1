#Requires -Version 5.1
<#
.SYNOPSIS
    Przygotowuje zainstalowanego runnera do budowania modulow nexo z repozytoriow Weba.
.DESCRIPTION
    Uruchom po install-nexo.ps1. Wykorzystuje Modules\Nexo.Sdk.zip, pobiera NuGet Connection
    w wersji zainstalowanego modulu z nuget.org. Module.Core przywraca z nuget.org.
    Konfiguruje Deployments i sprawdza kompilacje.
    W razie braku SDK .NET instaluje systemowe SDK 8 x64. Nie zmienia danych SQL.
    Tryb CI w Webie nie wymaga uruchamiania tego skryptu na serwerze.
.PARAMETER ConnectionPackagePath
    Lokalny plik Zapqio.Nexo.Connection.<wersja>.nupkg zamiast pobierania z nuget.org.
    Musi zawierac DLL zgodna z zainstalowanym ZIP-em. Core nadal pochodzi z nuget.org.
.PARAMETER NoRestart
    Nie restartuje uslugi. Nowe ustawienia srodowiska zadzialaja po jej restarcie.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\zapqio\runner',
    [string]$ServiceName = 'ZapqioRunner',
    [string]$ConnectionPackagePath,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-ZipText($Archive, [string]$Name) {
    $entry = $Archive.GetEntry($Name)
    if (-not $entry) {
        throw "W paczce brakuje $Name."
    }

    $reader = New-Object IO.StreamReader($entry.Open())
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

function Read-Xml([string]$Path, [string]$RootName) {
    $xml = New-Object Xml.XmlDocument
    $xml.XmlResolver = $null
    if (Test-Path -LiteralPath $Path) {
        $xml.Load($Path)
        if ($xml.DocumentElement.Name -ne $RootName) {
            throw "Nieprawidlowy element glowny w $Path."
        }
    }
    else {
        [void]$xml.AppendChild($xml.CreateElement($RootName))
    }

    return ,$xml
}

function Save-Xml($Xml, [string]$Path) {
    $settings = New-Object Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = New-Object Text.UTF8Encoding($false)
    $writer = [Xml.XmlWriter]::Create($Path, $settings)
    try {
        $Xml.Save($writer)
    }
    finally {
        $writer.Dispose()
    }
}

function Write-BuildNuGetConfig([string]$Path, [string]$PackageCache, [string]$LocalSource) {
    $escapedCache = [Security.SecurityElement]::Escape($PackageCache)
    $localEntry = ''
    $sourceMapping = ''
    if ($LocalSource) {
        $escapedSource = [Security.SecurityElement]::Escape($LocalSource)
        $localEntry = '<add key="ZapqioConnectionOverride" value="' + $escapedSource + '" />'
        $sourceMapping = '<packageSourceMapping><packageSource key="nuget.org"><package pattern="*" /></packageSource><packageSource key="ZapqioConnectionOverride"><package pattern="Zapqio.Nexo.Connection" /></packageSource></packageSourceMapping>'
    }

    # This managed configuration is for new build environments. Private project feeds
    # can be configured in a repository's own NuGet.Config.
    [xml]$config = @"
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
    $localEntry
  </packageSources>
  $sourceMapping
  <fallbackPackageFolders><clear /></fallbackPackageFolders>
  <config><add key="globalPackagesFolder" value="$escapedCache" /></config>
</configuration>
"@
    Save-Xml $config $Path
}

function Get-BuildDotnet([string]$Work) {
    $dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $dotnet) {
        $sdks = @(& $dotnet --list-sdks)
        if ($LASTEXITCODE -eq 0 -and ($sdks | Where-Object { $_ -match '^(8|9|[1-9][0-9])\.\d+\.\d+ ' })) {
            return $dotnet
        }
    }

    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Brak systemowego SDK .NET 8 lub nowszego. Uruchom skrypt jako administrator, aby je zainstalowac.'
    }

    Write-Host '==> Pobieram instalator .NET SDK 8 x64...'
    $metadata = Invoke-RestMethod 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json'
    $release = $metadata.releases | Where-Object { $_.sdk.version -eq $metadata.'latest-sdk' } | Select-Object -First 1
    $asset = $release.sdk.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -like '*.exe' } | Select-Object -First 1
    if (-not $asset -or $asset.hash -notmatch '^[a-fA-F0-9]{128}$' -or $asset.url -notlike 'https://*') {
        throw 'Nie udalo sie znalezc instalatora SDK w metadanych Microsoft.'
    }

    $installer = Join-Path $Work 'dotnet-sdk.exe'
    Invoke-WebRequest -Uri $asset.url -OutFile $installer -UseBasicParsing
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA512).Hash -ne $asset.hash) {
        throw 'Suma SHA512 instalatora .NET nie zgadza sie z metadanymi Microsoft.'
    }

    $process = Start-Process -FilePath $installer -ArgumentList '/install', '/quiet', '/norestart' -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) {
        throw "Instalator SDK .NET zakonczyl sie kodem $($process.ExitCode)."
    }

    $sdks = @(& $dotnet --list-sdks)
    if ($LASTEXITCODE -ne 0 -or -not ($sdks | Where-Object { $_ -match '^8\.\d+\.\d+ ' })) {
        throw 'SDK .NET nie jest dostepne po instalacji. Sprawdz wynik instalatora.'
    }

    return $dotnet
}

$InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir).TrimEnd('\')
$modules = Join-Path $InstallDir 'Modules'
foreach ($path in 'Zapqio.Runner.exe', 'Modules\Nexo.Connection.zip', 'Modules\Nexo.Sdk.zip') {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir $path))) {
        throw "Brak $path w $InstallDir. Najpierw uruchom install-nexo.ps1."
    }
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($service) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Uruchom skrypt jako administrator: konfiguracja konta uslugi wymaga podwyzszonych uprawnien.'
    }
}

$build = Join-Path $InstallDir 'Build'
$deployments = Join-Path $InstallDir 'Deployments'
$packageCache = Join-Path $build 'Packages'
$localSource = $null
$work = Join-Path $build ('setup-' + [guid]::NewGuid().ToString('N'))
$probe = $null
foreach ($directory in $build, $deployments, $work) {
    [void][IO.Directory]::CreateDirectory($directory)
}

try {
    $connectionZip = [IO.Compression.ZipFile]::OpenRead((Join-Path $modules 'Nexo.Connection.zip'))
    try {
        $entry = $connectionZip.GetEntry('Nexo.Connection.dll')
        if (-not $entry) {
            throw 'Paczka Connection nie zawiera Nexo.Connection.dll.'
        }

        $connectionDll = Join-Path $work 'Nexo.Connection.dll'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $connectionDll)
    }
    finally {
        $connectionZip.Dispose()
    }

    $connectionVersion = ([Diagnostics.FileVersionInfo]::GetVersionInfo($connectionDll).ProductVersion -split '\+')[0]
    if ($connectionVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "Nieprawidlowa wersja Connection: $connectionVersion."
    }

    $packageName = "Zapqio.Nexo.Connection.$connectionVersion.nupkg"
    $packagePath = Join-Path $work $packageName
    if ($ConnectionPackagePath) {
        Copy-Item -LiteralPath $ConnectionPackagePath -Destination $packagePath
    }
    else {
        Write-Host "==> Pobieram NuGet Connection $connectionVersion..."
        $packageUrl = "https://api.nuget.org/v3-flatcontainer/zapqio.nexo.connection/$connectionVersion/zapqio.nexo.connection.$connectionVersion.nupkg"
        try {
            Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath -UseBasicParsing
        }
        catch {
            throw "Nie mozna pobrac Zapqio.Nexo.Connection $connectionVersion z nuget.org. Wymagana jest dokladnie wersja zainstalowanego ZIP-a. Sprawdz publikacje tej wersji lub podaj -ConnectionPackagePath. Blad: $($_.Exception.Message)"
        }
    }

    $package = [IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
        [xml]$manifest = Read-ZipText $package 'Zapqio.Nexo.Connection.nuspec'
        if ($manifest.package.metadata.id -ne 'Zapqio.Nexo.Connection' -or $manifest.package.metadata.version -ne $connectionVersion) {
            throw "NuGet musi zawierac Zapqio.Nexo.Connection $connectionVersion, zgodny z zainstalowanym modulem."
        }

        [void](Read-ZipText $package 'build/Zapqio.Nexo.Connection.props')
        [void](Read-ZipText $package 'build/Zapqio.Nexo.Connection.targets')
        $reference = $package.GetEntry('lib/net8.0-windows7.0/Nexo.Connection.dll')
        if (-not $reference) {
            throw 'NuGet nie zawiera Nexo.Connection.dll dla net8.0-windows7.0.'
        }

        $referencePath = Join-Path $work 'reference.dll'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($reference, $referencePath)
        if ((Get-FileHash -LiteralPath $referencePath).Hash -ne (Get-FileHash -LiteralPath $connectionDll).Hash) {
            throw 'DLL w NuGet rozni sie od zainstalowanego Connection. Pobierz ZIP i NuGet z tego samego wydania.'
        }
    }
    finally {
        $package.Dispose()
    }

    if ($ConnectionPackagePath) {
        # Separate an explicit local package from public packages with the same ID/version.
        $packageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $localRoot = Join-Path $build ("LocalConnection\" + $packageHash)
        $localSource = Join-Path $localRoot 'Source'
        $packageCache = Join-Path $localRoot 'Packages'
        [void][IO.Directory]::CreateDirectory($localSource)
        Copy-Item -LiteralPath $packagePath -Destination (Join-Path $localSource $packageName) -Force
    }

    $sdkZipPath = Join-Path $modules 'Nexo.Sdk.zip'
    $sdkHash = (Get-FileHash -LiteralPath $sdkZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sdkBin = Join-Path $build "NexoSdk\$sdkHash\Bin"
    [void][IO.Directory]::CreateDirectory($sdkBin)
    $sdkZip = [IO.Compression.ZipFile]::OpenRead($sdkZipPath)
    try {
        if (-not $sdkZip.GetEntry('InsERT.Moria.Sfera.dll')) {
            throw 'Nexo.Sdk.zip nie zawiera InsERT.Moria.Sfera.dll w katalogu glownym.'
        }

        foreach ($entry in $sdkZip.Entries) {
            # Kopiujemy tylko biblioteki z katalogu glownego, bez sciezek z archiwum.
            if ($entry.FullName -match '^[^/\\:]+\.dll$' -and $entry.FullName -ne '..') {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $sdkBin $entry.Name), $true)
            }
        }
    }
    finally {
        $sdkZip.Dispose()
    }

    $sdkVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $sdkBin 'InsERT.Moria.Sfera.dll')).ProductVersion
    Write-Host "==> SDK nexo do kompilacji: $sdkVersion (z zainstalowanego Nexo.Sdk.zip)."
    $dotnet = Get-BuildDotnet $work
    $configPath = Join-Path $deployments 'NuGet.Config'
    Write-BuildNuGetConfig -Path $configPath -PackageCache $packageCache -LocalSource $localSource

    $propsPath = Join-Path $deployments 'Directory.Build.props'
    $props = Read-Xml $propsPath 'Project'
    $group = $props.DocumentElement.SelectSingleNode("PropertyGroup[@Label='ZapqioNexoBuild']")
    if (-not $group) {
        $group = $props.CreateElement('PropertyGroup')
        $group.SetAttribute('Label', 'ZapqioNexoBuild')
        [void]$props.DocumentElement.AppendChild($group)
    }

    $property = $group.SelectSingleNode('nexoSdkBinPath')
    if (-not $property) {
        $property = $props.CreateElement('nexoSdkBinPath')
        [void]$group.AppendChild($property)
    }

    $property.SetAttribute('Condition', "'`$(nexoSdkBinPath)' == ''")
    $property.InnerText = $sdkBin + '\'
    Save-Xml $props $propsPath

    # Proba korzysta z tych samych plikow nadrzednych co wdrozenia Weba.
    $probe = Join-Path $deployments ('nexo-build-check-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($probe)
    $project = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net8.0-windows</TargetFramework><UseWPF>true</UseWPF><PlatformTarget>x64</PlatformTarget></PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Zapqio.Nexo.Connection" Version="[$connectionVersion]" ExcludeAssets="runtime" />
    <PackageReference Include="Zapqio.Runner.Module.Core" Version="[1.2.0]" ExcludeAssets="runtime" />
  </ItemGroup>
</Project>
"@
    [IO.File]::WriteAllText((Join-Path $probe 'Probe.csproj'), $project)
    [IO.File]::WriteAllText((Join-Path $probe 'Probe.cs'), 'using Nexo; using InsERT.Moria.Uzytkownicy; public class Probe { public string Read(NexoClient client) => client.Uchwyt.PodajObiektTypu<IZalogowanyUzytkownik>().Dane.Sygnatura; }')
    Push-Location $probe
    try {
        & $dotnet build 'Probe.csproj' -c Release --nologo -v quiet "-p:RestoreConfigFile=$configPath" "-p:RestorePackagesPath=$packageCache"
        if ($LASTEXITCODE -ne 0) {
            throw 'Proba kompilacji nie powiodla sie. Popraw blad widoczny powyzej i uruchom skrypt ponownie.'
        }
    }
    finally {
        Pop-Location
    }

    $restoredDll = Join-Path $packageCache "zapqio.nexo.connection\$connectionVersion\lib\net8.0-windows7.0\Nexo.Connection.dll"
    if (-not (Test-Path -LiteralPath $restoredDll) -or (Get-FileHash -LiteralPath $restoredDll).Hash -ne (Get-FileHash -LiteralPath $connectionDll).Hash) {
        throw 'Przywrocona paczka Connection nie odpowiada DLL w zainstalowanym ZIP-ie.'
    }

    if ($service) {
        $serviceInfo = Get-CimInstance Win32_Service | Where-Object { $_.Name -eq $ServiceName } | Select-Object -First 1
        $account = $serviceInfo.StartName
        if ($account -and $account -ne 'LocalSystem') {
            & icacls $build /grant "${account}:(OI)(CI)M" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw 'Nie udalo sie nadac kontu uslugi praw do katalogu Build.'
            }

            & icacls $deployments /grant "${account}:(OI)(CI)M" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw 'Nie udalo sie nadac kontu uslugi praw do katalogu Deployments.'
            }
        }

        $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
        $environment = @((Get-ItemProperty -LiteralPath $serviceKey -Name Environment -ErrorAction SilentlyContinue).Environment | Where-Object { $_ })
        $oldPath = $environment | Where-Object { $_ -like 'PATH=*' } | Select-Object -First 1
        $searchPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if ($oldPath) {
            $searchPath = $oldPath.Substring(5)
        }

        $dotnetDir = Split-Path -Path $dotnet -Parent
        $pathParts = @($dotnetDir) + @($searchPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $dotnetDir })
        $environment = @($environment | Where-Object { $_ -notmatch '^(PATH|DOTNET_CLI_HOME|NUGET_PACKAGES)=' })
        $environment += 'PATH=' + ($pathParts -join ';')
        $environment += 'DOTNET_CLI_HOME=' + (Join-Path $build 'CliHome')
        $environment += 'NUGET_PACKAGES=' + $packageCache
        New-ItemProperty -LiteralPath $serviceKey -Name Environment -PropertyType MultiString -Value ([string[]]$environment) -Force | Out-Null
        if (-not $NoRestart) {
            Restart-Service -Name $ServiceName
        }
    }
    else {
        Write-Warning "Nie znaleziono uslugi $ServiceName. Przygotowano pliki; uprawnienia i srodowisko uslugi nie zostaly zmienione."
    }

    Write-Host "==> Kompilacja sprawdzona. W Webie mozesz wybrac budowanie na runnerze $ServiceName."
    if ($NoRestart -or -not $service) {
        Write-Host 'Uruchom ponownie runnera, aby wczytal srodowisko budowania.'
    }
}
finally {
    # Usuwamy wylacznie katalogi tego uruchomienia pod sprawdzonymi katalogami instalacji.
    foreach ($temporary in @($work, $probe)) {
        if ($temporary) {
            $full = [IO.Path]::GetFullPath($temporary)
            $parent = [IO.Path]::GetDirectoryName($full)
            if (($parent -in @($build, $deployments)) -and (Test-Path -LiteralPath $full)) {
                Remove-Item -LiteralPath $full -Recurse -Force
            }
        }
    }
}
