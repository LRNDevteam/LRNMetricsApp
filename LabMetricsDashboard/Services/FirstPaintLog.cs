using Microsoft.Extensions.Logging;

namespace LabMetricsDashboard.Services;

/// <summary>
/// First-paint timings for Production / Collection / LIS. Written at Warning so the
/// file logger keeps them, and also appended to Logs/first-paint.log under the app
/// and the repo so we can read them after a debug session.
/// </summary>
internal static class FirstPaintLog
{
    private static readonly string[] Paths =
    [
        Path.Combine(AppContext.BaseDirectory, "Logs", "first-paint.log"),
        Path.Combine(@"E:\LRN-GitHub\2026\LRNDevTeam\LabMetricsDashboard", "Logs", "first-paint.log"),
    ];

    public static void Write(ILogger logger, string report, string lab, string stage, long ms, string extra = "")
    {
        var line = $"[FirstPaint] {report} lab={lab} {stage} {ms}ms {extra}".TrimEnd();
        logger.LogWarning("{Line}", line);
        var text = $"{DateTime.Now:HH:mm:ss.fff} {line}{Environment.NewLine}";
        foreach (var path in Paths)
        {
            try
            {
                var dir = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(dir))
                    Directory.CreateDirectory(dir);
                File.AppendAllText(path, text);
            }
            catch
            {
                // never fail a page because logging failed
            }
        }
    }
}
