namespace LRN.AveragesImport.Core.Models;

/// <summary>
/// One parsed row of a CptAverage CSV. The CSV's "LabID" column actually carries the
/// lab NAME and is mapped to <see cref="LabName"/>; the numeric lab id comes from config.
/// </summary>
public sealed class CptAverageRecord
{
    public string? LabName { get; set; }
    public string? PayerCommonCode { get; set; }
    public string? PayerDisplayName { get; set; }
    public string? CptCode { get; set; }
    public int? AvgUnits { get; set; }
    public string? PanelName { get; set; }
    public string? WindowType { get; set; }
    public DateTime? StartDate { get; set; }
    public DateTime? EndDate { get; set; }
    public DateTime? AsOfDateTime { get; set; }
    public int? PaidLineCount { get; set; }
    public decimal? AvgChargeAmountPerUnit { get; set; }
    public decimal? AvgPaidAmountPerUnit { get; set; }
    public decimal? AvgAllowedAmountPerUnit { get; set; }
    public decimal? AvgPatientPaidAmountPerUnit { get; set; }
    public decimal? AvgPatientResponsibilityPerUnit { get; set; }
    public decimal? MedianPaidAmount { get; set; }
    public decimal? P25PaidAmount { get; set; }
    public decimal? P75PaidAmount { get; set; }
    public int? TotalLineCount { get; set; }
    public int? DeniedLineCount { get; set; }
    public int? AdjustedLineCount { get; set; }
    public DateTime? LastSeenDos { get; set; }
    public int? GlobalPayerId { get; set; }
}
