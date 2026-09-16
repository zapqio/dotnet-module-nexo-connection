using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Nexo
{
    /// <summary>
    /// Wspólny plik ustawień modułów Nexo: <c>Config\nexoModule.json</c> obok binarki runnera (katalog
    /// <c>Config\</c> zakłada runner, uprawnienia nadaje jego install.ps1). Każda klasa ustawień woła
    /// <see cref="Populate{T}"/> w konstruktorze: plik jest czytany, brakujące klucze dopisywane z wartości
    /// domyślnych klasy, a instancja wypełniana. Dzięki temu po starcie wszystkich modułów plik ma komplet
    /// kluczy do uzupełnienia, choć każdy moduł zna tylko swoje.
    /// </summary>
    public static class NexoConfig
    {
        public const string FileName = "nexoModule.json";

        private static readonly object Sync = new();
        private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
        [ThreadStatic] private static bool _loading;

        /// <summary>Katalog konfiguracji modułów runnera.</summary>
        public static string DirectoryPath => Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Config");

        /// <summary>Pełna ścieżka pliku ustawień modułów Nexo.</summary>
        public static string FilePath => Path.Combine(DirectoryPath, FileName);

        /// <summary>
        /// Wypełnia <paramref name="instance"/> z pliku. Zwraca false przy wywołaniu zwrotnym z deserializacji
        /// (wtedy konstruktor ma zostawić wartości domyślne). Brak pliku = plik z wartościami domyślnymi;
        /// stary <c>nexoModule.json</c> obok binarki jest przenoszony do <c>Config\</c>.
        /// </summary>
        public static bool Populate<T>(T instance) where T : class, new()
        {
            if (_loading)
            {
                return false;
            }
            lock (Sync)
            {
                _loading = true;
                try
                {
                    EnsureFile();
                    var file = ReadObject();
                    var defaults = JsonSerializer.SerializeToNode(new T(), Options) as JsonObject ?? new JsonObject();
                    if (Merge(file, defaults))
                    {
                        File.WriteAllText(FilePath, file.ToJsonString(Options));
                    }
                    var data = file.Deserialize<T>(Options) ?? new T();
                    foreach (var property in typeof(T).GetProperties())
                    {
                        if (property.CanRead && property.CanWrite)
                        {
                            property.SetValue(instance, property.GetValue(data));
                        }
                    }
                    return true;
                }
                finally
                {
                    _loading = false;
                }
            }
        }

        private static void EnsureFile()
        {
            Directory.CreateDirectory(DirectoryPath);
            if (File.Exists(FilePath))
            {
                return;
            }
            // Instalacje sprzed katalogu Config: plik leżał obok binarki runnera.
            var old = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, FileName);
            if (File.Exists(old))
            {
                File.Move(old, FilePath);
            }
        }

        private static JsonObject ReadObject()
        {
            if (!File.Exists(FilePath))
            {
                return new JsonObject();
            }
            return JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject ?? new JsonObject();
        }

        /// <summary>Dopisuje do <paramref name="target"/> klucze, których brakuje; obiekty zagnieżdżone rekurencyjnie.</summary>
        private static bool Merge(JsonObject target, JsonObject defaults)
        {
            var changed = false;
            foreach (var pair in defaults)
            {
                if (!target.ContainsKey(pair.Key))
                {
                    target[pair.Key] = pair.Value?.DeepClone();
                    changed = true;
                }
                else if (target[pair.Key] is JsonObject existing && pair.Value is JsonObject nested)
                {
                    changed |= Merge(existing, nested);
                }
            }
            return changed;
        }
    }
}
