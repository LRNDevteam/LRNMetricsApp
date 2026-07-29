using System.Collections.Concurrent;
using System.Globalization;

namespace LRN.ReportsApi.Services;

public sealed class FileLoggerOptions
{
    public string LogDirectory { get; set; } = "Logs/Api";
    public LogLevel MinLevel { get; set; } = LogLevel.Information;
    public int RetainDays { get; set; } = 30;
}

public sealed class FileLoggerProvider : ILoggerProvider
{
    private readonly ConcurrentDictionary<string, FileLogger> _loggers = new(StringComparer.OrdinalIgnoreCase);
    private readonly FileLogWriter _writer;
    private readonly LogLevel _minLevel;

    public FileLoggerProvider(FileLoggerOptions options)
    {
        var directory = Path.IsPathRooted(options.LogDirectory) ? options.LogDirectory : Path.Combine(AppContext.BaseDirectory, options.LogDirectory);
        Directory.CreateDirectory(directory);
        _writer = new FileLogWriter(directory, options.RetainDays);
        _minLevel = options.MinLevel;
    }

    public ILogger CreateLogger(string categoryName) => _loggers.GetOrAdd(categoryName, name => new FileLogger(name, _minLevel, _writer));
    public void Dispose() => _writer.Dispose();
}

internal sealed class FileLogger(string category, LogLevel minLevel, FileLogWriter writer) : ILogger
{
    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
    public bool IsEnabled(LogLevel logLevel) => logLevel >= minLevel;
    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        if (!IsEnabled(logLevel)) return;
        var entry = $"[{DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture)}] [{logLevel.ToString().ToUpperInvariant()}] [{category}] {formatter(state, exception)}";
        if (exception is not null) entry += Environment.NewLine + exception;
        writer.Write(entry);
    }
}

internal sealed class FileLogWriter : IDisposable
{
    private readonly string _directory;
    private readonly object _lock = new();
    private StreamWriter? _writer;
    private string _date = string.Empty;

    public FileLogWriter(string directory, int retainDays)
    {
        _directory = directory;
        if (retainDays <= 0) return;
        try
        {
            var cutoff = DateTime.Now.AddDays(-retainDays);
            foreach (var file in Directory.GetFiles(directory, "api-*.log"))
                if (File.GetLastWriteTime(file) < cutoff) File.Delete(file);
        }
        catch { }
    }

    public void Write(string entry)
    {
        var today = DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        lock (_lock)
        {
            try
            {
                if (_date != today || _writer is null)
                {
                    _writer?.Dispose();
                    _writer = OpenShared(Path.Combine(_directory, $"api-{today}.log"));
                    _date = today;
                }
                _writer.WriteLine(entry);
            }
            catch (IOException)
            {
                // Another process holds the handle for a moment (or is rolling the file). Never let
                // logging throw into the request pipeline — drop this line and re-open next time.
                try { _writer?.Dispose(); } catch { }
                _writer = null;
                _date = string.Empty;
            }
        }
    }

    // Open the rolling log with FileShare.ReadWrite so more than one API process (e.g. a VS debug
    // instance and a dotnet-run instance) can append to the same day's file without a sharing lock.
    private static StreamWriter OpenShared(string path)
    {
        var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
        return new StreamWriter(stream, System.Text.Encoding.UTF8) { AutoFlush = true };
    }

    public void Dispose() { lock (_lock) { try { _writer?.Dispose(); } catch { } } }
}
