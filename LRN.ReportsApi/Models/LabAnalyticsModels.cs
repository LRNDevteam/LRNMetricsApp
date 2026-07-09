namespace LRN.ReportsApi.Models;

// ── Analytics: Lab Modes / Lab Medians (Meridian) list pages ─────────────────
// View-only reference data. LabId, RunID, and CreatedOn are intentionally not
// exposed on the DTOs (LabId is accepted only as a filter).

public sealed class LabRateQuery
{
    public string? PayerName { get; set; }
    public string? PanelName { get; set; }
    public string? CptCode { get; set; }
    public int? LabId { get; set; }
    public string? SortColumn { get; set; }
    public string? SortDirection { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
}

public sealed class LabModeDto
{
    public string? PayerName { get; set; }
    public string? PanelName { get; set; }
    public string? CptCode { get; set; }
    public decimal? AllowedAmount { get; set; }
    public decimal? InsurancePayment { get; set; }
    public int? DistinctAllowedPaymentCount { get; set; }
    public decimal? ModeAllowedAmount { get; set; }
    public decimal? ModeInsurancePaymentAmount { get; set; }
    public decimal? AllowedAmountPerUnitMode { get; set; }
    public decimal? InsurancePaymentPerUnitMode { get; set; }
    public string LabName { get; set; } = string.Empty;
}

public sealed class LabMedianDto
{
    public string? PayerName { get; set; }
    public string? PanelName { get; set; }
    public string? CptCode { get; set; }
    public decimal? AllowedAmount { get; set; }
    public decimal? InsurancePayment { get; set; }
    public int? DistinctAllowedPaymentCount { get; set; }
    public decimal? MedianAllowedAmount { get; set; }
    public decimal? MedianInsurancePaymentAmount { get; set; }
    public decimal? AllowedAmountPerUnitMedian { get; set; }
    public decimal? InsurancePaymentPerUnitMedian { get; set; }
    public string LabName { get; set; } = string.Empty;
}
