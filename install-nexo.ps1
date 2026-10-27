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
      3. pobiera Nexo.Connection.zip z GitHub Releases jako źródło wersji Connection,
      4. przebudowuje Connection i zarejestrowane moduły pod SDK Subiekta, sprawdza zestaw i aktywuje go
         (update-nexo-sdk.ps1 pobiera SDK z publicznego FTP InsERT - ok. 500 MB),
      5. przygotowuje budowanie modułów na runnerze: SDK .NET, biblioteki SDK nexo oraz NuGet,
      6. restartuje usługę i czeka, aż w logu runnera pojawi się metoda "Nexo: Who am I".

    Uruchomiony ponownie działa jak aktualizacja: dane połączenia zostają (pyta tylko o brakujące),
    Connection aktualizuje się do wybranego wydania. Gotowy, sprawdzony zestaw tych samych źródeł i SDK
    jest używany ponownie; sama zmiana SDK nie zmienia numeru pakietu Connection.

.PARAMETER Language
    Język komunikatów i pytań: pl, en albo de. Bez parametru: wybór na początku instalacji.
    Enter wybiera język systemu (dla innych języków: angielski); bez konsoli używana jest ta sama wartość.

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
    -Version jest wtedy bez znaczenia. Zależności budowania są nadal pobierane z nuget.org.

.PARAMETER ConnectionPackagePath
    Parametr wycofany w tym instalatorze: lokalny NuGet powstaje automatycznie z docelowym SDK.
    Pozostaje obsługiwany przez install-nexo-build.ps1 dla starszych instalacji.

.PARAMETER ConnectionSource
    Katalog lub ZIP źródeł wybranego wydania Connection; opcjonalny przy migracji starszych paczek.

.PARAMETER ModulesConfig
    Rejestr źródeł modułów do przebudowy. Domyślnie Config\nexo-build-sources.json runnera.

.PARAMETER NoRestart
    Bez restartu usługi na końcu (nowe paczki zostaną wczytane przy następnym starcie).

.EXAMPLE
    .\install-nexo.ps1

.EXAMPLE
    .\install-nexo.ps1 -Language de

.EXAMPLE
    .\install-nexo.ps1 -Language pl -DatabaseServer 'SERWER\INSERTNEXO' -DatabaseName Nexo_Firma -DatabaseUser sa -DatabasePassword '...' -UserName Szef -UserPassword '...'

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
    [string]$ConnectionPackagePath,
    [string]$ConnectionSource,
    [string]$ModulesConfig,
    [switch]$NoRestart,
    [ValidateSet('pl', 'en', 'de')][string]$Language
)

$ErrorActionPreference = 'Stop'

function Resolve-InstallLanguage {
    param(
        [string]$RequestedLanguage,
        [string]$CultureName = [Globalization.CultureInfo]::CurrentUICulture.Name,
        [switch]$Prompt
    )
    if ($RequestedLanguage) { return $RequestedLanguage.ToLowerInvariant() }
    $defaultLanguage = [Globalization.CultureInfo]::GetCultureInfo($CultureName).TwoLetterISOLanguageName
    if ($defaultLanguage -notin 'pl', 'en', 'de') { $defaultLanguage = 'en' }
    if (-not $Prompt) { return $defaultLanguage }

    Write-Host '1. Polski (pl)'
    Write-Host '2. English (en)'
    Write-Host '3. Deutsch (de)'
    while ($true) {
        try { $answer = Read-Host "Język / Language / Sprache [$defaultLanguage]" }
        catch { return $defaultLanguage } # PowerShell -NonInteractive has no input prompt.
        if ([string]::IsNullOrWhiteSpace($answer)) { return $defaultLanguage }
        switch ($answer.Trim().ToLowerInvariant()) {
            { $_ -in '1', 'pl' } { return 'pl' }
            { $_ -in '2', 'en' } { return 'en' }
            { $_ -in '3', 'de' } { return 'de' }
        }
        Write-Warning 'Wybierz / Choose / Wählen Sie: 1/pl, 2/en, 3/de.'
    }
}

