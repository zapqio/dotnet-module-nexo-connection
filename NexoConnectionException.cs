using System;

namespace Nexo
{
    /// <summary>
    /// Sfera nie nawiązała połączenia z Subiektem. Komunikat niesie wersję SDK z paczki na runnerze
    /// i treść błędu Sfery; oryginalny wyjątek jest w <see cref="Exception.InnerException"/>.
    /// Najczęstszy powód to SDK w innej wersji niż Subiekt po jego aktualizacji.
    /// </summary>
    public class NexoConnectionException : Exception
    {
        public NexoConnectionException(string message, Exception inner) : base(message, inner)
        {
        }
    }
}
