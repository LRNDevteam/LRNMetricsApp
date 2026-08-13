namespace LRN.AveragesImport.Core.Models;

/// <summary>
/// One aggregate row from the lab's dbo.LineLevelData, grouped per SOP v1.1 §1 by
/// WindowBasis + WindowType + CPTCode + PanelName + Payer.
/// </summary>
public sealed class CptAverageRecord
{
    public string? LabName { get; set; }
    public string? CptCode { get; set; }
    public string? PanelName { get; set; }

    /// <summary>"DOS" (from DaystoDOS) or "Billed" (from DaystoBill) — SOP v1.1 §1.1 steps 3-4.</summary>
    public string? WindowBasis { get; set; }

    public string? WindowType { get; set; }
    public string? PayerCommonCode { get; set; }
    public string? PayerDisplayName { get; set; }
    public int? GlobalPayerId { get; set; }
    public int? AvgUnits { get; set; }
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
    public decimal? MedianAllowedAmount { get; set; }
    public decimal? ModePaidAmount { get; set; }
    public decimal? ModeAllowedAmount { get; set; }
    public decimal? P25PaidAmount { get; set; }
    public decimal? P75PaidAmount { get; set; }
    public int? TotalLineCount { get; set; }
    public int? DeniedLineCount { get; set; }
    public int? AdjustedLineCount { get; set; }
    public DateTime? LastSeenDos { get; set; }
}
