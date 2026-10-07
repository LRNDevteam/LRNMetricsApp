namespace LRN.ReportsApi.Models;

// ============================================================================================
// Recovery & Financial Analytics (T071) - the mockup's App.views.analytics
// (docs/Denial_WorkFlow/LRN_Denial_AR_Workbench_Demo_Account.html), every figure computed in SQL
// over the caller's scoped claims.
// ============================================================================================

public sealed class ArWorkbenchAnalytics
{
    public int TotalClaims { get; set; }
    /// <summary>Original insurance balance identified at intake (dbo.ARWB_Claim.InitialInsuranceAR).</summary>
    public decimal InitialAR { get; set; }
    public decimal Recovered { get; set; }
    /// <summary>Remaining insurance AR today.</summary>
    public decimal Outstanding { get; set; }
    /// <summary>Recovered / InitialAR over claims with a non-zero initial balance; 0 when there is none.</summary>
    public decimal RecoveryRate { get; set; }
    public DateTime? DataRefreshedOn { get; set; }

    public List<ArWorkbenchRecoveryRow> ByClient { get; set; } = new();
    public List<ArWorkbenchRecoveryRow> ByPayer { get; set; } = new();
    public List<ArWorkbenchRecoveryRow> ByPanel { get; set; } = new();
    public List<ArWorkbenchRecoveryRow> ByCategory { get; set; } = new();
    public List<ArWorkbenchRecoveryRow> ByAgent { get; set; } = new();
    public List<ArWorkbenchRecoveryRow> ByQueue { get; set; } = new();

    /// <summary>Follow-Up Comments Breakdown: every logged (non-system) follow-up note by Comments Framework field.</summary>
    public List<ArWorkbenchFollowUpBreakdownRow> ByClaimStatus { get; set; } = new();
    public List<ArWorkbenchFollowUpBreakdownRow> ByFixResolution { get; set; } = new();
    public List<ArWorkbenchFollowUpBreakdownRow> ByDenialRootCause { get; set; } = new();
}

/// <summary>
/// One recovered-vs-outstanding bar. Key is the Work Queue filter value for that dimension
/// (payer, panel, category, agent user name, queue id; "__none" for a blank value); null when the
/// row cannot drill (a rolled-up "All other" row, or the client dimension).
/// </summary>
public sealed class ArWorkbenchRecoveryRow
{
    public string Label { get; set; } = string.Empty;
    public string? Key { get; set; }
    public int Count { get; set; }
    public decimal InitialAR { get; set; }
    public decimal Recovered { get; set; }
    public decimal Outstanding { get; set; }
}

// ============================================================================================
// Reports (T073 / T074) - the mockup's App.views.reports. Every report is one table in the same
// shape, so the screen and the Excel export render any of them the same way.
// ============================================================================================

