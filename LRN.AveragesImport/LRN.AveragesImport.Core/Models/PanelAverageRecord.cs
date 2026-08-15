namespace LRN.AveragesImport.Core.Models;

/// <summary>
/// One aggregate row from the lab's dbo.ClaimLevelData, grouped per SOP v1.1 §2 by
/// WindowBasis + WindowType + PanelName + Payer.
///
/// Claim level, unlike CPT level, has no per-unit columns: §2.1.1/§2.1.2 name the
/// plain "AllowedAmount" / "InsurancePayment" columns, and the four counts
/// (§2.1.7-§2.1.10) are distinct claims rather than line items.
/// </summary>
public sealed class PanelAverageRecord
{
    public string? LabName { get; set; }
    public string? PanelName { get; set; }

    /// <summary>"DOS" (from DaystoDOS) or "Billed" (from DaystoBill) — SOP v1.1 §2.1 steps 3-4.</summary>
    public string? WindowBasis { get; set; }

    public string? WindowType { get; set; }
    public string? PayerId { get; set; }
    public string? PayerDisplayName { get; set; }
    public DateTime? StartDate { get; set; }
    public DateTime? EndDate { get; set; }
    public DateTime? AsOfDateTime { get; set; }
    public decimal? AvgChargeAmount { get; set; }
    public decimal? AvgPaidAmount { get; set; }
    public decimal? AvgAllowedAmount { get; set; }
    public decimal? AvgPatientPaidAmount { get; set; }
    public decimal? AvgPatientResponsibility { get; set; }
    public decimal? MedianPaidAmount { get; set; }
    public decimal? MedianAllowedAmount { get; set; }
    public decimal? ModePaidAmount { get; set; }
    public decimal? ModeAllowedAmount { get; set; }
    public decimal? P25PaidAmount { get; set; }
    public decimal? P75PaidAmount { get; set; }

    /// <summary>Distinct ClaimIDs — SOP v1.1 §2.1.7 "Count (Unique Claim ID)".</summary>
    public int? TotalLineCount { get; set; }

    public int? PaidLineCount { get; set; }
    public int? DeniedLineCount { get; set; }
    public int? AdjustedLineCount { get; set; }
    public DateTime? LastSeenDos { get; set; }
}
