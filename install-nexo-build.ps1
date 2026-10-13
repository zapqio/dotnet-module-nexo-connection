#Requires -Version 5.1
<#
.SYNOPSIS
    Przygotowuje zainstalowanego runnera do budowania modulow nexo z repozytoriow Weba.
.DESCRIPTION
    Uruchamiany automatycznie przez install-nexo.ps1. Mozna go tez uruchomic osobno, aby odswiezyc
    srodowisko budowania. Wykorzystuje Modules\Nexo.Sdk.zip, pobiera NuGet Connection w wersji
    zainstalowanego modulu z nuget.org. Module.Core przywraca z nuget.org.
    Konfiguruje Deployments i sprawdza kompilacje.
    W razie braku SDK .NET instaluje systemowe SDK 8 x64. Nie zmienia danych SQL.
.PARAMETER ConnectionPackagePath
    Lokalny plik Zapqio.Nexo.Connection.<wersja>.nupkg zamiast pobierania z nuget.org.
    Musi zawierac DLL zgodna z zainstalowanym ZIP-em. Core nadal pochodzi z nuget.org.
.PARAMETER Language
    Jezyk komunikatow: pl, en albo de. Domyslnie pl; install-nexo.ps1 przekazuje wybrany jezyk.
.PARAMETER NoRestart
    Nie restartuje uslugi. Nowe ustawienia srodowiska zadzialaja po jej restarcie.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\zapqio\runner',
    [string]$ServiceName = 'ZapqioRunner',
    [string]$ConnectionPackagePath,
    [switch]$NoRestart,
    [ValidateSet('pl', 'en', 'de')][string]$Language = 'pl'
)

$ErrorActionPreference = 'Stop'

