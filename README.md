# Zapqio Runner - moduł Nexo.Connection

Moduł współdzielony dla [Zapqio Runner](https://github.com/zapqio/dotnet-runner): jedno połączenie
z InsERT nexo (Subiekt) przez Sferę, wspólne dla wszystkich modułów Nexo na runnerze. Dostarcza:

- `Nexo.NexoClient` - singleton z uchwytem Sfery (`Uchwyt`), wstrzykiwany do metod innych modułów,
- `Nexo.ConnectionSettings` - dane połączenia z `Config\nexoModule.json`,
- metodę **„Nexo: Who am I”** - test instalacji (operator Sfery, wersja i paczka SDK),
- paczkę NuGet `Zapqio.Nexo.Connection` do kompilacji własnych modułów.

Na runnerze w `Modules\` leżą trzy rodzaje paczek:

| Paczka | Zawartość | Skąd |
|---|---|---|
| `Nexo.Sdk.zip` | SDK InsERT nexo w wersji Subiekta | `update-nexo-sdk.ps1` |
| `Nexo.Connection.zip` | `NexoClient`, „Nexo: Who am I” | [Releases](https://github.com/zapqio/dotnet-module-nexo-connection/releases) |
| `Nexo.Invoices.zip`, ... | metody | repozytoria modułów |

SDK jest osobno, więc aktualizacja Subiekta nie wymaga przebudowy modułów.

## Instalacja

Wymagany jest Zapqio Runner na .NET 8 (biblioteki InsERT nie działają na .NET 9+). W PowerShellu
**jako administrator**:

```powershell
$s = irm https://raw.githubusercontent.com/zapqio/dotnet-module-nexo-connection/main/install-nexo.ps1
& ([scriptblock]::Create($s.TrimStart([char]0xFEFF)))
```

Skrypt pyta o dane połączenia, odczytuje wersję Subiekta z bazy, zapisuje `Config\nexoModule.json`,
pobiera `Nexo.Connection.zip`, buduje `Nexo.Sdk.zip` (ok. 500 MB z FTP InsERT) i restartuje usługę.
Ponowne uruchomienie aktualizuje moduł; zapisane dane połączenia zostają.

Bez pytań - wszystko z parametrów:

```powershell
& ([scriptblock]::Create($s.TrimStart([char]0xFEFF))) -DatabaseServer 'SERWER\INSERTNEXO' -DatabaseName Nexo_Firma `
    -DatabaseUser sa -DatabasePassword '...' -UserName Szef -UserPassword '...'
```

| Parametr | Opis |
|---|---|
| `-DatabaseServer`, `-DatabaseName` | Serwer SQL z instancją i baza podmiotu. |
| `-DatabaseUser`, `-DatabasePassword` / `-WindowsLogin` | Logowanie SQL albo Windows (kontem usługi runnera). |
| `-UserName`, `-UserPassword` | Operator Subiekta dla Sfery. |
| `-SubiektVersion` | Wersja z „Pomoc > O programie”, gdy odczyt z bazy się nie uda. |
| `-SdkDir`, `-PackagePath` | Lokalny katalog `Bin` SDK i lokalny zip modułu (instalacja offline). |
| `-Version` | Konkretny release modułu (domyślnie najnowszy). |
| `-BuildTools` | Dodatkowo przygotowuje runner do budowania modułów ze źródeł (patrz niżej). |
| `-InstallDir`, `-ServiceName`, `-NoRestart` | Domyślnie `C:\zapqio\runner`, `ZapqioRunner`. |

**Sprawdzenie:** uruchom w panelu Web **„Nexo: Who am I”**. Komunikat błędu wskaże przyczynę: brak paczki,
niezgodna wersja SDK, dane SQL albo hasło operatora. Paczki z metodami wrzucasz do `Modules\`
i restartujesz usługę.

### Konfiguracja

`Config\nexoModule.json` (powstaje przy pierwszym starcie; inne moduły Nexo dopisują tu własne klucze):

```json
{
  "Connect": {
    "DatabaseServer": "192.168.1.10\\INSERTNEXO",
    "DatabaseName": "Nexo_Firma",
    "DatabaseUser": "sa",
    "DatabasePassword": "...",
    "WindowsLogin": false,
    "UserName": "Szef",
    "UserPassword": "..."
  },
  "SdkUpdate": {
    "Enabled": true,
    "Restart": true,
    "ModulesUrl": null,
    "ServiceName": "ZapqioRunner",
    "RunnerDir": ""
  }
}
```

Po zmianie zrestartuj usługę. Połączenie powstaje przy pierwszym użyciu `Uchwyt`.

### Instalacja ręczna

1. Jako administrator w katalogu runnera: `.\update-nexo-sdk.ps1 -Version 61.1.1 -NoRestart`
   (albo `-SdkDir C:\nexoSDK_61.1.1.9471\Bin` dla rozpakowanego SDK). Skrypt jest też w `Nexo.Connection.zip`.
2. `Nexo.Connection.zip` i paczki z metodami do `Modules\`.
3. Restart usługi, uzupełnienie `Config\nexoModule.json`, ponowny restart.

Na runnerze ma być dokładnie jedna paczka SDK i jedna z `NexoClient` - stary `Nexo.zip` trzeba usunąć
(instalator robi to sam).

## Aktualizacja Subiekta

Sfera wymaga SDK w tej samej wersji co Subiekt. Po aktualizacji Subiekta pierwsze zadanie Nexo kończy się
błędem, a `NexoClient` uruchamia w tle `update-nexo-sdk.ps1`, który podmienia `Nexo.Sdk.zip` i restartuje
usługę. Po kilku minutach zadania działają; przerwane trzeba ponowić. Log: `Logs\nexo-sdk-update.log`.

- `SdkUpdate.Enabled: false` - bez automatu, tylko komunikat z instrukcją.
- `SdkUpdate.Restart: false` - podmiana bez restartu.
- `SdkUpdate.ModulesUrl` - adres (z `{version}`) własnych kompletów modułów pod daną wersję SDK.

Ręcznie: `.\update-nexo-sdk.ps1 -Version <wersja z "O programie">`. Przebudowa modułu jest potrzebna
tylko, gdy InsERT zmienił w SDK coś, z czego moduł korzysta.

## Własny moduł

Potrzebne: .NET SDK 8 i SDK InsERT nexo (domyślnie w `C:\nexoSDK_61.1.0.9431\Bin\`). Wzorzec:
[dotnet-module-nexo-test](https://github.com/zapqio/dotnet-module-nexo-test).

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
    <!-- Tylko do kompilacji: w runtime dostarczają je runner i paczki współdzielone. -->
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

```csharp
using InsERT.Moria.Uzytkownicy;
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
        var user = _client.Uchwyt.PodajObiektTypu<IZalogowanyUzytkownik>().Dane;
        return Task.FromResult(user.Sygnatura);
    }
}
```

`dotnet publish -c Release` daje `bin\Release\<projekt>.zip` do `Modules\`.

**Ścieżka SDK** (w `.csproj`, `Directory.Build.props` lub `-p:`):

- `NexoSdkVersion` → `C:\nexoSDK_<wersja>\Bin\`,
- `nexoSdkBinPath` → dowolny katalog (ma pierwszeństwo).

Brak SDK kończy build błędem `ZNEXO001`. Paczka NuGet nie zawiera bibliotek InsERT.

## Wdrożenia z Weba

Tryb wybiera się dla każdego repozytorium osobno:

- **Budowanie na runnerze** - `install-nexo.ps1 -BuildTools`, a na już skonfigurowanym runnerze:

  ```powershell
  $s = irm https://raw.githubusercontent.com/zapqio/dotnet-module-nexo-connection/main/install-nexo-build.ps1
  & ([scriptblock]::Create($s.TrimStart([char]0xFEFF)))
  ```

  Instaluje .NET SDK 8 (jeśli brak), przygotowuje SDK nexo i NuGet w `Build\` i `Deployments\`
  i sprawdza kompilację próbnego modułu. Uruchom ponownie po zmianie Connection lub SDK nexo.
  `-ConnectionPackagePath` pozwala użyć lokalnie zbudowanego `.nupkg` (musi pasować do zainstalowanego zipa).
- **Gotowa paczka z CI** - wystarczy zwykły `install-nexo.ps1`. Web pobiera artefakt `zapqio-module`
  (z `module.zip`) z workflow repozytorium; wzorzec: `dotnet-module-nexo-test/.github/workflows/build.yml`.

## Budowanie i wydania

`dotnet publish -c Release` daje w `bin\Release\` `Nexo.Connection.zip` (dla runnera) oraz
`Zapqio.Nexo.Connection.<wersja>.nupkg` (dla modułów).

Push na `main` ze zmienionym `Version` w csproj uruchamia `.github/workflows/release.yml`, który buduje,
testuje (`tests/Test-NuGetPackage.ps1`) i publikuje release `v<Version>`. Plik `.nupkg` z release'u wgrywa
się ręcznie na nuget.org - zip i nupkg muszą pochodzić z tego samego builda.

`AssemblyVersion` zostaje `1.0.0.0` do pierwszej zmiany łamiącej API (wtedy `2.0.0.0` i przebudowa
konsumentów).

Test instalatora `-BuildTools` (bez usługi i bazy):

```powershell
.\tests\Test-BuildSetup.ps1 -ConnectionZip 'C:\pakiety\Nexo.Connection.zip' -SdkZip 'C:\pakiety\Nexo.Sdk.zip'
```
