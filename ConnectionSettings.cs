using System;
using System.IO;
using System.Text.Json;
using Zapqio.Runner.Core;

namespace Nexo
{
    /// <summary>
    /// Dane połączenia z Nexo: sekcja <c>Connect</c> w pliku <c>nexoModule.json</c> obok binarki runnera.
    /// Ten sam plik czytają pozostałe moduły Nexo (każdy swoje klucze, nieznane pola są ignorowane).
    /// Plik z wartościami domyślnymi powstaje tylko wtedy, gdy go nie ma.
    /// </summary>
    public class ConnectionSettings : IRunnerInjection
    {
        private static readonly object _lock = new();
        private static bool _isLoading = false;

        public ConnectionSettings()
        {
            lock (_lock)
            {
                if (_isLoading) return; // przerwij rekurencję (deserializacja woła ten konstruktor)

                _isLoading = true;
                try
                {
                    var data = ReadFromFile();
                    if (data != null)
                    {
                        foreach (var item in typeof(ConnectionSettings).GetProperties())
                        {
                            if (item.CanWrite)
                            {
                                item.SetValue(this, item.GetValue(data));
                            }
                        }
                    }
                }
                finally
                {
                    _isLoading = false;
                }
            }
        }

        private static ConnectionSettings ReadFromFile()
        {
            string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
            string path = Path.Combine(baseDirectory, "nexoModule.json");
            if (File.Exists(path))
            {
                return JsonSerializer.Deserialize<ConnectionSettings>(File.ReadAllText(path));
            }
            else
            {
                var d = new ConnectionSettings();
                File.WriteAllText(path, JsonSerializer.Serialize(d, new JsonSerializerOptions() { WriteIndented = true }));
                return null;
            }
        }

        public class NexoConnect
        {
            public string DatabaseServer { get; set; } = "172.24.43.98,1433";
            public string DatabaseUser { get; set; } = "sa";
            public string DatabasePassword { get; set; } = "sa";
            public string DatabaseName { get; set; } = "Nexo_Demo";
            public string UserName { get; set; } = "Szef";
            public string UserPassword { get; set; } = "robocze";
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
            /// (np. https://github.com/HDWR-Global/zapqio-modules/releases/download/sdk-{version}). Puste = tylko SDK.
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
