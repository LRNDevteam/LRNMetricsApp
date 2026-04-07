namespace PredictionAnalysis.Models;

public class ClaimRecord
{
    // ── Typed fields used for analysis logic ─────────────────────────────────
    public string AccessionNumber { get; set; } = string.Empty;
    public string VisitNumber { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    /// <summary>Source panel / test name (e.g. "Respiratory Panel"). Falls back to ForecastingP when blank.</summary>
    public string PanelName { get; set; } = string.Empty;
    public string ForecastingP { get; set; } = string.Empty;
    public string PayStatus { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;
    public string DenialDescription { get; set; } = string.Empty;
    public DateTime? ExpectedPaymentDate { get; set; }
    public DateTime? FirstBilledDate { get; set; }
    public decimal ModeAllowedAmount { get; set; }   // Mode Allowed Amount - Same Lab
    public decimal ModeInsurancePaid { get; set; }   // Mode Insurance Paid - Same Lab
    public decimal AllowedAmount { get; set; }   // Actual Allowed Amount
    public decimal InsurancePayment { get; set; }   // Actual Insurance Payment

    // ── Age calculation fields ────────────────────────────────────────────────
    /// <summary>Days between Today and Expected Payment Date.</summary>
    public int DaysSinceExpectedPayment { get; set; }
    
    /// <summary>Age bucket: "0-30", "31-60", "61-90", "91-120", ">120".</summary>
    public string AgeGroup { get; set; } = string.Empty;

    // ── All raw source columns preserved in original order ───────────────────
    // Key   = exact header text from the source Excel sheet
    // Value = raw cell string value
    // Used by WriteSheet5 / WriteSheet6 to reproduce every source column.
    public Dictionary<string, string> RawColumns { get; set; } = [];

    // ── Ordered header list (shared across all records in a load) ─────────────
    // Populated once by ExcelReaderService and stored on the first record;
    // the writer reads it from records[0].SourceHeaders.
    public List<string> SourceHeaders { get; set; } = [];
}