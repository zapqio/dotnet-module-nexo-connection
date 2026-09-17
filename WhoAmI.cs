using InsERT.Moria.Uzytkownicy;
using System;
using System.Text.Json;
using System.Threading.Tasks;
using Zapqio.Runner.Core;

namespace Nexo
{
    /// <summary>
    /// Sprawdzenie instalacji: loguje się do Subiekta przez współdzielony <see cref="NexoClient"/> i zwraca
    /// operatora Sfery oraz to, z czym runner pracuje (wersja i paczka SDK, serwer i baza z konfiguracji).
    /// Jedyna metoda tej paczki. Moduły z metodami biznesowymi biorą <see cref="NexoClient"/> tak samo,
    /// przez konstruktor.
    /// </summary>
    public class WhoAmI : IRunnerMethod
    {
        private readonly NexoClient _client;
        private readonly ConnectionSettings _settings;

        public WhoAmI(NexoClient client, ConnectionSettings settings)
        {
            _client = client;
            _settings = settings;
        }

        public string NameMethod() => "Nexo: Who am I";

        public Type InData() => null;

        public Type OutData() => typeof(Out);

        public Task<string> Run(string data)
        {
            // Pierwsze sięgnięcie po Uchwyt nawiązuje połączenie: brak konfiguracji, zła wersja SDK albo
            // nieudane logowanie operatora wychodzą tu jako wyjątek z komunikatem NexoClient.
            var user = _client.Uchwyt.PodajObiektTypu<IZalogowanyUzytkownik>().Dane;
            var output = new Out
            {
                Operator = user.Sygnatura,
                SdkVersion = _client.SdkVersion,
                SdkPackage = _client.SdkPackage,
                DatabaseServer = _settings.Connect.DatabaseServer,
                DatabaseName = _settings.Connect.DatabaseName,
            };
            var json = JsonSerializer.Serialize(output);
            Console.WriteLine(json);
            return Task.FromResult(json);
        }

        public class Out
        {
            /// <summary>Sygnatura operatora Subiekta, na którego zalogowała się Sfera.</summary>
            public string Operator { get; set; }

            /// <summary>Wersja SDK InsERT z paczki na runnerze, np. 61.1.0.9431; musi być równa wersji Subiekta.</summary>
            public string SdkVersion { get; set; }

            /// <summary>Nazwa paczki w Modules\, z której załadowano SDK (Nexo.Sdk).</summary>
            public string SdkPackage { get; set; }

            public string DatabaseServer { get; set; }

            public string DatabaseName { get; set; }
        }
    }
}
