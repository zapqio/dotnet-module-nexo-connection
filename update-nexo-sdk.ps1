<#
.SYNOPSIS
  Podmienia SDK InsERT nexo na runnerze Zapqio na wersję zgodną z Subiektem.

.DESCRIPTION
  Pobiera nexoSDK z publicznego FTP InsERT (albo bierze gotowy katalog Bin), pakuje go do
  Modules\Nexo.Sdk.zip z markerami ##Shared i ##Dll i restartuje usługę runnera.
  Moduły Nexo nie wymagają przebudowy: zestawy SDK mają stałą AssemblyVersion, więc wiążą się
  z każdą wersją SDK po nazwie. Uruchamiać jako administrator (restart usługi).

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

.EXAMPLE
  .\update-nexo-sdk.ps1 -Version 61.1.1

.EXAMPLE
  .\update-nexo-sdk.ps1 -Version 61.1.1 -ModulesUrl https://github.com/HDWR-Global/zapqio-modules/releases/download/sdk-{version}

.EXAMPLE
  .\update-nexo-sdk.ps1 -SdkDir C:\nexoSDK_61.1.0.9431\Bin -RunnerDir D:\zapqio\runner
#>
[CmdletBinding(DefaultParameterSetName = 'Download')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Download')] [string] $Version,
    [Parameter(Mandatory = $true, ParameterSetName = 'Local')] [string] $SdkDir,
    [string] $RunnerDir = 'C:\zapqio\runner',
    [string] $ServiceName = 'ZapqioRunner',
    [switch] $NoRestart,
    [string] $ModulesUrl,
    [string] $ModulesPath
)

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
        Write-Warning "Brak kompletu modułów dla SDK $ShortVersion pod $base (jeszcze nie zbudowany?). Obecne moduły zostają - działają z nowym SDK, a skrypt można uruchomić ponownie później."
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
        Write-Host "Podmieniono $($m.name) (komplet dla SDK $ShortVersion, zbudowany $($manifest.built), testy na żywo: $($manifest.testedLive))"
    }
}

$ErrorActionPreference = 'Stop'
$ftp = 'https://ftp.insertcdn.pl/pub/aktualizacje/InsERT_nexo'
$modules = Join-Path $RunnerDir 'Modules'
if (-not (Test-Path $modules)) {
    throw "Nie ma katalogu $modules - sprawdź -RunnerDir"
}

$temp = Join-Path $env:TEMP ('zapqio-nexo-sdk-' + [guid]::NewGuid().ToString('N'))
New-Item $temp -ItemType Directory | Out-Null
try {
    if ($PSCmdlet.ParameterSetName -eq 'Download') {
        if ($Version -notmatch '^\d+\.\d+\.\d+$') {
            throw "Wersja ma mieć trzy człony, np. 61.1.1 (podano: $Version)"
        }
        $file = 'nexoSDK_' + ($Version -replace '\.', '_') + '.exe'
        $exe = Join-Path $temp $file
        Write-Host "Pobieram $ftp/$file ..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "$ftp/$file" -OutFile $exe -UseBasicParsing
        Write-Host ("Pobrano {0:N0} MB, rozpakowuję ..." -f ((Get-Item $exe).Length / 1MB))

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
    Write-Host "SDK $sdkVersion z $SdkDir"

    # Paczka współdzielona runnera: ##Shared = inne paczki biorą stąd biblioteki,
    # pusty ##Dll = runner niczego tu nie skanuje (w SDK nie ma metod ani wstrzyknięć).
    # Do paczki idą biblioteki (*.dll) i zasoby (*.pak) z poziomu Bin, bez podkatalogów, programów .exe,
    # dokumentacji i pomocy: to nadzbiór tego, co niósł dotychczasowy Nexo.zip budowany przez MSBuild
    # (549 DLL + Xml.pak + Mrt.pak), a cały Bin ma 1,1 GB, z czego połowa to Subiekt.exe, libcef i Pomoc.chm.
    $staging = Join-Path $temp 'Nexo.Sdk'
    New-Item $staging -ItemType Directory | Out-Null
    $files = Get-ChildItem $SdkDir -File | Where-Object { $_.Extension -in '.dll', '.pak' }
    $files | Copy-Item -Destination $staging
    Write-Host ("Pakuję {0} plików ({1:N0} MB)" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB))
    New-Item (Join-Path $staging '##Shared') -ItemType File | Out-Null
    New-Item (Join-Path $staging '##Dll') -ItemType File | Out-Null

    # Stała nazwa: na runnerze ma być dokładnie jedna paczka SDK, podmieniana, nie dokładana.
    $zip = Join-Path $modules 'Nexo.Sdk.zip'
    $new = "$zip.new"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $new) { Remove-Item $new }
    [IO.Compression.ZipFile]::CreateFromDirectory($staging, $new)
    Move-Item $new $zip -Force
    Write-Host ("Zapisano {0} ({1:N0} MB, SDK {2})" -f $zip, ((Get-Item $zip).Length / 1MB), $sdkVersion)

    if (Test-Path (Join-Path $modules 'Nexo.zip')) {
        Write-Warning "W Modules jest jeszcze Nexo.zip sprzed podziału modułu - niesie własny NexoClient i SDK, usuń go."
    }

    if ($ModulesUrl -or $ModulesPath) {
        Update-ModuleSet (($sdkVersion -split '\.')[0..2] -join '.') $modules
    }

    if ($NoRestart) {
        Write-Host "Bez restartu (-NoRestart). Zrestartuj usługę $ServiceName, żeby runner wczytał nowe SDK."
        return
    }
    Write-Host "Restartuję usługę $ServiceName ..."
    Restart-Service -Name $ServiceName
    Start-Sleep -Seconds 10
    $log = Get-ChildItem (Join-Path $RunnerDir 'Logs') -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($log) {
        Write-Host "Ostatnie wpisy logu ($($log.Name)):"
        Get-Content $log.FullName -Tail 200 |
            Select-String 'Nexo.Sdk|Nexo.Connection|nie została utworzona' |
            ForEach-Object { $_.Line }
    }
    else {
        Write-Host "Brak logu w $RunnerDir\Logs - sprawdź Logger:PathDirectory w appsettings.json"
    }
}
finally {
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}
