using InsERT.Moria.Sfera;
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using Zapqio.Runner.Core;

namespace Nexo
{
    /// <summary>
    /// Jedno połączenie do Nexo na proces runnera: singleton wstrzykiwany do metod ze wszystkich
    /// modułów Nexo. Sfera obsługuje użycie wielowątkowe, więc jeden <see cref="Uchwyt"/> obsługuje
    /// wszystkie równoległe zadania; jedyna blokada to leniwe nawiązanie połączenia.
    /// </summary>
    public class NexoClient : IRunnerInjection, IDisposable
    {
        internal class ConnectingStatusSfery : IPostepLadowaniaSfery
        {
            public ConnectingStatusSfery()
            {
            }
            private int _percentMod = -1;
            private string _descryption;

            public void RaportujPostep(PostepLadowaniaSferyEventArgs args)
            {
                var perMod = args.BiezacyProcent / 10;
                var des = args.Opis;
                if (_percentMod != perMod || _descryption != des)
                {
#if DEBUG
                    Console.WriteLine($"Nexo - {des}:{perMod * 10}");
#endif
                    _percentMod = perMod;
                    _descryption = des;

                }
            }
        }
        private readonly ConnectionSettings _settings;
        private readonly SdkAutoUpdate _sdkUpdate;
        private Uchwyt _uchwyt;

        /// <summary>
        /// Wersja SDK InsERT, z którym działa ten proces: ProductVersion InsERT.Moria.Sfera.dll, np. 61.1.0.9431.
        /// Musi zgadzać się z wersją Subiekta, inaczej Sfera odrzuci połączenie.
        /// </summary>
        public string SdkVersion { get; }

        /// <summary>Nazwa paczki w Modules\ runnera, z której załadowano SDK (katalog zestawu Sfery).</summary>
        public string SdkPackage { get; }

        public Uchwyt Uchwyt
        {
            get
            {
                if (_uchwyt == null)
                {
                    Connection();
                }
                return _uchwyt;
            }
        }
        public NexoClient(ConnectionSettings settings)
        {
            _settings = settings;
            // Odczyt wersji celowo w konstruktorze: wymusza załadowanie Sfery przy tworzeniu metod, więc brak
            // paczki SDK w Modules\ wychodzi przy starcie runnera jako czytelny błąd, a nie w środku zadania.
            var sfera = typeof(Uchwyt).Assembly;
            SdkVersion = ReadSdkVersion(sfera);
            SdkPackage = Path.GetFileName(Path.GetDirectoryName(sfera.Location)) ?? "?";
            // Skrypt podmiany SDK jedzie w paczce Connection; kopia w katalogu runnera, żeby klient nie instalował nic poza zipem.
            _sdkUpdate = new SdkAutoUpdate(settings?.SdkUpdate);
            _sdkUpdate.EnsureScript(Path.GetDirectoryName(typeof(NexoClient).Assembly.Location));
        }

        private static string ReadSdkVersion(Assembly sfera)
        {
            // ProductVersion to np. "61.1.0.9431+438cf094..." - AssemblyVersion jest zawsze 1.0.0.0 i nic nie mówi.
            var product = FileVersionInfo.GetVersionInfo(sfera.Location).ProductVersion ?? string.Empty;
            var plus = product.IndexOf('+');
            return plus > 0 ? product.Substring(0, plus) : product;
        }

        public void Dispose()
        {
            _uchwyt?.Dispose();
            _uchwyt = null;
        }

        private void Connection()
        {
            lock (this)
            {
                if (_uchwyt != null)
                {
                    return;
                }
                Console.WriteLine($"Connecting Nexo (SDK {SdkVersion} z paczki {SdkPackage})");
                DanePolaczenia connectingData;
                if (_settings.Connect.WindowsLogin)
                {
                    connectingData = DanePolaczenia.Jawne(
                    serwer: _settings.Connect.DatabaseServer,
                        baza: _settings.Connect.DatabaseName,
                        autentykacjaWindowsDoSerwera: true);
                }
                else
                {
                    connectingData = DanePolaczenia.Jawne(
                        serwer: _settings.Connect.DatabaseServer,
                        baza: _settings.Connect.DatabaseName,
                        uzytkownikSerwera: _settings.Connect.DatabaseUser,
                        hasloUzytkownikaSerwera: _settings.Connect.DatabasePassword);
                }
                Uchwyt uchwyt;
                try
                {
                    uchwyt = new MenedzerPolaczen().Polacz(connectingData, InsERT.Mox.Product.ProductId.Subiekt, new ConnectingStatusSfery());
                }
                catch (Exception ex)
                {
                    // Tu ląduje niezgodność wersji SDK z Subiektem (po jego aktualizacji), a także brak serwera SQL itp.
                    throw new NexoConnectionException(
                        $"SDK {SdkVersion} (paczka {SdkPackage}) nie połączył się z Subiektem: {ex.Message} {MismatchHint(ex.Message)}",
                        ex);
                }
                if (!uchwyt.ZalogujOperatora(_settings.Connect.UserName, _settings.Connect.UserPassword))
                {
                    // Nieudane logowanie nie może zostawić uchwytu w polu - kolejne wywołanie dostałoby połączenie bez operatora.
                    uchwyt.Dispose();
                    throw new Exception($"Nexo login failed: operator {_settings.Connect.UserName} (SDK {SdkVersion})");
                }
                _uchwyt = uchwyt;
            }
        }

        /// <summary>
        /// Przy niezgodności wersji uruchamia automatyczną podmianę SDK (o ile włączona) i zwraca zdanie do
        /// komunikatu błędu; przy innych błędach ogólną wskazówkę.
        /// </summary>
        private string MismatchHint(string sferaMessage)
        {
            var subiekt = SdkAutoUpdate.SubiektVersionFrom(sferaMessage);
            if (subiekt == null)
            {
                return "Jeśli Subiekt ma inną wersję, uruchom na runnerze update-nexo-sdk.ps1 -Version <wersja z \"O programie\">.";
            }
            var started = _sdkUpdate.TryStart(subiekt);
            if (started == null)
            {
                return $"Uruchom na runnerze update-nexo-sdk.ps1 -Version {subiekt} (automatyczna podmiana wyłączona w nexoModule.json).";
            }
            Console.WriteLine(started);
            return char.ToUpperInvariant(started[0]) + started.Substring(1) + ".";
        }
    }
}
