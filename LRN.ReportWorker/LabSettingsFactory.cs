using LabMetricsDashboard.Models;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker;

/// <summary>
/// Builds the same <see cref="LabSettings"/> the dashboard uses, from the same
/// per-lab JSON files ({LabConfigFolder}\{LabName}.json, root section = lab name).
/// Needed by the web services the worker reuses (LabCsvFileResolver, view-model
/// builders) for the Prediction / Forecasting generators.
/// </summary>
public static class LabSettingsFactory
{
    public static LabSettings Build(string configFolder, IReadOnlyList<string> labNames, ILogger logger)
    {
        var builder = new ConfigurationBuilder();
        var found = new List<string>();

        foreach (var lab in labNames)
        {
            var path = Path.Combine(configFolder, $"{lab}.json");
            if (File.Exists(path))
            {
                builder.AddJsonFile(path, optional: true, reloadOnChange: false);
                found.Add(lab);
            }
            else
            {
                logger.LogWarning("Lab config not found: {Path} — {Lab} skipped.", path, lab);
            }
        }

        var config = builder.Build();
        return new LabSettings
        {
            Labs = found.ToDictionary(
                lab => lab,
                lab => config.GetSection(lab).Get<LabCsvConfig>() ?? new LabCsvConfig(),
                StringComparer.OrdinalIgnoreCase),
        };
    }
}
