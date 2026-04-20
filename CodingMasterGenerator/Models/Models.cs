namespace CodingMasterGenerator.Models;

/// <summary>Represents one row from the Line Level CSV.</summary>
public sealed class LineLevelRow
{
    public string ClaimID { get; set; } = string.Empty;
    public string CPTCode { get; set; } = string.Empty;
    public int Units { get; set; } = 1;
    public decimal ChargeAmount { get; set; }
    public string PayerName { get; set; } = string.Empty;
    public string Payer_Common_Code { get; set; } = string.Empty;
    public string Panelname { get; set; } = string.Empty;
}

/// <summary>Intermediate: one processed claim (all lines aggregated).</summary>
public sealed class ProcessedClaim
{
    public string ClaimID { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public string Payer_Common_Code { get; set; } = string.Empty;
    public string RawPanelName { get; set; } = string.Empty;

    /// <summary>Detected or data-driven panel name (before ABR suffix).</summary>
    public string DetectedPanel { get; set; } = string.Empty;

    /// <summary>Final Coding Master Panel Name (with +ABR if applicable).</summary>
    public string CodingMasterPanelName { get; set; } = string.Empty;

    /// <summary>Production Panel Name derived from Coding Master Panel Name.</summary>
    public string ProductionPanelName { get; set; } = string.Empty;

    /// <summary>Procedure string, e.g. "87798*12,87594*1".</summary>
    public string Procedure { get; set; } = string.Empty;

    public decimal TotalBilledCharge { get; set; }

    /// <summary>Set of CPT codes on this claim.</summary>
    public HashSet<string> CptCodes { get; set; } = [];
}

/// <summary>Final output row for the Excel sheet.</summary>
public sealed class CodingMasterOutputRow
{
    public int SNo { get; set; }
    public string ProductionPanelName { get; set; } = string.Empty;
    public string CodingMasterPanelName { get; set; } = string.Empty;
    public string Payer { get; set; } = string.Empty;
    public string Payer_Common_Code { get; set; } = string.Empty;
    public string Procedure { get; set; } = string.Empty;
    public decimal TotalBilledCharge { get; set; }
    public string ConditionIfAny { get; set; } = string.Empty;
}
