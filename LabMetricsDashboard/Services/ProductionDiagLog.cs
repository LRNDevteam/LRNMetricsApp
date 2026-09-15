using Microsoft.Extensions.Logging;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Temporary Production Summary diagnostics. Appends the same line to every
/// path below so both IIS (/LRNMetrics) and VS IIS Express (localhost:44351)
/// land in a file we can read after a reproduce.
/// </summary>
internal static class ProductionDiagLog
{
    private static readonly string[] Paths =
    [
        Path.Combine(AppContext.BaseDirectory, "Logs", "production-summary.log"),
        Path.Combine(@"E:\LRN-GitHub\2026\LRNDevTeam\LabMetricsDashboard", "Logs", "production-summary.log"),
        Path.Combine(@"E:\LRN-Data\PayerPolicy_v2\2026\DeploymentChanges-2026\LabMetricsApplication\LrnMetric", "Logs", "production-summary.log"),
    ];

    public static void Write(string message)
    {
        var line = $"{DateTime.Now:HH:mm:ss.fff} [PrDiag] {message}{Environment.NewLine}";
        foreach (var path in Paths)
        {
            try
            {
                var dir = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(dir))
                    Directory.CreateDirectory(dir);
                File.AppendAllText(path, line);
            }
            catch
            {
                // never fail a page because logging failed
            }
        }
    }

    public static void Write(ILogger logger, string message)
    {
        logger.LogWarning("[PrDiag] {Message}", message);
        Write(message);
    }

    public static void Error(ILogger logger, Exception ex, string message)
    {
        logger.LogError(ex, "[PrDiag] {Message}", message);
        Write($"{message} EX={ex.GetType().Name}: {ex.Message} | {ex.StackTrace}");
    }
}
