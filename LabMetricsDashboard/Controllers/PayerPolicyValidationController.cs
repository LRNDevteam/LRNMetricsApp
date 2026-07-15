using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Http.Timeouts;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Lab-scoped Payer Policy Validation viewer — loads dbo.PayerValidationReport
/// from the selected lab's database with dimension filters and Excel export.
/// </summary>
public class PayerPolicyValidationController : Controller
{
    private const int PageSize = 50;

    private readonly LabSettings _labSettings;
    private readonly PayerPolicyValidationService _service;
    private readonly ILogger<PayerPolicyValidationController> _logger;

    public PayerPolicyValidationController(
        LabSettings labSettings,
        PayerPolicyValidationService service,
        ILogger<PayerPolicyValidationController> logger)
    {
        _labSettings = labSettings;
        _service     = service;
        _logger      = logger;
    }

    /// <summary>GET /PayerPolicyValidation?lab=Phi_Life</summary>
    public async Task<IActionResult> Index(
        string? lab,
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterPayability,
        string? filterCPTCode,
        bool search = true,  // Changed: default to true to load all data by default
        int page = 1,
        CancellationToken ct = default)
    {
        var availableLabs = PayerPolicyValidationService.GetAvailableLabs(_labSettings.Labs);
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        if (availableLabs.Count == 0)
        {
            return View(new PayerPolicyValidationViewModel
            {
                ErrorMessage = "No labs are configured for Payer Policy Validation (EnablePrediction with database or report file).",
            });
        }

        if (!_labSettings.Labs.TryGetValue(selectedLab, out var labConfig)
            || !PayerPolicyValidationService.IsEligible(selectedLab, labConfig))
        {
            return View(new PayerPolicyValidationViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Payer Policy Validation is not available for {selectedLab}.",
            });
        }

        if (!search)
        {
            return View(new PayerPolicyValidationViewModel
            {
                AvailableLabs             = availableLabs,
                SelectedLab               = selectedLab,
                DbEnabled                 = labConfig.DBEnabled,
                FilterPayerName           = filterPayerName,
                FilterPayerType           = filterPayerType,
                FilterPanelName           = filterPanelName,
                FilterFinalCoverageStatus = filterFinalCoverageStatus,
                FilterPayability          = filterPayability,
                FilterCPTCode             = filterCPTCode,
            });
        }

        try
        {
            var result = await _service.LoadAsync(
                selectedLab, labConfig,
                filterPayerName, filterPayerType, filterPanelName,
                filterFinalCoverageStatus, filterPayability, filterCPTCode,
                page, PageSize, ct);

            var baseData = result.BaseDataset;

            return View(new PayerPolicyValidationViewModel
            {
                AvailableLabs             = availableLabs,
                SelectedLab               = selectedLab,
                DataLoaded                = true,
                DbEnabled                 = result.UsingDb,
                DataSourceLabel           = result.DataSourceLabel,
                Records                   = result.PagedRows,
                Paging                    = new PageInfo(page, PageSize, result.AllFilteredRows.Count, baseData.Count),

                FilterPayerName           = filterPayerName,
                FilterPayerType           = filterPayerType,
                FilterPanelName           = filterPanelName,
                FilterFinalCoverageStatus = filterFinalCoverageStatus,
                FilterPayability          = filterPayability,
                FilterCPTCode             = filterCPTCode,

                PayerNames            = Distinct(baseData, r => r.PayerNameNormalized),
                PayerTypes            = Distinct(baseData, r => r.PayerType),
                PanelNames            = Distinct(baseData, r => r.PanelName),
                FinalCoverageStatuses = Distinct(baseData, r => r.FinalCoverageStatus),
                PayabilityOptions     = Distinct(baseData, r => r.Payability),
                CPTCodes              = Distinct(baseData, r => r.CPTCode),
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "PayerPolicyValidation load failed for lab {Lab}.", selectedLab);
            return View(new PayerPolicyValidationViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                DbEnabled     = labConfig.DBEnabled,
                ErrorMessage  = $"Failed to load PayerValidationReport for {selectedLab}: {ex.Message}",
            });
        }
    }

    /// <summary>GET /PayerPolicyValidation/ExportExcel?lab=Phi_Life</summary>
    [RequestTimeout(milliseconds: 900_000)]
    public async Task<IActionResult> ExportExcel(
        string? lab,
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterPayability,
        string? filterCPTCode,
        CancellationToken ct = default)
    {
        var availableLabs = PayerPolicyValidationService.GetAvailableLabs(_labSettings.Labs);
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        if (!_labSettings.Labs.TryGetValue(selectedLab, out var labConfig))
            return BadRequest($"Unknown lab: {selectedLab}");

        try
        {
            var result = await _service.LoadAsync(
                selectedLab, labConfig,
                filterPayerName, filterPayerType, filterPanelName,
                filterFinalCoverageStatus, filterPayability, filterCPTCode,
                page: 1, pageSize: int.MaxValue, ct);

            var activeFilters = BuildActiveFilters(
                filterPayerName, filterPayerType, filterPanelName,
                filterFinalCoverageStatus, filterPayability, filterCPTCode);

            var bytes = PayerPolicyValidationExcelBuilder.CreateWorkbook(
                selectedLab,
                result.AllFilteredRows,
                activeFilters.Count > 0 ? activeFilters : null);

            _logger.LogInformation(
                "PayerPolicyValidation export [{Lab}]: {Rows:N0} rows.",
                selectedLab, result.AllFilteredRows.Count);

            Response.Cookies.Append("ppvExportDone", "1", new CookieOptions
            {
                Path     = "/",
                HttpOnly = false,
                SameSite = SameSiteMode.Lax,
                MaxAge   = TimeSpan.FromSeconds(30),
            });

            var fileName = $"{selectedLab}_PayerPolicyValidation_{DateTime.Now:yyyyMMddHHmmss}.xlsx";
            return File(bytes,
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "PayerPolicyValidation Excel export failed for lab {Lab}.", selectedLab);
            return StatusCode(500, $"Export failed: {ex.Message}");
        }
    }

    private static List<string> Distinct(
        IEnumerable<PredictionRecord> rows,
        Func<PredictionRecord, string> selector) =>
        rows.Select(selector).Where(v => !string.IsNullOrWhiteSpace(v))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(v => v)
            .ToList();

    private static List<(string Label, string? Value)> BuildActiveFilters(
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterPayability,
        string? filterCPTCode)
    {
        var list = new List<(string, string?)>();
        if (!string.IsNullOrWhiteSpace(filterPayerName)) list.Add(("Payer Name", filterPayerName));
        if (!string.IsNullOrWhiteSpace(filterPayerType)) list.Add(("Payer Type", filterPayerType));
        if (!string.IsNullOrWhiteSpace(filterPanelName)) list.Add(("Panel", filterPanelName));
        if (!string.IsNullOrWhiteSpace(filterFinalCoverageStatus)) list.Add(("Final Coverage", filterFinalCoverageStatus));
        if (!string.IsNullOrWhiteSpace(filterPayability)) list.Add(("Payability", filterPayability));
        if (!string.IsNullOrWhiteSpace(filterCPTCode)) list.Add(("CPT Code", filterCPTCode));
        return list;
    }
}
