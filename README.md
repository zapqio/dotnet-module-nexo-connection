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
| `Nexo.Connection.zip` | `NexoClient`, „Nexo: Who am I”, `update-nexo-sdk.ps1` | [Releases](https://github.com/zapqio/dotnet-module-nexo-connection/releases) |
| `Nexo.Invoices.zip`, ... | metody | repozytoria modułów |

SDK jest w osobnej paczce, więc aktualizacja Subiekta nie wymaga przebudowy modułów. Paczka SDK
i paczka z `NexoClient` mają być dokładnie po jednej - stary `Nexo.zip` sprzed podziału zawiera
obie, więc trzeba go usunąć (instalator robi to sam).

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
polskiego. Starsze paczki Connection mogą zawierać skrypt aktualizacji SDK bez obsługi języków.
Wtedy instalator informuje o tym i kontynuuje, a komunikaty tego skryptu pozostają po polsku.
Komunikaty narzędzi zewnętrznych (PowerShell, SQL, .NET) i odczytane logi runnera zachowują swój język.

Skrypt:

1. pyta o dane połączenia (serwer SQL, logowanie SQL albo Windows, baza podmiotu - podpowiada listę
   baz z serwera, operator Subiekta i jego hasło), sprawdza połączenie z SQL i odczytuje z bazy wersję
   Subiekta,
2. zapisuje sekcję `Connect` w `Config\nexoModule.json` (pozostałe klucze pliku zostają),
3. pobiera `Nexo.Connection.zip` do `Modules\` i kopiuje `update-nexo-sdk.ps1` do katalogu runnera,
4. tworzy `Modules\Nexo.Sdk.zip` z SDK w wersji Subiekta,
5. zawsze przygotowuje budowanie modułów na runnerze (patrz [Budowanie na runnerze](#budowanie-na-runnerze)),
6. restartuje usługę i czeka do 60 s, aż w logu pojawi się `Add method: Nexo.WhoAmI`.

Ponowne uruchomienie aktualizuje instalację: dane połączenia zostają (skrypt pyta tylko o brakujące),
zip modułu jest podmieniany na najnowszy, a SDK tylko przy zmianie wersji Subiekta (zainstalowaną
wersję pamięta `nexo-sdk.json` w katalogu runnera). Stary `Nexo.zip` jest przemianowywany na `Nexo.zip.old`.

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
| `-Version` | Konkretny release modułu, np. `1.1.3`; domyślnie najnowszy. |
| `-ConnectionPackagePath` | Lokalny `.nupkg` Connection zamiast pobierania z nuget.org. |
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
  **Usługa o innej nazwie niż `ZapqioRunner`: wpisz ją w `ServiceName`** - instalator tego nie robi,
  a bez tego automat nie zrestartuje runnera.
- Inne moduły Nexo dopisują do pliku własne sekcje przy pierwszym starcie.

Plik zawiera hasła, więc katalog `Config\` ma uprawnienia jak `appsettings.json` runnera (nadaje je
`install.ps1` runnera, a na starszej instalacji `install-nexo.ps1`). Plik `nexoModule.json` obok binarki
(starsze instalacje) moduł przenosi do `Config\`, jeśli tam jeszcze go nie ma.

Połączenie powstaje przy pierwszym użyciu `Uchwyt`; w logu zadania widać wtedy
`Connecting Nexo (SDK 61.1.1.9471 z paczki Nexo.Sdk)`. Po nieudanej próbie kolejne zadanie łączy się od nowa.

### Instalacja ręczna

1. Jako administrator uruchom `update-nexo-sdk.ps1` (z repo albo z `Nexo.Connection.zip`) z wersją
   z „Pomoc > O programie”:

   ```powershell
   .\update-nexo-sdk.ps1 -Version 61.1.1 -NoRestart
   ```

   Skrypt pobiera `nexoSDK_61_1_1.exe` z FTP InsERT i tworzy `Modules\Nexo.Sdk.zip`. Masz rozpakowane
   SDK: `-SdkDir C:\nexoSDK_61.1.1.9471\Bin` zamiast `-Version`. Runner w innym katalogu niż
   `C:\zapqio\runner`: dodaj `-RunnerDir <katalog>`.
2. Wrzuć `Nexo.Connection.zip` i paczki z metodami do `Modules\`.
3. Zrestartuj usługę. W logu: `Moduł współdzielony: Nexo.Sdk`, `Moduł współdzielony: Nexo.Connection`,
   `Add injection: Nexo.NexoClient`, `Add method: Nexo.WhoAmI`.
4. Uzupełnij sekcję `Connect` w utworzonym `Config\nexoModule.json` i zrestartuj usługę ponownie.

## Aktualizacja Subiekta

Sfera wymaga SDK w tej samej wersji co Subiekt. Po aktualizacji Subiekta pierwsze zadanie Nexo kończy
się błędem `... Wersja bazy danych to X ...`, a `NexoClient` uruchamia w tle `update-nexo-sdk.ps1 -Version X`.
Skrypt pobiera SDK z FTP InsERT, podmienia `Nexo.Sdk.zip` i restartuje usługę. Po kilku minutach zadania
działają; zadania przerwane restartem trzeba ponowić z panelu.

- Przebieg jest w `Logs\nexo-sdk-update.log`, stan w `nexo-sdk-update.json` w katalogu runnera.
- Kolejne padające zadania nie uruchamiają drugiej podmiany. Nieudana próba dla tej samej wersji jest
  ponawiana najwcześniej po godzinie.
- Skrypt działa na koncie usługi: potrzebuje dostępu do `ftp.insertcdn.pl` i miejsca na dysku
  (pobrane i rozpakowane SDK zajmuje w `.sdk-tmp` ponad 1,5 GB).
- Restart wymaga, żeby konto usługi miało prawo start/stop na własnej usłudze (nadaje je `install.ps1`
  runnera od wersji 0.1.9). Bez niego skrypt kończy proces runnera, a usługa wstaje z opcji odzyskiwania
  po 5 s.

Ustawienia w sekcji `SdkUpdate`:

- `Enabled: false` - bez automatu; błąd zadania podaje polecenie do uruchomienia ręcznie,
- `Restart: false` - skrypt podmienia zip, restart robisz sam,
- `ServiceName` - usługa do restartu,
- `RunnerDir` - katalog runnera; `null` = katalog binarki,
- `ModulesUrl` - [komplety modułów](#komplety-modułów).

Ręcznie, jako administrator:

```powershell
.\update-nexo-sdk.ps1 -Version <wersja z "O programie"> [-RunnerDir <katalog runnera>]
```

Moduły nie wymagają przebudowy, bo wiążą się z SDK po nazwie zestawu. Programista jest potrzebny tylko
wtedy, gdy InsERT zmienił w SDK składową, z której korzysta moduł - wychodzi to przy kompilacji modułu
przeciw nowemu SDK (`-p:NexoSdkVersion=<wersja>`).

### Komplety modułów

Opcja dla wdrożeń z własnym serwerem modułów zbudowanych pod daną wersję SDK. `ModulesUrl` to adres
z `{version}` (wersja trzyczłonowa, np. `61.1.1`), np. `https://serwer.firma.pl/zapqio/sdk-{version}`.
Pod nim leży `manifest.json`:

```json
{
  "built": "2026-10-01",
  "testedLive": true,
  "modules": [
    { "name": "Nexo.Invoices.zip", "sha256": "..." }
  ]
}
```

Po podmianie SDK skrypt pobiera z listy tylko zipy, które już są w `Modules\`, i sprawdza `sha256`
(jeśli podane); `built` i `testedLive` trafiają tylko do logu. Gdy kompletu dla nowej wersji nie ma,
obecne moduły zostają z ostrzeżeniem. Przy ręcznym uruchomieniu zamiast adresu można podać katalog
albo udział: `-ModulesPath \\serwer\zapqio\sdk-{version}`.

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
    <PackageReference Include="Zapqio.Nexo.Connection" Version="1.1.3" ExcludeAssets="runtime" />
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
$s = irm https://raw.githubusercontent.com/zapqio/dotnet-module-nexo-connection/main/install-nexo-build.ps1
& ([scriptblock]::Create($s.TrimStart([char]0xFEFF))) -InstallDir 'C:\zapqio\runner' -ServiceName 'ZapqioRunner'
```

Skrypt:

- pobiera z nuget.org `Zapqio.Nexo.Connection` w wersji zainstalowanego zipa (sprawdza, że DLL jest ta sama)
  i `Zapqio.Runner.Module.Core 1.2.0`,
- rozpakowuje biblioteki z `Modules\Nexo.Sdk.zip` do `Build\NexoSdk\<hash paczki>\Bin` i wpisuje tę ścieżkę jako
  `nexoSdkBinPath` do `Deployments\Directory.Build.props`,
- zapisuje `Deployments\NuGet.Config` (tylko nuget.org, cache w `Build\Packages`),
- instaluje systemowe .NET SDK 8 x64, jeśli nie ma .NET SDK 8 lub nowszego,
- daje kontu usługi prawo zapisu do `Build\` i `Deployments\` i ustawia w jej środowisku `PATH`,
  `DOTNET_CLI_HOME` i `NUGET_PACKAGES`,
- kompiluje próbny moduł i restartuje usługę (chyba że podano `-NoRestart`).

Biblioteki w `Build\NexoSdk\` i cache NuGet pozostają na dysku do kolejnych kompilacji. Skrypt usuwa
tylko pliki tymczasowe instalacji i projekt próbny.

Próbna kompilacja działa na koncie administratora; ścieżkę na koncie usługi sprawdza dopiero pierwsze
wdrożenie z Weba.

Uruchom skrypt ponownie po zmianie Connection lub SDK nexo. Wersja Connection z zainstalowanego zipa
musi być opublikowana na nuget.org (od `1.1.3`) - skrypt nie zastępuje jej inną. Repozytorium z własnym
`Directory.Build.props` musi importować plik nadrzędny albo ustawić `nexoSdkBinPath`. Prywatne źródła
paczek dodaj w `NuGet.Config` repozytorium, zostawiając nuget.org.

`-ConnectionPackagePath <plik.nupkg>` używa lokalnie zbudowanego Connection (DLL musi być ta sama co
w zainstalowanym zipie). Ta jedna paczka idzie z osobnego źródła i cache w `Build\LocalConnection\<hash>`,
pozostałe nadal z nuget.org.

### Gotowa paczka z CI

Na serwerze uruchom `install-nexo.ps1`; środowisko budowania jest przygotowywane również przy korzystaniu
z paczek z CI. Moduł buduje workflow repozytorium w GitHub Actions, a Web pobiera z udanego przebiegu
dla wybranego commita artefakt `zapqio-module` z plikiem
`module.zip`. Zip z GitHub Releases go nie zastępuje. Wzorcowy workflow:
[dotnet-module-nexo-test/.github/workflows/build.yml](https://github.com/zapqio/dotnet-module-nexo-test/blob/main/.github/workflows/build.yml).

## Budowanie i wydania

Build tego repo wymaga SDK InsERT w `C:\nexoSDK_61.1.0.9431\Bin\` (albo `-p:nexoSdkBinPath=...`).
`dotnet publish -c Release` daje w `bin\Release\`:

- `Nexo.Connection.zip` - paczka dla runnera: `Nexo.Connection.dll`, `update-nexo-sdk.ps1`, `LICENSE`,
  `##Dll`, `##Shared`, bez SDK,
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

`Version` rośnie z każdą zmianą modułu. `AssemblyVersion` zostaje `1.0.0.0`, dopóki zmiana nie łamie
API: moduł skompilowany przeciw 1.0.0 działa z każdym zipem 1.x. Zmiana łamiąca to `2.0.0.0` i przebudowa
wszystkich konsumentów. Wersja Subiekta nie ma z tym nic wspólnego.

### Testy

Języki instalatora (Windows PowerShell 5.1, bez sieci, bazy i zmian w działającym runnerze):

```powershell
.\tests\Test-InstallerLanguage.ps1
```

Sprawdza kompletność tłumaczeń, formatowanie parametrów, menu wyboru języka, pracę bez konsoli,
przekazywanie języka do skryptów pomocniczych i komunikaty każdego skryptu w trzech językach.
Workflow wydania uruchamia ten test przy każdym pushu na `main`, także bez zmiany wersji paczki.

Paczki (to samo robi workflow wydania; wymaga .NET SDK i nuget.org):

```powershell
.\tests\Test-NuGetPackage.ps1 -PackagePath bin\Release\Zapqio.Nexo.Connection.1.1.3.nupkg `
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
