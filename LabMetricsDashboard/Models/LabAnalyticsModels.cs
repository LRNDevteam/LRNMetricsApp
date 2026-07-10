namespace LabMetricsDashboard.Models;

// ── Analytics: Lab Modes / Meridian (LabMedians) view-only list pages ────────

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

/// <summary>Column metadata consumed by the shared Views/Analytics/LabRates.cshtml grid.</summary>
public sealed class LabRateColumn
{
    public LabRateColumn(string key, string label, string type)
    {
        Key = key;
        Label = label;
        Type = type;
    }

    /// <summary>camelCase JSON field name; also sent to the API as sortColumn.</summary>
    public string Key { get; }
    public string Label { get; }
    /// <summary>text | money | int — controls formatting and alignment.</summary>
    public string Type { get; }
}

public sealed class LabRatePageViewModel
{
    public string Title { get; set; } = string.Empty;
    public string Subtitle { get; set; } = string.Empty;
    public string DataUrl { get; set; } = string.Empty;
    public string LabsUrl { get; set; } = string.Empty;
    public string ExportUrl { get; set; } = string.Empty;
    public string OptionsUrl { get; set; } = string.Empty;
    public IReadOnlyList<LabRateColumn> Columns { get; set; } = Array.Empty<LabRateColumn>();
}
