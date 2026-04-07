using System.Text;

namespace PredictionAnalysis.Services;

/// <summary>
/// Tees every Console.Write / Console.WriteLine to both the console window
/// and a plain-text .txt log file saved in the log output folder.
/// Usage: using var log = FileLogger.Attach(logFolder, labName);
/// </summary>
public sealed class FileLogger : TextWriter
{
    private readonly TextWriter   _originalConsole;
    private readonly StreamWriter _fileWriter;

    public string LogFilePath { get; }

    public override Encoding Encoding => Encoding.UTF8;

    // ── Construction ──────────────────────────────────────────────────────────

    private FileLogger(TextWriter originalConsole, StreamWriter fileWriter, string logFilePath)
    {
        _originalConsole = originalConsole;
        _fileWriter      = fileWriter;
        LogFilePath      = logFilePath;
    }

    /// <summary>
    /// Creates a daily .txt log file named
    /// PredictionAnalysis_{labName}_{yyyyMMdd}.txt in <paramref name="logFolder"/>,
    /// appending to the same file for all runs on the same day.
    /// Replaces Console.Out with this tee-writer and returns the logger instance.
    /// </summary>
    public static FileLogger Attach(string logFolder, string labName)
    {
        Directory.CreateDirectory(logFolder);

        var logFilePath = Path.Combine(
            logFolder,
            $"PredictionAnalysis_{labName}_{DateTime.Now:yyyyMMdd}.txt");

        var fileWriter = new StreamWriter(logFilePath, append: true, encoding: Encoding.UTF8)
        {
            AutoFlush = true
        };

        var logger = new FileLogger(Console.Out, fileWriter, logFilePath);
        Console.SetOut(logger);
        if (!File.Exists(logFilePath))
            Console.WriteLine($"[Log] Log file: {logFilePath}");
        else
            Console.WriteLine($"[Log] Appending to: {logFilePath}");
        return logger;
    }

    // ── TextWriter overrides ──────────────────────────────────────────────────

    public override void Write(char value)
    {
        _originalConsole.Write(value);
        _fileWriter.Write(value);
    }

    public override void Write(string? value)
    {
        _originalConsole.Write(value);
        _fileWriter.Write(value);
    }

    public override void WriteLine()
    {
        _originalConsole.WriteLine();
        _fileWriter.WriteLine();
    }

    public override void WriteLine(string? value)
    {
        // Prefix every line in the text file with a timestamp
        var stamped = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}]  {value}";
        _originalConsole.WriteLine(stamped);
        _fileWriter.WriteLine(stamped);
    }

    // ── Cleanup ───────────────────────────────────────────────────────────────

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            Console.SetOut(_originalConsole);  // restore original Console.Out
            _fileWriter.Flush();
            _fileWriter.Dispose();
        }
        base.Dispose(disposing);
    }
}