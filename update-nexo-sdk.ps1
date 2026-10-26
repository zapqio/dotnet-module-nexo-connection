<#
.SYNOPSIS
  Podmienia SDK InsERT nexo na runnerze Zapqio na wersję zgodną z Subiektem.

.DESCRIPTION
  Pobiera nexoSDK z publicznego FTP InsERT (albo bierze gotowy katalog Bin), pakuje go do
  Modules\Nexo.Sdk.zip z markerami ##Shared i ##Dll, przebudowuje Connection i zarejestrowane moduły,
  sprawdza cały zestaw, aktywuje go z kopią zapasową oraz restartuje usługę runnera.
  Wersja NuGet Connection pozostaje bez zmian; wariant SDK ma osobne lokalne źródło i cache.

  Uruchamiany ręcznie jako administrator albo automatycznie przez NexoClient (moduł Nexo.Connection) po
  wykryciu niezgodności wersji: wtedy działa na koncie usługi, bez konsoli (-Log) i zapisuje wynik do
  pliku stanu (-State). Restart: Restart-Service, a gdy konto nie ma do tego prawa, zakończenie procesu
  runnera, który SCM podnosi z opcji odzyskiwania.

.PARAMETER Version
  Wersja Subiekta z "Pomoc > O programie", np. 62.0.0 lub 62.0.0.9537.

.PARAMETER SdkDir
  Gotowy katalog Bin rozpakowanego SDK (np. C:\nexoSDK_61.1.0.9431\Bin); pomija pobieranie.

.PARAMETER RunnerDir
  Katalog instalacji runnera z podkatalogiem Modules (domyślnie C:\zapqio\runner).

.PARAMETER ServiceName
  Nazwa usługi runnera (domyślnie ZapqioRunner).

.PARAMETER Language
  Język komunikatów: pl, en albo de. Domyślnie pl; install-nexo.ps1 przekazuje wybrany język.

.PARAMETER NoRestart
  Aktywacja całego zestawu bez restartu usługi. Do samego przygotowania użyj -PrepareOnly.

.PARAMETER ModulesUrl
  Parametr wycofany; skrypt zgłasza błąd. Zarejestruj źródła przez -ModulesConfig.

.PARAMETER ModulesPath
  Parametr wycofany; skrypt zgłasza błąd. Zarejestruj źródła przez -ModulesConfig.

.PARAMETER ConnectionZip
  ZIP Connection do przebudowy. Domyślnie Modules\Nexo.Connection.zip runnera.

.PARAMETER ConnectionSource
  Katalog lub ZIP źródeł tej samej wersji Connection. Potrzebny tylko przy migracji paczki bez źródeł/commita.

.PARAMETER ModulesConfig
  Rejestr źródeł modułów. Domyślnie Config\nexo-build-sources.json; opis formatu w README.md.

.PARAMETER PrepareOnly
  Buduje i sprawdza zestaw, ale nie zmienia zainstalowanych modułów, konfiguracji budowania ani usługi.

.PARAMETER Log
  Plik, do którego dopisywane są komunikaty (oprócz konsoli); NexoClient podaje Logs\nexo-sdk-update.log.

.PARAMETER State
  Plik JSON ze stanem podmiany (version, startedAt, finishedAt, result, message), czytany przez NexoClient.

.PARAMETER WorkDir
  Katalog roboczy na pobrany plik i rozpakowane SDK (domyślnie <RunnerDir>\.sdk-tmp; konto usługi nie ma
  zwykłego %TEMP%). Sprzątany na końcu.

.EXAMPLE
  .\update-nexo-sdk.ps1 -Version 61.1.1

.EXAMPLE
  .\update-nexo-sdk.ps1 -Version 62.0.0.9537 -PrepareOnly

.EXAMPLE
  .\update-nexo-sdk.ps1 -SdkDir C:\nexoSDK_61.1.0.9431\Bin -RunnerDir D:\zapqio\runner -NoRestart
