using Zapqio.Runner.Core;

namespace Nexo
{
    /// <summary>
    /// Dane połączenia z Nexo: sekcja <c>Connect</c> w <c>Config\nexoModule.json</c> (patrz <see cref="NexoConfig"/>).
    /// Ten sam plik czytają pozostałe moduły Nexo, każdy swoje klucze. Plik powstaje przy pierwszym starcie
    /// z pustymi danymi połączenia; do czasu ich uzupełnienia każde zadanie kończy się błędem o braku konfiguracji.
    /// </summary>
    public class ConnectionSettings : IRunnerInjection
    {
        public ConnectionSettings()
        {
            NexoConfig.Populate(this);
        }

        public class NexoConnect
        {
            /// <summary>Serwer SQL z instancją, np. "192.168.1.10\INSERTNEXO" albo "192.168.1.10,1433".</summary>
            public string DatabaseServer { get; set; } = "";
            public string DatabaseUser { get; set; } = "";
            public string DatabasePassword { get; set; } = "";
            /// <summary>Nazwa bazy podmiotu, np. "Nexo_Firma".</summary>
            public string DatabaseName { get; set; } = "";
            /// <summary>Operator Subiekta, na którego loguje się Sfera.</summary>
            public string UserName { get; set; } = "";
            public string UserPassword { get; set; } = "";
            /// <summary>true = uwierzytelnianie Windows do serwera SQL zamiast DatabaseUser/DatabasePassword.</summary>
            public bool WindowsLogin { get; set; } = false;
        }

        /// <summary>
        /// Automatyczna podmiana SDK po aktualizacji Subiekta: gdy Sfera odrzuci połączenie przez niezgodność
        /// wersji, <see cref="NexoClient"/> uruchamia w tle <c>update-nexo-sdk.ps1</c> z katalogu runnera.
        /// </summary>
        public class SdkUpdateSettings
        {
            /// <summary>Wyłączenie zostawia tylko komunikat z instrukcją ręcznej podmiany.</summary>
            public bool Enabled { get; set; } = true;

            /// <summary>
            /// Skąd brać komplet modułów zbudowany pod nową wersję SDK, adres z {version}
            /// (np. https://serwer.firma.pl/zapqio/sdk-{version}, w środku manifest.json z listą zipów). Puste = tylko SDK.
            /// </summary>
            public string ModulesUrl { get; set; }

            /// <summary>Nazwa usługi runnera do restartu po podmianie.</summary>
            public string ServiceName { get; set; } = "ZapqioRunner";

            /// <summary>false przy pracy z konsoli i w testach: skrypt podmienia zip, ale nie restartuje usługi.</summary>
            public bool Restart { get; set; } = true;

            /// <summary>Katalog runnera z podkatalogiem Modules; puste = katalog binarki runnera.</summary>
            public string RunnerDir { get; set; }
        }

        public NexoConnect Connect { get; set; } = new();

        public SdkUpdateSettings SdkUpdate { get; set; } = new();
    }
}
