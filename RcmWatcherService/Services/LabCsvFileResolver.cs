using Microsoft.Extensions.Logging;
using RcmWatcherService.Models;

namespace RcmWatcherService.Services;

/// <summary>
/// Resolves the latest Claim Level CSV for a lab by walking all sub-folders
/// under <see cref="LabCsvConfig.ProductionMasterCsvPath"/>.
/// "Latest" = highest <c>LastWriteTimeUtc</c> among all matching files.
/// </summary>
public sealed class LabCsvFileResolver
{
    private const string ClaimLevelKeyword = "Claim Level";

    private readonly LabSettings                 _labSettings;
    private readonly ILogger<LabCsvFileResolver> _logger;

    public LabCsvFileResolver(LabSettings labSettings, ILogger<LabCsvFileResolver> logger)
    {
        _labSettings = labSettings;
        _logger      = logger;
    }

    /// <summary>
    /// Returns the full path of the latest Claim Level CSV for the given lab,
    /// or <c>null</c> when none is found.
    /// </summary>
    public string? ResolveClaimLevelCsv(string labName)
    {
        if (!_labSettings.Labs.TryGetValue(labName, out var config))
        {
            _logger.LogWarning("Lab '{Lab}' not found in LabSettings.", labName);
            return null;
        }

        var root = config.ProductionMasterCsvPath;

        if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
        {
            _logger.LogWarning(
                "ProductionMasterCsvPath '{Path}' for lab '{Lab}' does not exist.",
                root, labName);
            return null;
        }

        var match = Directory
            .EnumerateFiles(root, "*.csv", SearchOption.AllDirectories)
            .Where(f => Path.GetFileName(f).Contains(ClaimLevelKeyword, StringComparison.OrdinalIgnoreCase))
            .Select(f => new FileInfo(f))
            .MaxBy(fi => fi.LastWriteTimeUtc)
            ?.FullName;

        if (match is null)
            _logger.LogWarning("No Claim Level CSV found under '{Path}' for lab '{Lab}'.", root, labName);
        else
            _logger.LogInformation("Resolved Claim Level CSV for '{Lab}': {File}", labName, match);

        return match;
    }
}