$messages = @{
    pl = @{
        MissingEntry = 'W paczce brakuje {0}.'
        InvalidXml = 'Nieprawidłowy element główny w {0}.'
        DotnetAdmin = 'Brak systemowego SDK .NET 8 lub nowszego. Uruchom skrypt jako administrator, aby je zainstalować.'
        DownloadDotnet = '==> Pobieram instalator .NET SDK 8 x64...'
        MissingDotnetAsset = 'Nie udało się znaleźć instalatora SDK w metadanych Microsoft.'
        DotnetHash = 'Suma SHA512 instalatora .NET nie zgadza się z metadanymi Microsoft.'
        DotnetExit = 'Instalator SDK .NET zakończył się kodem {0}.'
        DotnetUnavailable = 'SDK .NET nie jest dostępne po instalacji. Sprawdź wynik instalatora.'
        MissingRuntime = 'Brak {0} w {1}. Najpierw uruchom install-nexo.ps1.'
        ServiceAdmin = 'Uruchom skrypt jako administrator: konfiguracja konta usługi wymaga podwyższonych uprawnień.'
        MissingConnection = 'Paczka Connection nie zawiera Nexo.Connection.dll.'
        InvalidConnectionVersion = 'Nieprawidłowa wersja Connection: {0}.'
        DownloadConnection = '==> Pobieram NuGet Connection {0}...'
        ConnectionDownloadFailed = 'Nie można pobrać Zapqio.Nexo.Connection {0} z nuget.org. Wymagana jest dokładnie wersja zainstalowanego ZIP-a. Sprawdź publikację tej wersji lub podaj -ConnectionPackagePath. Błąd: {1}'
        ConnectionVersionMismatch = 'NuGet musi zawierać Zapqio.Nexo.Connection {0}, zgodny z zainstalowanym modułem.'
        MissingReference = 'NuGet nie zawiera Nexo.Connection.dll dla net8.0-windows7.0.'
        ConnectionDllMismatch = 'DLL w NuGet różni się od zainstalowanego Connection. Pobierz ZIP i NuGet z tego samego wydania.'
        MissingSdk = 'Nexo.Sdk.zip nie zawiera InsERT.Moria.Sfera.dll w katalogu głównym.'
        BuildSdk = '==> SDK nexo do kompilacji: {0} (z zainstalowanego Nexo.Sdk.zip).'
        ProbeFailed = 'Próba kompilacji nie powiodła się. Popraw błąd widoczny powyżej i uruchom skrypt ponownie.'
        RestoredDllMismatch = 'Przywrócona paczka Connection nie odpowiada DLL w zainstalowanym ZIP-ie.'
        BuildPermissions = 'Nie udało się nadać kontu usługi praw do katalogu Build.'
        DeploymentPermissions = 'Nie udało się nadać kontu usługi praw do katalogu Deployments.'
        NoService = 'Nie znaleziono usługi {0}. Przygotowano pliki; uprawnienia i środowisko usługi nie zostały zmienione.'
        BuildReady = '==> Kompilacja sprawdzona. W Webie możesz wybrać budowanie na runnerze {0}.'
        RestartRequired = 'Uruchom ponownie runnera, aby wczytał środowisko budowania.'
    }
    en = @{
        MissingEntry = 'The package is missing {0}.'
        InvalidXml = 'Invalid root element in {0}.'
        DotnetAdmin = 'The system .NET SDK 8 or later is missing. Run this script as administrator to install it.'
        DownloadDotnet = '==> Downloading the .NET SDK 8 x64 installer...'
        MissingDotnetAsset = 'Could not find the SDK installer in Microsoft release metadata.'
        DotnetHash = 'The .NET installer SHA512 checksum does not match Microsoft metadata.'
        DotnetExit = 'The .NET SDK installer exited with code {0}.'
        DotnetUnavailable = 'The .NET SDK is unavailable after installation. Check the installer result.'
        MissingRuntime = '{0} is missing in {1}. Run install-nexo.ps1 first.'
        ServiceAdmin = 'Run this script as administrator: configuring the service account requires elevated permissions.'
        MissingConnection = 'The Connection package does not contain Nexo.Connection.dll.'
        InvalidConnectionVersion = 'Invalid Connection version: {0}.'
        DownloadConnection = '==> Downloading Connection NuGet package {0}...'
        ConnectionDownloadFailed = 'Cannot download Zapqio.Nexo.Connection {0} from nuget.org. It must match the installed ZIP version exactly. Check that this version is published or provide -ConnectionPackagePath. Error: {1}'
        ConnectionVersionMismatch = 'The NuGet package must contain Zapqio.Nexo.Connection {0}, matching the installed module.'
        MissingReference = 'The NuGet package does not contain Nexo.Connection.dll for net8.0-windows7.0.'
        ConnectionDllMismatch = 'The NuGet DLL differs from the installed Connection. Download the ZIP and NuGet package from the same release.'
        MissingSdk = 'Nexo.Sdk.zip does not contain InsERT.Moria.Sfera.dll at its root.'
        BuildSdk = '==> nexo SDK for builds: {0} (from the installed Nexo.Sdk.zip).'
        ProbeFailed = 'The test build failed. Fix the error above and run this script again.'
        RestoredDllMismatch = 'The restored Connection package does not match the DLL in the installed ZIP.'
        BuildPermissions = 'Could not grant the service account permissions to the Build directory.'
        DeploymentPermissions = 'Could not grant the service account permissions to the Deployments directory.'
        NoService = 'Service {0} was not found. Files are ready; service permissions and environment were not changed.'
        BuildReady = '==> Test build passed. You can now select builds on runner {0} in the Web panel.'
        RestartRequired = 'Restart the runner to load the build environment.'
    }
    de = @{
        MissingEntry = 'Im Paket fehlt {0}.'
        InvalidXml = 'Ungültiges Wurzelelement in {0}.'
        DotnetAdmin = 'Das systemweite .NET SDK 8 oder neuer fehlt. Führen Sie dieses Skript als Administrator aus, um es zu installieren.'
        DownloadDotnet = '==> Das Installationsprogramm für .NET SDK 8 x64 wird heruntergeladen...'
        MissingDotnetAsset = 'Das SDK-Installationsprogramm wurde in den Microsoft-Releasemetadaten nicht gefunden.'
        DotnetHash = 'Die SHA512-Prüfsumme des .NET-Installationsprogramms stimmt nicht mit den Microsoft-Metadaten überein.'
        DotnetExit = 'Das .NET SDK-Installationsprogramm wurde mit Code {0} beendet.'
        DotnetUnavailable = 'Das .NET SDK ist nach der Installation nicht verfügbar. Prüfen Sie das Installationsergebnis.'
        MissingRuntime = '{0} fehlt in {1}. Führen Sie zuerst install-nexo.ps1 aus.'
        ServiceAdmin = 'Führen Sie dieses Skript als Administrator aus: Die Konfiguration des Dienstkontos erfordert erhöhte Rechte.'
        MissingConnection = 'Das Connection-Paket enthält keine Nexo.Connection.dll.'
        InvalidConnectionVersion = 'Ungültige Connection-Version: {0}.'
        DownloadConnection = '==> Das Connection-NuGet-Paket {0} wird heruntergeladen...'
        ConnectionDownloadFailed = 'Zapqio.Nexo.Connection {0} kann nicht von nuget.org heruntergeladen werden. Die Version muss genau dem installierten ZIP entsprechen. Prüfen Sie, ob diese Version veröffentlicht wurde, oder geben Sie -ConnectionPackagePath an. Fehler: {1}'
        ConnectionVersionMismatch = 'Das NuGet-Paket muss Zapqio.Nexo.Connection {0} enthalten, passend zum installierten Modul.'
        MissingReference = 'Das NuGet-Paket enthält keine Nexo.Connection.dll für net8.0-windows7.0.'
        ConnectionDllMismatch = 'Die DLL im NuGet-Paket unterscheidet sich vom installierten Connection-Modul. Laden Sie ZIP und NuGet-Paket aus derselben Veröffentlichung herunter.'
        MissingSdk = 'Nexo.Sdk.zip enthält keine InsERT.Moria.Sfera.dll im Stammverzeichnis.'
        BuildSdk = '==> nexo SDK zum Kompilieren: {0} (aus dem installierten Nexo.Sdk.zip).'
        ProbeFailed = 'Die Testkompilierung ist fehlgeschlagen. Beheben Sie den oben angezeigten Fehler und führen Sie das Skript erneut aus.'
        RestoredDllMismatch = 'Das wiederhergestellte Connection-Paket stimmt nicht mit der DLL im installierten ZIP überein.'
        BuildPermissions = 'Dem Dienstkonto konnten keine Rechte für das Verzeichnis Build erteilt werden.'
        DeploymentPermissions = 'Dem Dienstkonto konnten keine Rechte für das Verzeichnis Deployments erteilt werden.'
        NoService = 'Der Dienst {0} wurde nicht gefunden. Die Dateien sind vorbereitet; Dienstberechtigungen und -umgebung wurden nicht geändert.'
        BuildReady = '==> Testkompilierung erfolgreich. Im Webpanel können Sie nun das Kompilieren auf Runner {0} auswählen.'
        RestartRequired = 'Starten Sie den Runner neu, damit die Build-Umgebung geladen wird.'
    }
}

