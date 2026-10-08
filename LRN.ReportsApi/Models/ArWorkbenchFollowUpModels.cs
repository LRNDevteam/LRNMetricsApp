namespace LRN.ReportsApi.Models;

/// <summary>Automatic Adjustment: the claims (and $) adjusted, or that would be on a preview.</summary>
public sealed class ArWorkbenchAdjustmentResult
{
    public int ClaimCount { get; set; }
    public decimal TotalAmount { get; set; }
    public string? Message { get; set; }
}

/// <summary>Claims to adjust or mark posted. ClaimKeys null on process / preview = every eligible claim.</summary>
public sealed class ArWorkbenchAdjustmentRequest
{
    public List<long>? ClaimKeys { get; set; }
}

// ============================================================================================
// AR Workbench - follow-up notes, Data Processing insights, timely-filing limits and the claim
// export. Rules follow the mockup's App.actions.logFollowUp / App.openFollowUpModal.
// ============================================================================================

/// <summary>The Log Follow-Up Note form (Comments Framework fields).</summary>
public sealed class ArWorkbenchFollowUpRequest
{
    public string? ClaimType { get; set; }
    public string? FollowUpType { get; set; }
    /// <summary>The Comments Framework claim status (Paid / Denied / ...), not the ingested source status.</summary>
    public string? ClaimStatus { get; set; }
    /// <summary>Required when ClaimStatus is Denied; ignored otherwise.</summary>
    public string? DenialRootCause { get; set; }
    public string? FixResolution { get; set; }
    public string? Comment { get; set; }
    /// <summary>Null = no further follow-up expected.</summary>
    public DateTime? NextFollowUpDate { get; set; }
    /// <summary>Required when FixResolution is "CIP - Client Escalations".</summary>
    public string? CipCategory { get; set; }
    public string? CipRequiredInfo { get; set; }
    public string? CipComment { get; set; }
}

public sealed class ArWorkbenchFollowUpResult
{
    public long FollowUpId { get; set; }
    public long? CipCaseId { get; set; }
    public string WorkflowStatus { get; set; } = string.Empty;
    public string Message { get; set; } = string.Empty;
}

/// <summary>One Denial Analysis Report row: a denial code's insight for a sync week, with what is still unassigned.</summary>
public sealed class ArWorkbenchInsightRow
{
    public int DenialInsightId { get; set; }
    public DateTime WeekStart { get; set; }
    public bool IsCurrentWeek { get; set; }
    public string DenialCode { get; set; } = string.Empty;
    public string? DenialDescription { get; set; }
    public string? DenialCategory { get; set; }
    public string? CategoryTag { get; set; }
    public string? RecommendedAction { get; set; }
    public int ClaimCountAtBuild { get; set; }
    public decimal TotalBalanceAtBuild { get; set; }
    public int OutstandingClaims { get; set; }
    public decimal OutstandingBalance { get; set; }
    public string? TopPayer { get; set; }
    public decimal? TopPayerBalance { get; set; }
    public decimal? ImpactPct { get; set; }
    public string? TopServiceLine { get; set; }
    public string? Observation { get; set; }
}

/// <summary>
/// Data Processing > Denial Analysis Report: the team's own Key Observations, uploaded in LRN Metrics
/// (Denial Claim Report > Key Observations &amp; Highlights, lab table dbo.DenialClaimLevelInsight).
/// When a week has none, the page shows the system-generated insights instead.
/// </summary>
public sealed class ArWorkbenchUploadedInsights
{
    /// <summary>False when the lab has no dbo.DenialClaimLevelInsight table (nothing ever uploaded).</summary>
    public bool TableInstalled { get; set; }
    public List<ArWorkbenchUploadedInsight> Current { get; set; } = new();
    public List<ArWorkbenchUploadedInsight> Previous { get; set; } = new();
}

public sealed class ArWorkbenchUploadedInsight
{
    public long Id { get; set; }
    public DateTime WeekStart { get; set; }
    public int SortOrder { get; set; }
    /// <summary>As uploaded ('CO-242', 'M127').</summary>
    public string DenialCode { get; set; } = string.Empty;
    /// <summary>The claim sync's normalized form ('242'), what the Work Queue denial-code filter matches.</summary>
    public string? NormalizedCode { get; set; }
    public string? Description { get; set; }
    public string? PayerName { get; set; }
    public int NoOfDenials { get; set; }
    public decimal TotalBalance { get; set; }
    public int InsuranceNoOfDenials { get; set; }
    public decimal InsuranceBalance { get; set; }
    /// <summary>"$ Impact (%)" as the workbook showed it; an impossible (&gt; 100%) figure is recomputed from the balances.</summary>
    public string? Impact { get; set; }
    /// <summary>Plain text (the stored rich text with bullets kept as "• " lines).</summary>
    public string? Observation { get; set; }
    public string? ActionCategory { get; set; }
    public string? Action { get; set; }
    public string? Responsibility { get; set; }
    public string? Status { get; set; }
    public DateTime? Eta { get; set; }
    public DateTime? UpdatedOn { get; set; }
    public string? UpdatedBy { get; set; }
    /// <summary>Live: claims whose primary denial is this code, still unassigned with an open insurance balance.</summary>
    public int OpenClaims { get; set; }
    public decimal OpenBalance { get; set; }
}

/// <summary>Timely-filing limit for one financial class (dbo.ARWB_TflThreshold).</summary>
public sealed class ArWorkbenchTflThreshold
{
    public string FinancialClass { get; set; } = string.Empty;
    public int ThresholdDays { get; set; }
    /// <summary>Synced claims whose PayerType is this financial class.</summary>
    public int ClaimCount { get; set; }
}

public sealed class ArWorkbenchTflSettings
{
    public List<ArWorkbenchTflThreshold> Thresholds { get; set; } = new();
    /// <summary>AppSetting TflDefaultDays: the limit for a financial class with no row.</summary>
    public int DefaultDays { get; set; }
    /// <summary>AppSetting TflRiskWindowDays: open claims this close to the deadline are TFL-at-risk.</summary>
    public int RiskWindowDays { get; set; }
    /// <summary>Financial classes on synced claims that have no row and so use DefaultDays.</summary>
    public List<ArWorkbenchTflThreshold> UnmappedClasses { get; set; } = new();
}

public sealed class ArWorkbenchTflThresholdRequest
{
    /// <summary>The class being edited (update only).</summary>
    public string? OriginalFinancialClass { get; set; }
    public string? FinancialClass { get; set; }
    public int? ThresholdDays { get; set; }
}

public sealed class ArWorkbenchTflDefaultsRequest
{
    public int? DefaultDays { get; set; }
    public int? RiskWindowDays { get; set; }
}
