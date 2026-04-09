using Microsoft.Extensions.Configuration;

namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// Lightweight logger that writes timestamped entries to both the console
/// and a rolling daily log file under <c>Logging:LogFolder</c>.
/// Old log files beyond <c>Logging:RetainDays</c> are pruned on startup.
/// </summary>
public sealed class AppLogger : IDisposable
{
    private readonly StreamWriter _writer;
    private readonly string _logFilePath;
    private bool _disposed;

    public AppLogger(IConfiguration cfg)
    {
        var logFolder = cfg["Logging:LogFolder"]
            ?? Path.Combine(AppContext.BaseDirectory, "Logs");

        Directory.CreateDirectory(logFolder);

        var dateSuffix = DateTime.Now.ToString("yyyyMMdd");
        _logFilePath = Path.Combine(logFolder, $"ClaimLineCSVDataCapture_{dateSuffix}.log");

        _writer = new StreamWriter(_logFilePath, append: true, encoding: System.Text.Encoding.UTF8)
        {
            AutoFlush = true
        };

        PruneOldLogs(logFolder, cfg);
    }

    public void Info(string message)    => Write("INFO ", message);
    public void Success(string message) => Write("OK   ", message);
    public void Warn(string message)    => Write("WARN ", message);
    public void Error(string message)   => Write("ERROR", message);
    public void Blank()                 => Write(null, string.Empty);

    /// <summary>Writes a section header banner.</summary>
    public void Header(string title)
    {
        var line = new string('-', 60);
        Write(null, line);
        Write("INFO ", title);
        Write(null, line);
    }

    public string LogFilePath => _logFilePath;

    private void Write(string? level, string message)
    {
        var timestamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        var prefix    = level is null ? new string(' ', 25) : $"{timestamp} [{level}]";
        var formatted = $"{prefix} {message}";

        Console.WriteLine(formatted);
        _writer.WriteLine(formatted);
    }

    private static void PruneOldLogs(string logFolder, IConfiguration cfg)
    {
        if (!int.TryParse(cfg["Logging:RetainDays"], out var retainDays) || retainDays <= 0)
            retainDays = 30;

        var cutoff = DateTime.Now.AddDays(-retainDays);
        foreach (var file in Directory.EnumerateFiles(logFolder, "ClaimLineCSVDataCapture_*.log"))
        {
            try
            {
                if (File.GetLastWriteTime(file) < cutoff)
                    File.Delete(file);
            }
            catch { /* best-effort */ }
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _writer.Flush();
        _writer.Dispose();
        _disposed = true;
    }
}
