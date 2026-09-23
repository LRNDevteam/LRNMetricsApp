using Microsoft.Extensions.Logging;

namespace LabMetricsDashboard.Services;

/// <summary>
/// First-paint timings for Production / Collection / LIS. Diagnostic only, so written at
/// Debug and silent in production. To capture them again, set
/// "Logging:LogLevel:LabMetricsDashboard": "Debug" — they then also go to Logs/first-paint.log.
/// </summary>
internal static class FirstPaintLog
{
    private static readonly string LogPath = Path.Combine(AppContext.BaseDirectory, "Logs", "first-paint.log");
    private static readonly object FileLock = new();

    public static void Write(ILogger logger, string report, string lab, string stage, long ms, string extra = "")
    {
        if (!logger.IsEnabled(LogLevel.Debug))
            return;

        var line = $"[FirstPaint] {report} lab={lab} {stage} {ms}ms {extra}".TrimEnd();
        logger.LogDebug("{Line}", line);
        try
        {
            lock (FileLock)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
                File.AppendAllText(LogPath, $"{DateTime.Now:HH:mm:ss.fff} {line}{Environment.NewLine}");
            }
        }
        catch
        {
            // never fail a page because logging failed
        }
    }
}