#>
[CmdletBinding(DefaultParameterSetName = 'Download')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Download')] [string] $Version,
    [Parameter(Mandatory = $true, ParameterSetName = 'Local')] [string] $SdkDir,
    [string] $RunnerDir = 'C:\zapqio\runner',
    [string] $ServiceName = 'ZapqioRunner',
    [switch] $NoRestart,
    [string] $ModulesUrl,
    [string] $ModulesPath,
    [string] $Log,
    [string] $State,
    [string] $WorkDir,
    [string] $ConnectionZip,
    [string] $ConnectionSource,
    [string] $ModulesConfig,
    [switch] $PrepareOnly,
    [ValidateSet('pl', 'en', 'de')][string] $Language = 'pl'
)

$ErrorActionPreference = 'Stop'

$messages = @{
    pl = @{
        MissingModuleSet = 'Brak kompletu modułów dla SDK {0} pod {1} (jeszcze nie zbudowany?). Obecne moduły zostają - działają z nowym SDK, a skrypt można uruchomić ponownie później.'
        ModuleHashMismatch = 'Suma SHA-256 {0} nie zgadza się z manifestem'
        ModuleReplaced = 'Podmieniono {0} (komplet dla SDK {1}, zbudowany {2}, testy na żywo: {3})'
        NoService = 'Usługi {0} nie ma (runner z konsoli?) - uruchom runner ponownie ręcznie, żeby wczytał nowe SDK.'
        ServiceRestarted = 'Usługa {0} zrestartowana.'
        ServiceRestartFailed = 'Restart-Service {0} nie powiódł się ({1}). Kończę proces runnera - SCM podniesie usługę z opcji odzyskiwania (5 s).'
        NoRunnerProcess = 'Nie znaleziono procesu Zapqio.Runner z {0} - zrestartuj usługę ręcznie: Restart-Service {1}'
        RunnerStopped = 'Proces runnera zakończony (PID {0}); usługa wstanie z opcji odzyskiwania.'
        MissingModules = 'Nie ma katalogu {0} - sprawdź -RunnerDir'
        InvalidVersion = 'Wersja ma mieć trzy człony, np. 61.1.1 (podano: {0})'
        Downloading = 'Pobieram {0}/{1} ...'
        ExtractionFailed = 'Rozpakowanie {0} zakończyło się kodem {1}'
        MissingBin = 'W rozpakowanym SDK nie ma katalogu Bin'
        InvalidSdkDirectory = 'W {0} nie ma InsERT.Moria.Sfera.dll - to nie jest katalog Bin SDK'
        SdkSource = 'SDK {0} z {1}'
        LegacyZip = 'W Modules jest jeszcze Nexo.zip sprzed podziału modułu - niesie własny NexoClient i SDK, usuń go.'
        NoRestart = 'Bez restartu (-NoRestart). Zrestartuj usługę {0}, żeby runner wczytał nowe SDK.'
        Restarting = 'Restartuję usługę {0} ...'
        LatestLog = 'Ostatnie wpisy logu runnera ({0}):'
        Error = 'BŁĄD: {0}'
        Downloaded = 'Pobrano {0:N0} MB, rozpakowuję ...'
        Packing = 'Pakuję {0} plików ({1:N0} MB)'
        Saved = 'Zapisano {0} ({1:N0} MB, SDK {2})'
        Started = 'skrypt uruchomiony'
        UpdatedNoRestart = 'SDK {0} podmienione, bez restartu (-NoRestart)'
        UpdatedRestart = 'SDK {0} podmienione, restart usługi'
        WarningPrefix = 'UWAGA: '
    }
    en = @{
        MissingModuleSet = 'No module set for SDK {0} was found at {1} (not built yet?). Existing modules will be kept; they work with the new SDK. You can rerun this script later.'
        ModuleHashMismatch = 'The SHA-256 checksum of {0} does not match the manifest'
        ModuleReplaced = 'Replaced {0} (set for SDK {1}, built {2}, live tests: {3})'
        NoService = 'Service {0} was not found (console runner?). Restart the runner manually to load the new SDK.'
        ServiceRestarted = 'Service {0} restarted.'
        ServiceRestartFailed = 'Restart-Service {0} failed ({1}). Stopping the runner process; SCM will restart the service using its recovery settings (5 s).'
        NoRunnerProcess = 'No Zapqio.Runner process was found in {0}. Restart the service manually: Restart-Service {1}'
        RunnerStopped = 'Runner process stopped (PID {0}); the service will restart using its recovery settings.'
        MissingModules = 'Directory {0} was not found; check -RunnerDir'
        InvalidVersion = 'The version must have three parts, e.g. 61.1.1 (received: {0})'
        Downloading = 'Downloading {0}/{1} ...'
        ExtractionFailed = 'Extracting {0} exited with code {1}'
        MissingBin = 'The extracted SDK does not contain a Bin directory'
        InvalidSdkDirectory = '{0} does not contain InsERT.Moria.Sfera.dll; this is not an SDK Bin directory'
        SdkSource = 'SDK {0} from {1}'
        LegacyZip = 'Modules still contains the old Nexo.zip from before the module split. It includes its own NexoClient and SDK; remove it.'
        NoRestart = 'No restart (-NoRestart). Restart service {0} to load the new SDK.'
        Restarting = 'Restarting service {0} ...'
        LatestLog = 'Latest runner log entries ({0}):'
        Error = 'ERROR: {0}'
        Downloaded = 'Downloaded {0:N0} MB, extracting ...'
        Packing = 'Packaging {0} files ({1:N0} MB)'
        Saved = 'Saved {0} ({1:N0} MB, SDK {2})'
        Started = 'script started'
        UpdatedNoRestart = 'SDK {0} replaced, no restart (-NoRestart)'
        UpdatedRestart = 'SDK {0} replaced, restarting service'
        WarningPrefix = 'WARNING: '
    }
    de = @{
        MissingModuleSet = 'Unter {1} wurde kein Modulsatz für SDK {0} gefunden (noch nicht erstellt?). Bestehende Module bleiben erhalten und funktionieren mit dem neuen SDK. Sie können das Skript später erneut ausführen.'
        ModuleHashMismatch = 'Die SHA-256-Prüfsumme von {0} stimmt nicht mit dem Manifest überein'
        ModuleReplaced = '{0} wurde ersetzt (Modulsatz für SDK {1}, erstellt {2}, Livetests: {3})'
        NoService = 'Der Dienst {0} wurde nicht gefunden (Runner in einer Konsole?). Starten Sie den Runner manuell neu, um das neue SDK zu laden.'
        ServiceRestarted = 'Dienst {0} wurde neu gestartet.'
        ServiceRestartFailed = 'Restart-Service {0} ist fehlgeschlagen ({1}). Der Runner-Prozess wird beendet; SCM startet den Dienst über die Wiederherstellungseinstellungen neu (5 s).'
        NoRunnerProcess = 'Kein Zapqio.Runner-Prozess aus {0} gefunden. Starten Sie den Dienst manuell neu: Restart-Service {1}'
        RunnerStopped = 'Runner-Prozess beendet (PID {0}); der Dienst wird über die Wiederherstellungseinstellungen neu gestartet.'
        MissingModules = 'Verzeichnis {0} wurde nicht gefunden; prüfen Sie -RunnerDir'
        InvalidVersion = 'Die Version muss aus drei Teilen bestehen, z. B. 61.1.1 (angegeben: {0})'
        Downloading = '{0}/{1} wird heruntergeladen ...'
        ExtractionFailed = 'Das Entpacken von {0} wurde mit Code {1} beendet'
        MissingBin = 'Das entpackte SDK enthält kein Bin-Verzeichnis'
        InvalidSdkDirectory = '{0} enthält keine InsERT.Moria.Sfera.dll; dies ist kein Bin-Verzeichnis des SDK'
        SdkSource = 'SDK {0} aus {1}'
        LegacyZip = 'Modules enthält noch das alte Nexo.zip aus der Zeit vor der Modulaufteilung. Es enthält einen eigenen NexoClient und ein eigenes SDK; entfernen Sie es.'
        NoRestart = 'Kein Neustart (-NoRestart). Starten Sie den Dienst {0} neu, um das neue SDK zu laden.'
        Restarting = 'Dienst {0} wird neu gestartet ...'
        LatestLog = 'Letzte Runner-Protokolleinträge ({0}):'
        Error = 'FEHLER: {0}'
        Downloaded = '{0:N0} MB heruntergeladen, wird entpackt ...'
        Packing = '{0} Dateien werden gepackt ({1:N0} MB)'
        Saved = '{0} gespeichert ({1:N0} MB, SDK {2})'
        Started = 'Skript gestartet'
        UpdatedNoRestart = 'SDK {0} ersetzt, kein Neustart (-NoRestart)'
        UpdatedRestart = 'SDK {0} ersetzt, Dienst wird neu gestartet'
        WarningPrefix = 'WARNUNG: '
    }
}

