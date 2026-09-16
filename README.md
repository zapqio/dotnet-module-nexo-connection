# Zapqio Runner - moduł Nexo.Connection

Moduł współdzielony dla [Zapqio Runner](https://github.com/zapqio/runner-dotnet): jedno połączenie
do InsERT nexo (Subiekt) przez Sferę, wspólne dla wszystkich modułów Nexo na tym samym runnerze.
Sam nie ma żadnej metody. Dostarcza:

- `Nexo.NexoClient` - singleton z uchwytem Sfery (`Uchwyt`), wstrzykiwany do metod innych modułów,
- `Nexo.ConnectionSettings` - dane połączenia z pliku `nexoModule.json`,
- paczkę NuGet z API i referencjami do SDK, przeciw której kompilują się moduły konsumenckie.

Sam SDK InsERT nexo leży na runnerze w osobnej paczce `Nexo.Sdk.zip`, którą tworzy skrypt
`update-nexo-sdk.ps1`. Dzięki temu zmiana wersji Subiekta nie wymaga przebudowy żadnego modułu.

## Instalacja na runnerze

W `Modules\` runnera mają leżeć trzy rodzaje paczek:

| Paczka | Skąd | Zawartość |
|---|---|---|
| `Nexo.Sdk.zip` | `update-nexo-sdk.ps1` na runnerze | SDK InsERT nexo w wersji Subiekta klienta |
| `Nexo.Connection.zip` | to repo, `dotnet publish` | `Nexo.Connection.dll` (NexoClient) |
| `Nexo.TestConnect.zip`, `Nexo.Invoices.zip`, ... | repo modułów | metody |

Kolejność:

1. Skopiuj `update-nexo-sdk.ps1` do katalogu runnera i uruchom jako administrator z wersją Subiekta
   z "Pomoc > O programie":

   ```powershell
   .\update-nexo-sdk.ps1 -Version 61.1.1 -NoRestart
   ```

   Skrypt pobiera `nexoSDK_61_1_1.exe` z publicznego FTP InsERT, rozpakowuje, pakuje do
   `Modules\Nexo.Sdk.zip`. Masz już rozpakowane SDK: `-SdkDir C:\nexoSDK_61.1.1.9471\Bin`.
2. `Nexo.Connection.zip` i paczki z metodami do `Modules\`.
3. Restart usługi. W logu: `Moduł współdzielony: Nexo.Sdk`, `Moduł współdzielony: Nexo.Connection`,
   `Add injection: Nexo.NexoClient`, `Add method: ...`.
4. Przy pierwszym starcie obok binarki runnera powstaje `nexoModule.json` z sekcją `Connect`
   (serwer SQL, baza, użytkownik SQL, operator Subiekta). Uzupełnij i zrestartuj usługę.

```json
{
  "Connect": {
    "DatabaseServer": "172.24.43.98,1433",
    "DatabaseUser": "sa",
    "DatabasePassword": "sa",
    "DatabaseName": "Nexo_Demo",
    "UserName": "Szef",
    "UserPassword": "robocze",
    "WindowsLogin": false
  }
}
```

Połączenie jest nawiązywane leniwie, gdy pierwsza metoda sięgnie po `Uchwyt`. W logu zadania widać
wtedy `Connecting Nexo (SDK 61.1.1.9471 z paczki Nexo.Sdk)`. Inne moduły Nexo trzymają w tym samym
pliku własne klucze; nieznane pola są ignorowane.

Na runnerze ma być dokładnie jedna paczka z SDK i dokładnie jedna z `NexoClient`. Stary `Nexo.zip`
sprzed podziału niesie jedno i drugie, więc trzeba go usunąć.

## Aktualizacja Subiekta

Sfera wymaga SDK w tej samej wersji co Subiekt. Po aktualizacji Subiekta metody Nexo kończą się
błędem `SDK <stara wersja> (paczka Nexo.Sdk) nie połączył się z Subiektem: ...` z tym zdaniem na końcu:

```powershell
.\update-nexo-sdk.ps1 -Version <wersja z "O programie">
```

To wszystko: skrypt pobiera SDK, podmienia `Nexo.Sdk.zip` i restartuje usługę. Moduły zostają, bo
wiążą się z SDK po nazwie zestawu. Bez SDK w `Modules\` metody Nexo nie powstają wcale, runner loguje
`Metoda ... nie została utworzona ... 'InsERT.Moria.Sfera'`, a pozostałe moduły działają.

Programista jest potrzebny tylko wtedy, gdy InsERT zmienił w SDK składową, z której korzysta któryś
moduł. Wychodzi to przy kompilacji modułu przeciw nowemu SDK (`-p:NexoSdkVersion=<wersja>`), a nie
przy podmianie paczki.

## Własny moduł na Nexo.Connection

Wymagania: .NET SDK 8, SDK InsERT nexo w `C:\nexoSDK_<wersja>\Bin\` do kompilacji oraz paczki NuGet
`Zapqio.Runner.Module.Core` i `Zapqio.Nexo.Connection` w źródle, które widzi `dotnet restore`.

Csproj (wzorzec: [module-nexo-testconnect](https://github.com/zapqio/module-nexo-testconnect)):

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
    <PackageReference Include="Zapqio.Runner.Module.Core" Version="1.0.0" ExcludeAssets="runtime" />
    <PackageReference Include="Zapqio.Nexo.Connection" Version="1.0.0" ExcludeAssets="runtime" />
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

Referencje do SDK przychodzą z paczki (plik `build/Zapqio.Nexo.Connection.props`) z `Private="false"`,
więc nie trzeba ich przepisywać. Inna ścieżka albo wersja SDK do kompilacji to jedna właściwość:

```xml
<PropertyGroup>
  <NexoSdkVersion>61.1.0.9431</NexoSdkVersion>
  <!-- albo cała ścieżka -->
  <nexoSdkBinPath>D:\sdk\nexo\Bin\</nexoSdkBinPath>
</PropertyGroup>
```

Metoda dostaje klienta przez konstruktor:

```csharp
using InsERT.Moria.Uzytkownicy;
using Zapqio.Runner.Core;

public class WhoAmI : IRunnerMethod
{
    private readonly NexoClient _client;

    public WhoAmI(NexoClient client) => _client = client;

    public string NameMethod() => "Who am I";
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

`dotnet publish -c Release` daje `bin\Release\<projekt>.zip` do wrzucenia do `Modules\`. Jak runner
ładuje paczki współdzielone, opisuje dokumentacja runnera (`docs/szczegoly.md`, sekcja
"Moduły współdzielone"). Bez `Nexo.Connection.zip` w `Modules\` metody tego modułu nie powstaną:
runner zgłosi w logu `Metoda ... nie została utworzona`, a pozostałe moduły będą działać.

## Budowanie i wersje

`dotnet publish -c Release` w tym repo daje w `bin\Release\`:

- `Nexo.Connection.zip` - paczka dla runnera: `Nexo.Connection.dll`, `##Dll`, `##Shared`, bez SDK,
- `Zapqio.Nexo.Connection.<wersja>.nupkg` - paczka NuGet dla modułów konsumenckich.

`Version` w csproj rośnie z każdą zmianą tego modułu. `AssemblyVersion` zostaje `1.0.0.0`, dopóki
zmiana nie łamie API: moduł skompilowany przeciw 1.0.0 działa z każdym zipem 1.x. Zmiana łamiąca to
`2.0.0.0` i przebudowa wszystkich konsumentów.

Wersja Subiekta nie ma z tym nic wspólnego: SDK żyje w `Nexo.Sdk.zip` i podmienia go skrypt.
