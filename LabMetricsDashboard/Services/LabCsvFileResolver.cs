using LabMetricsDashboard.Models;

using Microsoft.Extensions.Caching.Memory;

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
/// Results are cached for 5 minutes to avoid repeated directory scans.
/// </summary>
public sealed class LabCsvFileResolver
{
    private const string ClaimLevelKeyword    = "Claim Level";
    private const string LineLevelKeyword     = "Line Level";
    private const string PredictionKeyword    = "Payer_Policy_ValidationReport";
    private const string CodingKeyword        = "CodingValidated";

    private static readonly TimeSpan CacheDuration = TimeSpan.FromMinutes(5);

    private readonly LabSettings _labSettings;
    private readonly ILogger<LabCsvFileResolver> _logger;
    private readonly IMemoryCache _cache;

    public LabCsvFileResolver(LabSettings labSettings, ILogger<LabCsvFileResolver> logger, IMemoryCache cache)
    {
        _labSettings = labSettings;
        _logger = logger;
        _cache = cache;
    }

    /// <summary>
    /// Returns the full path of the latest Claim Level CSV for the given lab,
    /// or null when none is found.
    /// </summary>
    public string? ResolveClaimLevelCsv(string labName) =>
        ResolveCsvCached(labName).ClaimLevelPath;

    /// <summary>
    /// Returns the full path of the latest Line Level CSV for the given lab,
    /// or null when none is found.
    /// </summary>
    public string? ResolveLineLevelCsv(string labName) =>
        ResolveCsvCached(labName).LineLevelPath;

    /// <summary>
    /// Resolves both paths for every configured lab in one pass.
    /// </summary>
    public IReadOnlyDictionary<string, ResolvedLabCsvPaths> ResolveAll()
    {
        return _labSettings.Labs.Keys.ToDictionary(
            labName => labName,
            labName =>
            {
                var cached = ResolveCsvCached(labName);
                return new ResolvedLabCsvPaths(cached.ClaimLevelPath, cached.LineLevelPath);
            },
            StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Returns the full path of the latest Payer Policy Validation Report Excel file
    /// for the given lab, or null when none is found.
    /// </summary>
    public string? ResolvePredictionValidationReport(string labName)
    {
        var cacheKey = $"LabResolver_Prediction_{labName}";

        return _cache.GetOrCreate(cacheKey, entry =>
        {
            entry.AbsoluteExpirationRelativeToNow = CacheDuration;

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
        });
    }

    // -------------------------------------------------------------------------

    /// <summary>
    /// Returns the full path of the latest CodingValidated Excel report
    /// under the <c>Reports</c> folder configured for the given lab, or null when none is found.
    /// </summary>
    public string? ResolveCodingMasterReport(string labName)
    {
        var cacheKey = $"LabResolver_Coding_{labName}";

        return _cache.GetOrCreate(cacheKey, entry =>
        {
            entry.AbsoluteExpirationRelativeToNow = CacheDuration;

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
                .Where(f => Path.GetFileName(f).Contains(CodingKeyword, StringComparison.OrdinalIgnoreCase))
                .Select(f => new FileInfo(f))
                .MaxBy(fi => fi.LastWriteTimeUtc)
                ?.FullName;

            if (match is not null)
                _logger.LogInformation("Resolved CodingMaster report for lab '{LabName}': {FilePath}", labName, match);

            return match;
        });
    }

    /// <summary>
    /// Resolves both Claim Level and Line Level CSV paths in a single directory scan,
    /// cached for <see cref="CacheDuration"/>.
    /// </summary>
    private CsvPathPair ResolveCsvCached(string labName)
    {
        var cacheKey = $"LabResolver_Csv_{labName}";

        return _cache.GetOrCreate(cacheKey, entry =>
        {
            entry.AbsoluteExpirationRelativeToNow = CacheDuration;
            return ResolveCsvPair(labName);
        })!;
    }

    /// <summary>
    /// Walks the CSV directory once and finds both Claim Level and Line Level in one pass.
    /// </summary>
    private CsvPathPair ResolveCsvPair(string labName)
    {
        if (!_labSettings.Labs.TryGetValue(labName, out var config))
        {
            _logger.LogWarning("Lab '{LabName}' not found in LabSettings.", labName);
            return CsvPathPair.Empty;
        }

        var rootPath = config.ProductionMasterCsvPath;

        if (string.IsNullOrWhiteSpace(rootPath) || !Directory.Exists(rootPath))
        {
            _logger.LogWarning(
                "ProductionMasterCsvPath '{Path}' for lab '{LabName}' does not exist or is empty.",
                rootPath, labName);
            return CsvPathPair.Empty;
        }

        // Single directory scan — classify each file into Claim or Line bucket.
        FileInfo? bestClaim = null;
        FileInfo? bestLine  = null;

        foreach (var filePath in Directory.EnumerateFiles(rootPath, "*.csv", SearchOption.AllDirectories))
        {
            var fileName = Path.GetFileName(filePath);

            bool isClaim = fileName.Contains(ClaimLevelKeyword, StringComparison.OrdinalIgnoreCase);
            bool isLine  = fileName.Contains(LineLevelKeyword, StringComparison.OrdinalIgnoreCase);

            if (!isClaim && !isLine) continue;

            var fi = new FileInfo(filePath);

            if (isClaim && (bestClaim is null || fi.LastWriteTimeUtc > bestClaim.LastWriteTimeUtc))
                bestClaim = fi;

            if (isLine && (bestLine is null || fi.LastWriteTimeUtc > bestLine.LastWriteTimeUtc))
                bestLine = fi;
        }

        if (bestClaim is null)
            _logger.LogWarning("No '{Keyword}' CSV found under '{Path}' for lab '{LabName}'.",
                ClaimLevelKeyword, rootPath, labName);
        else
            _logger.LogInformation("Resolved '{Keyword}' CSV for lab '{LabName}': {FilePath}",
                ClaimLevelKeyword, labName, bestClaim.FullName);

        if (bestLine is null)
            _logger.LogWarning("No '{Keyword}' CSV found under '{Path}' for lab '{LabName}'.",
                LineLevelKeyword, rootPath, labName);
        else
            _logger.LogInformation("Resolved '{Keyword}' CSV for lab '{LabName}': {FilePath}",
                LineLevelKeyword, labName, bestLine.FullName);

        return new CsvPathPair(bestClaim?.FullName, bestLine?.FullName);
    }

    private sealed record CsvPathPair(string? ClaimLevelPath, string? LineLevelPath)
    {
        public static readonly CsvPathPair Empty = new(null, null);
    }
}

/// <summary>Resolved latest CSV paths for a single lab.</summary>
public sealed record ResolvedLabCsvPaths(
    string? ClaimLevelCsvPath,
    string? LineLevelCsvPath);
