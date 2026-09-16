using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Nexo
{
    /// <summary>
    /// Automatyczna podmiana SDK. Gdy Sfera odrzuci połączenie przez niezgodność wersji z Subiektem,
    /// uruchamia w tle <c>update-nexo-sdk.ps1</c> z wersją Subiekta odczytaną z odpowiedzi Sfery. Skrypt
    /// pobiera SDK z FTP InsERT, podmienia <c>Modules\Nexo.Sdk.zip</c> i restartuje usługę runnera.
    /// Moduł sam niczego nie podmienia ani nie restartuje: skrypt to osobny proces, który przeżywa
    /// zatrzymanie usługi. Blokada w pliku stanu pilnuje, żeby kolejne padające zadania nie uruchamiały
    /// drugiej podmiany i żeby nieudana próba nie była ponawiana co chwilę.
    /// </summary>
    internal sealed class SdkAutoUpdate
    {
        private const string ScriptName = "update-nexo-sdk.ps1";
        private const string StateName = "nexo-sdk-update.json";
        private static readonly Regex Mismatch = new(@"Wersja bazy danych to ([\d.]+), a wersja Sfery to ([\d.]+)", RegexOptions.CultureInvariant);
        private static readonly TimeSpan RunningTimeout = TimeSpan.FromMinutes(30);
        private static readonly TimeSpan RetryAfter = TimeSpan.FromHours(1);
        private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true, WriteIndented = true };

        private readonly ConnectionSettings.SdkUpdateSettings _settings;
        private readonly string _runnerDir;

        public SdkAutoUpdate(ConnectionSettings.SdkUpdateSettings settings)
        {
            _settings = settings ?? new ConnectionSettings.SdkUpdateSettings();
            var dir = string.IsNullOrWhiteSpace(_settings.RunnerDir) ? AppDomain.CurrentDomain.BaseDirectory : _settings.RunnerDir;
            _runnerDir = Path.TrimEndingDirectorySeparator(Path.GetFullPath(dir));
        }

        public string ScriptPath => Path.Combine(_runnerDir, ScriptName);

        /// <summary>
        /// Kopiuje skrypt z paczki Connection do katalogu runnera, gdy go tam nie ma albo jest starszy.
        /// Klient nie instaluje nic poza zipem.
        /// </summary>
        public void EnsureScript(string packageDir)
        {
            try
            {
                var source = Path.Combine(packageDir ?? string.Empty, ScriptName);
                if (!File.Exists(source))
                {
                    return;
                }
                if (!File.Exists(ScriptPath) || File.GetLastWriteTimeUtc(source) > File.GetLastWriteTimeUtc(ScriptPath))
                {
                    File.Copy(source, ScriptPath, overwrite: true);
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // Bez prawa zapisu w katalogu runnera automat nie zadziała; komunikat o wersji nadal mówi, co zrobić ręcznie.
            }
        }

        /// <summary>Wersja Subiekta z treści błędu Sfery albo null, gdy to nie jest błąd niezgodności wersji.</summary>
        public static string SubiektVersionFrom(string sferaMessage)
        {
            var m = Mismatch.Match(sferaMessage ?? string.Empty);
            return m.Success ? m.Groups[1].Value : null;
        }

        /// <summary>
        /// Uruchamia skrypt dla podanej wersji Subiekta. Zwraca zdanie do logu zadania: co uruchomiono albo
        /// dlaczego nie. Null tylko wtedy, gdy automat jest wyłączony w ustawieniach.
        /// </summary>
        public string TryStart(string subiektVersion)
        {
            if (!_settings.Enabled)
            {
                return null;
            }
            var parts = subiektVersion.Split('.');
            var shortVersion = string.Join(".", parts.Length >= 3 ? parts[..3] : parts);
            if (!File.Exists(ScriptPath))
            {
                return $"automatyczna podmiana SDK niemożliwa: nie ma {ScriptPath}";
            }

            var statePath = Path.Combine(_runnerDir, StateName);
            var state = ReadState(statePath);
            if (state != null && state.Version == shortVersion)
            {
                var age = DateTimeOffset.UtcNow - state.StartedAt;
                var startedLocal = state.StartedAt.ToLocalTime().ToString("HH:mm:ss");
                if (state.Result == "running" && age < RunningTimeout)
                {
                    return $"automatyczna podmiana SDK na {shortVersion} już trwa (od {startedLocal})";
                }
                if (state.Result == "ok" && age < RetryAfter)
                {
                    return $"automatyczna podmiana SDK na {shortVersion} zakończyła się o {startedLocal}, runner czeka na restart";
                }
                if (state.Result == "failed" && age < RetryAfter)
                {
                    return $"automatyczna podmiana SDK na {shortVersion} nie powiodła się o {startedLocal} ({state.Message}); kolejna próba po godzinie";
                }
            }

            WriteState(statePath, new State { Version = shortVersion, StartedAt = DateTimeOffset.UtcNow, Result = "running", Message = "uruchomiono z NexoClient" });
            var logPath = Path.Combine(_runnerDir, "Logs", "nexo-sdk-update.log");
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = _runnerDir,
            };
            foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ScriptPath,
                                      "-Version", shortVersion, "-RunnerDir", _runnerDir, "-ServiceName", _settings.ServiceName ?? "ZapqioRunner",
                                      "-Log", logPath, "-State", statePath })
            {
                psi.ArgumentList.Add(a);
            }
            if (!string.IsNullOrWhiteSpace(_settings.ModulesUrl))
            {
                psi.ArgumentList.Add("-ModulesUrl");
                psi.ArgumentList.Add(_settings.ModulesUrl);
            }
            if (!_settings.Restart)
            {
                psi.ArgumentList.Add("-NoRestart");
            }
            try
            {
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                WriteState(statePath, new State { Version = shortVersion, StartedAt = DateTimeOffset.UtcNow, Result = "failed", Message = ex.Message });
                return $"automatyczna podmiana SDK nie wystartowała: {ex.Message}";
            }
            var restart = _settings.Restart ? "usługa runnera zostanie zrestartowana, zadania w toku zakończą się błędem" : "bez restartu (Restart=false), zrestartuj runner po zakończeniu";
            return $"uruchomiono automatyczną podmianę SDK na {shortVersion} (log: {logPath}); {restart}";
        }

        private static State ReadState(string path)
        {
            try
            {
                return File.Exists(path) ? JsonSerializer.Deserialize<State>(File.ReadAllText(path), Json) : null;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
            {
                return null;
            }
        }

        private static void WriteState(string path, State state)
        {
            try
            {
                File.WriteAllText(path, JsonSerializer.Serialize(state, Json));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }

        /// <summary>Ten sam plik czyta i dopisuje skrypt (result, message, finishedAt).</summary>
        private sealed class State
        {
            [JsonPropertyName("version")] public string Version { get; set; }
            [JsonPropertyName("startedAt")] public DateTimeOffset StartedAt { get; set; }
            [JsonPropertyName("finishedAt")] public DateTimeOffset? FinishedAt { get; set; }
            [JsonPropertyName("result")] public string Result { get; set; }
            [JsonPropertyName("message")] public string Message { get; set; }
        }
    }
}
