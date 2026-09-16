<#
.SYNOPSIS
  Podmienia SDK InsERT nexo na runnerze Zapqio na wersję zgodną z Subiektem.

.DESCRIPTION
  Pobiera nexoSDK z publicznego FTP InsERT (albo bierze gotowy katalog Bin), pakuje go do
  Modules\Nexo.Sdk.zip z markerami ##Shared i ##Dll, opcjonalnie pobiera komplet modułów zbudowany pod tę
  wersję SDK i restartuje usługę runnera. Moduły Nexo nie wymagają przebudowy: zestawy SDK mają stałą
  AssemblyVersion, więc wiążą się z każdą wersją SDK po nazwie.

  Uruchamiany ręcznie jako administrator albo automatycznie przez NexoClient (moduł Nexo.Connection) po
  wykryciu niezgodności wersji: wtedy działa na koncie usługi, bez konsoli (-Log) i zapisuje wynik do
  pliku stanu (-State). Restart: Restart-Service, a gdy konto nie ma do tego prawa, zakończenie procesu
  runnera, który SCM podnosi z opcji odzyskiwania.

.PARAMETER Version
  Wersja Subiekta z "Pomoc > O programie", trzy człony jak w nazwie pliku na FTP, np. 61.1.1.

.PARAMETER SdkDir
  Gotowy katalog Bin rozpakowanego SDK (np. C:\nexoSDK_61.1.0.9431\Bin); pomija pobieranie.

.PARAMETER RunnerDir
  Katalog instalacji runnera z podkatalogiem Modules (domyślnie C:\zapqio\runner).

.PARAMETER ServiceName
  Nazwa usługi runnera (domyślnie ZapqioRunner).

.PARAMETER NoRestart
  Tylko podmiana zipa, bez restartu usługi (np. sprawdzenie bez zainstalowanej usługi).

.PARAMETER ModulesUrl
  Skąd brać komplet modułów zbudowany pod tę wersję SDK (build-modules.ps1): adres HTTP z {version},
  np. https://github.com/HDWR-Global/zapqio-modules/releases/download/sdk-{version}. Podmieniane są tylko
  te zipy, które już leżą w Modules. Brak kompletu = ostrzeżenie, obecne moduły zostają.

.PARAMETER ModulesPath
  To samo, ale katalog albo udział z {version}, np. \\serwer\zapqio\releases\sdk-{version}.

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
  .\update-nexo-sdk.ps1 -Version 61.1.1 -ModulesUrl https://github.com/HDWR-Global/zapqio-modules/releases/download/sdk-{version}

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
    [string] $WorkDir
)

$ErrorActionPreference = 'Stop'
$ftp = 'https://ftp.insertcdn.pl/pub/aktualizacje/InsERT_nexo'

function Write-Log([string] $Message, [switch] $IsWarning) {
    if ($IsWarning) { Write-Warning $Message } else { Write-Host $Message }
    if ($Log) {
        try {
            $dir = Split-Path $Log -Parent
            if ($dir -and -not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
            Add-Content -Path $Log -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}{2}" -f (Get-Date), $(if ($IsWarning) { 'UWAGA: ' } else { '' }), $Message) -Encoding UTF8
        }
        catch { }
    }
}

