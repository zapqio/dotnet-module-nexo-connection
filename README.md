# Zapqio Runner - moduł Nexo.Connection

Moduł współdzielony dla [Zapqio Runner](https://github.com/zapqio/dotnet-runner): jedno połączenie
z InsERT nexo (Subiekt) przez Sferę, wspólne dla wszystkich modułów Nexo na runnerze. Zawiera:

- `Nexo.NexoClient` - singleton z uchwytem Sfery (`Uchwyt`), wstrzykiwany do metod innych modułów,
- `Nexo.ConnectionSettings` - dane połączenia z `Config\nexoModule.json`,
- metodę **„Nexo: Who am I”** - sprawdzenie instalacji,
- paczkę NuGet `Zapqio.Nexo.Connection` do kompilacji własnych modułów.

W `Modules\` runnera leżą trzy rodzaje paczek:

| Paczka | Zawartość | Skąd |
|---|---|---|
| `Nexo.Sdk.zip` | SDK InsERT nexo w wersji Subiekta | tworzy ją `update-nexo-sdk.ps1` |
| `Nexo.Connection.zip` | `NexoClient`, „Nexo: Who am I”, źródła do przebudowy i skrypty | przebudowa wybranego [wydania](https://github.com/zapqio/dotnet-module-nexo-connection/releases) pod SDK klienta |
| `Nexo.Invoices.zip`, ... | metody | repozytoria modułów |

SDK jest w osobnej paczce, ale zmiana SDK wymaga przebudowy Connection. Skrypty robią to automatycznie,
zachowując numer pakietu Connection i wpisy `PackageReference`. Moduły ze zgodnymi referencjami mogą
pozostać bez zmian; te z niezgodnymi zależnościami wymagają przebudowy. Przykładowo
SDK 61 i 62 mają różne `PublicKeyToken` bibliotek InsERT mimo jednakowego `AssemblyVersion=1.0.0.0`.
Sama podmiana `Nexo.Sdk.zip` może więc zakończyć się `FileLoadException (0x80131040)`.
Paczka SDK i paczka z `NexoClient` mają być dokładnie po jednej; instalator przenosi stary `Nexo.zip`
do `Nexo.zip.old` (przy nieudanej aktywacji przywraca go).

## Instalacja na runnerze

Wymagania:

- [Zapqio Runner](https://github.com/zapqio/dotnet-runner) w wariancie .NET 8 (domyślnym w jego
  `install.ps1`) - biblioteki InsERT nie ładują się na .NET 9+,
- PowerShell uruchomiony jako administrator,
- dostęp do GitHuba (skrypty, paczka), `ftp.insertcdn.pl` (SDK, ok. 500 MB), nuget.org (zależności
  budowania) i serwerów Microsoft (instalator SDK .NET, jeśli potrzebny).

```powershell
$s = irm https://raw.githubusercontent.com/zapqio/dotnet-module-nexo-connection/main/install-nexo.ps1
& ([scriptblock]::Create($s.TrimStart([char]0xFEFF)))
```

Na początku wybierz język komunikatów i pytań: **Polski (`pl`)**, **English (`en`)** albo
**Deutsch (`de`)**. Enter zatwierdza język systemu; dla systemów w innych językach domyślny jest
angielski. Bez interaktywnej konsoli skrypt używa tej samej wartości domyślnej.
Parametr `-Language` pomija pytanie o język, np.:

```powershell
& ([scriptblock]::Create($s.TrimStart([char]0xFEFF))) -Language de
```

Wybór obejmuje także przygotowanie SDK i środowiska budowania. Skrypty `install-nexo-build.ps1`
i `update-nexo-sdk.ps1` można też uruchamiać osobno z `-Language pl|en|de`; bez parametru używają
polskiego. Instalator dostarcza też `build-nexo-set.ps1`; diagnostyka tego narzędzia jest po angielsku.
Komunikaty narzędzi zewnętrznych (PowerShell, SQL, .NET) i odczytane logi runnera zachowują swój język.

Skrypt:

1. pyta o dane połączenia (serwer SQL, logowanie SQL albo Windows, baza podmiotu - podpowiada listę
   baz z serwera, operator Subiekta i jego hasło), sprawdza połączenie z SQL i odczytuje z bazy wersję
   Subiekta,
2. zapisuje sekcję `Connect` oraz `SdkUpdate.ServiceName` w `Config\nexoModule.json` (pozostałe klucze zostają),
3. pobiera wybrane wydanie `Nexo.Connection.zip` i SDK w wersji Subiekta,
4. buduje oraz sprawdza Connection, lokalny NuGet i zarejestrowane moduły, następnie aktywuje cały zestaw,
5. zawsze przygotowuje budowanie modułów na runnerze (patrz [Budowanie na runnerze](#budowanie-na-runnerze)),
6. restartuje usługę i czeka do 60 s, aż w logu pojawi się `Add method: Nexo.WhoAmI`.

Ponowne uruchomienie aktualizuje instalację: dane połączenia zostają (skrypt pyta tylko o brakujące),
Connection aktualizuje się do wybranego wydania (domyślnie najnowszego). Gotowy zestaw tych samych
źródeł, SDK i narzędzi jest używany ponownie. Aktywny zestaw wskazuje `nexo-build.json`, wersję SDK
pamięta również `nexo-sdk.json` w katalogu runnera.

Bez pytań, wszystko z parametrów:

```powershell
& ([scriptblock]::Create($s.TrimStart([char]0xFEFF))) -Language pl -DatabaseServer 'SERWER\INSERTNEXO' -DatabaseName Nexo_Firma `
    -DatabaseUser sa -DatabasePassword '...' -UserName Szef -UserPassword '...'
```

| Parametr | Opis |
|---|---|
| `-Language` | Język komunikatów i pytań: `pl`, `en` albo `de`. Pomija wybór języka na początku. |
| `-DatabaseServer`, `-DatabaseName` | Serwer SQL z instancją (np. `SERWER\INSERTNEXO`) i baza podmiotu. |
| `-DatabaseUser`, `-DatabasePassword` | Logowanie do SQL użytkownikiem SQL. |
| `-WindowsLogin` | Logowanie do SQL kontem Windows. Łączy się **konto usługi runnera**, a test w skrypcie robi konto administratora, więc nie potwierdza dostępu usługi. Zwykle wymaga przełączenia usługi na konto domenowe z prawami do bazy. |
| `-UserName`, `-UserPassword` | Operator Subiekta, na którego loguje się Sfera; hasło może być puste. |
| `-SubiektVersion` | Wersja z „Pomoc > O programie” (np. `61.1.1`) zamiast odczytu z bazy. |
| `-SdkDir` | Gotowy katalog `Bin` rozpakowanego SDK zamiast pobierania z FTP. |
| `-PackagePath` | Lokalny `Nexo.Connection.zip` zamiast pobierania z GitHuba. Zależności budowania są nadal pobierane z nuget.org. |
| `-Version` | Konkretny release modułu, np. `1.1.4`; domyślnie najnowszy. |
| `-ConnectionSource` | Katalog lub ZIP źródeł wybranej wersji Connection; opcjonalny przy migracji starszego wydania. |
| `-ModulesConfig` | Rejestr źródeł modułów; domyślnie `Config\nexo-build-sources.json`. |
| `-InstallDir`, `-ServiceName` | Katalog i usługa runnera; domyślnie `C:\zapqio\runner` i `ZapqioRunner`. |
| `-NoRestart` | Bez restartu usługi na końcu. |

### Sprawdzenie

W panelu Web uruchom **„Nexo: Who am I”** - zwraca sygnaturę operatora, wersję SDK i nazwę paczki SDK.

| Objaw | Przyczyna |
|---|---|
| Brak metody „Nexo: Who am I” | Brak `Nexo.Connection.zip` albo `Nexo.Sdk.zip` w `Modules\`; w logu runnera `Metoda ... nie została utworzona`. |
| `Brak konfiguracji połączenia z Nexo: ...` | Pusta sekcja `Connect` - uzupełnij ją i zrestartuj usługę. |
| `SDK ... nie połączył się z Subiektem: ... Wersja bazy danych to X ...` | SDK w innej wersji niż Subiekt - patrz [Aktualizacja Subiekta](#aktualizacja-subiekta). |
| `SDK ... nie połączył się z Subiektem: ...` (inna treść) | Złe dane SQL albo serwer niedostępny. |
| `Nexo login failed: operator ...` | Zły operator albo hasło. |
| `FileLoadException`, `manifest definition does not match`, `0x80131040` | Connection lub moduł zbudowany pod inne SDK. Uruchom nowy updater, przebudowujący cały zestaw. |

Paczki z metodami (np. `Nexo.Invoices.zip`) wrzucasz do `Modules\` i restartujesz usługę.

### Konfiguracja

`Config\nexoModule.json` powstaje przy pierwszym starcie runnera z modułem; sekcję `Connect` wypełnia
instalator. Po każdej zmianie zrestartuj usługę.

```json
{
  "Connect": {
    "DatabaseServer": "192.168.1.10\\INSERTNEXO",
    "DatabaseUser": "sa",
    "DatabasePassword": "...",
    "DatabaseName": "Nexo_Firma",
    "UserName": "Szef",
    "UserPassword": "...",
    "WindowsLogin": false
  },
  "SdkUpdate": {
    "Enabled": true,
    "ModulesUrl": null,
    "ServiceName": "ZapqioRunner",
    "Restart": true,
    "RunnerDir": null
  }
}
```

- `Connect` - jak parametry instalatora; przy `WindowsLogin: true` pola `DatabaseUser` i `DatabasePassword`
  są pomijane.
- `SdkUpdate` - automatyczna podmiana SDK, patrz [Aktualizacja Subiekta](#aktualizacja-subiekta).
  Instalator zapisuje przekazane `-ServiceName`, również dla usługi o niestandardowej nazwie.
- Inne moduły Nexo dopisują do pliku własne sekcje przy pierwszym starcie.

Plik zawiera hasła, więc katalog `Config\` ma uprawnienia jak `appsettings.json` runnera (nadaje je
`install.ps1` runnera, a na starszej instalacji `install-nexo.ps1`). Plik `nexoModule.json` obok binarki
(starsze instalacje) moduł przenosi do `Config\`, jeśli tam jeszcze go nie ma.

Połączenie powstaje przy pierwszym użyciu `Uchwyt`; w logu zadania widać wtedy
`Connecting Nexo (SDK 61.1.1.9471 z paczki Nexo.Sdk)`. Po nieudanej próbie kolejne zadanie łączy się od nowa.

### Instalacja ręczna

1. Umieść wybrane wydanie `Nexo.Connection.zip` w `Modules\`. Skrypty `update-nexo-sdk.ps1`,
   `build-nexo-set.ps1` i `install-nexo-build.ps1` muszą leżeć razem, np. w katalogu repozytorium.
   Źródła własnych modułów rejestruj tylko wtedy, gdy mają być lokalnie przebudowywane.
2. Jako administrator uruchom updater z wersją z „Pomoc > O programie”:

   ```powershell
   .\update-nexo-sdk.ps1 -Version 62.0.0.9537 -NoRestart
   ```

   Skrypt pobiera `nexoSDK_62_0_0.exe` z FTP InsERT, buduje i aktywuje cały zestaw. Masz rozpakowane
   SDK: `-SdkDir C:\nexoSDK_62.0.0.9537\Bin` zamiast `-Version`. Runner w innym katalogu:
   dodaj `-RunnerDir <katalog>`. Nie nadpisuj potem Connection publicznym ZIP-em sprzed przebudowy.
3. Zrestartuj usługę. W logu: `Moduł współdzielony: Nexo.Sdk`, `Moduł współdzielony: Nexo.Connection`,
   `Add injection: Nexo.NexoClient`, `Add method: Nexo.WhoAmI`.
4. Uzupełnij sekcję `Connect` w utworzonym `Config\nexoModule.json` i zrestartuj usługę ponownie.

## Aktualizacja Subiekta

Sfera wymaga SDK w tej samej wersji co Subiekt. Po aktualizacji Subiekta pierwsze zadanie Nexo kończy
się błędem `... Wersja bazy danych to X ...`, a `NexoClient` uruchamia w tle `update-nexo-sdk.ps1 -Version X`.
Skrypt pobiera SDK z FTP InsERT i przygotowuje spójny zestaw: SDK, Connection, lokalny NuGet oraz
zależne moduły ze źródeł zawartych w ich paczkach. Dopiero po kompilacji i sprawdzeniu referencji podmienia pliki
i restartuje usługę. Zadania przerwane restartem trzeba ponowić z panelu.

- Przebieg jest w `Logs\nexo-sdk-update.log`, stan w `nexo-sdk-update.json` w katalogu runnera.
- Kolejne padające zadania nie uruchamiają drugiej podmiany. Nieudana próba dla tej samej wersji jest
  ponawiana najwcześniej po godzinie.
- Skrypt działa na koncie usługi: potrzebuje .NET SDK 8+, dostępu do źródeł przebudowywanych modułów, nuget.org,
  `ftp.insertcdn.pl` i miejsca na dysku. Pobrane i rozpakowane SDK zajmuje ponad 1,5 GB; dodatkowo
  zachowywane są zestawy w `Build\NexoSets` i kopie poprzedniej instalacji w `Build\NexoTransactions`.
- Restart wymaga, żeby konto usługi miało prawo start/stop na własnej usłudze (nadaje je `install.ps1`
  runnera od wersji 0.1.9). Bez niego skrypt kończy proces runnera, a usługa wstaje z opcji odzyskiwania
  po 5 s.

Ustawienia w sekcji `SdkUpdate`:

- `Enabled: false` - bez automatu; błąd zadania podaje polecenie do uruchomienia ręcznie,
- `Restart: false` - skrypt aktywuje zestaw plików, restart robisz sam,
- `ServiceName` - usługa do restartu,
- `RunnerDir` - katalog runnera; `null` = katalog binarki,
- `ModulesUrl` - pozostaw `null`; stare zestawy samych ZIP-ów nie są już obsługiwane.

Ręcznie, jako administrator:

```powershell
.\update-nexo-sdk.ps1 -Version 62.0.0.9537 -RunnerDir 'C:\zapqio\runner'
```

Ten sam mechanizm obsługuje kolejne wersje, np. 63 i 64: nie ma listy dozwolonych wersji SDK ani
potrzeby podbijania Connection z powodu zmiany SDK. Jeśli InsERT zmieni używane API, kompilacja
zgłosi błąd, a dotychczasowy zestaw pozostanie zainstalowany.

Automatyczne wykrywanie w `NexoClient` pozostaje bez zmian. `FileLoadException` występujący jeszcze
przed wejściem do kodu połączenia może nie uruchomić automatu — po wcześniejszej podmianie samych DLL
trzeba raz uruchomić nowy updater ręcznie. To nie jest nowy mechanizm monitorowania wersji bazy.

### Źródła i zestawy do przebudowy

Przy pierwszej migracji uruchom nowy `install-nexo.ps1`, który instaluje trzy współpracujące skrypty.
Connection pobiera własne źródła z `nexo-source.zip` zawartego w paczce. Dla starego wydania może
jednorazowo pobrać źródła z GitHuba według pełnego commita zapisanego w DLL. Jeśli brak obu danych,
podaj `-ConnectionSource <katalog lub ZIP>` z tą samą wersją projektu. Nie pobiera bieżącego `main`
jako zamiennika kodu starszego Connection. Po przebudowie ZIP niesie już źródła do kolejnych aktualizacji.

**Migracja jednorazowa:** zainstaluj nowe skrypty i Connection 1.1.4, ustaw w modułach
`Zapqio.Nexo.Connection` 1.1.4 i ponownie wdróż je przez panel. Target NuGet dodaje do wyniku
`dotnet publish` pliki `nexo-module-source.zip` i `nexo-module-source.json`. Paczka wdrożeniowa
musi zachować te pliki. Nie trzeba rejestrować źródeł modułów z panelu ani zmieniać wersji NuGet
przy kolejnych SDK 63, 64 itd., o ile kod nadal się kompiluje i działa z danym SDK.

Pierwszy `install-nexo.ps1` może pozostawić stare moduły bez źródeł, **wyłącznie jeśli ich
referencje są zgodne z instalowanym zestawem**. Pozwala to najpierw przygotować prywatny NuGet 1.1.4
dla aktualnego SDK, a następnie wdrożyć moduły z panelu. Jeśli stare DLL są już niezgodne z SDK,
najpierw przebuduj i wdróż je przez panel/CI; instalator nadal blokuje taki niezgodny zestaw.
Automatyczne aktualizacje wymagają źródeł — wyjątek migracyjny instalatora nie jest domyślnym trybem
`update-nexo-sdk.ps1` (`-AllowCompatibleLegacyModules` włącza go jawnie).

Updater skanuje referencje DLL w zainstalowanych ZIP-ach. Moduły używające Connection lub InsERT
przebudowuje ze źródeł dołączonych do tej konkretnej paczki, bez pobierania nowszego commita.
Brak lub uszkodzenie źródeł zgłasza dla wszystkich znalezionych modułów przed pobraniem SDK.
Moduły niezwiązane z nexo pozostają bez zmian. Samo DLL pozwala wykryć zależność, ale nie zastępuje
projektu źródłowego potrzebnego do kompilacji.

Archiwum obejmuje pliki projektu, zadeklarowany kod i zasoby, `ProjectReference` oraz własne importy
MSBuild. Dodatkowe wejścia budowania można wskazać przez `<NexoSourceInclude Include="ścieżka" />`.
Nie obejmuje bin/obj, konfiguracji runnera, NuGet.Config, appsettings, .env ani kluczy prywatnych.
Projekt musi odtwarzać swoje pliki generowane; nietypowe narzędzia i prywatne zależności wymagają
konfiguracji środowiska budowania. Nie umieszczaj sekretów w plikach źródłowych ani zasobach.

Dla modułów instalowanych lokalnie nadal można jawnie wskazać źródła w
`Config\nexo-build-sources.json`:

```json
{
  "modules": [
    {
      "packageName": "Nexo.Invoices",
      "sourcePath": "D:\\zapqio-sources\\nexo-invoices",
      "project": "Nexo.Invoices.csproj"
    }
  ]
}
```

`packageName` to nazwa ZIP-a bez rozszerzenia. `sourcePath` wskazuje katalog lub ZIP ze źródłami;
ścieżki względne liczone są od pliku konfiguracji. `project` jest ścieżką `.csproj` względem korzenia
tych źródeł. Zamiast `sourcePath` można podać `sourceUrl` (HTTPS) i obowiązkowe `sha256` archiwum.
Opcjonalna sekcja `connection` ma taki sam format źródła. Konto usługi musi móc odczytać te dane.
Źródła powinny być samodzielne, wraz z używanymi `ProjectReference` i konfiguracją budowania.
Nie rejestruj źródeł z hasłami: są kopiowane do profilu budowania.

Updater sprawdza także już zainstalowane ZIP-y. Niezgodna referencja (np. zmieniony klucz podpisu
InsERT) albo prywatna kopia Connection/SDK w module zatrzymuje aktywację z nazwą modułu i przyczyną.
Taki moduł wymaga poprawienia paczki lub przebudowy pod docelowe SDK. Stare `-ModulesUrl` i
`-ModulesPath` zgłaszają błąd zamiast zostawiać niezgodne moduły po aktualizacji SDK.

Samo przygotowanie, bez zmiany zainstalowanych plików i bez restartu:

```powershell
.\update-nexo-sdk.ps1 -Version 62.0.0.9537 -RunnerDir 'C:\zapqio\runner' -PrepareOnly
# albo z gotowym SDK, bez pobierania:
.\build-nexo-set.ps1 -SdkDir 'C:\nexoSDK_62.0.0.9537\Bin' -RunnerDir 'C:\zapqio\runner'
```

Wynik znajduje się w `Build\NexoSets\<hash>\`: manifest `nexo-set.json`, ZIP-y w `Modules`, prywatny
NuGet w `Feed`, cache w `Packages`, SDK w `Sdk\Bin` i logi kompilacji przy źródłach. Hash uwzględnia
zawartość SDK, źródła oraz narzędzia; ponowne uruchomienie sprawdza sumy i używa gotowego zestawu.
Prywatny NuGet zachowuje wersję Connection, ale nigdy nie trafia ponownie na nuget.org.

Aktywacja zapisuje kopie i dziennik `Build\nexo-update-journal.json`. Błąd podmiany przywraca poprzednie
ZIP-y, konfigurację budowania i skrypty; przerwaną podmianę odzyskuje kolejne uruchomienie updatera.
Restart następuje po zatwierdzeniu zestawu. Nieudany restart pozostawia spójny nowy zestaw na dysku
i zgłasza błąd. `-NoRestart` wymaga późniejszego restartu, aby proces wczytał nowe biblioteki.

Moduły z panelu są przebudowywane wyłącznie z zatwierdzonych, zainstalowanych źródeł w ich ZIP-ach.
Pod blokadą `Deployments\state.lock` skrypt sprawdza, czy podczas kompilacji panel nie wdrożył
innej wersji. Następnie podmienia kompletny zestaw i aktualizuje tylko `installed[].zipSha256`
w `Deployments\state.json`. Identyfikatory wdrożeń, commity, manifesty źródeł i raporty zostają
zachowane. Wycofanie aktualizacji przywraca również te sumy, bez cofania pozostałych danych panelu.
Równoległa zmiana wdrożenia zatrzymuje aktywację i wymaga ponowienia. Runner i Web nie wymagają
zmian kodu. Nie powstaje osobne wdrożenie w historii panelu dla lokalnej zmiany SDK.

## Własny moduł na Nexo.Connection

Wymagania: .NET SDK 8 i SDK InsERT nexo do kompilacji (domyślnie w `C:\nexoSDK_61.1.0.9431\Bin\`).
Paczki `Zapqio.Runner.Module.Core` i `Zapqio.Nexo.Connection` są na nuget.org.
Wzorzec: [dotnet-module-nexo-test](https://github.com/zapqio/dotnet-module-nexo-test).

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0-windows</TargetFramework>
    <UseWPF>true</UseWPF>
    <PlatformTarget>x64</PlatformTarget>
    <AppendTargetFrameworkToOutputPath>false</AppendTargetFrameworkToOutputPath>
    <AppendRuntimeIdentifierToOutputPath>false</AppendRuntimeIdentifierToOutputPath>
  </PropertyGroup>
  <ItemGroup>
    <!-- Obie paczki tylko do kompilacji: w runtime kontrakt dostarcza runner, NexoClient przychodzi
         z zipa Nexo.Connection, SDK z zipa Nexo.Sdk. Do zipa tego modułu trafia tylko jego własna DLL. -->
    <PackageReference Include="Zapqio.Runner.Module.Core" Version="1.2.0" ExcludeAssets="runtime" />
    <PackageReference Include="Zapqio.Nexo.Connection" Version="1.1.4" ExcludeAssets="runtime" />
  </ItemGroup>
  <Target Name="ZipAfterPublish" AfterTargets="Publish">
    <PropertyGroup>
      <ZipFilePath>$(PublishDir)..\$(MSBuildProjectName).zip</ZipFilePath>
    </PropertyGroup>
    <WriteLinesToFile File="$(PublishDir)##Dll" Lines="$(TargetFileName)" Overwrite="true" />
    <Delete Files="$(ZipFilePath)" Condition="Exists('$(ZipFilePath)')" />
    <ZipDirectory SourceDirectory="$(PublishDir)" DestinationFile="$(ZipFilePath)" />
  </Target>
</Project>
```

Metoda dostaje klienta przez konstruktor:

```csharp
using System;
using System.Threading.Tasks;
using InsERT.Moria.Uzytkownicy;
using Nexo;
using Zapqio.Runner.Core;

public class MyMethod : IRunnerMethod
{
    private readonly NexoClient _client;

    public MyMethod(NexoClient client) => _client = client;

    public string NameMethod() => "My method";
    public Type InData() => null;
    public Type OutData() => null;

    public Task<string> Run(string data)
    {
        // Jedno połączenie na proces, współdzielone przez wszystkie metody i równoległe zadania.
        var user = _client.Uchwyt.PodajObiektTypu<IZalogowanyUzytkownik>().Dane;
        return Task.FromResult(user.Sygnatura);
    }
}
```

`NexoClient` udostępnia też `SdkVersion` i `SdkPackage` (wersja i paczka SDK na runnerze). Brak
konfiguracji i błąd połączenia kończą się `NexoConnectionException` (przy błędzie połączenia wyjątek
Sfery jest w `InnerException`), a nieudane logowanie operatora - zwykłym `Exception`.

`dotnet publish -c Release` daje `bin\Release\<projekt>.zip` do wrzucenia do `Modules\`. Bez
`Nexo.Connection.zip` lub `Nexo.Sdk.zip` w `Modules\` metody modułu nie powstaną (w logu
`Metoda ... nie została utworzona`), a pozostałe moduły działają. Zasady paczek współdzielonych:
[docs/moduly.md](https://github.com/zapqio/dotnet-runner/blob/main/docs/moduly.md#moduły-współdzielone) runnera.

### SDK do kompilacji

Paczka NuGet nie zawiera bibliotek InsERT, tylko referencje do nich z `Private="false"` (nie trafiają
do zipa modułu): `InsERT.Moria.API`, `InsERT.Moria.DaneDomyslne`, `InsERT.Moria.ModelDanych`,
`InsERT.Moria.Sfera`, `InsERT.Mox.Core`, `InsERT.Mox.DataExtensions`, `InsERT.Mox.EntityFramework.Core`,
`InsERT.Mox.EntityFrameworkSupport`. Inną bibliotekę z SDK dodaj własnym `<Reference>` z `HintPath`
do katalogu SDK i `Private="false"` - w runtime dostarcza ją `Nexo.Sdk.zip`.

Katalog SDK ustawiasz w `.csproj`, `Directory.Build.props` albo przez `-p:`:

- bez ustawień: `C:\nexoSDK_61.1.0.9431\Bin\`,
- `NexoSdkVersion`: `C:\nexoSDK_<wersja>\Bin\`,
- `nexoSdkBinPath`: dowolny katalog `Bin`; ma pierwszeństwo, końcowy ukośnik jest opcjonalny.

```xml
<PropertyGroup>
  <NexoSdkVersion>61.1.1.9471</NexoSdkVersion>
  <!-- albo cała ścieżka -->
  <nexoSdkBinPath>D:\sdk\nexo\Bin\</nexoSdkBinPath>
</PropertyGroup>
```

Brak biblioteki SDK kończy build błędem `ZNEXO001` ze ścieżką brakującego pliku; restore NuGet nie
pobiera SDK. `NexoSdkCopyLocal=true` kopiuje biblioteki SDK do katalogu wyjściowego; paczka do
`Modules\` ma zostać przy domyślnym `false`.

### Własne ustawienia w nexoModule.json

Moduł Nexo może trzymać ustawienia w tym samym pliku. Klasa z publicznym konstruktorem bez parametrów
woła w nim `NexoConfig.Populate(this)`: brakujące klucze są dopisywane do pliku z wartości domyślnych,
a obiekt wypełniany z pliku. Właściwości klasy to sekcje pliku - nazwij je inaczej niż `Connect`
i `SdkUpdate`. Dzięki `IRunnerInjection` runner wstrzykuje ustawienia do metod przez konstruktor.

```csharp
using Nexo;
using Zapqio.Runner.Core;

public class InvoiceSettings : IRunnerInjection
{
    public InvoiceSettings() => NexoConfig.Populate(this);

    public InvoiceOptions Invoices { get; set; } = new();

    public class InvoiceOptions
    {
        public string Warehouse { get; set; } = "MAG";
    }
}
```

## Wdrożenia modułów z Weba

Tryb budowania (na runnerze albo w CI) wybiera się w Webie osobno dla każdego repozytorium; na jednym
runnerze mogą działać moduły z obu trybów. W obu przypadkach Connection, SDK i dane połączenia instaluje
`install-nexo.ps1`. Ogólne zasady: [docs/wdrozenia.md](https://github.com/zapqio/dotnet-runner/blob/main/docs/wdrozenia.md) runnera.

### Budowanie na runnerze

`install-nexo.ps1` zawsze przygotowuje środowisko budowania, także przy ponownym uruchomieniu.
Na już skonfigurowanym runnerze można odświeżyć samo środowisko poniższym skryptem
(PowerShell jako administrator; nie pyta o SQL):

```powershell
& 'C:\zapqio\runner\install-nexo-build.ps1' -InstallDir 'C:\zapqio\runner' -ServiceName 'ZapqioRunner'
```

Skrypt:

- odczytuje aktywny profil z `nexo-build.json`, używa jego prywatnego `Zapqio.Nexo.Connection`
  i sprawdza zgodność DLL z zainstalowanym ZIP-em; pozostałe zależności pobiera z nuget.org,
- wpisuje SDK profilu jako `nexoSdkBinPath` do `Deployments\Directory.Build.props`,
- zapisuje `Deployments\NuGet.Config` ze źródłem prywatnym, mapowaniem pakietu Connection i nuget.org;
  `RestorePackagesPath` wskazuje cache konkretnego profilu, również przy starym `NUGET_PACKAGES` usługi,
- instaluje systemowe .NET SDK 8 x64, jeśli nie ma .NET SDK 8 lub nowszego,
- daje kontu usługi prawo zapisu do `Build\` i `Deployments\` i ustawia w jej środowisku `PATH`,
  `DOTNET_CLI_HOME` i `NUGET_PACKAGES`,
- kompiluje próbny moduł i restartuje usługę (chyba że podano `-NoRestart`).

Profile `Build\NexoSets\` i cache NuGet pozostają na dysku do kolejnych kompilacji i aktualizacji.
Nie usuwaj profilu wskazanego w `nexo-build.json` ani plików potrzebnych do odzyskania transakcji.

Próbna kompilacja działa na koncie administratora; ścieżkę na koncie usługi sprawdza dopiero pierwsze
wdrożenie z Weba.

Do zmiany SDK używaj `update-nexo-sdk.ps1`; samo `install-nexo-build.ps1` nie przebudowuje Connection.
Repozytorium z własnym `Directory.Build.props` musi importować plik nadrzędny albo ustawić zarówno
`nexoSdkBinPath`, jak i `RestorePackagesPath`. Własny `NuGet.Config` musi zachować źródło wariantu
i mapowanie `Zapqio.Nexo.Connection`; sam publiczny pakiet o tym samym numerze nie jest zamiennikiem.

Starsza instalacja bez `nexo-build.json` nadal używa publicznego NuGet o wersji i DLL zgodnych z ZIP-em,
`Build\NexoSdk\<hash>\Bin` oraz `Build\Packages`. To tryb zgodności; migrację wykonuje nowy instalator.

`-ConnectionPackagePath <plik.nupkg>` używa lokalnie zbudowanego Connection (DLL musi być ta sama co
w zainstalowanym zipie). Ta jedna paczka idzie z osobnego źródła i cache w `Build\LocalConnection\<hash>`,
pozostałe nadal z nuget.org. Ten parametr pozostaje w `install-nexo-build.ps1`; główny `install-nexo.ps1`
go odrzuca, ponieważ sam buduje właściwy pakiet.

### Gotowa paczka z CI

Na serwerze uruchom `install-nexo.ps1`; środowisko budowania jest przygotowywane również przy korzystaniu
z paczek z CI. Moduł buduje workflow repozytorium w GitHub Actions, a Web pobiera z udanego przebiegu
dla wybranego commita artefakt `zapqio-module` z plikiem
`module.zip`. Zip z GitHub Releases go nie zastępuje. Wzorcowy workflow:
[dotnet-module-nexo-test/.github/workflows/build.yml](https://github.com/zapqio/dotnet-module-nexo-test/blob/main/.github/workflows/build.yml).

CI także musi użyć SDK i prywatnego wariantu Connection odpowiadających serwerowi. Publiczny NuGet
oraz samo przestawienie `nexoSdkBinPath` konsumenta nie przebudują DLL Connection. Przygotowany zestaw
udostępnia `Feed`, `NuGet.Config`, `Sdk\Bin` i ZIP-y; ścieżki konfiguracji trzeba dostosować na maszynie CI.

## Budowanie i wydania

Build tego repo wymaga SDK InsERT w `C:\nexoSDK_61.1.0.9431\Bin\` (albo `-p:nexoSdkBinPath=...`).
`dotnet publish -c Release` daje w `bin\Release\`:

- `Nexo.Connection.zip` - paczka dla runnera: `Nexo.Connection.dll`, trzy skrypty aktualizacji/budowania,
  `nexo-source.zip`, `LICENSE`, `##Dll`, `##Shared`, bez SDK,
- `Zapqio.Nexo.Connection.<wersja>.nupkg` - paczka NuGet dla modułów (opis na nuget.org to `NUGET.md`).

Wydanie:

1. Podbij `<Version>` w `Nexo.Connection.csproj` i wypchnij na `main`.
2. `.github/workflows/release.yml` pobiera SDK z FTP InsERT (wersja z `build/Zapqio.Nexo.Connection.props`,
   trzymana w cache GitHuba), buduje, uruchamia `tests/Test-NuGetPackage.ps1` i publikuje release
   `v<Version>` z obiema paczkami. Push bez zmiany `Version` niczego nie wydaje.
3. Pobierz `.nupkg` z release'u i wgraj go ręcznie na nuget.org (strona Upload). Zip i `.nupkg` muszą
   pochodzić z tego samego builda - `install-nexo-build.ps1` porównuje ich DLL.

Najnowszy zip jest zawsze pod
`https://github.com/zapqio/dotnet-module-nexo-connection/releases/latest/download/Nexo.Connection.zip`.

`Version` identyfikuje wydanie kodu/API Connection. `AssemblyVersion` zostaje `1.0.0.0`, dopóki zmiana
nie łamie API. Zmiana samego SDK nie wymaga nowego numeru pakietu, ale wymaga zgodnych referencji
InsERT w Connection i konsumentach. Dlatego warianty SDK o tym samym numerze są rozdzielone
prywatnymi źródłami i cache; nie są kolejnymi publicznymi wydaniami tego samego numeru NuGet.

### Testy

Języki instalatora (Windows PowerShell 5.1, bez sieci, bazy i zmian w działającym runnerze):

```powershell
.\tests\Test-InstallerLanguage.ps1
```

Sprawdza kompletność tłumaczeń, formatowanie parametrów, menu wyboru języka, pracę bez konsoli,
przekazywanie języka do skryptów pomocniczych i komunikaty każdego skryptu w trzech językach.
Workflow wydania uruchamia ten test przy każdym pushu na `main`, także bez zmiany wersji paczki.

Odzyskiwanie przerwanej aktualizacji, kontrola ścieżek i integralności kopii (offline, tylko TEMP):

```powershell
.\tests\Test-NexoSetSafety.ps1
```

Walidacja referencji, wykrywanie źródeł modułów, zgłaszanie wszystkich brakujących archiwów,
odrzucanie uszkodzonych źródeł i zmian wdrożenia podczas aktualizacji (offline, tylko TEMP):

```powershell
.\tests\Test-NexoInstalledConsumers.ps1
```

Pełna przebudowa Connection i dwóch modułów zarządzanych przez Web, z niezmienionym
`PackageReference`, izolacją cache, aktywacją, zachowaniem tożsamości wdrożeń, ponownym użyciem
zestawu i obsługą błędu kompilacji (bez prawdziwej usługi i SQL):

```powershell
.\tests\Test-NexoSdkRebuild.ps1 -SdkDir 'C:\nexoSDK_62.0.0.9537\Bin' `
    -ConnectionDll 'bin\Release\Nexo.Connection.dll' -PreviousSdkDir 'C:\nexoSDK_61.1.0.9431\Bin'
```

DLL wejściowa musi mieć tę samą wersję, co bieżące źródła. `-PreviousSdkDir` jest opcjonalne.
`tests/Test-NexoBinding.ps1 -ConnectionDll <DLL> -SdkDir <Bin> -CoreDll <DLL Core>` sprawdza JIT
`WhoAmI.Run` na .NET 8 bez logowania do SQL. Testy nie potwierdzają logowania ani restartu rzeczywistej usługi.

Paczki (to samo robi workflow wydania; wymaga .NET SDK i nuget.org):

```powershell
.\tests\Test-NuGetPackage.ps1 -PackagePath bin\Release\Zapqio.Nexo.Connection.1.1.4.nupkg `
    -RuntimeZipPath bin\Release\Nexo.Connection.zip -SdkBinPath C:\nexoSDK_61.1.0.9431\Bin
```

`-CorePackagePath <plik.nupkg>` bierze Core z pliku zamiast z nuget.org.

Instalator budowania (izolowany katalog tymczasowy, bez usługi i bazy; wymaga .NET SDK 8+ i nuget.org,
a ZIP Connection musi odpowiadać paczce na nuget.org):

```powershell
.\tests\Test-BuildSetup.ps1 -ConnectionZip 'C:\pakiety\Nexo.Connection.zip' -SdkZip 'C:\pakiety\Nexo.Sdk.zip'
```

## Licencja

Kod Zapqio: Apache-2.0 (`LICENSE`). Oprogramowanie i SDK InsERT podlegają własnym licencjom.