# Keep translations inside the script: it can also be run directly from a downloaded scriptblock.
function Get-InstallText {
    param([string]$Key, [object[]]$Values = @())
    $template = $messages[$Language][$Key]
    if ($null -eq $template) { throw "Missing installer translation: $Language/$Key" }
    return [string]::Format([Globalization.CultureInfo]::GetCultureInfo($Language), $template, $Values)
}

$ftp = 'https://ftp.insertcdn.pl/pub/aktualizacje/InsERT_nexo'

function Write-Log([string] $Message, [switch] $IsWarning) {
    if ($IsWarning) { Write-Warning $Message } else { Write-Host $Message }
    if ($Log) {
        try {
            $dir = Split-Path $Log -Parent
            if ($dir -and -not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
            Add-Content -Path $Log -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}{2}" -f (Get-Date), $(if ($IsWarning) { (Get-InstallText 'WarningPrefix') } else { '' }), $Message) -Encoding UTF8
        }
        catch { }
    }
}

# Stan czyta NexoClient: 'running' blokuje kolejne uruchomienia, 'ok' / 'failed' z czasem sterują ponowieniem.
function Write-State([string] $Result, [string] $Message) {
    if (-not $State) { return }
    try {
        $obj = [ordered]@{
            version    = $(if ($Version) { $Version } else { $sdkVersion })
            startedAt  = $updateStartedAt
            finishedAt = $(if ($Result -eq 'running') { $null } else { (Get-Date).ToString('o') })
            result     = $Result
            message    = $Message
        }
        [IO.File]::WriteAllText($State, ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    }
    catch { }
}

function Restart-Runner {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Log (Get-InstallText 'NoService' @($ServiceName)) -IsWarning
        return $false
    }
    try {
        Restart-Service -Name $ServiceName -ErrorAction Stop
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
        Write-Log (Get-InstallText 'ServiceRestarted' @($ServiceName))
        return $true
    }
    catch {
        Write-Log (Get-InstallText 'ServiceRestartFailed' @($ServiceName, $_.Exception.Message)) -IsWarning
    }
    # Zapas dla instalacji bez prawa start/stop dla konta usługi: własny proces wolno zakończyć.
    $expectedExe = Join-Path $RunnerDir 'Zapqio.Runner.exe'
    $procs = @(Get-Process -Name 'Zapqio.Runner' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and [string]::Equals($_.Path, $expectedExe, [StringComparison]::OrdinalIgnoreCase) })
    if ($procs.Count -eq 0) {
        Write-Log (Get-InstallText 'NoRunnerProcess' @($RunnerDir, $ServiceName)) -IsWarning
        throw (Get-InstallText 'NoRunnerProcess' @($RunnerDir, $ServiceName))
    }
    $procs | Stop-Process -Force
    Write-Log (Get-InstallText 'RunnerStopped' @(($procs.Id -join ', ')))
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
    return $true
}