$Language = Resolve-InstallLanguage -RequestedLanguage $Language -Prompt:([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)

$messages = @{
    pl = @{
        AdminRequired = 'Uruchom ten skrypt w PowerShellu jako administrator.'
        NoService = 'Usługi {0} nie ma (runner uruchamiany z konsoli?). Paczki zostaną wgrane, restart zrób sam.'
        InvalidConfig = 'Nie udało się sparsować {0}: {1}. Popraw albo usuń plik i uruchom skrypt ponownie.'
        ConnectionPrompt = 'Dane połączenia z Subiektem nexo (ten sam serwer SQL i baza podmiotu, do których łączy się Subiekt):'
        ServerPrompt = 'Serwer SQL, np. SERWER\INSERTNEXO'
        SqlUserPrompt = 'Użytkownik SQL, np. sa (Enter = uwierzytelnianie Windows kontem usługi runnera)'
        SqlPasswordPrompt = 'Hasło SQL użytkownika {0}'
        WindowsAccount = 'Do SQL połączy się konto usługi ({0}) - musi mieć dostęp do bazy podmiotu. Ten skrypt testuje połączenie kontem {1}.'
        DatabaseList = '  Bazy na {0}: {1}'
        ServerConnectionFailed = 'Nie udało się połączyć z {0}: {1}'
        DatabasePrompt = 'Baza podmiotu, np. Nexo_Firma'
        OperatorPrompt = 'Operator Subiekta (login z okna logowania), np. Szef'
        OperatorPasswordPrompt = 'Hasło operatora {0}'
        MissingConnection = 'Brak danych połączenia: {0}. Sesja bez konsoli - podaj je parametrami (-DatabaseServer, -DatabaseName, -DatabaseUser/-DatabasePassword albo -WindowsLogin, -UserName, -UserPassword).'
        CheckingSql = '==> Sprawdzam połączenie z bazą {0} na {1}...'
        SqlReady = '==> Połączenie z SQL działa.'
        ConnectionFailed = 'Połączenie nie powiodło się: {0}'
        CorrectSettings = 'Popraw dane (Enter zostawia wartość w nawiasie).'
        SqlFailed = 'Połączenie z bazą {0} na {1} nie powiodło się: {2}'
        DatabaseVersion = '==> Wersja Subiekta z bazy: {0} ({1})'
        InvalidVersionResult = 'Zapytanie o wersję ({0}) zwróciło ''{1}'' - to nie jest numer wersji.'
        VersionQueryFailed = 'Zapytanie o wersję ({0}) nie powiodło się: {1}'
        NoDatabaseVersion = 'Nie udało się odczytać wersji Subiekta z bazy (uruchom z -Verbose, żeby zobaczyć przyczyny).'
        InvalidVersion = '-SubiektVersion ma mieć trzy człony, np. 61.1.1 (podano: {0})'
        VersionPrompt = 'Wersja Subiekta z "Pomoc > O programie", np. 61.1.1'
        VersionExample = 'Podaj wersję z trzema członami, np. 61.1.1.'
        MissingVersion = 'Nie znam wersji Subiekta - podaj ją w -SubiektVersion (trzy człony, np. 61.1.1; w Subiekcie: Pomoc > O programie).'
        AclFailed = 'icacls na {0} zakończyło się kodem {1}.'
        ConfigSaved = '==> Zapisano sekcję Connect w {0}.'
        LegacyConfig = 'Obok binarki leży stary {0} - moduł czyta już tylko {1}, ten plik można usunąć.'
        MissingPackage = 'Nie ma pliku {0} (-PackagePath).'
        LocalPackage = '==> Biorę paczkę z {0}'
        Downloading = '==> Pobieram {0}'
        DownloadFailed = 'Nie udało się pobrać paczki ({0}). Release''y: https://github.com/{1}/releases'
        InvalidPackage = 'W paczce nie ma Nexo.Connection.dll albo {0} - to nie wygląda na {1}.'
        ConnectionInstalled = '==> Nexo.Connection {0} w {1}.'
        LegacyZip = 'Stary Nexo.zip (sprzed podziału na Nexo.Sdk + Nexo.Connection) przemianowany na Nexo.zip.old - runner go pominie; usuń, gdy nowe paczki zadziałają.'
        SdkPresent = '==> SDK {0} już jest w {1} - bez podmiany.'
        PackingSdk = '==> Pakuję SDK z {0} do {1}...'
        DownloadingSdk = '==> Pobieram SDK InsERT nexo {0} (ok. 500 MB) i pakuję do {1}...'
        SdkSetupFailed = 'Aktualizacja zestawu nexo zakończyła się kodem {0}. Popraw przyczynę z komunikatu wyżej i uruchom ponownie ten sam install-nexo.ps1 z tymi samymi parametrami (także -SdkDir, jeśli był podany). Nie uruchamiaj skryptu z tymczasowego katalogu instalatora.'
        SdkMismatch = 'SDK {0} w {1} nie zgadza się z wersją Subiekta z bazy ({2}) - Sfera odrzuci połączenie. Uruchom: {3} -Version {4} -RunnerDir {5}'
        BuildSetupFailed = 'Przygotowanie budowania modułów nie powiodło się. Popraw błąd i uruchom install-nexo-build.ps1.'
        NoRestart = '==> Bez restartu (-NoRestart). Runner wczyta paczki przy następnym starcie: Restart-Service {0}'
        Restarting = '==> Restartuję usługę {0}...'
        WaitingMethod = '==> Czekam, aż runner ogłosi metodę "Nexo: Who am I" (do 60 s)...'
        MethodReady = '==> Runner ogłosił metodę "Nexo: Who am I".'
        MethodUnconfirmed = 'W ciągu 60 s log nie potwierdził metody - zajrzyj do {0} (szukaj: Nexo.Sdk, Nexo.Connection, ''nie została utworzona'').'
        FileLogsDisabled = '==> Logi plikowe wyłączone - listę metod sprawdź w panelu Web.'
        Summary = 'Moduł Nexo na runnerze {0}{1}.'
        SummaryConnection = '  Nexo.Connection: {0} ({1})'
        SummarySdk = '  SDK InsERT nexo: {0} ({1})'
        SummaryConfig = '  Konfiguracja: {0}'
        SummaryUpdate = '  Skrypt podmiany SDK: {0} (po aktualizacji Subiekta moduł uruchamia go sam)'
        Verification = 'Sprawdzenie: w panelu Web uruchom na tym runnerze metodę "Nexo: Who am I" - zwraca operatora oraz wersję i paczkę SDK.'
        Troubleshooting = 'Błąd zadania mówi wprost, co poprawić (SDK, dane SQL albo hasło operatora).'
        InstallingModules = 'Paczki z metodami (np. Nexo.Invoices.zip) wrzucaj do {0} i restartuj usługę.'
        KeepValue = ' (Enter = bez zmian)'
        EmptyValue = ' (Enter = brak)'
        AuditVersionSource = 'ślad rewizyjny - ostatni program łączący się z bazą'
        MissingRunner = 'W {0} nie ma Zapqio.Runner.exe. Najpierw zainstaluj runner (https://github.com/zapqio/dotnet-runner, install.ps1), a jeśli jest w innym katalogu, podaj go w -InstallDir.'
        WrongRuntime = 'Runner w {0} jest zbudowany na {1}, a moduły Nexo działają tylko na .NET 8. Uruchom install.ps1 runnera bez -Net10, aby zainstalować wariant .NET 8 z zachowaniem konfiguracji i modułów, a potem uruchom ten skrypt ponownie.'
        SummarySubiekt = '  Subiekt: {0}, baza {1}, operator {2}, SQL: {3}'
        WindowsAuthentication = 'uwierzytelnianie Windows'
        LegacyScriptLanguage = 'Skrypt {0} z tej paczki nie obsługuje wyboru języka; jego komunikaty pozostaną po polsku.'
    }
    en = @{
        AdminRequired = 'Run this script in PowerShell as administrator.'
        NoService = 'Service {0} was not found (is the runner started from a console?). Packages will be installed; restart the runner manually.'
        InvalidConfig = 'Could not parse {0}: {1}. Fix or remove the file and run this script again.'
        ConnectionPrompt = 'Subiekt nexo connection settings (the same SQL server and company database used by Subiekt):'
        ServerPrompt = 'SQL server, e.g. SERVER\INSERTNEXO'
        SqlUserPrompt = 'SQL user, e.g. sa (Enter = Windows authentication using the runner service account)'
        SqlPasswordPrompt = 'SQL password for {0}'
        WindowsAccount = 'SQL will use the service account ({0}), which needs access to the company database. This script tests the connection as {1}.'
        DatabaseList = '  Databases on {0}: {1}'
        ServerConnectionFailed = 'Could not connect to {0}: {1}'
        DatabasePrompt = 'Company database, e.g. Nexo_Firma'
        OperatorPrompt = 'Subiekt operator (username from the login window), e.g. Szef'
        OperatorPasswordPrompt = 'Password for operator {0}'
        MissingConnection = 'Missing connection settings: {0}. No console is available; provide parameters (-DatabaseServer, -DatabaseName, -DatabaseUser/-DatabasePassword or -WindowsLogin, -UserName, -UserPassword).'
        CheckingSql = '==> Checking the connection to database {0} on {1}...'
        SqlReady = '==> SQL connection successful.'
        ConnectionFailed = 'Connection failed: {0}'
        CorrectSettings = 'Correct the settings (Enter keeps the value in brackets).'
        SqlFailed = 'Connection to database {0} on {1} failed: {2}'
        DatabaseVersion = '==> Subiekt version from the database: {0} ({1})'
        InvalidVersionResult = 'The version query ({0}) returned ''{1}'', which is not a version number.'
        VersionQueryFailed = 'The version query ({0}) failed: {1}'
        NoDatabaseVersion = 'Could not read the Subiekt version from the database (use -Verbose for details).'
        InvalidVersion = '-SubiektVersion must have three parts, e.g. 61.1.1 (received: {0})'
        VersionPrompt = 'Subiekt version from "Pomoc > O programie" (Help > About), e.g. 61.1.1'
        VersionExample = 'Enter a three-part version, e.g. 61.1.1.'
        MissingVersion = 'The Subiekt version is unknown. Specify -SubiektVersion with three parts, e.g. 61.1.1 (in Subiekt: Pomoc > O programie / Help > About).'
        AclFailed = 'icacls for {0} exited with code {1}.'
        ConfigSaved = '==> Saved the Connect section in {0}.'
        LegacyConfig = 'An old {0} is next to the executable. The module now reads only {1}; the old file can be removed.'
        MissingPackage = 'File {0} was not found (-PackagePath).'
        LocalPackage = '==> Using the package from {0}'
        Downloading = '==> Downloading {0}'
        DownloadFailed = 'Could not download the package ({0}). Releases: https://github.com/{1}/releases'
        InvalidPackage = 'The package is missing Nexo.Connection.dll or {0}; it does not appear to be {1}.'
        ConnectionInstalled = '==> Nexo.Connection {0} installed in {1}.'
        LegacyZip = 'The old Nexo.zip (from before the Nexo.Sdk + Nexo.Connection split) was renamed to Nexo.zip.old. The runner will ignore it; remove it once the new packages work.'
        SdkPresent = '==> SDK {0} is already in {1}; no replacement needed.'
        PackingSdk = '==> Packaging the SDK from {0} into {1}...'
        DownloadingSdk = '==> Downloading InsERT nexo SDK {0} (about 500 MB) and packaging it into {1}...'
        SdkSetupFailed = 'The nexo set update exited with code {0}. Fix the error above and rerun the same install-nexo.ps1 with the same parameters (including -SdkDir if supplied). Do not run a script from the temporary installer directory.'
        SdkMismatch = 'SDK {0} in {1} does not match the Subiekt database version ({2}); Sfera will reject the connection. Run: {3} -Version {4} -RunnerDir {5}'
        BuildSetupFailed = 'Build environment setup failed. Fix the error and run install-nexo-build.ps1.'
        NoRestart = '==> No restart (-NoRestart). The runner will load packages on its next start: Restart-Service {0}'
        Restarting = '==> Restarting service {0}...'
        WaitingMethod = '==> Waiting for the runner to register "Nexo: Who am I" (up to 60 s)...'
        MethodReady = '==> The runner registered "Nexo: Who am I".'
        MethodUnconfirmed = 'The log did not confirm the method within 60 s. Check {0} (search for: Nexo.Sdk, Nexo.Connection, ''nie została utworzona'').'
        FileLogsDisabled = '==> File logging is disabled. Check the method list in the Web panel.'
        Summary = 'Nexo module on runner {0}{1}.'
        SummaryConnection = '  Nexo.Connection: {0} ({1})'
        SummarySdk = '  InsERT nexo SDK: {0} ({1})'
        SummaryConfig = '  Configuration: {0}'
        SummaryUpdate = '  SDK update script: {0} (the module runs it automatically after a Subiekt update)'
        Verification = 'To verify, run "Nexo: Who am I" on this runner in the Web panel. It returns the operator, SDK version and SDK package.'
        Troubleshooting = 'A task error indicates what to fix: SDK, SQL settings or operator password.'
        InstallingModules = 'Copy method packages (e.g. Nexo.Invoices.zip) to {0} and restart the service.'
        KeepValue = ' (Enter = keep current value)'
        EmptyValue = ' (Enter = leave empty)'
        AuditVersionSource = 'audit trail - last application connected to the database'
        MissingRunner = 'Zapqio.Runner.exe was not found in {0}. Install the runner first (https://github.com/zapqio/dotnet-runner, install.ps1), or specify its directory with -InstallDir.'
        WrongRuntime = 'The runner in {0} targets {1}, but Nexo modules require .NET 8. Run the runner install.ps1 without -Net10 to install the .NET 8 variant while keeping configuration and modules, then run this script again.'
        SummarySubiekt = '  Subiekt: {0}, database {1}, operator {2}, SQL: {3}'
        WindowsAuthentication = 'Windows authentication'
        LegacyScriptLanguage = 'Script {0} from this package does not support language selection; its messages will remain in Polish.'
    }
    de = @{
        AdminRequired = 'Führen Sie dieses Skript in PowerShell als Administrator aus.'
        NoService = 'Der Dienst {0} wurde nicht gefunden (läuft der Runner in einer Konsole?). Die Pakete werden installiert; starten Sie den Runner manuell neu.'
        InvalidConfig = '{0} konnte nicht eingelesen werden: {1}. Korrigieren oder entfernen Sie die Datei und führen Sie das Skript erneut aus.'
        ConnectionPrompt = 'Verbindungsdaten für Subiekt nexo (derselbe SQL-Server und dieselbe Firmendatenbank wie in Subiekt):'
        ServerPrompt = 'SQL-Server, z. B. SERVER\INSERTNEXO'
        SqlUserPrompt = 'SQL-Benutzer, z. B. sa (Eingabe = Windows-Authentifizierung mit dem Dienstkonto des Runners)'
        SqlPasswordPrompt = 'SQL-Kennwort für {0}'
        WindowsAccount = 'Die SQL-Verbindung verwendet das Dienstkonto ({0}), das Zugriff auf die Firmendatenbank benötigt. Dieses Skript testet die Verbindung als {1}.'
        DatabaseList = '  Datenbanken auf {0}: {1}'
        ServerConnectionFailed = 'Verbindung zu {0} fehlgeschlagen: {1}'
        DatabasePrompt = 'Firmendatenbank, z. B. Nexo_Firma'
        OperatorPrompt = 'Subiekt-Benutzer (Name aus dem Anmeldefenster), z. B. Szef'
        OperatorPasswordPrompt = 'Kennwort für Benutzer {0}'
        MissingConnection = 'Verbindungsdaten fehlen: {0}. Keine Konsole verfügbar; geben Sie die Parameter an (-DatabaseServer, -DatabaseName, -DatabaseUser/-DatabasePassword oder -WindowsLogin, -UserName, -UserPassword).'
        CheckingSql = '==> Verbindung zur Datenbank {0} auf {1} wird geprüft...'
        SqlReady = '==> SQL-Verbindung erfolgreich.'
        ConnectionFailed = 'Verbindung fehlgeschlagen: {0}'
        CorrectSettings = 'Korrigieren Sie die Angaben (Eingabe behält den Wert in Klammern bei).'
        SqlFailed = 'Verbindung zur Datenbank {0} auf {1} fehlgeschlagen: {2}'
        DatabaseVersion = '==> Subiekt-Version aus der Datenbank: {0} ({1})'
        InvalidVersionResult = 'Die Versionsabfrage ({0}) lieferte ''{1}''; dies ist keine Versionsnummer.'
        VersionQueryFailed = 'Die Versionsabfrage ({0}) ist fehlgeschlagen: {1}'
        NoDatabaseVersion = 'Die Subiekt-Version konnte nicht aus der Datenbank gelesen werden (Details mit -Verbose).'
        InvalidVersion = '-SubiektVersion muss aus drei Teilen bestehen, z. B. 61.1.1 (angegeben: {0})'
        VersionPrompt = 'Subiekt-Version aus "Pomoc > O programie" (Hilfe > Über), z. B. 61.1.1'
        VersionExample = 'Geben Sie eine dreiteilige Version ein, z. B. 61.1.1.'
        MissingVersion = 'Die Subiekt-Version ist unbekannt. Geben Sie -SubiektVersion mit drei Teilen an, z. B. 61.1.1 (in Subiekt: Pomoc > O programie / Hilfe > Über).'
        AclFailed = 'icacls für {0} wurde mit Code {1} beendet.'
        ConfigSaved = '==> Der Abschnitt Connect wurde in {0} gespeichert.'
        LegacyConfig = 'Neben der Programmdatei liegt eine alte Datei {0}. Das Modul liest nur noch {1}; die alte Datei kann entfernt werden.'
        MissingPackage = 'Datei {0} wurde nicht gefunden (-PackagePath).'
        LocalPackage = '==> Paket aus {0} wird verwendet'
        Downloading = '==> {0} wird heruntergeladen'
        DownloadFailed = 'Das Paket konnte nicht heruntergeladen werden ({0}). Veröffentlichungen: https://github.com/{1}/releases'
        InvalidPackage = 'Im Paket fehlt Nexo.Connection.dll oder {0}; es scheint kein gültiges {1} zu sein.'
        ConnectionInstalled = '==> Nexo.Connection {0} wurde in {1} installiert.'
        LegacyZip = 'Das alte Nexo.zip (vor der Aufteilung in Nexo.Sdk + Nexo.Connection) wurde in Nexo.zip.old umbenannt. Der Runner ignoriert es; entfernen Sie es, sobald die neuen Pakete funktionieren.'
        SdkPresent = '==> SDK {0} ist bereits in {1} vorhanden; kein Austausch erforderlich.'
        PackingSdk = '==> Das SDK aus {0} wird in {1} gepackt...'
        DownloadingSdk = '==> InsERT nexo SDK {0} (ca. 500 MB) wird heruntergeladen und in {1} gepackt...'
        SdkSetupFailed = 'Die Aktualisierung des nexo-Satzes wurde mit Code {0} beendet. Beheben Sie den obigen Fehler und starten Sie dieselbe install-nexo.ps1 mit denselben Parametern erneut (einschließlich -SdkDir, falls angegeben). Starten Sie kein Skript aus dem temporären Installationsverzeichnis.'
        SdkMismatch = 'SDK {0} in {1} stimmt nicht mit der Subiekt-Datenbankversion ({2}) überein; Sfera wird die Verbindung ablehnen. Führen Sie aus: {3} -Version {4} -RunnerDir {5}'
        BuildSetupFailed = 'Die Einrichtung der Build-Umgebung ist fehlgeschlagen. Beheben Sie den Fehler und führen Sie install-nexo-build.ps1 aus.'
        NoRestart = '==> Kein Neustart (-NoRestart). Der Runner lädt die Pakete beim nächsten Start: Restart-Service {0}'
        Restarting = '==> Dienst {0} wird neu gestartet...'
        WaitingMethod = '==> Warten auf die Registrierung von "Nexo: Who am I" durch den Runner (bis zu 60 s)...'
        MethodReady = '==> Der Runner hat "Nexo: Who am I" registriert.'
        MethodUnconfirmed = 'Das Protokoll hat die Methode innerhalb von 60 s nicht bestätigt. Prüfen Sie {0} (Suchbegriffe: Nexo.Sdk, Nexo.Connection, ''nie została utworzona'').'
        FileLogsDisabled = '==> Dateiprotokollierung ist deaktiviert. Prüfen Sie die Methodenliste im Webpanel.'
        Summary = 'Nexo-Modul auf Runner {0}{1}.'
        SummaryConnection = '  Nexo.Connection: {0} ({1})'
        SummarySdk = '  InsERT nexo SDK: {0} ({1})'
        SummaryConfig = '  Konfiguration: {0}'
        SummaryUpdate = '  SDK-Aktualisierungsskript: {0} (wird nach einem Subiekt-Update automatisch vom Modul gestartet)'
        Verification = 'Zur Prüfung führen Sie im Webpanel auf diesem Runner "Nexo: Who am I" aus. Die Methode liefert Benutzer, SDK-Version und SDK-Paket.'
        Troubleshooting = 'Eine Fehlermeldung der Aufgabe zeigt, was korrigiert werden muss: SDK, SQL-Einstellungen oder Benutzerkennwort.'
        InstallingModules = 'Kopieren Sie Methodenpakete (z. B. Nexo.Invoices.zip) nach {0} und starten Sie den Dienst neu.'
        KeepValue = ' (Eingabe = aktuellen Wert beibehalten)'
        EmptyValue = ' (Eingabe = leer lassen)'
        AuditVersionSource = 'Änderungsprotokoll - letzte mit der Datenbank verbundene Anwendung'
        MissingRunner = 'Zapqio.Runner.exe wurde in {0} nicht gefunden. Installieren Sie zuerst den Runner (https://github.com/zapqio/dotnet-runner, install.ps1), oder geben Sie sein Verzeichnis mit -InstallDir an.'
        WrongRuntime = 'Der Runner in {0} verwendet {1}, Nexo-Module benötigen jedoch .NET 8. Führen Sie install.ps1 des Runners ohne -Net10 aus, um die .NET-8-Variante unter Beibehaltung der Konfiguration und Module zu installieren. Führen Sie danach dieses Skript erneut aus.'
        SummarySubiekt = '  Subiekt: {0}, Datenbank {1}, Benutzer {2}, SQL: {3}'
        WindowsAuthentication = 'Windows-Authentifizierung'
        LegacyScriptLanguage = 'Das Skript {0} aus diesem Paket unterstützt keine Sprachauswahl; seine Meldungen bleiben auf Polnisch.'
    }
}

# Keep translations inside the script: it can also be run directly from a downloaded scriptblock.
function Get-InstallText {
    param([string]$Key, [object[]]$Values = @())
    $template = $messages[$Language][$Key]
    if ($null -eq $template) { throw "Missing installer translation: $Language/$Key" }
    return [string]::Format([Globalization.CultureInfo]::GetCultureInfo($Language), $template, $Values)
}

function Get-InstallerLanguageArguments {
    param([string]$Path)
    # Older Connection ZIPs contain a script without -Language; keep those releases installable.
    if ((Get-Command -Name $Path -ErrorAction Stop).Parameters.ContainsKey('Language')) {
        return @('-Language', $Language)
    }
    if ($Language -ne 'pl') {
        Write-Warning (Get-InstallText 'LegacyScriptLanguage' @((Split-Path -Path $Path -Leaf)))
    }
}

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
    @{ Source = (Get-InstallText 'AuditVersionSource')
       Query  = 'SELECT TOP 1 Wersja FROM ModelDanychContainer.ProgramyZdarzenSladuRewizyjnego ORDER BY Id DESC' }
)

