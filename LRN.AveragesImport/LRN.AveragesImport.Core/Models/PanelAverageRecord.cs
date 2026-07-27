namespace LRN.AveragesImport.Core.Models;

/// <summary>
/// One parsed row of a PanelAverage CSV. The CSV's "LabID" column actually carries the
/// lab NAME and is mapped to <see cref="LabName"/>; the numeric lab id comes from config.
/// </summary>
public sealed class PanelAverageRecord
{
    public string? LabName { get; set; }
    public string? PayerId { get; set; }
    public string? PayerDisplayName { get; set; }
    public string? PanelName { get; set; }
    public string? WindowType { get; set; }
    public DateTime? StartDate { get; set; }
    public DateTime? EndDate { get; set; }
    public DateTime? AsOfDateTime { get; set; }
    public int? PaidLineCount { get; set; }
    public decimal? AvgChargeAmount { get; set; }
    public decimal? AvgPaidAmount { get; set; }
    public decimal? AvgAllowedAmount { get; set; }
    public decimal? AvgPatientPaidAmount { get; set; }
    public decimal? AvgPatientResponsibility { get; set; }
    public decimal? MedianPaidAmount { get; set; }
    public decimal? P25PaidAmount { get; set; }
    public decimal? P75PaidAmount { get; set; }
    public int? TotalLineCount { get; set; }
    public int? DeniedLineCount { get; set; }
    public int? AdjustedLineCount { get; set; }
    public DateTime? LastSeenDos { get; set; }
}