# Ścieżki względne liczone od bieżącej lokalizacji PowerShella ("cd C:\zapqio\runner" + "-RunnerDir .").
# [IO.Path]::GetFullPath liczyłoby od katalogu startowego procesu, czyli zwykle od profilu użytkownika.
function Resolve-Full([string] $Path) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
$RunnerDir = (Resolve-Full $RunnerDir).TrimEnd('\')
if ($SdkDir) { $SdkDir = Resolve-Full $SdkDir }
if ($WorkDir) { $WorkDir = Resolve-Full $WorkDir }
if ($Log) { $Log = Resolve-Full $Log }
if ($State) { $State = Resolve-Full $State }
$modules = Join-Path $RunnerDir 'Modules'
if (-not $WorkDir) { $WorkDir = Join-Path $RunnerDir '.sdk-tmp' }
$temp = Join-Path $WorkDir ('sdk-' + [guid]::NewGuid().ToString('N'))
$updateStartedAt = (Get-Date).ToString('o')
$updateLock = $null
$helpersLoaded = $false

try {
    if (-not (Test-Path $modules)) {
        throw (Get-InstallText 'MissingModules' @($modules))
    }
    if ($ModulesUrl -or $ModulesPath) { throw 'ZIP-only module sets cannot be assumed SDK-compatible. Register sources with -ModulesConfig (Config\nexo-build-sources.json), or deploy a complete rebuilt set through Web.' }
    $buildScript = Join-Path $PSScriptRoot 'build-nexo-set.ps1'
    if (-not (Test-Path -LiteralPath $buildScript)) { throw 'Missing build-nexo-set.ps1. Run the updated install-nexo.ps1 once to install the build tools.' }
    . (& $buildScript -FunctionsOnly)
    $helpersLoaded = $true
    $buildDir = Get-NexoChildPath $RunnerDir 'Build'
    [void][IO.Directory]::CreateDirectory($buildDir)
    $updateLock = [IO.File]::Open((Join-Path $buildDir 'nexo-update.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    if (-not $PrepareOnly) { Restore-NexoTransaction $RunnerDir }
    Write-State 'running' (Get-InstallText 'Started')
    New-Item $temp -ItemType Directory -Force | Out-Null

    if ($PSCmdlet.ParameterSetName -eq 'Download') {
        if ($Version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
            throw (Get-InstallText 'InvalidVersion' @($Version))
        }
        $requestedVersion = $Version
        $Version = (($Version -split '\.')[0..2] -join '.')
        $activePath = Join-Path $RunnerDir 'nexo-build.json'
        if (Test-Path -LiteralPath $activePath) {
            $active = Get-Content -LiteralPath $activePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ((($active.sdkVersion -split '\.')[0..2] -join '.') -eq $Version -and ($requestedVersion -eq $Version -or $active.sdkVersion -eq $requestedVersion)) {
                $activeSet = Read-NexoSet $active.manifestPath
                $SdkDir = Get-NexoChildPath $activeSet.Root $activeSet.sdkBin
            }
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'Download' -and -not $SdkDir) {
        $file = 'nexoSDK_' + ($Version -replace '\.', '_') + '.exe'
        $exe = Join-Path $temp $file
        Write-Log (Get-InstallText 'Downloading' @($ftp, $file))
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "$ftp/$file" -OutFile $exe -UseBasicParsing
        Write-Log (Get-InstallText 'Downloaded' @(((Get-Item $exe).Length / 1MB)))

        # Plik to 7-Zip SFX: -y bez pytań, -o katalog docelowy; w środku nexoSDK_<pełna wersja>\Bin.
        $extract = Join-Path $temp 'sdk'
        $p = Start-Process -FilePath $exe -ArgumentList @('-y', "-o`"$extract`"") -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) {
            throw (Get-InstallText 'ExtractionFailed' @($file, $p.ExitCode))
        }
        $bin = Get-ChildItem $extract -Directory -Filter 'Bin' -Recurse | Select-Object -First 1
        if (-not $bin) {
            throw (Get-InstallText 'MissingBin')
        }
        $SdkDir = $bin.FullName
    }

    $sfera = Join-Path $SdkDir 'InsERT.Moria.Sfera.dll'
    if (-not (Test-Path $sfera)) {
        throw (Get-InstallText 'InvalidSdkDirectory' @($SdkDir))
    }
    $sdkVersion = ([Diagnostics.FileVersionInfo]::GetVersionInfo($sfera).ProductVersion -split '\+')[0]
    $shortVersion = (($sdkVersion -split '\.')[0..2] -join '.')
    if ($Version -and ($shortVersion -ne $Version -or ($requestedVersion -ne $Version -and $sdkVersion -ne $requestedVersion))) { throw "Downloaded SDK $sdkVersion does not match requested $requestedVersion." }
    Write-Log (Get-InstallText 'SdkSource' @($sdkVersion, $SdkDir))

    # Paczka współdzielona runnera: ##Shared = inne paczki biorą stąd biblioteki,
    # pusty ##Dll = runner niczego tu nie skanuje (w SDK nie ma metod ani wstrzyknięć).
    # Do paczki idą biblioteki (*.dll) i zasoby (*.pak) z poziomu Bin, bez podkatalogów, programów .exe,
    # dokumentacji i pomocy: to nadzbiór tego, co niósł dotychczasowy Nexo.zip budowany przez MSBuild
    # (549 DLL + Xml.pak + Mrt.pak), a cały Bin ma 1,1 GB, z czego połowa to Subiekt.exe, libcef i Pomoc.chm.
    $buildParameters = @{ RunnerDir = $RunnerDir; SdkDir = $SdkDir; Language = $Language }
    if ($ConnectionZip) { $buildParameters.ConnectionZip = $ConnectionZip }
    if ($ConnectionSource) { $buildParameters.ConnectionSource = $ConnectionSource }
    if ($ModulesConfig) { $buildParameters.ModulesConfig = $ModulesConfig }
    $manifestPath = & $buildScript @buildParameters
    $set = Read-NexoSet $manifestPath
    Write-Log ("Prepared nexo set: " + $set.ManifestPath)
    if ($PrepareOnly) {
        Write-State 'prepared' ("Prepared set: " + $set.ManifestPath)
        return
    }
    Test-NexoInstalledConsumers $RunnerDir $set $temp
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install-nexo-build.ps1') -InstallDir $RunnerDir -ServiceName $ServiceName -SetManifestPath $set.ManifestPath -ValidateOnly -NoRestart -Language $Language
    if ($LASTEXITCODE -ne 0) { throw 'The prepared build configuration failed validation; installed files were not changed.' }
    Install-NexoSet $RunnerDir $set $ServiceName $Language

    if ($NoRestart) {
        Write-State 'ok' (Get-InstallText 'UpdatedNoRestart' @($sdkVersion))
        Write-Log (Get-InstallText 'NoRestart' @($ServiceName))
        return
    }
    Write-Log (Get-InstallText 'Restarting' @($ServiceName))
    if (-not (Restart-Runner)) {
        Write-State 'ok' (Get-InstallText 'UpdatedNoRestart' @($sdkVersion))
        return
    }
    Write-State 'ok' (Get-InstallText 'UpdatedRestart' @($sdkVersion))
    Start-Sleep -Seconds 15
    $latest = Get-ChildItem (Join-Path $RunnerDir 'Logs') -File -ErrorAction SilentlyContinue |
        Where-Object { -not $Log -or $_.Name -ne (Split-Path $Log -Leaf) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        Write-Log (Get-InstallText 'LatestLog' @($latest.Name))
        Get-Content $latest.FullName -Tail 200 |
            Select-String 'Nexo.Sdk|Nexo.Connection|nie została utworzona' |
            ForEach-Object { Write-Log ('  ' + $_.Line) }
    }
}
catch {
    Write-Log (Get-InstallText 'Error' @($_.Exception.Message)) -IsWarning
    Write-State 'failed' $_.Exception.Message
    exit 1
}
finally {
    if ($updateLock) { $updateLock.Dispose() }
    if ($helpersLoaded -and (Test-Path -LiteralPath $temp)) { Remove-NexoWork $WorkDir $temp }
}