/// <summary>One entry of the Reports screen (GET reports).</summary>
public sealed class ArWorkbenchReportInfo
{
    public string Id { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    /// <summary>The featured report shown above the others (AR Collections Progress).</summary>
    public bool Featured { get; set; }
    /// <summary>The AR Reporting Requirements report this one delivers (RPT-02, RPT-04 ...), if any.</summary>
    public string? Code { get; set; }
    /// <summary>Event reports take a from / to date range (default the last 30 days).</summary>
    public bool HasDateRange { get; set; }
}

/// <summary>GET reports: the reports this user can open, and where each RPT-01..09 lives in the AR Workbench (T075).</summary>
public sealed class ArWorkbenchReportCatalog
{
    public List<ArWorkbenchReportInfo> Reports { get; set; } = new();
    public List<ArWorkbenchRptEntry> Rpt { get; set; } = new();
}

/// <summary>
/// One report of the Denial Workflow's RPT-01..09 catalog, re-pointed at the AR Workbench event
/// tables: either a report on the Reports page (ReportId) or a screen (Route).
/// </summary>
public sealed class ArWorkbenchRptEntry
{
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string? ReportId { get; set; }
    public string? Route { get; set; }
    public string? NavId { get; set; }
    public string Source { get; set; } = string.Empty;
}

/// <summary>Inclusive date range of an event report (dates, no time).</summary>
public sealed class ArWorkbenchReportRange
{
    public DateTime From { get; set; }
    public DateTime To { get; set; }
}

// ---- Operational SLA targets (RPT-09) - ARWB_AppSetting, edited on Master Values ----------------

public sealed class ArWorkbenchSlaTarget
{
    public string Key { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public int Days { get; set; }
}

public sealed class ArWorkbenchSlaSettings
{
    public List<ArWorkbenchSlaTarget> Targets { get; set; } = new();
    /// <summary>False until the team confirms the targets; the report labels them as drafts until then.</summary>
    public bool Confirmed { get; set; }
    public DateTime? UpdatedOn { get; set; }
    public string? UpdatedBy { get; set; }
}

public sealed class ArWorkbenchSlaSettingsRequest
{
    /// <summary>Milestone key -> target days.</summary>
    public Dictionary<string, int>? Targets { get; set; }
    public bool Confirmed { get; set; }
}

public sealed class ArWorkbenchReport
{
    public string Id { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string? Code { get; set; }
    public DateTime? DataRefreshedOn { get; set; }
    /// <summary>The date range an event report covers (inclusive); null for point-in-time reports.</summary>
    public DateTime? From { get; set; }
    public DateTime? To { get; set; }
    public List<ArWorkbenchReportColumn> Columns { get; set; } = new();
    public List<ArWorkbenchReportRow> Rows { get; set; } = new();
    /// <summary>Narrative bullets under the table (AR Collections Progress).</summary>
    public List<string> Insights { get; set; } = new();
    /// <summary>How the figures are defined - shown under the table and on the export.</summary>
    public string? Note { get; set; }
}

public sealed class ArWorkbenchReportColumn
{
    public string Key { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    /// <summary>text | count | decimal | money | pct | date</summary>
    public string Format { get; set; } = "text";
}

public sealed class ArWorkbenchReportRow
{
    /// <summary>0 = top-level / total row, 1 = indented detail under it.</summary>
    public int Level { get; set; }
    /// <summary>Category subtotal or grand total: bold on screen and in the export.</summary>
    public bool IsTotal { get; set; }
    /// <summary>One value per column, in column order.</summary>
    public List<object?> Values { get; set; } = new();
}

/// <summary>
/// One AR Queue leaf's figures for the AR Collections Progress Summary (T074), summed in SQL; the
/// confidence tiers and the rollup are applied in <c>ArWorkbenchReportRules</c>.
/// </summary>
public sealed class ArWorkbenchQueueLeafTotals
{
    public string QueueId { get; set; } = string.Empty;
    public string QueueLabel { get; set; } = string.Empty;
    public int QueueSort { get; set; }
    public string? SubQueueId { get; set; }
    public string? SubQueueLabel { get; set; }
    public int SubQueueSort { get; set; }
    public int Count { get; set; }
    /// <summary>Initial insurance AR (revenue expectation at 100%).</summary>
    public decimal InitialAR { get; set; }
    /// <summary>Initial insurance AR of the claims still owed by insurance (remaining AR &gt; 0).</summary>
    public decimal InitialAROpen { get; set; }
    /// <summary>Payments posted: recovered amount to date.</summary>
    public decimal Recovered { get; set; }
}

public sealed class ArWorkbenchFollowUpBreakdownRow
{
    public string Label { get; set; } = string.Empty;
    /// <summary>Follow-up notes logged with this value.</summary>
    public int Notes { get; set; }
    /// <summary>Distinct claims those notes touched.</summary>
    public int Claims { get; set; }
    /// <summary>Current remaining AR of those claims (each claim counted once).</summary>
    public decimal Balance { get; set; }
}