# Keep translations inside the script: it can also be run directly from a downloaded scriptblock.
function Get-InstallText {
    param([string]$Key, [object[]]$Values = @())
    $template = $messages[$Language][$Key]
    if ($null -eq $template) { throw "Missing installer translation: $Language/$Key" }
    return [string]::Format([Globalization.CultureInfo]::GetCultureInfo($Language), $template, $Values)
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-ZipText($Archive, [string]$Name) {
    $entry = $Archive.GetEntry($Name)
    if (-not $entry) {
        throw (Get-InstallText 'MissingEntry' @($Name))
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
            throw (Get-InstallText 'InvalidXml' @($Path))
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
        throw (Get-InstallText 'DotnetAdmin')
    }

    Write-Host (Get-InstallText 'DownloadDotnet')
    $metadata = Invoke-RestMethod 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json'
    $release = $metadata.releases | Where-Object { $_.sdk.version -eq $metadata.'latest-sdk' } | Select-Object -First 1
    $asset = $release.sdk.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -like '*.exe' } | Select-Object -First 1
    if (-not $asset -or $asset.hash -notmatch '^[a-fA-F0-9]{128}$' -or $asset.url -notlike 'https://*') {
        throw (Get-InstallText 'MissingDotnetAsset')
    }

    $installer = Join-Path $Work 'dotnet-sdk.exe'
    Invoke-WebRequest -Uri $asset.url -OutFile $installer -UseBasicParsing
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA512).Hash -ne $asset.hash) {
        throw (Get-InstallText 'DotnetHash')
    }

    $process = Start-Process -FilePath $installer -ArgumentList '/install', '/quiet', '/norestart' -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) {
        throw (Get-InstallText 'DotnetExit' @($process.ExitCode))
    }

    $sdks = @(& $dotnet --list-sdks)
    if ($LASTEXITCODE -ne 0 -or -not ($sdks | Where-Object { $_ -match '^8\.\d+\.\d+ ' })) {
        throw (Get-InstallText 'DotnetUnavailable')
    }

    return $dotnet
}

$InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir).TrimEnd('\')
$modules = Join-Path $InstallDir 'Modules'
foreach ($path in 'Zapqio.Runner.exe', 'Modules\Nexo.Connection.zip', 'Modules\Nexo.Sdk.zip') {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir $path))) {
        throw (Get-InstallText 'MissingRuntime' @($path, $InstallDir))
    }
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($service) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw (Get-InstallText 'ServiceAdmin')
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
            throw (Get-InstallText 'MissingConnection')
        }

        $connectionDll = Join-Path $work 'Nexo.Connection.dll'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $connectionDll)
    }
    finally {
        $connectionZip.Dispose()
    }

    $connectionVersion = ([Diagnostics.FileVersionInfo]::GetVersionInfo($connectionDll).ProductVersion -split '\+')[0]
    if ($connectionVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw (Get-InstallText 'InvalidConnectionVersion' @($connectionVersion))
    }

    $packageName = "Zapqio.Nexo.Connection.$connectionVersion.nupkg"
    $packagePath = Join-Path $work $packageName
    if ($ConnectionPackagePath) {
        Copy-Item -LiteralPath $ConnectionPackagePath -Destination $packagePath
    }
    else {
        Write-Host (Get-InstallText 'DownloadConnection' @($connectionVersion))
        $packageUrl = "https://api.nuget.org/v3-flatcontainer/zapqio.nexo.connection/$connectionVersion/zapqio.nexo.connection.$connectionVersion.nupkg"
        try {
            Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath -UseBasicParsing
        }
        catch {
            throw (Get-InstallText 'ConnectionDownloadFailed' @($connectionVersion, $_.Exception.Message))
        }
    }

    $package = [IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
        [xml]$manifest = Read-ZipText $package 'Zapqio.Nexo.Connection.nuspec'
        if ($manifest.package.metadata.id -ne 'Zapqio.Nexo.Connection' -or $manifest.package.metadata.version -ne $connectionVersion) {
            throw (Get-InstallText 'ConnectionVersionMismatch' @($connectionVersion))
        }

        [void](Read-ZipText $package 'build/Zapqio.Nexo.Connection.props')
        [void](Read-ZipText $package 'build/Zapqio.Nexo.Connection.targets')
        $reference = $package.GetEntry('lib/net8.0-windows7.0/Nexo.Connection.dll')
        if (-not $reference) {
            throw (Get-InstallText 'MissingReference')
        }

        $referencePath = Join-Path $work 'reference.dll'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($reference, $referencePath)
        if ((Get-FileHash -LiteralPath $referencePath).Hash -ne (Get-FileHash -LiteralPath $connectionDll).Hash) {
            throw (Get-InstallText 'ConnectionDllMismatch')
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
            throw (Get-InstallText 'MissingSdk')
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
    Write-Host (Get-InstallText 'BuildSdk' @($sdkVersion))
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
            throw (Get-InstallText 'ProbeFailed')
        }
    }
    finally {
        Pop-Location
    }

    $restoredDll = Join-Path $packageCache "zapqio.nexo.connection\$connectionVersion\lib\net8.0-windows7.0\Nexo.Connection.dll"
    if (-not (Test-Path -LiteralPath $restoredDll) -or (Get-FileHash -LiteralPath $restoredDll).Hash -ne (Get-FileHash -LiteralPath $connectionDll).Hash) {
        throw (Get-InstallText 'RestoredDllMismatch')
    }

    if ($service) {
        $serviceInfo = Get-CimInstance Win32_Service | Where-Object { $_.Name -eq $ServiceName } | Select-Object -First 1
        $account = $serviceInfo.StartName
        if ($account -and $account -ne 'LocalSystem') {
            & icacls $build /grant "${account}:(OI)(CI)M" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw (Get-InstallText 'BuildPermissions')
            }

            & icacls $deployments /grant "${account}:(OI)(CI)M" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw (Get-InstallText 'DeploymentPermissions')
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
        Write-Warning (Get-InstallText 'NoService' @($ServiceName))
    }

    Write-Host (Get-InstallText 'BuildReady' @($ServiceName))
    if ($NoRestart -or -not $service) {
        Write-Host (Get-InstallText 'RestartRequired')
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
