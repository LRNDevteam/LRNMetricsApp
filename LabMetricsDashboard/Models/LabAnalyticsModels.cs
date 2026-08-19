namespace LabMetricsDashboard.Models;

// ── Analytics: CPT & Panel Lookup ────────────────────────────────────────────
// One screen over two LRNMaster tables — dbo.CPTAverage and dbo.PanelAverage.
// Each carries its own averages AND mode/median columns, so nothing is joined.
// View-only; all data comes from LRN.ReportsApi (/api/analytics/*).

/// <summary>One CPTAverage row: averages, mode, median, percentiles and counts.</summary>
public sealed class CptLookupRowDto
{
    public int? LabId { get; set; }
    public string? LabName { get; set; }
    public string? CptCode { get; set; }
    public string? PanelName { get; set; }
    public string? PayerDisplayName { get; set; }
    public string? PayerCommonCode { get; set; }
    public int? GlobalPayerId { get; set; }
    public string? WindowType { get; set; }
    public DateTime? StartDate { get; set; }
    public DateTime? EndDate { get; set; }
    public DateTime? AsOfDate { get; set; }

    public int? AvgUnits { get; set; }
    public decimal? AvgChargeAmountPerUnit { get; set; }
    public decimal? AvgAllowedAmountPerUnit { get; set; }
    public decimal? AvgPaidAmountPerUnit { get; set; }
    public decimal? AvgPatientResponsibilityPerUnit { get; set; }
    public decimal? MedianPaidAmount { get; set; }
    public decimal? P25PaidAmount { get; set; }
    public decimal? P75PaidAmount { get; set; }
    public int? PaidLineCount { get; set; }
    public int? TotalLineCount { get; set; }
    public int? DeniedLineCount { get; set; }
    public int? AdjustedLineCount { get; set; }

    public decimal? ModeAllowedAmount { get; set; }
    public decimal? ModeInsurancePaymentAmount { get; set; }

    public decimal? MedianAllowedAmount { get; set; }
    public decimal? MedianInsurancePaymentAmount { get; set; }

    public decimal? DenialRate { get; set; }
}

/// <summary>A PanelAverage row — panel-level averages, no CPT breakdown.</summary>
public sealed class PanelLookupRowDto
{
    public int? LabId { get; set; }
    public string? LabName { get; set; }
    public string? PanelName { get; set; }
    public string? PayerId { get; set; }
    public string? PayerDisplayName { get; set; }
    public string? WindowType { get; set; }
    public DateTime? StartDate { get; set; }
    public DateTime? EndDate { get; set; }
    public DateTime? AsOfDate { get; set; }
    public decimal? AvgChargeAmount { get; set; }
    public decimal? AvgAllowedAmount { get; set; }
    public decimal? AvgPaidAmount { get; set; }
    public decimal? AvgPatientResponsibility { get; set; }
    public decimal? MedianPaidAmount { get; set; }
    public decimal? P25PaidAmount { get; set; }
    public decimal? P75PaidAmount { get; set; }
    public int? PaidLineCount { get; set; }
    public int? TotalLineCount { get; set; }
    public int? DeniedLineCount { get; set; }
    public int? AdjustedLineCount { get; set; }

    // True panel-level mode/median from the PanelAverage row itself, no longer an
    // average of per-CPT modes — so there is no CPT count to qualify it with.
    public decimal? ModeAllowedAmount { get; set; }
    public decimal? ModeInsurancePaymentAmount { get; set; }
    public decimal? MedianAllowedAmount { get; set; }

    public decimal? DenialRate { get; set; }
}

public sealed class LookupSummaryDto
{
    public int RowCount { get; set; }
    public decimal? AvgAllowed { get; set; }
    public decimal? AvgPaid { get; set; }
    public decimal? DenialRate { get; set; }
}

public sealed class LookupResultDto<T>
{
    public List<T> Items { get; set; } = new();
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
    public int TotalCount { get; set; }
    public int TotalPages { get; set; }
    public LookupSummaryDto Summary { get; set; } = new();
}

/// <summary>Endpoint URLs handed to Views/Analytics/CptLookup.cshtml.</summary>
public sealed class CptLookupPageViewModel
{
    public string CptDataUrl { get; set; } = string.Empty;
    public string PanelDataUrl { get; set; } = string.Empty;
    public string CptWindowsUrl { get; set; } = string.Empty;
    public string PanelWindowsUrl { get; set; } = string.Empty;
    public string CptOptionsUrl { get; set; } = string.Empty;
    public string PanelOptionsUrl { get; set; } = string.Empty;
    public string CptExportUrl { get; set; } = string.Empty;
    public string PanelExportUrl { get; set; } = string.Empty;
    public string LabsUrl { get; set; } = string.Empty;

    /// <summary>
    /// POST target that queues the export in LRN.ReportWorker instead of building it inside
    /// the request. The direct *ExportUrl endpoints stay as the fallback for when the shared
    /// queue lab is not configured — but an unfiltered export through those exceeds the
    /// dashboard's 120s HttpClient timeout, so this is the normal path.
    /// </summary>
    public string QueueExportUrl { get; set; } = string.Empty;

    /// <summary>False when the shared LRNMaster queue lab is missing; the page then downloads inline.</summary>
    public bool BackgroundExportEnabled { get; set; }
}
