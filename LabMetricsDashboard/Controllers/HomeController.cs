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
                    ClaimFilePath         = claimPath,
                    LineFilePath          = linePath,
                    PredictionFilePath    = predictionPath,
                    CodingMasterFilePath  = codingMasterPath,
                };
            })
            .ToList();

        return View(new HomeViewModel { LabTiles = tiles });
    }

    public IActionResult Privacy() => View();

    [ResponseCache(Duration = 0, Location = ResponseCacheLocation.None, NoStore = true)]
    public IActionResult Error() =>
        View(new ErrorViewModel { RequestId = Activity.Current?.Id ?? HttpContext.TraceIdentifier });
}
