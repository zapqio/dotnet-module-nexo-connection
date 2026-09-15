# Zapqio Runner - moduł Nexo.Connection

Moduł współdzielony dla [Zapqio Runner](https://github.com/zapqio/runner-dotnet): jedno połączenie
do InsERT nexo (Subiekt) przez Sferę, wspólne dla wszystkich modułów Nexo na tym samym runnerze.
Sam nie ma żadnej metody. Dostarcza:

- `Nexo.NexoClient` - singleton z uchwytem Sfery (`Uchwyt`), wstrzykiwany do metod innych modułów,
- `Nexo.ConnectionSettings` - dane połączenia z pliku `nexoModule.json`,
- biblioteki SDK InsERT nexo, z których korzystają moduły konsumenckie.

Paczka `Nexo.Connection.zip` ma być **jedyną** paczką w `Modules\` runnera, która niesie `NexoClient`.
Dwie takie paczki to dwa połączenia.

## Instalacja na runnerze

1. `Nexo.Connection.zip` do katalogu `Modules\` runnera, obok paczek z metodami
   (np. `Nexo.TestConnect.zip`).
2. Restart usługi. W logu: `Moduł współdzielony: Nexo.Connection` i `Add injection: Nexo.NexoClient`.
3. Przy pierwszym starcie obok binarki runnera powstaje `nexoModule.json` z sekcją `Connect`
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

Połączenie jest nawiązywane leniwie, gdy pierwsza metoda sięgnie po `Uchwyt`. Inne moduły Nexo
trzymają w tym samym pliku własne klucze; nieznane pola są ignorowane.

## Własny moduł na Nexo.Connection

Wymagania: .NET SDK 8, SDK InsERT nexo w `C:\nexoSDK_<wersja>\Bin\` (ta sama wersja, co w paczce
na runnerze) oraz paczki NuGet `Zapqio.Runner.Module.Core` i `Zapqio.Nexo.Connection` w źródle,
które widzi `dotnet restore`.

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
    <!-- Obie paczki tylko do kompilacji: w runtime kontrakt dostarcza runner, a NexoClient i SDK
         przychodzą z zipa Nexo.Connection. Do zipa tego modułu trafia tylko jego własna DLL. -->
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
więc nie trzeba ich przepisywać. Inna ścieżka albo wersja SDK to jedna właściwość w csproj:

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

- `Nexo.Connection.zip` - paczka dla runnera: SDK, `Nexo.Connection.dll`, `##Dll`, `##Shared`,
- `Zapqio.Nexo.Connection.<wersja>.nupkg` - paczka NuGet dla modułów konsumenckich.

`Version` w csproj rośnie z każdą zmianą API. `AssemblyVersion` zostaje `1.0.0.0`, dopóki zmiana nie
łamie API: moduł skompilowany przeciw 1.0.0 działa z każdym zipem 1.x. Zmiana łamiąca to `2.0.0.0`
i przebudowa wszystkich konsumentów.

Zmiana wersji Subiekta: nowa wartość `NexoSdkVersion` w `build/Zapqio.Nexo.Connection.props`, nowy zip
i nowa paczka. Konsumenci nie wymagają przebudowy, bo zestawy SDK InsERT mają stałą wersję
(1.0.0.0) w każdym wydaniu.
