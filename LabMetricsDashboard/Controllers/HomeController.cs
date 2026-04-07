using System.Diagnostics;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

public class HomeController : Controller
{
    private readonly ILogger<HomeController> _logger;
    private readonly LabSettings _labSettings;
    private readonly LabCsvFileResolver _resolver;

    public HomeController(
        ILogger<HomeController> logger,
        LabSettings labSettings,
        LabCsvFileResolver resolver)
    {
        _logger = logger;
        _labSettings = labSettings;
        _resolver = resolver;
    }

    public IActionResult Index()
    {
        var tiles = _labSettings.Labs.Keys
            .OrderBy(name => name)
            .Select(labName =>
            {
                var claimPath        = _resolver.ResolveClaimLevelCsv(labName);
                var linePath         = _resolver.ResolveLineLevelCsv(labName);
                var predictionPath   = _resolver.ResolvePredictionValidationReport(labName);
                var codingMasterPath = _resolver.ResolveCodingMasterReport(labName);

                var labConfig  = _labSettings.Labs.TryGetValue(labName, out var cfg) ? cfg : null;
                var dbEnabled  = labConfig?.DBEnabled == true;
                var lineClaimEnabled = labConfig?.LineClaimEnable == true;

                return new LabTileViewModel
                {
                    LabName               = labName,
                    HasClaimFile          = claimPath        is not null,
                    HasLineFile           = linePath         is not null,
                    HasPredictionFile     = predictionPath   is not null,
                    HasCodingMasterFile   = codingMasterPath is not null,
                    PredictionEnabled     = true,
                    DBEnabled             = dbEnabled,
                    CodingEnabled         = dbEnabled && !string.IsNullOrWhiteSpace(labConfig?.Reports),
                    LineClaimEnabled      = lineClaimEnabled,
                    ClaimFilePath         = claimPath,
                    LineFilePath          = linePath,
                    PredictionFilePath    = predictionPath,
                    CodingMasterFilePath  = codingMasterPath,
                    ClaimRunId            = ExtractRunId(claimPath),
                    LineRunId             = ExtractRunId(linePath),
                    PredictionRunId       = ExtractRunId(predictionPath),
                    CodingRunId           = ExtractRunId(codingMasterPath),
                    WeekRange             = ExtractWeekRange(claimPath),
                    ClaimFileAgeHours     = GetFileAgeHours(claimPath),
                    LineFileAgeHours      = GetFileAgeHours(linePath),
                };
            })
            .ToList();

        return View(new HomeViewModel { LabTiles = tiles });
    }

    public IActionResult Privacy() => View();

    /// <summary>
    /// Extracts RunId from a file path by taking the prefix before the first underscore.
    /// </summary>
    private static string? ExtractRunId(string? filePath)
    {
        if (string.IsNullOrWhiteSpace(filePath)) return null;
        var name = Path.GetFileNameWithoutExtension(filePath);
        if (string.IsNullOrEmpty(name)) return null;
        var idx = name.IndexOf('_');
        return idx > 0 ? name[..idx] : name;
    }

    /// <summary>
    /// Returns the total hours since the file was last written, or null if the file doesn't exist.
    /// </summary>
    private static double? GetFileAgeHours(string? filePath)
    {
        if (string.IsNullOrWhiteSpace(filePath) || !System.IO.File.Exists(filePath)) return null;
        return (DateTime.Now - System.IO.File.GetLastWriteTime(filePath)).TotalHours;
    }

    /// <summary>
    /// Extracts the week date range from a file name.
    /// E.g. "20260403R0251_PCR Labs of America_Claim Level_03.26.2026 to 04.01.2026.csv"
    /// returns "03.26.2026 to 04.01.2026".
    /// </summary>
    private static string? ExtractWeekRange(string? filePath)
    {
        if (string.IsNullOrWhiteSpace(filePath)) return null;
        var name = Path.GetFileNameWithoutExtension(filePath);
        if (string.IsNullOrEmpty(name)) return null;
        var lastUnderscore = name.LastIndexOf('_');
        if (lastUnderscore < 0 || lastUnderscore >= name.Length - 1) return null;
        var range = name[(lastUnderscore + 1)..];
        return range.Contains("to", StringComparison.OrdinalIgnoreCase) ? range : null;
    }

    [ResponseCache(Duration = 0, Location = ResponseCacheLocation.None, NoStore = true)]
    public IActionResult Error() =>
        View(new ErrorViewModel { RequestId = Activity.Current?.Id ?? HttpContext.TraceIdentifier });
}
