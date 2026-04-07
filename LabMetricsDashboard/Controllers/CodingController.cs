using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

public class CodingController : Controller
{
    private readonly LabSettings _labSettings;
    private readonly ICodingValidationRepository _repo;
    private readonly ILogger<CodingController> _logger;

    public CodingController(
        LabSettings labSettings,
        ICodingValidationRepository repo,
        ILogger<CodingController> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _logger      = logger;
    }

    /// <summary>GET /Coding/Summary?lab=PCRLabsofAmerica</summary>
    public async Task<IActionResult> Summary(string? lab, CancellationToken ct)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = lab ?? availableLabs.FirstOrDefault() ?? string.Empty;

        if (string.IsNullOrWhiteSpace(selectedLab))
            return View(new CodingSummaryViewModel { AvailableLabs = availableLabs });

        if (!_labSettings.Labs.TryGetValue(selectedLab, out var config) || !config.DBEnabled)
        {
            return View(new CodingSummaryViewModel
            {
                LabName       = selectedLab,
                AvailableLabs = availableLabs,
                ErrorMessage  = $"Coding Summary is currently not available for {selectedLab}. Please contact your administrator for more details.",
            });
        }

        var connStr = config.DbConnectionString;
        if (string.IsNullOrWhiteSpace(connStr))
        {
            return View(new CodingSummaryViewModel
            {
                LabName       = selectedLab,
                AvailableLabs = availableLabs,
                ErrorMessage  = $"Coding Summary is currently not available for {selectedLab}. Please contact your administrator for more details.",
            });
        }

        // Resolve the DB lab name (may differ from the config key)
        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? selectedLab : config.DbLabName;

        var (insights, summaries, wtdInsights, wtdSummaries, financial, detail, fetchError) =
            await FetchDataAsync(connStr, dbLabName, ct);

        return View(new CodingSummaryViewModel
        {
            LabName        = selectedLab,
            AvailableLabs  = availableLabs,
            InsightRows    = insights,
            SummaryRows    = summaries,
            WtdInsightRows = wtdInsights,
            WtdSummaryRows = wtdSummaries,
            FinancialRows  = financial,
            DetailRows     = detail,
            ErrorMessage   = fetchError,
        });
    }

    private async Task<(List<CodingInsightRow> Insights, List<CodingSummaryRow> Summaries,
                         List<CodingWtdInsightRow> WtdInsights, List<CodingWtdSummaryRow> WtdSummaries,
                         List<CodingFinancialSummaryRow> Financial,
                         List<CodingValidationDetailRow> Detail,
                         string? Error)>
        FetchDataAsync(string connStr, string labName, CancellationToken ct)
    {

        try
        {
            var t1 = _repo.GetYtdInsightsAsync(connStr, labName, ct);
            var t2 = _repo.GetYtdSummaryAsync(connStr, labName, ct);
            var t3 = _repo.GetWtdInsightsAsync(connStr, labName, ct);
            var t4 = _repo.GetWtdSummaryAsync(connStr, labName, ct);
            var t5 = _repo.GetFinancialSummaryAsync(connStr, ct);
            var t6 = _repo.GetValidationDetailRowsAsync(connStr, ct);
            await Task.WhenAll(t1, t2, t3, t4, t5, t6);
            return (t1.Result, t2.Result, t3.Result, t4.Result, t5.Result, t6.Result, null);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "FetchDataAsync failed for lab '{LabName}'.", labName);
            return ([], [], [], [], [], [], ex.Message);
        }
    }
}
