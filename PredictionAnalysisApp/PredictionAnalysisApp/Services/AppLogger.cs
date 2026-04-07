using System.Text;

namespace PredictionAnalysis.Services;

/// <summary>
/// Application-level general log that spans the entire run session.
/// Writes timestamped entries to:
///   PredictionAnalysis_AppLog_{yyyyMMdd_HHmmss}.txt
/// in the shared log output folder.
///
/// Usage:
///   AppLogger.Initialize(logFolder);
///   AppLogger.Log("message");
///   AppLogger.LogError("something failed", ex);
///   AppLogger.Flush();   // at the end of Program.cs
/// </summary>
public static class AppLogger
{
    private static StreamWriter? _writer;
    private static string        _logFilePath = string.Empty;
    private static readonly object _lock = new();

    public static string LogFilePath => _logFilePath;

    // ── Initialization ────────────────────────────────────────────────────────

    /// <summary>
    /// Call once at startup before the lab loop begins.
    /// Creates a daily log file (one per day) that all runs append to.
    /// </summary>
    public static void Initialize(string logFolder)
    {
        Directory.CreateDirectory(logFolder);

        _logFilePath = Path.Combine(
            logFolder,
            $"PredictionAnalysis_AppLog_{DateTime.Now:yyyyMMdd}.txt");

        _writer = new StreamWriter(_logFilePath, append: true, encoding: Encoding.UTF8)
        {
            AutoFlush = true
        };

        Write("INFO ", $"=== Application run started at {DateTime.Now:yyyy-MM-dd HH:mm:ss} ===");
        Write("INFO ", $"Log file: {_logFilePath}");
    }

    // ── Public logging methods ────────────────────────────────────────────────

    public static void Log(string message)
        => Write("INFO ", message);

    public static void LogWarn(string message)
        => Write("WARN ", message);

    public static void LogDb(string message)
        => Write("DB   ", message);

    public static void LogDbWarn(string message)
        => Write("DB[!]", message);

    public static void LogDbError(string message, Exception ex)
    {
        Write("DB[!]", message);
        Write("DB[!]", $"  {ex.GetType().Name}: {ex.Message}");
        if (ex.InnerException != null)
            Write("DB[!]", $"  Inner: {ex.InnerException.GetType().Name}: {ex.InnerException.Message}");
        if (ex.StackTrace != null)
            foreach (var line in ex.StackTrace.Split('\n'))
                Write("DB[!]", line.TrimEnd());
    }

    public static void LogError(string message, Exception? ex = null)
    {
        Write("ERROR", message);
        if (ex != null)
        {
            Write("ERROR", $"  Exception : {ex.GetType().Name}: {ex.Message}");
            if (ex.StackTrace != null)
                foreach (var line in ex.StackTrace.Split('\n'))
                    Write("     ", line.TrimEnd());
        }
    }

    /// <summary>
    /// Write the final run summary and close the log file. 
    /// </summary>
    public static void Flush(int success, int failed, int skipped, TimeSpan elapsed)
    {
        Write("INFO ", $"=== Run Complete ===");
        Write("INFO ", $"  Success : {success}");
        Write("INFO ", $"  Failed  : {failed}");
        Write("INFO ", $"  Skipped : {skipped}");
        Write("INFO ", $"  Elapsed : {elapsed:mm\\:ss}");
        Write("INFO ", $"=== Application ended ===");

        lock (_lock)
        {
            _writer?.Flush();
            _writer?.Dispose();
            _writer = null;
        }
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    private static void Write(string level, string message)
    {
        if (_writer == null) return;

        var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] [{level}] {message}";

        lock (_lock)
        {
            _writer.WriteLine(line);
        }

        // Also echo to console (captured by FileLogger tee if inside a lab block)
        Console.WriteLine(line);
    }
}