# #Requires -RunAsAdministrator nie działa, gdy skrypt idzie przez irm | scriptblock
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw (Get-InstallText 'AdminRequired')
}

# Pytanie z wartością bieżącą jako domyślną (Enter = zostaw). Hasła bez echa; przy istniejącym haśle
# Enter zostawia stare, przy braku Enter = brak hasła (operator Subiekta może go nie mieć).
function Read-Value {
    param([string]$Prompt, [string]$Current, [switch]$Required, [switch]$Secret)
    $hint = if ($Current) { if ($Secret) { (Get-InstallText 'KeepValue') } else { " [$Current]" } }
            elseif (-not $Required) { (Get-InstallText 'EmptyValue') } else { '' }
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

$InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir).TrimEnd('\')
if ($ConnectionPackagePath) { throw 'ConnectionPackagePath is no longer used by install-nexo.ps1. The matching NuGet is built automatically; provide ConnectionSource for an older source-less release.' }
$exePath = Join-Path $InstallDir 'Zapqio.Runner.exe'
if (-not (Test-Path $exePath)) {
    throw (Get-InstallText 'MissingRunner' @($InstallDir))
}

# Sfera i pozostałe biblioteki InsERT-a są obfuskowane i loader .NET 9+ je odrzuca - moduł na runnerze
# .NET 10 nie powstałby wcale. Wariant runnera zdradza runtimeconfig.
$runtimeConfigPath = Join-Path $InstallDir 'Zapqio.Runner.runtimeconfig.json'
if (Test-Path $runtimeConfigPath) {
    $tfm = (Get-Content -Path $runtimeConfigPath -Raw | ConvertFrom-Json).runtimeOptions.tfm
    if ($tfm -and $tfm -notlike 'net8.*') {
        throw (Get-InstallText 'WrongRuntime' @($InstallDir, $tfm))
    }
}

$modulesDir = Join-Path $InstallDir 'Modules'
$configDir = Join-Path $InstallDir 'Config'
$configPath = Join-Path $configDir $configFileName
if (-not (Test-Path $modulesDir)) { New-Item -ItemType Directory -Path $modulesDir | Out-Null }

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Warning (Get-InstallText 'NoService' @($ServiceName))
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
    catch { throw (Get-InstallText 'InvalidConfig' @($configPath, $_.Exception.Message)) }
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
            Write-Host (Get-InstallText 'ConnectionPrompt')
            $server = Read-Value (Get-InstallText 'ServerPrompt') $server -Required
            $answer = Read-Value (Get-InstallText 'SqlUserPrompt') $(if ($integrated) { '' } else { $sqlUser })
            if ($answer) {
                $integrated = $false
                $sqlUser = $answer
                $sqlPassword = Read-Value (Get-InstallText 'SqlPasswordPrompt' @($sqlUser)) $sqlPassword -Secret
            } else {
                $integrated = $true
                $sqlUser = ''
                $sqlPassword = ''
                Write-Warning (Get-InstallText 'WindowsAccount' @($serviceAccount, "$env:USERDOMAIN\$env:USERNAME"))
            }
            if (-not $database) {
                # Lista baz z serwera jako podpowiedź - nazwa bazy podmiotu bywa nieoczywista
                try {
                    $names = Get-SqlDatabases (New-SqlConnectionString $server 'master' $integrated $sqlUser $sqlPassword)
                    if ($names.Count -gt 0) { Write-Host (Get-InstallText 'DatabaseList' @($server, ($names -join ', '))) }
                } catch {
                    Write-Warning (Get-InstallText 'ServerConnectionFailed' @($server, $_.Exception.Message))
                }
            }
            $database = Read-Value (Get-InstallText 'DatabasePrompt') $database -Required
            $operator = Read-Value (Get-InstallText 'OperatorPrompt') $operator -Required
            $operatorPassword = Read-Value (Get-InstallText 'OperatorPasswordPrompt' @($operator)) $operatorPassword -Secret
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
        throw (Get-InstallText 'MissingConnection' @(($missing -join ', ')))
    }

    # --- 3. Test połączenia i wersja Subiekta ---------------------------------------

    Write-Host (Get-InstallText 'CheckingSql' @($database, $server))
    $connectionString = New-SqlConnectionString $server $database $integrated $sqlUser $sqlPassword
    try {
        [void](Invoke-SqlScalar $connectionString 'SELECT 1')
        Write-Host (Get-InstallText 'SqlReady')
    } catch {
        $reason = $_.Exception.Message
        if ($interactive) {
            Write-Warning (Get-InstallText 'ConnectionFailed' @($reason))
            Write-Host (Get-InstallText 'CorrectSettings')
            continue
        }
        throw (Get-InstallText 'SqlFailed' @($database, $server, $reason))
    }

    # Wersję z bazy czytamy zawsze, gdy połączenie działa: przy -SubiektVersion / -SdkDir tylko do porównania.
    $dbVersion = $null
    foreach ($q in $versionQueries) {
        try {
            $value = [string](Invoke-SqlScalar $connectionString $q.Query)
            if (Get-ShortVersion $value) {
                $dbVersion = $value
                Write-Host (Get-InstallText 'DatabaseVersion' @($dbVersion, $q.Source))
                break
            }
            Write-Verbose (Get-InstallText 'InvalidVersionResult' @($q.Source, $value))
        } catch {
            Write-Verbose (Get-InstallText 'VersionQueryFailed' @($q.Source, $_.Exception.Message))
        }
    }
    if (-not $dbVersion) {
        Write-Warning (Get-InstallText 'NoDatabaseVersion')
    }
    break
}