# Stan czyta NexoClient: 'running' blokuje kolejne uruchomienia, 'ok' / 'failed' z czasem sterują ponowieniem.
function Write-State([string] $Result, [string] $Message) {
    if (-not $State) { return }
    try {
        $current = $null
        if (Test-Path $State) { $current = Get-Content $State -Raw -Encoding UTF8 | ConvertFrom-Json }
        $obj = [ordered]@{
            version    = $(if ($current -and $current.version) { $current.version } elseif ($Version) { $Version } else { $null })
            startedAt  = $(if ($current -and $current.startedAt) { $current.startedAt } else { (Get-Date).ToString('o') })
            finishedAt = $(if ($Result -eq 'running') { $null } else { (Get-Date).ToString('o') })
            result     = $Result
            message    = $Message
        }
        [IO.File]::WriteAllText($State, ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    }
    catch { }
}

# Komplet modułów dla wersji SDK: manifest.json z listą zipów, podmiana tylko tych, które klient już ma.
function Update-ModuleSet([string] $ShortVersion, [string] $ModulesDir) {
    $base = if ($ModulesUrl) { $ModulesUrl.Replace('{version}', $ShortVersion).TrimEnd('/') } else { $ModulesPath.Replace('{version}', $ShortVersion).TrimEnd('\') }
    $manifest = $null
    try {
        if ($ModulesUrl) { $manifest = (Invoke-WebRequest -Uri "$base/manifest.json" -UseBasicParsing).Content | ConvertFrom-Json }
        elseif (Test-Path (Join-Path $base 'manifest.json')) { $manifest = Get-Content (Join-Path $base 'manifest.json') -Raw | ConvertFrom-Json }
    }
    catch {
        $manifest = $null
    }
    if (-not $manifest) {
        Write-Log "Brak kompletu modułów dla SDK $ShortVersion pod $base (jeszcze nie zbudowany?). Obecne moduły zostają - działają z nowym SDK, a skrypt można uruchomić ponownie później." -IsWarning
        return
    }
    foreach ($m in $manifest.modules) {
        $target = Join-Path $ModulesDir $m.name
        if (-not (Test-Path $target)) { continue }   # klient nie ma tego modułu, nie dokładamy
        $new = "$target.new"
        if ($ModulesUrl) { Invoke-WebRequest -Uri "$base/$($m.name)" -OutFile $new -UseBasicParsing }
        else { Copy-Item (Join-Path $base $m.name) $new }
        $hash = (Get-FileHash $new -Algorithm SHA256).Hash.ToLower()
        if ($m.sha256 -and $hash -ne $m.sha256) { Remove-Item $new; throw "Suma SHA-256 $($m.name) nie zgadza się z manifestem" }
        Move-Item $new $target -Force
        Write-Log "Podmieniono $($m.name) (komplet dla SDK $ShortVersion, zbudowany $($manifest.built), testy na żywo: $($manifest.testedLive))"
    }
}

function Restart-Runner {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Log "Usługi $ServiceName nie ma (runner z konsoli?) - uruchom runner ponownie ręcznie, żeby wczytał nowe SDK." -IsWarning
        return
    }
    try {
        Restart-Service -Name $ServiceName -ErrorAction Stop
        Write-Log "Usługa $ServiceName zrestartowana."
        return
    }
    catch {
        Write-Log "Restart-Service $ServiceName nie powiódł się ($($_.Exception.Message)). Kończę proces runnera - SCM podniesie usługę z opcji odzyskiwania (5 s)." -IsWarning
    }
    # Zapas dla instalacji bez prawa start/stop dla konta usługi: własny proces wolno zakończyć.
    $procs = @(Get-Process -Name 'Zapqio.Runner' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($RunnerDir, [StringComparison]::OrdinalIgnoreCase) })
    if ($procs.Count -eq 0) {
        Write-Log "Nie znaleziono procesu Zapqio.Runner z $RunnerDir - zrestartuj usługę ręcznie: Restart-Service $ServiceName" -IsWarning
        return
    }
    $procs | Stop-Process -Force
    Write-Log "Proces runnera zakończony (PID $($procs.Id -join ', ')); usługa wstanie z opcji odzyskiwania."
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

try {
    if (-not (Test-Path $modules)) {
        throw "Nie ma katalogu $modules - sprawdź -RunnerDir"
    }
    Write-State 'running' 'skrypt uruchomiony'
    New-Item $temp -ItemType Directory -Force | Out-Null

    if ($PSCmdlet.ParameterSetName -eq 'Download') {
        if ($Version -notmatch '^\d+\.\d+\.\d+$') {
            throw "Wersja ma mieć trzy człony, np. 61.1.1 (podano: $Version)"
        }
        $file = 'nexoSDK_' + ($Version -replace '\.', '_') + '.exe'
        $exe = Join-Path $temp $file
        Write-Log "Pobieram $ftp/$file ..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "$ftp/$file" -OutFile $exe -UseBasicParsing
        Write-Log ("Pobrano {0:N0} MB, rozpakowuję ..." -f ((Get-Item $exe).Length / 1MB))

        # Plik to 7-Zip SFX: -y bez pytań, -o katalog docelowy; w środku nexoSDK_<pełna wersja>\Bin.
        $extract = Join-Path $temp 'sdk'
        $p = Start-Process -FilePath $exe -ArgumentList @('-y', "-o`"$extract`"") -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) {
            throw "Rozpakowanie $file zakończyło się kodem $($p.ExitCode)"
        }
        $bin = Get-ChildItem $extract -Directory -Filter 'Bin' -Recurse | Select-Object -First 1
        if (-not $bin) {
            throw "W rozpakowanym SDK nie ma katalogu Bin"
        }
        $SdkDir = $bin.FullName
    }

    $sfera = Join-Path $SdkDir 'InsERT.Moria.Sfera.dll'
    if (-not (Test-Path $sfera)) {
        throw "W $SdkDir nie ma InsERT.Moria.Sfera.dll - to nie jest katalog Bin SDK"
    }
    $sdkVersion = ([Diagnostics.FileVersionInfo]::GetVersionInfo($sfera).ProductVersion -split '\+')[0]
    $shortVersion = (($sdkVersion -split '\.')[0..2] -join '.')
    Write-Log "SDK $sdkVersion z $SdkDir"

    # Paczka współdzielona runnera: ##Shared = inne paczki biorą stąd biblioteki,
    # pusty ##Dll = runner niczego tu nie skanuje (w SDK nie ma metod ani wstrzyknięć).
    # Do paczki idą biblioteki (*.dll) i zasoby (*.pak) z poziomu Bin, bez podkatalogów, programów .exe,
    # dokumentacji i pomocy: to nadzbiór tego, co niósł dotychczasowy Nexo.zip budowany przez MSBuild
    # (549 DLL + Xml.pak + Mrt.pak), a cały Bin ma 1,1 GB, z czego połowa to Subiekt.exe, libcef i Pomoc.chm.
    $staging = Join-Path $temp 'Nexo.Sdk'
    New-Item $staging -ItemType Directory | Out-Null
    $files = Get-ChildItem $SdkDir -File | Where-Object { $_.Extension -in '.dll', '.pak' }
    $files | Copy-Item -Destination $staging
    Write-Log ("Pakuję {0} plików ({1:N0} MB)" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB))
    New-Item (Join-Path $staging '##Shared') -ItemType File | Out-Null
    New-Item (Join-Path $staging '##Dll') -ItemType File | Out-Null

    # Stała nazwa: na runnerze ma być dokładnie jedna paczka SDK, podmieniana, nie dokładana.
    $zip = Join-Path $modules 'Nexo.Sdk.zip'
    $new = "$zip.new"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $new) { Remove-Item $new }
    [IO.Compression.ZipFile]::CreateFromDirectory($staging, $new)
    Move-Item $new $zip -Force
    Write-Log ("Zapisano {0} ({1:N0} MB, SDK {2})" -f $zip, ((Get-Item $zip).Length / 1MB), $sdkVersion)
    [IO.File]::WriteAllText((Join-Path $RunnerDir 'nexo-sdk.json'), (@{ version = $sdkVersion; at = (Get-Date).ToString('o') } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))

    if (Test-Path (Join-Path $modules 'Nexo.zip')) {
        Write-Log "W Modules jest jeszcze Nexo.zip sprzed podziału modułu - niesie własny NexoClient i SDK, usuń go." -IsWarning
    }

    if ($ModulesUrl -or $ModulesPath) {
        Update-ModuleSet $shortVersion $modules
    }

    if ($NoRestart) {
        Write-State 'ok' "SDK $sdkVersion podmienione, bez restartu (-NoRestart)"
        Write-Log "Bez restartu (-NoRestart). Zrestartuj usługę $ServiceName, żeby runner wczytał nowe SDK."
        return
    }
    Write-State 'ok' "SDK $sdkVersion podmienione, restart usługi"
    Write-Log "Restartuję usługę $ServiceName ..."
    Restart-Runner
    Start-Sleep -Seconds 15
    $latest = Get-ChildItem (Join-Path $RunnerDir 'Logs') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne (Split-Path $Log -Leaf) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        Write-Log "Ostatnie wpisy logu runnera ($($latest.Name)):"
        Get-Content $latest.FullName -Tail 200 |
            Select-String 'Nexo.Sdk|Nexo.Connection|nie została utworzona' |
            ForEach-Object { Write-Log ('  ' + $_.Line) }
    }
}
catch {
    Write-Log "BŁĄD: $($_.Exception.Message)" -IsWarning
    Write-State 'failed' $_.Exception.Message
    exit 1
}
finally {
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    if ((Test-Path $WorkDir) -and -not (Get-ChildItem $WorkDir -Force -ErrorAction SilentlyContinue)) {
        Remove-Item $WorkDir -Force -ErrorAction SilentlyContinue
    }
}
