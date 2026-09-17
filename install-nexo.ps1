#Requires -Version 5.1

<#
.SYNOPSIS
    Instaluje lub aktualizuje moduł Nexo (InsERT nexo / Subiekt) na zainstalowanym Zapqio Runnerze.

.DESCRIPTION
    Zakłada runner zainstalowany przez install.ps1 (https://github.com/zapqio/dotnet-runner) w wariancie
    .NET 8 - moduły Nexo korzystają z obfuskowanych bibliotek InsERT-a, które nie ładują się na .NET 9+.

    Kolejno:
      1. pyta o dane połączenia z Subiektem nexo (serwer SQL, baza podmiotu, użytkownik SQL, operator)
         albo bierze je z parametrów; sprawdza połączenie z serwerem SQL i odczytuje z bazy wersję Subiekta,
      2. zapisuje je w Config\nexoModule.json (sekcja Connect; inne klucze pliku zostają),
      3. pobiera Nexo.Connection.zip z GitHub Releases do Modules\,
      4. pakuje SDK InsERT nexo w wersji Subiekta do Modules\Nexo.Sdk.zip (update-nexo-sdk.ps1 z paczki
         pobiera SDK z publicznego FTP InsERT - ok. 500 MB),
      5. restartuje usługę i czeka, aż w logu runnera pojawi się metoda "Nexo: Who am I".

    Uruchomiony ponownie działa jak aktualizacja: dane połączenia zostają (pyta tylko o brakujące),
    zip modułu jest podmieniany na najnowszy, SDK podmieniane tylko przy zmianie wersji Subiekta.

.PARAMETER InstallDir
    Katalog instalacji runnera. Domyślnie C:\zapqio\runner.

.PARAMETER ServiceName
    Nazwa usługi Windows runnera. Domyślnie ZapqioRunner.

.PARAMETER Version
    Wersja release'u modułu, np. 1.1.0. Pusta = najnowszy release z GitHuba.

.PARAMETER DatabaseServer
    Serwer SQL z instancją, np. SERWER\INSERTNEXO albo 192.168.1.10,1433.

.PARAMETER DatabaseName
    Nazwa bazy podmiotu, np. Nexo_Firma.

.PARAMETER DatabaseUser
    Użytkownik SQL, np. sa. Bez niego (i bez -WindowsLogin) skrypt dopyta.

.PARAMETER DatabasePassword
    Hasło użytkownika SQL.

.PARAMETER WindowsLogin
    Uwierzytelnianie Windows do serwera SQL zamiast użytkownika SQL. Łączy się wtedy KONTO USŁUGI runnera
    (domyślnie NT SERVICE\ZapqioRunner), a nie osoba uruchamiająca skrypt - test połączenia w skrypcie
    tego nie sprawdzi. Zwykle wymaga przełączenia usługi na konto domenowe z prawami do bazy.

.PARAMETER UserName
    Operator Subiekta, na którego loguje się Sfera, np. Szef.

.PARAMETER UserPassword
    Hasło operatora. Może być puste.

.PARAMETER SubiektVersion
    Wersja Subiekta (trzy człony, np. 61.1.1) zamiast odczytu z bazy - np. gdy zapytanie o wersję
    nie działa na danej bazie. Wersja jest w Subiekcie w "Pomoc > O programie".

.PARAMETER SdkDir
    Gotowy katalog Bin rozpakowanego SDK (np. C:\nexoSDK_61.1.1.9471\Bin) zamiast pobierania z FTP;
    wersja SDK musi zgadzać się z Subiektem.

.PARAMETER PackagePath
    Lokalny Nexo.Connection.zip (np. z bin\Release po dotnet publish) zamiast pobierania z GitHub Releases;
    -Version jest wtedy bez znaczenia. Razem z -SdkDir daje instalację bez dostępu do internetu.

.PARAMETER NoRestart
    Bez restartu usługi na końcu (nowe paczki zostaną wczytane przy następnym starcie).

.EXAMPLE
    .\install-nexo.ps1

.EXAMPLE
    .\install-nexo.ps1 -DatabaseServer 'SERWER\INSERTNEXO' -DatabaseName Nexo_Firma -DatabaseUser sa -DatabasePassword '...' -UserName Szef -UserPassword '...'

.NOTES
    Bez klonowania repo, w PowerShellu jako administrator (TrimStart zdejmuje BOM UTF-8, którego irm nie
    usuwa, a na którym wykłada się parser - dlatego proste `irm ... | iex` NIE zadziała):

      $s = irm https://raw.githubusercontent.com/zapqio/dotnet-module-nexo-connection/main/install-nexo.ps1
      & ([scriptblock]::Create($s.TrimStart([char]0xFEFF)))

    Z parametrami:

      & ([scriptblock]::Create($s.TrimStart([char]0xFEFF))) -DatabaseServer 'SERWER\INSERTNEXO' -DatabaseName Nexo_Firma
#>

[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\zapqio\runner',
    [string]$ServiceName = 'ZapqioRunner',
    [string]$Version,
    [string]$DatabaseServer,
    [string]$DatabaseName,
    [string]$DatabaseUser,
    [string]$DatabasePassword,
    [switch]$WindowsLogin,
    [string]$UserName,
    [string]$UserPassword,
    [string]$SubiektVersion,
    [string]$SdkDir,
    [string]$PackagePath,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'

$repo = 'zapqio/dotnet-module-nexo-connection'
$moduleZipName = 'Nexo.Connection.zip'
$sdkZipName = 'Nexo.Sdk.zip'
$updateScriptName = 'update-nexo-sdk.ps1'
$configFileName = 'nexoModule.json'
# Wersja Subiekta = wersja bazy podmiotu (Sfera wymaga SDK w tej samej wersji; przy rozjeździe zgłasza "Wersja bazy
# danych to X, a wersja Sfery to Y"). Źródło główne: rejestr launchera InsERT w bazie (InsLauncher.InstalledProducts,
# wiersz Nexo, np. 61.1.0.9431). Zapas: wersja ostatniego programu nexo, który łączył się z bazą (ślad rewizyjny).
# Sprawdzone na bazie 61.1.0.9431: oba zwracają wersję SDK, które się z nią połączyło. ModelDanychContainer.BazyDanych
# (kolumna Wersja) jest w bazie podmiotu puste - to rejestr baz, nie wersja.
$versionQueries = @(
    @{ Source = 'InsLauncher.InstalledProducts'
       Query  = "SELECT TOP 1 CAST(VersionMajor AS varchar(10)) + '.' + CAST(VersionMinor AS varchar(10)) + '.' + CAST(VersionBuild AS varchar(10)) + '.' + CAST(VersionRevision AS varchar(10)) FROM InsLauncher.InstalledProducts WHERE Name = 'Nexo'" },
    @{ Source = 'ślad rewizyjny - ostatni program łączący się z bazą'
       Query  = 'SELECT TOP 1 Wersja FROM ModelDanychContainer.ProgramyZdarzenSladuRewizyjnego ORDER BY Id DESC' }
)

# #Requires -RunAsAdministrator nie działa, gdy skrypt idzie przez irm | scriptblock
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Uruchom ten skrypt w PowerShellu jako administrator.'
}

# ConvertTo-Json w Windows PowerShell formatuje brzydko (podwójne spacje po dwukropku,
# rozjechane wcięcia zagnieżdżonych obiektów) - znormalizuj do wcięć 2-spacjowych
function Format-Json {
    param([Parameter(Mandatory)][string]$Json)
    $indent = 0
    (($Json -split "`r?`n") | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^[}\]]') { $indent = [Math]::Max(0, $indent - 1) }
        $out = (' ' * (2 * $indent)) + ($line -replace '":\s+', '": ')
        if ($line -match '[{\[]$') { $indent++ }
        $out
    }) -join [Environment]::NewLine
}

