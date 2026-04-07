using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Resolves the latest Claim Level and Line Level CSV files for each lab
/// by walking all sub-folders under ProductionMasterCsvPath.
///
/// Folder layout is flexible — works with:
///   {root}\{year}\{month}\{week}\file.csv
///   {root}\{month}\{week}\file.csv
///   {root}\{week}\file.csv
///   Any other depth, mixed across labs.
///
/// "Latest" = highest LastWriteTimeUtc among all matching files.
/// </summary>
public sealed class LabCsvFileResolver
{
    private const string ClaimLevelKeyword    = "Claim Level";
    private const string LineLevelKeyword     = "Line Level";
    private const string PredictionKeyword    = "Payer_Policy_ValidationReport";

    private readonly LabSettings _labSettings;
    private readonly ILogger<LabCsvFileResolver> _logger;

    public LabCsvFileResolver(LabSettings labSettings, ILogger<LabCsvFileResolver> logger)
    {
        _labSettings = labSettings;
        _logger = logger;
    }

    /// <summary>
    /// Returns the full path of the latest Claim Level CSV for the given lab,
    /// or null when none is found.
    /// </summary>
    public string? ResolveClaimLevelCsv(string labName) =>
        Resolve(labName, ClaimLevelKeyword);

    /// <summary>
    /// Returns the full path of the latest Line Level CSV for the given lab,
    /// or null when none is found.
    /// </summary>
    public string? ResolveLineLevelCsv(string labName) =>
        Resolve(labName, LineLevelKeyword);

    /// <summary>
    /// Resolves both paths for every configured lab in one pass.
    /// </summary>
    public IReadOnlyDictionary<string, ResolvedLabCsvPaths> ResolveAll()
    {
        return _labSettings.Labs.Keys.ToDictionary(
            labName => labName,
            labName => new ResolvedLabCsvPaths(
                ClaimLevelCsvPath: Resolve(labName, ClaimLevelKeyword),
                LineLevelCsvPath:  Resolve(labName, LineLevelKeyword)),
            StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Returns the full path of the latest Payer Policy Validation Report Excel file
    /// for the given lab, or null when none is found.
    /// </summary>
    public string? ResolvePredictionValidationReport(string labName)
    {
        if (!_labSettings.Labs.TryGetValue(labName, out var config))
        {
            _logger.LogWarning("Lab '{LabName}' not found in LabSettings.", labName);
            return null;
        }

        var rootPath = config.PayerPolicyValidationReportPath;

        if (string.IsNullOrWhiteSpace(rootPath) || !Directory.Exists(rootPath))
        {
            _logger.LogWarning(
                "PayerPolicyValidationReportPath '{Path}' for lab '{LabName}' does not exist or is empty.",
                rootPath, labName);
            return null;
        }

        var match = Directory
            .EnumerateFiles(rootPath, "*.xlsx", SearchOption.AllDirectories)
            .Where(f => Path.GetFileName(f).Contains(PredictionKeyword, StringComparison.OrdinalIgnoreCase))
            .Select(f => new FileInfo(f))
            .MaxBy(fi => fi.LastWriteTimeUtc)
            ?.FullName;

        if (match is null)
            _logger.LogWarning(
                "No '{Keyword}' Excel file found under '{Path}' for lab '{LabName}'.",
                PredictionKeyword, rootPath, labName);
        else
            _logger.LogInformation(
                "Resolved prediction report for lab '{LabName}': {FilePath}",
                labName, match);

        return match;
    }

    // -------------------------------------------------------------------------

    /// <summary>
    /// Returns the full path of the latest CodingValidated Excel report
    /// under the <c>Reports</c> folder configured for the given lab, or null when none is found.
    /// </summary>
    public string? ResolveCodingMasterReport(string labName)
    {
        if (!_labSettings.Labs.TryGetValue(labName, out var config))
        {
            _logger.LogWarning("Lab '{LabName}' not found in LabSettings.", labName);
            return null;
        }

        var rootPath = config.Reports;

        if (string.IsNullOrWhiteSpace(rootPath) || !Directory.Exists(rootPath))
            return null;

        var match = Directory
            .EnumerateFiles(rootPath, "*.xlsx", SearchOption.AllDirectories)
            .Where(f => Path.GetFileName(f).Contains("CodingValidated", StringComparison.OrdinalIgnoreCase))
            .Select(f => new FileInfo(f))
            .MaxBy(fi => fi.LastWriteTimeUtc)
            ?.FullName;

        if (match is not null)
            _logger.LogInformation("Resolved CodingMaster report for lab '{LabName}': {FilePath}", labName, match);

        return match;
    }

    private string? Resolve(string labName, string keyword)
    {
        if (!_labSettings.Labs.TryGetValue(labName, out var config))
        {
            _logger.LogWarning("Lab '{LabName}' not found in LabSettings.", labName);
            return null;
        }

        var rootPath = config.ProductionMasterCsvPath;

        if (string.IsNullOrWhiteSpace(rootPath) || !Directory.Exists(rootPath))
        {
            _logger.LogWarning(
                "ProductionMasterCsvPath '{Path}' for lab '{LabName}' does not exist or is empty.",
                rootPath, labName);
            return null;
        }

        // Materialise FileInfo once per file so LastWriteTimeUtc is not re-read in MaxBy.
        // Works regardless of folder depth — year\month\week or month\week or just week, etc.
        var match = Directory
            .EnumerateFiles(rootPath, "*.csv", SearchOption.AllDirectories)
            .Where(f => Path.GetFileName(f).Contains(keyword, StringComparison.OrdinalIgnoreCase))
            .Select(f => new FileInfo(f))
            .MaxBy(fi => fi.LastWriteTimeUtc)
            ?.FullName;

        if (match is null)
            _logger.LogWarning(
                "No '{Keyword}' CSV found under '{Path}' for lab '{LabName}'.",
                keyword, rootPath, labName);
        else
            _logger.LogInformation(
                "Resolved '{Keyword}' CSV for lab '{LabName}': {FilePath}",
                keyword, labName, match);

        return match;
    }
}

/// <summary>Resolved latest CSV paths for a single lab.</summary>
public sealed record ResolvedLabCsvPaths(
    string? ClaimLevelCsvPath,
    string? LineLevelCsvPath);
