using System;
using System.Collections.Concurrent;
using System.IO;
using System.Reflection;
using log4net;
using log4net.Config;
using log4net.Repository;
using Microsoft.Extensions.Logging;

/// <summary>
/// Minimal Microsoft.Extensions.Logging provider that writes to log4net.
/// Keeps your existing ILogger&lt;T&gt; calls, but also writes them into a rolling file.
/// </summary>
public sealed class Log4NetLoggerProvider : ILoggerProvider
{
    private readonly ConcurrentDictionary<string, Log4NetLogger> _loggers = new();
    private readonly ILoggerRepository _repo;

    public Log4NetLoggerProvider(string configFilePath, string logDir)
    {
        if (string.IsNullOrWhiteSpace(configFilePath))
            throw new ArgumentException("configFilePath is required.", nameof(configFilePath));

        if (string.IsNullOrWhiteSpace(logDir))
            throw new ArgumentException("logDir is required.", nameof(logDir));

        Directory.CreateDirectory(logDir);

        // Make log dir available to log4net.config via %property{LogDir}
        log4net.GlobalContext.Properties["LogDir"] = logDir;

        // Use entry assembly repository so configuration applies consistently
        var entryAsm = Assembly.GetEntryAssembly() ?? typeof(Log4NetLoggerProvider).Assembly;
        _repo = log4net.LogManager.GetRepository(entryAsm);

        if (!File.Exists(configFilePath))
            throw new FileNotFoundException($"log4net.config not found at: {configFilePath}");

        XmlConfigurator.ConfigureAndWatch(_repo, new FileInfo(configFilePath));
    }

    public Microsoft.Extensions.Logging.ILogger CreateLogger(string categoryName)
        => _loggers.GetOrAdd(categoryName, n => new Log4NetLogger(_repo, n));

    public void Dispose() => _loggers.Clear();
}

internal sealed class Log4NetLogger : Microsoft.Extensions.Logging.ILogger
{
    private readonly ILog _log;

    public Log4NetLogger(ILoggerRepository repo, string categoryName)
    {
        _log = log4net.LogManager.GetLogger(repo.Name, categoryName);
    }

    public IDisposable BeginScope<TState>(TState state) => NullScope.Instance;

    public bool IsEnabled(LogLevel logLevel) => logLevel != LogLevel.None;

    public void Log<TState>(
        LogLevel logLevel,
        EventId eventId,
        TState state,
        Exception? exception,
        Func<TState, Exception?, string> formatter)
    {
        if (!IsEnabled(logLevel)) return;

        var message = formatter(state, exception);
        if (string.IsNullOrWhiteSpace(message) && exception is null) return;

        switch (logLevel)
        {
            case LogLevel.Trace:
            case LogLevel.Debug:
                if (_log.IsDebugEnabled) _log.Debug(message, exception);
                break;
            case LogLevel.Information:
                if (_log.IsInfoEnabled) _log.Info(message, exception);
                break;
            case LogLevel.Warning:
                if (_log.IsWarnEnabled) _log.Warn(message, exception);
                break;
            case LogLevel.Error:
                if (_log.IsErrorEnabled) _log.Error(message, exception);
                break;
            case LogLevel.Critical:
                if (_log.IsFatalEnabled) _log.Fatal(message, exception);
                break;
            default:
                if (_log.IsInfoEnabled) _log.Info(message, exception);
                break;
        }
    }

    private sealed class NullScope : IDisposable
    {
        public static NullScope Instance { get; } = new();
        public void Dispose() { }
    }
}
