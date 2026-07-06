using System.Collections.Concurrent;
using System.Globalization;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Configuration for the rolling-file logger.
/// </summary>
public sealed class FileLoggerOptions
{
    /// <summary>Folder where log files are written. Defaults to "Logs" under the app root.</summary>
    public string LogDirectory { get; set; } = "Logs";

    /// <summary>Minimum log level written to file. Defaults to Warning.</summary>
    public LogLevel MinLevel { get; set; } = LogLevel.Warning;

    /// <summary>Minimum log level written to the Production Excel split log. Defaults to Information.</summary>
    public LogLevel ProductionExcelSplitMinLevel { get; set; } = LogLevel.Information;

    /// <summary>Number of days to retain log files. 0 = keep forever.</summary>
    public int RetainDays { get; set; } = 30;
}

/// <summary>
/// A lightweight rolling-file logger provider.
/// Creates one log file per day: <c>app-yyyy-MM-dd.log</c>.
/// Thread-safe; flushes immediately so crash context is never lost.
/// </summary>
public sealed class FileLoggerProvider : ILoggerProvider
{
    private readonly FileLoggerOptions _options;
    private readonly ConcurrentDictionary<string, FileLogger> _loggers = new(StringComparer.OrdinalIgnoreCase);
    private readonly FileLogWriter _writer;
    private readonly FileLogWriter _productionExcelSplitWriter;

    public FileLoggerProvider(FileLoggerOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _options = options;

        var dir = Path.IsPathRooted(options.LogDirectory)
            ? options.LogDirectory
            : Path.Combine(AppContext.BaseDirectory, options.LogDirectory);

        Directory.CreateDirectory(dir);
        _writer = new FileLogWriter(dir, "app", options.RetainDays);
        _productionExcelSplitWriter = new FileLogWriter(dir, "prod-excel-export-split", options.RetainDays);
    }

    public ILogger CreateLogger(string categoryName) =>
        _loggers.GetOrAdd(categoryName, name => new FileLogger(
            name,
            _options.MinLevel,
            _options.ProductionExcelSplitMinLevel,
            _writer,
            _productionExcelSplitWriter));

    public void Dispose()
    {
        _writer.Dispose();
        _productionExcelSplitWriter.Dispose();
        _loggers.Clear();
    }
}

/// <summary>
/// Logger instance that formats and delegates writes to <see cref="FileLogWriter"/>.
/// </summary>
internal sealed class FileLogger : ILogger
{
    private readonly string _category;
    private readonly LogLevel _minLevel;
    private readonly LogLevel _productionExcelSplitMinLevel;
    private readonly FileLogWriter _writer;
    private readonly FileLogWriter _productionExcelSplitWriter;

    internal FileLogger(
        string category,
        LogLevel minLevel,
        LogLevel productionExcelSplitMinLevel,
        FileLogWriter writer,
        FileLogWriter productionExcelSplitWriter)
    {
        _category = category;
        _minLevel = minLevel;
        _productionExcelSplitMinLevel = productionExcelSplitMinLevel;
        _writer = writer;
        _productionExcelSplitWriter = productionExcelSplitWriter;
    }

    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

    public bool IsEnabled(LogLevel logLevel) =>
        logLevel >= _minLevel || logLevel >= _productionExcelSplitMinLevel;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state,
        Exception? exception, Func<TState, Exception?, string> formatter)
    {
        var timestamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture);
        var level = logLevel.ToString().ToUpperInvariant();
        var message = formatter(state, exception);
        var isProductionExcelSplitLog = message.Contains("[ProdExcelExportSplit]", StringComparison.Ordinal);

        if (logLevel < _minLevel && (!isProductionExcelSplitLog || logLevel < _productionExcelSplitMinLevel))
            return;

        var entry = $"[{timestamp}] [{level}] [{_category}] {message}";

        if (exception is not null)
        {
            entry += Environment.NewLine + FormatException(exception);
        }

        if (logLevel >= _minLevel)
            _writer.Write(entry);

        if (isProductionExcelSplitLog && logLevel >= _productionExcelSplitMinLevel)
            _productionExcelSplitWriter.Write(entry);
    }

    private static string FormatException(Exception ex)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine($"  Exception Type : {ex.GetType().FullName}");
        sb.AppendLine($"  Message        : {ex.Message}");
        sb.AppendLine($"  Stack Trace    : {ex.StackTrace}");

        var inner = ex.InnerException;
        var depth = 0;
        while (inner is not null && depth < 5)
        {
            depth++;
            sb.AppendLine($"  --- Inner Exception (depth {depth}) ---");
            sb.AppendLine($"  Type    : {inner.GetType().FullName}");
            sb.AppendLine($"  Message : {inner.Message}");
            sb.AppendLine($"  Stack   : {inner.StackTrace}");
            inner = inner.InnerException;
        }

        return sb.ToString();
    }
}

/// <summary>
/// Thread-safe writer that appends to a daily rolling log file.
/// Purges files older than <paramref name="retainDays"/> on startup.
/// </summary>
internal sealed class FileLogWriter : IDisposable
{
    private readonly string _directory;
    private readonly string _filePrefix;
    private readonly Lock _lock = new();
    private StreamWriter? _currentWriter;
    private string _currentDate = string.Empty;

    internal FileLogWriter(string directory, string filePrefix, int retainDays)
    {
        _directory = directory;
        _filePrefix = filePrefix;
        PurgeOldFiles(retainDays);
    }

    internal void Write(string entry)
    {
        var today = DateTime.Now.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);

        lock (_lock)
        {
            try
            {
                if (_currentDate != today)
                {
                    _currentWriter?.Flush();
                    _currentWriter?.Dispose();

                    var path = Path.Combine(_directory, $"{_filePrefix}-{today}.log");
                    _currentWriter = new StreamWriter(path, append: true, System.Text.Encoding.UTF8)
                    {
                        AutoFlush = true
                    };
                    _currentDate = today;
                }

                _currentWriter!.WriteLine(entry);
            }
            catch (UnauthorizedAccessException)
            {
                // Logging must never terminate the web application.
                _currentWriter?.Dispose();
                _currentWriter = null;
                _currentDate = string.Empty;
            }
            catch (IOException)
            {
                // Transient file locks or unavailable paths are best-effort logging failures.
                _currentWriter?.Dispose();
                _currentWriter = null;
                _currentDate = string.Empty;
            }
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _currentWriter?.Flush();
            _currentWriter?.Dispose();
            _currentWriter = null;
        }
    }

    private void PurgeOldFiles(int retainDays)
    {
        if (retainDays <= 0) return;

        try
        {
            var cutoff = DateTime.Now.AddDays(-retainDays);
            foreach (var file in Directory.GetFiles(_directory, $"{_filePrefix}-*.log"))
            {
                if (File.GetLastWriteTime(file) < cutoff)
                    File.Delete(file);
            }
        }
        catch
        {
            // Purge is best-effort; don't crash the app on cleanup failure.
        }
    }
}