# Pytanie z wartością bieżącą jako domyślną (Enter = zostaw). Hasła bez echa; przy istniejącym haśle
# Enter zostawia stare, przy braku Enter = brak hasła (operator Subiekta może go nie mieć).
function Read-Value {
    param([string]$Prompt, [string]$Current, [switch]$Required, [switch]$Secret)
    $hint = if ($Current) { if ($Secret) { ' (Enter = bez zmian)' } else { " [$Current]" } }
            elseif (-not $Required) { ' (Enter = brak)' } else { '' }
    do {
        if ($Secret) {
            $secure = Read-Host "$Prompt$hint" -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { $answer = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        } else {
            $answer = (Read-Host "$Prompt$hint").Trim()
        }
        if (-not $answer) { $answer = $Current }
    } while ($Required -and -not $answer)
    return $answer
}

function New-SqlConnectionString {
    param([string]$Server, [string]$Database, [bool]$Integrated, [string]$User, [string]$Password)
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Server
    $b['Initial Catalog'] = $Database
    if ($Integrated) { $b['Integrated Security'] = $true } else { $b['User ID'] = $User; $b['Password'] = $Password }
    $b['Connect Timeout'] = 10
    $b['TrustServerCertificate'] = $true
    $b['Application Name'] = 'zapqio-install-nexo'
    return $b.ConnectionString
}

function Invoke-SqlScalar {
    param([string]$ConnectionString, [string]$Query)
    $connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = 15
        return $command.ExecuteScalar()
    } finally {
        $connection.Dispose()
    }
}

