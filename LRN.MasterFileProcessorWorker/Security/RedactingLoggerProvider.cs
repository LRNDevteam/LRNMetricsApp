namespace LRN.MasterFileProcessorWorker.Security;

/// <summary>
/// Wraps a logger provider so every message and exception it writes passes through
/// <see cref="PhiRedactor"/> first.
/// <para>
/// Used for the Windows event log, which is kept on the server and read by anyone with admin rights
/// there. The console provider is not wrapped: a Windows service has no console, so nothing it
/// writes is kept.
/// </para>
/// <para>
/// Filter rules bind to the provider TYPE, so a rule written for the inner provider (for example
/// <c>AddFilter&lt;EventLogLoggerProvider&gt;</c>) no longer applies - register it against
/// <see cref="RedactingLoggerProvider"/> instead.
/// </para>
/// </summary>
public sealed class RedactingLoggerProvider : ILoggerProvider
{
    private readonly ILoggerProvider _inner;

    public RedactingLoggerProvider(ILoggerProvider inner) => _inner = inner;

    public ILogger CreateLogger(string categoryName) => new RedactingLogger(_inner.CreateLogger(categoryName));

    public void Dispose() => _inner.Dispose();

    private sealed class RedactingLogger : ILogger
    {
        private readonly ILogger _inner;

        public RedactingLogger(ILogger inner) => _inner = inner;

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => _inner.BeginScope(state);

        public bool IsEnabled(LogLevel logLevel) => _inner.IsEnabled(logLevel);

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            // The original exception goes to the original formatter (it may read properties off it);
            // only what leaves this process is scrubbed.
            _inner.Log(logLevel, eventId, state, PhiRedactor.Wrap(exception),
                (s, _) => PhiRedactor.Scrub(formatter(s, exception)) ?? "");
        }
    }
}
