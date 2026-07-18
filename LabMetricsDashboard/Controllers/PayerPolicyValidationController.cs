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
    private const int DefaultPageSize = 50;
    private const int MaxPageSize     = 100_000;

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

    private static int NormalizePageSize(int pageSize) =>
        pageSize < 1 ? DefaultPageSize : Math.Min(pageSize, MaxPageSize);

    /// <summary>GET /PayerPolicyValidation?lab=Phi_Life</summary>
    public async Task<IActionResult> Index(
        string? lab,
        string? filterPayerName,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterCPTCode,
        string? filterForecastingPayabilitySubstatus,
        string? filterPredictionStatus,
        string? filterPayStatus,
        bool search = true,  // Changed: default to true to load all data by default
        int page = 1,
        int pageSize = DefaultPageSize,
        CancellationToken ct = default)
    {
        pageSize = NormalizePageSize(pageSize);

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
                AvailableLabs                        = availableLabs,
                SelectedLab                          = selectedLab,
                DbEnabled                            = labConfig.DBEnabled,
                PageSize                             = pageSize,
                FilterPayerName                      = filterPayerName,
                FilterPanelName                      = filterPanelName,
                FilterFinalCoverageStatus            = filterFinalCoverageStatus,
                FilterCPTCode                        = filterCPTCode,
                FilterForecastingPayabilitySubstatus = filterForecastingPayabilitySubstatus,
                FilterPredictionStatus               = filterPredictionStatus,
                FilterPayStatus                      = filterPayStatus,
            });
        }

        try
        {
            var result = await _service.LoadAsync(
                selectedLab, labConfig,
                filterPayerName, filterPanelName, filterFinalCoverageStatus, filterCPTCode,
                filterForecastingPayabilitySubstatus, filterPredictionStatus, filterPayStatus,
                page, pageSize, ct);

            return View(new PayerPolicyValidationViewModel
            {
                AvailableLabs                        = availableLabs,
                SelectedLab                          = selectedLab,
                DataLoaded                           = true,
                DbEnabled                            = result.UsingDb,
                DataSourceLabel                      = result.DataSourceLabel,
                Records                              = result.PagedRows,
                Paging                               = new PageInfo(page, pageSize, result.TotalFiltered, result.TotalAll),
                PageSize                             = pageSize,

                FilterPayerName                      = filterPayerName,
                FilterPanelName                      = filterPanelName,
                FilterFinalCoverageStatus            = filterFinalCoverageStatus,
                FilterCPTCode                        = filterCPTCode,
                FilterForecastingPayabilitySubstatus = filterForecastingPayabilitySubstatus,
                FilterPredictionStatus               = filterPredictionStatus,
                FilterPayStatus                      = filterPayStatus,

                PayerNames                       = result.Options.PayerNames,
                PanelNames                       = result.Options.PanelNames,
                FinalCoverageStatuses            = result.Options.FinalCoverageStatuses,
                CPTCodes                         = result.Options.CPTCodes,
                ForecastingPayabilitySubstatuses = result.Options.ForecastingPayabilitySubstatuses,
                PredictionStatuses               = result.Options.PredictionStatuses,
                PayStatuses                      = result.Options.PayStatuses,
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
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterCPTCode,
        string? filterForecastingPayabilitySubstatus,
        string? filterPredictionStatus,
        string? filterPayStatus,
        CancellationToken ct = default)
    {
        var availableLabs = PayerPolicyValidationService.GetAvailableLabs(_labSettings.Labs);
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        if (!_labSettings.Labs.TryGetValue(selectedLab, out var labConfig))
            return BadRequest($"Unknown lab: {selectedLab}");

        try
        {
            var allFilteredRows = await _service.LoadAllFilteredAsync(
                selectedLab, labConfig,
                filterPayerName, filterPanelName, filterFinalCoverageStatus, filterCPTCode,
                filterForecastingPayabilitySubstatus, filterPredictionStatus, filterPayStatus, ct);

            var activeFilters = BuildActiveFilters(
                filterPayerName, filterPanelName, filterFinalCoverageStatus, filterCPTCode,
                filterForecastingPayabilitySubstatus, filterPredictionStatus, filterPayStatus);

            var bytes = PayerPolicyValidationExcelBuilder.CreateWorkbook(
                selectedLab,
                allFilteredRows,
                activeFilters.Count > 0 ? activeFilters : null);

            _logger.LogInformation(
                "PayerPolicyValidation export [{Lab}]: {Rows:N0} rows.",
                selectedLab, allFilteredRows.Count);

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

    private static List<(string Label, string? Value)> BuildActiveFilters(
        string? filterPayerName,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterCPTCode,
        string? filterForecastingPayabilitySubstatus,
        string? filterPredictionStatus,
        string? filterPayStatus)
    {
        var list = new List<(string, string?)>();
        if (!string.IsNullOrWhiteSpace(filterPayerName)) list.Add(("Payer Name", filterPayerName));
        if (!string.IsNullOrWhiteSpace(filterPanelName)) list.Add(("Panel", filterPanelName));
        if (!string.IsNullOrWhiteSpace(filterFinalCoverageStatus)) list.Add(("Final Coverage", filterFinalCoverageStatus));
        if (!string.IsNullOrWhiteSpace(filterCPTCode)) list.Add(("CPT Code", filterCPTCode));
        if (!string.IsNullOrWhiteSpace(filterForecastingPayabilitySubstatus)) list.Add(("Forecast Substatus", filterForecastingPayabilitySubstatus));
        if (!string.IsNullOrWhiteSpace(filterPredictionStatus)) list.Add(("Prediction Status", filterPredictionStatus));
        if (!string.IsNullOrWhiteSpace(filterPayStatus)) list.Add(("Pay Status", filterPayStatus));
        return list;
    }
}