if ($SubiektVersion) {
    $targetVersion = Get-ShortVersion $SubiektVersion
    if (-not $targetVersion) { throw (Get-InstallText 'InvalidVersion' @($SubiektVersion)) }
} elseif ($SdkDir) {
    $targetVersion = $null   # wersję wyznacza gotowe SDK, sprawdzi ją update-nexo-sdk.ps1
} elseif ($dbVersion) {
    $targetVersion = Get-ShortVersion $dbVersion
} else {
    $targetVersion = $null
    if ($interactive) {
        try {
            do {
                $answer = (Read-Host (Get-InstallText 'VersionPrompt')).Trim()
                $targetVersion = Get-ShortVersion $answer
                if (-not $targetVersion) { Write-Warning (Get-InstallText 'VersionExample') }
            } while (-not $targetVersion)
        } catch { }
    }
    if (-not $targetVersion) {
        throw (Get-InstallText 'MissingVersion')
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
    if ($LASTEXITCODE -ne 0) { throw (Get-InstallText 'AclFailed' @($configDir, $LASTEXITCODE)) }
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
$sdkUpdate = Get-Field $config 'SdkUpdate'
if (-not $sdkUpdate) { $sdkUpdate = [pscustomobject]@{} }
$sdkUpdate | Add-Member -NotePropertyName 'ServiceName' -NotePropertyValue $ServiceName -Force
$config | Add-Member -NotePropertyName 'SdkUpdate' -NotePropertyValue $sdkUpdate -Force
($config | ConvertTo-Json -Depth 30) | Set-Content -Path $configPath -Encoding UTF8
Write-Host (Get-InstallText 'ConfigSaved' @($configPath))

$legacyConfig = Join-Path $InstallDir $configFileName
if (Test-Path $legacyConfig) {
    Write-Warning (Get-InstallText 'LegacyConfig' @($configFileName, $configPath))
}

$tempDir = Join-Path $env:TEMP ("zapqio-nexo-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempDir | Out-Null
$legacyMoved = $false
$setActivated = $false

try {
    # --- 5. Paczka Nexo.Connection --------------------------------------------------------

    $zipPath = Join-Path $tempDir $moduleZipName
    if ($PackagePath) {
        if (-not (Test-Path $PackagePath)) { throw (Get-InstallText 'MissingPackage' @($PackagePath)) }
        Write-Host (Get-InstallText 'LocalPackage' @($PackagePath))
        Copy-Item -Path $PackagePath -Destination $zipPath
    } else {
        $zipUrl = if ($Version) { "https://github.com/$repo/releases/download/v$($Version -replace '^v', '')/$moduleZipName" }
                  else { "https://github.com/$repo/releases/latest/download/$moduleZipName" }
        Write-Host (Get-InstallText 'Downloading' @($zipUrl))
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        } catch {
            throw (Get-InstallText 'DownloadFailed' @($_.Exception.Message, $repo))
        } finally {
            $ProgressPreference = $oldProgress
        }
    }

    $extractDir = Join-Path $tempDir 'extract'
    Expand-Archive -Path $zipPath -DestinationPath $extractDir
    $moduleDll = Join-Path $extractDir 'Nexo.Connection.dll'
    $updateScriptSource = Join-Path $extractDir $updateScriptName
    if (-not (Test-Path $moduleDll) -or -not (Test-Path $updateScriptSource)) {
        throw (Get-InstallText 'InvalidPackage' @($updateScriptName, $moduleZipName))
    }
    $moduleVersion = (Get-Item $moduleDll).VersionInfo.ProductVersion -replace '\+.*$', ''

    # Stage all update tools. The downloaded runtime ZIP is only an input: the
    # updater rebuilds it against the selected SDK before changing installed files.
    $toolsDir = Join-Path $tempDir 'tools'
    [void][IO.Directory]::CreateDirectory($toolsDir)
    foreach ($helper in 'update-nexo-sdk.ps1', 'build-nexo-set.ps1', 'install-nexo-build.ps1') {
        $localHelper = if ($PSScriptRoot) { Join-Path $PSScriptRoot $helper } else { $null }
        $packedHelper = Join-Path $extractDir $helper
        $helperTarget = Join-Path $toolsDir $helper
        if ($localHelper -and (Test-Path -LiteralPath $localHelper)) { Copy-Item -LiteralPath $localHelper -Destination $helperTarget }
        elseif ((Test-Path -LiteralPath (Join-Path $extractDir 'build-nexo-set.ps1')) -and (Test-Path -LiteralPath $packedHelper)) { Copy-Item -LiteralPath $packedHelper -Destination $helperTarget }
        else { Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$repo/main/$helper" -OutFile $helperTarget -UseBasicParsing }
    }
    $updateScript = Join-Path $toolsDir $updateScriptName

    # Paczka sprzed podziału modułu niesie własny NexoClient i SDK - dwa komplety w Modules\ to konflikt.
    $legacyZip = Join-Path $modulesDir 'Nexo.zip'
    if (Test-Path $legacyZip) {
        if (Test-Path -LiteralPath "$legacyZip.old") { throw "Legacy backup already exists: $legacyZip.old. Move it aside before migrating Nexo.zip." }
        Move-Item -LiteralPath $legacyZip -Destination "$legacyZip.old"
        $legacyMoved = $true
        Write-Warning (Get-InstallText 'LegacyZip')
    }

    # --- 6. SDK InsERT nexo ------------------------------------------------------------------

    $sdkZip = Join-Path $modulesDir $sdkZipName
    $sdkStatePath = Join-Path $InstallDir 'nexo-sdk.json'
    $installedSdk = $null
    if ((Test-Path $sdkZip) -and (Test-Path $sdkStatePath)) {
        try { $installedSdk = [string](Get-Content -Path $sdkStatePath -Raw | ConvertFrom-Json).version } catch { }
    }

    # SDK version alone is not proof of a complete matching Connection build.
    # The updater reuses a validated source/SDK profile when it is already ready.
    & {
        $scriptArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $updateScript,
                        '-RunnerDir', $InstallDir, '-ServiceName', $ServiceName, '-NoRestart', '-ConnectionZip', $zipPath, '-AllowCompatibleLegacyModules')
        if ($ConnectionSource) { $scriptArgs += @('-ConnectionSource', (Resolve-Path -LiteralPath $ConnectionSource).Path) }
        if ($ModulesConfig) { $scriptArgs += @('-ModulesConfig', (Resolve-Path -LiteralPath $ModulesConfig).Path) }
        if ($SdkDir) {
            Write-Host (Get-InstallText 'PackingSdk' @($SdkDir, $sdkZip))
            $scriptArgs += @('-SdkDir', $SdkDir)
        } else {
            Write-Host (Get-InstallText 'DownloadingSdk' @($targetVersion, $sdkZip))
            $scriptArgs += @('-Version', $targetVersion)
        }
        $scriptArgs += @(Get-InstallerLanguageArguments $updateScript)
        & powershell.exe @scriptArgs
        if ($LASTEXITCODE -ne 0) {
            throw (Get-InstallText 'SdkSetupFailed' @($LASTEXITCODE))
        }
    }
    $setActivated = $true
    $installedSdk = [string](Get-Content -Path $sdkStatePath -Raw | ConvertFrom-Json).version
    $updateScript = Join-Path $InstallDir $updateScriptName
    Write-Host (Get-InstallText 'ConnectionInstalled' @($moduleVersion, $modulesDir))
    if ($dbVersion -and $installedSdk -and (Get-ShortVersion $installedSdk) -ne (Get-ShortVersion $dbVersion)) {
        Write-Warning (Get-InstallText 'SdkMismatch' @($installedSdk, $sdkZip, $dbVersion, $updateScript, (Get-ShortVersion $dbVersion), $InstallDir))
    }

    # --- 7. Środowisko budowania modułów -----------------------------------------------------
    $buildScript = Join-Path $toolsDir 'install-nexo-build.ps1'

    $buildArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $buildScript,
                   '-InstallDir', $InstallDir, '-ServiceName', $ServiceName, '-NoRestart')
    # The updater's active profile selects its private package automatically.
    # A public/previous SDK NuGet must never replace the freshly rebuilt variant.

    $buildArgs += @(Get-InstallerLanguageArguments $buildScript)
    & powershell.exe @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw (Get-InstallText 'BuildSetupFailed')
    }

    # --- 8. Restart i sprawdzenie w logu ---------------------------------------------------------

    $methodSeen = $false
    $problems = @()
    if ($NoRestart) {
        Write-Host (Get-InstallText 'NoRestart' @($ServiceName))
    } else {
        # Zapamiętaj, dokąd log sięgał przed restartem - czytamy tylko nowe wpisy
        $preLogFile = $null
        $preLogOffset = 0
        if ($logsDir) {
            $preLogFile = Get-ChildItem -Path $logsDir -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($preLogFile) { $preLogOffset = $preLogFile.Length }
        }

        Write-Host (Get-InstallText 'Restarting' @($ServiceName))
        Restart-Service -Name $ServiceName

        if ($logsDir) {
            Write-Host (Get-InstallText 'WaitingMethod')
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
                Write-Host (Get-InstallText 'MethodReady')
            } else {
                Write-Warning (Get-InstallText 'MethodUnconfirmed' @($logsDir))
            }
            foreach ($p in $problems) { Write-Warning $p }
        } else {
            Write-Host (Get-InstallText 'FileLogsDisabled')
        }
    }

    # --- 9. Podsumowanie ---------------------------------------------------------------------------

    Write-Host ''
    Write-Host (Get-InstallText 'Summary' @($ServiceName, $(if ($service) { " ($((Get-Service -Name $ServiceName).Status))" })))
    Write-Host (Get-InstallText 'SummaryConnection' @($moduleVersion, (Join-Path $modulesDir $moduleZipName)))
    Write-Host (Get-InstallText 'SummarySdk' @($(if ($installedSdk) { $installedSdk } else { '?' }), $sdkZip))
    Write-Host (Get-InstallText 'SummarySubiekt' @($server, $database, $operator, $(if ($integrated) { Get-InstallText 'WindowsAuthentication' } else { $sqlUser })))
    Write-Host (Get-InstallText 'SummaryConfig' @($configPath))
    Write-Host (Get-InstallText 'SummaryUpdate' @($updateScript))
    Write-Host ''
    Write-Host (Get-InstallText 'Verification')
    Write-Host (Get-InstallText 'Troubleshooting')
    Write-Host (Get-InstallText 'InstallingModules' @($modulesDir))
} finally {
    if ($legacyMoved -and -not $setActivated) { Move-Item -LiteralPath "$legacyZip.old" -Destination $legacyZip }
    # Remove-Item wykrzacza się na ścieżkach ze skróconą nazwą 8.3 (np. C:\Users\UKASZ~1),
    # a taką potrafi mieć %TEMP% - .NET usuwa je bez problemu
    try { [IO.Directory]::Delete($tempDir, $true) } catch {}
}