function Get-SqlDatabases {
    param([string]$ConnectionString)
    $connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = 'SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name'
        $reader = $command.ExecuteReader()
        $names = @()
        while ($reader.Read()) { $names += $reader.GetString(0) }
        return $names
    } finally {
        $connection.Dispose()
    }
}

# Trzy pierwsze człony wersji (61.1.0.9431 -> 61.1.0) - tak nazywa się plik SDK na FTP InsERT
function Get-ShortVersion {
    param([string]$Text)
    if ($Text -match '(\d+)\.(\d+)\.(\d+)') { return "$($Matches[1]).$($Matches[2]).$($Matches[3])" }
    return $null
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- 1. Runner ------------------------------------------------------------------

$InstallDir = $InstallDir.TrimEnd('\')
$exePath = Join-Path $InstallDir 'Zapqio.Runner.exe'
if (-not (Test-Path $exePath)) {
    throw @"
W $InstallDir nie ma Zapqio.Runner.exe. Ten skrypt dokłada moduł Nexo do zainstalowanego runnera - najpierw
zainstaluj runner (https://github.com/zapqio/dotnet-runner, install.ps1), a jeśli jest w innym katalogu,
podaj go w -InstallDir.
"@
}

# Sfera i pozostałe biblioteki InsERT-a są obfuskowane i loader .NET 9+ je odrzuca - moduł na runnerze
# .NET 10 nie powstałby wcale. Wariant runnera zdradza runtimeconfig.
$runtimeConfigPath = Join-Path $InstallDir 'Zapqio.Runner.runtimeconfig.json'
if (Test-Path $runtimeConfigPath) {
    $tfm = (Get-Content -Path $runtimeConfigPath -Raw | ConvertFrom-Json).runtimeOptions.tfm
    if ($tfm -and $tfm -notlike 'net8.*') {
        throw @"
Runner w $InstallDir jest zbudowany na $tfm, a moduły Nexo działają tylko na .NET 8 (biblioteki InsERT-a nie ładują
się na .NET 9+). Zainstaluj ponownie wariant .NET 8 - install.ps1 runnera bez -Net10 aktualizuje instalację w miejscu,
zachowując konfigurację i moduły - i uruchom ten skrypt jeszcze raz.
"@
    }
}

$modulesDir = Join-Path $InstallDir 'Modules'
$configDir = Join-Path $InstallDir 'Config'
$configPath = Join-Path $configDir $configFileName
if (-not (Test-Path $modulesDir)) { New-Item -ItemType Directory -Path $modulesDir | Out-Null }

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Warning "Usługi $ServiceName nie ma (runner uruchamiany z konsoli?). Paczki zostaną wgrane, restart zrób sam."
    $NoRestart = $true
}
$serviceAccount = if ($service) { (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'").StartName } else { $null }

$appsettingsPath = Join-Path $InstallDir 'appsettings.json'
$logsDir = Join-Path $InstallDir 'Logs'
if (Test-Path $appsettingsPath) {
    $rawConfig = Get-Content -Path $appsettingsPath -Raw
    if ($rawConfig -match '"PathDirectory"\s*:\s*"([^"]*)"') {
        $logsPath = $Matches[1] -replace '\\\\', '\'
        $logsDir = if (-not $logsPath) { $null } elseif ([IO.Path]::IsPathRooted($logsPath)) { $logsPath } else { Join-Path $InstallDir $logsPath }
    }
}

# --- 2. Dane połączenia z Subiektem -------------------------------------------------

# Istniejąca konfiguracja to wartości domyślne pytań; parametry mają pierwszeństwo.
$config = $null
if (Test-Path $configPath) {
    try { $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json }
    catch { throw "Nie udało się sparsować ${configPath}: $($_.Exception.Message). Popraw albo usuń plik i uruchom skrypt ponownie." }
}
if (-not $config) { $config = [pscustomobject]@{} }
$connect = $config.PSObject.Properties['Connect']
$connect = if ($connect -and $connect.Value -is [System.Management.Automation.PSCustomObject]) { $connect.Value } else { [pscustomobject]@{} }
function Get-Field([object]$Object, [string]$Name) {
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

$server = if ($DatabaseServer) { $DatabaseServer } else { [string](Get-Field $connect 'DatabaseServer') }
$database = if ($DatabaseName) { $DatabaseName } else { [string](Get-Field $connect 'DatabaseName') }
$sqlUser = if ($DatabaseUser) { $DatabaseUser } else { [string](Get-Field $connect 'DatabaseUser') }
$sqlPassword = if ($PSBoundParameters.ContainsKey('DatabasePassword')) { $DatabasePassword } else { [string](Get-Field $connect 'DatabasePassword') }
$operator = if ($UserName) { $UserName } else { [string](Get-Field $connect 'UserName') }
$operatorPassword = if ($PSBoundParameters.ContainsKey('UserPassword')) { $UserPassword } else { [string](Get-Field $connect 'UserPassword') }
$integrated = if ($WindowsLogin) { $true } elseif ($DatabaseUser) { $false } else { [bool](Get-Field $connect 'WindowsLogin') }

$interactive = $true
$dbVersion = $null
$attempt = 0
while ($true) {
    $attempt++
    $missing = @()
    if (-not $server) { $missing += 'DatabaseServer' }
    if (-not $database) { $missing += 'DatabaseName' }
    if (-not $integrated -and -not $sqlUser) { $missing += 'DatabaseUser' }
    if (-not $operator) { $missing += 'UserName' }

    # Przy ponownej próbie po nieudanym połączeniu pytamy o wszystko, z dotychczasowymi wartościami jako domyślnymi.
    if ($interactive -and ($missing.Count -gt 0 -or $attempt -gt 1)) {
        try {
            Write-Host ''
            Write-Host 'Dane połączenia z Subiektem nexo (ten sam serwer SQL i baza podmiotu, do których łączy się Subiekt):'
            $server = Read-Value 'Serwer SQL, np. SERWER\INSERTNEXO' $server -Required
            $answer = Read-Value 'Użytkownik SQL, np. sa (Enter = uwierzytelnianie Windows kontem usługi runnera)' $(if ($integrated) { '' } else { $sqlUser })
            if ($answer) {
                $integrated = $false
                $sqlUser = $answer
                $sqlPassword = Read-Value "Hasło SQL użytkownika $sqlUser" $sqlPassword -Secret
            } else {
                $integrated = $true
                $sqlUser = ''
                $sqlPassword = ''
                Write-Warning "Do SQL połączy się konto usługi ($serviceAccount) - musi mieć dostęp do bazy podmiotu. Ten skrypt testuje połączenie kontem $env:USERDOMAIN\$env:USERNAME."
            }
            if (-not $database) {
                # Lista baz z serwera jako podpowiedź - nazwa bazy podmiotu bywa nieoczywista
                try {
                    $names = Get-SqlDatabases (New-SqlConnectionString $server 'master' $integrated $sqlUser $sqlPassword)
                    if ($names.Count -gt 0) { Write-Host "  Bazy na ${server}: $($names -join ', ')" }
                } catch {
                    Write-Warning "Nie udało się połączyć z ${server}: $($_.Exception.Message)"
                }
            }
            $database = Read-Value 'Baza podmiotu, np. Nexo_Firma' $database -Required
            $operator = Read-Value 'Operator Subiekta (login z okna logowania), np. Szef' $operator -Required
            $operatorPassword = Read-Value "Hasło operatora $operator" $operatorPassword -Secret
        } catch {
            # sesja bez konsoli - niżej czytelny błąd zamiast pętli
            $interactive = $false
        }
    }

    $missing = @()
    if (-not $server) { $missing += 'DatabaseServer' }
    if (-not $database) { $missing += 'DatabaseName' }
    if (-not $integrated -and -not $sqlUser) { $missing += 'DatabaseUser' }
    if (-not $operator) { $missing += 'UserName' }
    if ($missing.Count -gt 0) {
        throw "Brak danych połączenia: $($missing -join ', '). Sesja bez konsoli - podaj je parametrami (-DatabaseServer, -DatabaseName, -DatabaseUser/-DatabasePassword albo -WindowsLogin, -UserName, -UserPassword)."
    }

    # --- 3. Test połączenia i wersja Subiekta ---------------------------------------

    Write-Host "==> Sprawdzam połączenie z bazą $database na $server..."
    $connectionString = New-SqlConnectionString $server $database $integrated $sqlUser $sqlPassword
    try {
        [void](Invoke-SqlScalar $connectionString 'SELECT 1')
        Write-Host '==> Połączenie z SQL działa.'
    } catch {
        $reason = $_.Exception.Message
        if ($interactive) {
            Write-Warning "Połączenie nie powiodło się: $reason"
            Write-Host 'Popraw dane (Enter zostawia wartość w nawiasie).'
            continue
        }
        throw "Połączenie z bazą $database na $server nie powiodło się: $reason"
    }

    # Wersję z bazy czytamy zawsze, gdy połączenie działa: przy -SubiektVersion / -SdkDir tylko do porównania.
    $dbVersion = $null
    foreach ($q in $versionQueries) {
        try {
            $value = [string](Invoke-SqlScalar $connectionString $q.Query)
            if (Get-ShortVersion $value) {
                $dbVersion = $value
                Write-Host "==> Wersja Subiekta z bazy: $dbVersion ($($q.Source))"
                break
            }
            Write-Verbose "Zapytanie o wersję ($($q.Source)) zwróciło '$value' - to nie jest numer wersji."
        } catch {
            Write-Verbose "Zapytanie o wersję ($($q.Source)) nie powiodło się: $($_.Exception.Message)"
        }
    }
    if (-not $dbVersion) {
        Write-Warning 'Nie udało się odczytać wersji Subiekta z bazy (uruchom z -Verbose, żeby zobaczyć przyczyny).'
    }
    break
}

if ($SubiektVersion) {
    $targetVersion = Get-ShortVersion $SubiektVersion
    if (-not $targetVersion) { throw "-SubiektVersion ma mieć trzy człony, np. 61.1.1 (podano: $SubiektVersion)" }
} elseif ($SdkDir) {
    $targetVersion = $null   # wersję wyznacza gotowe SDK, sprawdzi ją update-nexo-sdk.ps1
} elseif ($dbVersion) {
    $targetVersion = Get-ShortVersion $dbVersion
} else {
    $targetVersion = $null
    if ($interactive) {
        try {
            do {
                $answer = (Read-Host 'Wersja Subiekta z "Pomoc > O programie", np. 61.1.1').Trim()
                $targetVersion = Get-ShortVersion $answer
                if (-not $targetVersion) { Write-Warning 'Podaj wersję z trzema członami, np. 61.1.1.' }
            } while (-not $targetVersion)
        } catch { }
    }
    if (-not $targetVersion) {
        throw 'Nie znam wersji Subiekta - podaj ją w -SubiektVersion (trzy człony, np. 61.1.1; w Subiekcie: Pomoc > O programie).'
    }
}

# --- 4. Zapis Config\nexoModule.json --------------------------------------------------

# Katalog zakłada install.ps1 runnera (od 0.1.9) z ACL jak na appsettings.json, bo w pliku są hasła.
# Starsza instalacja go nie ma - wtedy te same uprawnienia nadajemy tutaj.
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir | Out-Null
    $grants = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')  # SYSTEM, Administratorzy
    if ($serviceAccount -and $serviceAccount -ne 'LocalSystem') { $grants += "${serviceAccount}:(OI)(CI)M" }
    & icacls $configDir /inheritance:r /grant:r $grants | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls na $configDir zakończyło się kodem $LASTEXITCODE." }
}

$values = [ordered]@{
    DatabaseServer   = $server
    DatabaseUser     = $(if ($integrated) { '' } else { $sqlUser })
    DatabasePassword = $(if ($integrated) { '' } else { [string]$sqlPassword })
    DatabaseName     = $database
    UserName         = $operator
    UserPassword     = [string]$operatorPassword
    WindowsLogin     = [bool]$integrated
}
foreach ($key in $values.Keys) {
    $connect | Add-Member -NotePropertyName $key -NotePropertyValue $values[$key] -Force
}
$config | Add-Member -NotePropertyName 'Connect' -NotePropertyValue $connect -Force
Format-Json ($config | ConvertTo-Json -Depth 10) | Set-Content -Path $configPath -Encoding UTF8
Write-Host "==> Zapisano sekcję Connect w $configPath."

$legacyConfig = Join-Path $InstallDir $configFileName
if (Test-Path $legacyConfig) {
    Write-Warning "Obok binarki leży stary $configFileName - moduł czyta już tylko $configPath, ten plik można usunąć."
}

$tempDir = Join-Path $env:TEMP ("zapqio-nexo-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    # --- 5. Paczka Nexo.Connection --------------------------------------------------------

    $zipPath = Join-Path $tempDir $moduleZipName
    if ($PackagePath) {
        if (-not (Test-Path $PackagePath)) { throw "Nie ma pliku $PackagePath (-PackagePath)." }
        Write-Host "==> Biorę paczkę z $PackagePath"
        Copy-Item -Path $PackagePath -Destination $zipPath
    } else {
        $zipUrl = if ($Version) { "https://github.com/$repo/releases/download/v$($Version -replace '^v', '')/$moduleZipName" }
                  else { "https://github.com/$repo/releases/latest/download/$moduleZipName" }
        Write-Host "==> Pobieram $zipUrl"
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        } catch {
            throw "Nie udało się pobrać paczki ($($_.Exception.Message)). Release'y: https://github.com/$repo/releases"
        } finally {
            $ProgressPreference = $oldProgress
        }
    }

    $extractDir = Join-Path $tempDir 'extract'
    Expand-Archive -Path $zipPath -DestinationPath $extractDir
    $moduleDll = Join-Path $extractDir 'Nexo.Connection.dll'
    $updateScriptSource = Join-Path $extractDir $updateScriptName
    if (-not (Test-Path $moduleDll) -or -not (Test-Path $updateScriptSource)) {
        throw "W paczce nie ma Nexo.Connection.dll albo $updateScriptName - to nie wygląda na $moduleZipName."
    }
    $moduleVersion = (Get-Item $moduleDll).VersionInfo.ProductVersion -replace '\+.*$', ''

    Copy-Item -Path $zipPath -Destination (Join-Path $modulesDir $moduleZipName) -Force
    # Skrypt podmiany SDK leży w katalogu runnera (stąd uruchamia go NexoClient po aktualizacji Subiekta i admin ręcznie)
    $updateScript = Join-Path $InstallDir $updateScriptName
    Copy-Item -Path $updateScriptSource -Destination $updateScript -Force
    Write-Host "==> Nexo.Connection $moduleVersion w $modulesDir."

    # Paczka sprzed podziału modułu niesie własny NexoClient i SDK - dwa komplety w Modules\ to konflikt.
    $legacyZip = Join-Path $modulesDir 'Nexo.zip'
    if (Test-Path $legacyZip) {
        Move-Item -Path $legacyZip -Destination "$legacyZip.old" -Force
        Write-Warning "Stary Nexo.zip (sprzed podziału na Nexo.Sdk + Nexo.Connection) przemianowany na Nexo.zip.old - runner go pominie; usuń, gdy nowe paczki zadziałają."
    }

    # --- 6. SDK InsERT nexo ------------------------------------------------------------------

    $sdkZip = Join-Path $modulesDir $sdkZipName
    $sdkStatePath = Join-Path $InstallDir 'nexo-sdk.json'
    $installedSdk = $null
    if ((Test-Path $sdkZip) -and (Test-Path $sdkStatePath)) {
        try { $installedSdk = [string](Get-Content -Path $sdkStatePath -Raw | ConvertFrom-Json).version } catch { }
    }

    if ($targetVersion -and $installedSdk -and (Get-ShortVersion $installedSdk) -eq $targetVersion) {
        Write-Host "==> SDK $installedSdk już jest w $sdkZip - bez podmiany."
    } else {
        $scriptArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $updateScript,
                        '-RunnerDir', $InstallDir, '-ServiceName', $ServiceName, '-NoRestart')
        if ($SdkDir) {
            Write-Host "==> Pakuję SDK z $SdkDir do $sdkZip..."
            $scriptArgs += @('-SdkDir', $SdkDir)
        } else {
            Write-Host "==> Pobieram SDK InsERT nexo $targetVersion (ok. 500 MB) i pakuję do $sdkZip..."
            $scriptArgs += @('-Version', $targetVersion)
        }
        & powershell.exe @scriptArgs
        if ($LASTEXITCODE -ne 0) {
            throw "update-nexo-sdk.ps1 zakończył się kodem $LASTEXITCODE - SDK nie zostało zainstalowane. Popraw przyczynę z komunikatu wyżej i uruchom ponownie: $updateScript -Version $targetVersion -RunnerDir $InstallDir"
        }
        try { $installedSdk = [string](Get-Content -Path $sdkStatePath -Raw | ConvertFrom-Json).version } catch { }
    }
    if ($dbVersion -and $installedSdk -and (Get-ShortVersion $installedSdk) -ne (Get-ShortVersion $dbVersion)) {
        Write-Warning "SDK $installedSdk w $sdkZip nie zgadza się z wersją Subiekta z bazy ($dbVersion) - Sfera odrzuci połączenie. Uruchom: $updateScript -Version $(Get-ShortVersion $dbVersion) -RunnerDir $InstallDir"
    }

    # --- 7. Restart i sprawdzenie w logu ---------------------------------------------------------

    $methodSeen = $false
    $problems = @()
    if ($NoRestart) {
        Write-Host "==> Bez restartu (-NoRestart). Runner wczyta paczki przy następnym starcie: Restart-Service $ServiceName"
    } else {
        # Zapamiętaj, dokąd log sięgał przed restartem - czytamy tylko nowe wpisy
        $preLogFile = $null
        $preLogOffset = 0
        if ($logsDir) {
            $preLogFile = Get-ChildItem -Path $logsDir -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($preLogFile) { $preLogOffset = $preLogFile.Length }
        }

        Write-Host "==> Restartuję usługę $ServiceName..."
        Restart-Service -Name $ServiceName

        if ($logsDir) {
            Write-Host '==> Czekam, aż runner ogłosi metodę "Nexo: Who am I" (do 60 s)...'
            $deadline = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 2
                $logFile = Get-ChildItem -Path $logsDir -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if (-not $logFile) { continue }
                $offset = if ($preLogFile -and $logFile.FullName -eq $preLogFile.FullName) { $preLogOffset } else { 0 }
                try {
                    $stream = [IO.File]::Open($logFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                    try {
                        if ($offset -le $stream.Length) { [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin) }
                        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
                        $newLog = $reader.ReadToEnd()
                    } finally {
                        $stream.Dispose()
                    }
                } catch {
                    continue
                }
                $problems = @([regex]::Matches($newLog, '(Metoda [^\r\n]*nie została utworzona[^\r\n]*|Nie udało się załadować[^\r\n]*|Brak dostępu do katalogu modułów[^\r\n]*)') | ForEach-Object { $_.Value } | Select-Object -Unique)
                if ($newLog -match 'Add method: [^\r\n]*WhoAmI') { $methodSeen = $true; break }
                # "Wysyłam Info" zamyka skan modułów - dalsze czekanie nic nie zmieni
                if ($newLog -match 'Wysyłam Info') { break }
            }
            if ($methodSeen) {
                Write-Host '==> Runner ogłosił metodę "Nexo: Who am I".'
            } else {
                Write-Warning "W ciągu 60 s log nie potwierdził metody - zajrzyj do $logsDir (szukaj: Nexo.Sdk, Nexo.Connection, 'nie została utworzona')."
            }
            foreach ($p in $problems) { Write-Warning $p }
        } else {
            Write-Host '==> Logi plikowe wyłączone - listę metod sprawdź w panelu Web.'
        }
    }

    # --- 8. Podsumowanie ---------------------------------------------------------------------------

    Write-Host ''
    Write-Host "Moduł Nexo na runnerze $ServiceName$(if ($service) { " ($((Get-Service -Name $ServiceName).Status))" })."
    Write-Host "  Nexo.Connection: $moduleVersion ($(Join-Path $modulesDir $moduleZipName))"
    Write-Host "  SDK InsERT nexo: $(if ($installedSdk) { $installedSdk } else { '?' }) ($sdkZip)"
    Write-Host "  Subiekt: $server, baza $database, operator $operator$(if ($integrated) { ', SQL: uwierzytelnianie Windows' } else { ", SQL: $sqlUser" })"
    Write-Host "  Konfiguracja: $configPath"
    Write-Host "  Skrypt podmiany SDK: $updateScript (po aktualizacji Subiekta moduł uruchamia go sam)"
    Write-Host ''
    Write-Host 'Sprawdzenie: w panelu Web uruchom na tym runnerze metodę "Nexo: Who am I" - zwraca operatora, wersję SDK'
    Write-Host 'oraz serwer i bazę. Błąd zadania mówi wprost, co poprawić (SDK, dane SQL albo hasło operatora).'
    Write-Host "Paczki z metodami (np. Nexo.Invoices.zip) wrzucaj do $modulesDir i restartuj usługę."
} finally {
    # Remove-Item wykrzacza się na ścieżkach ze skróconą nazwą 8.3 (np. C:\Users\UKASZ~1),
    # a taką potrafi mieć %TEMP% - .NET usuwa je bez problemu
    try { [IO.Directory]::Delete($tempDir, $true) } catch {}
}
