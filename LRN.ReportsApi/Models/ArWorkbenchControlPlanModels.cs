namespace LRN.ReportsApi.Models;

// ============================================================================================
// Dashboard Control Plan and SLA tiles (handoff FR-DASH-02 / FR-DASH-03, retest DEF-23):
// GET dashboard/control-plan, over the caller's scoped claims.
// ============================================================================================

public sealed class ArWorkbenchControlPlan
{
    /// <summary>One row per denial classification (central Denial Code Master, by primary code).</summary>
    public List<ArWorkbenchControlPlanRow> ByClassification { get; set; } = new();
    /// <summary>One row per action / task bucket (the last follow-up's fix / resolution). Empty for client users.</summary>
    public List<ArWorkbenchControlPlanRow> ByAction { get; set; } = new();
    /// <summary>Null for client users.</summary>
    public ArWorkbenchSlaSummary? Sla { get; set; }
    /// <summary>Null for client users.</summary>
    public ArWorkbenchAppealSummary? Appeals { get; set; }
}

/// <summary>Open = not closed and unassigned; In Progress = not closed and with an agent; Closed = financially closed or work completed.</summary>
public sealed class ArWorkbenchControlPlanRow
{
    public string Label { get; set; } = string.Empty;
    /// <summary>Work Queue filter value for this row (fix / resolution, "__none" for blank); null when the row cannot drill.</summary>
    public string? Key { get; set; }
    public int OpenCount { get; set; }
    public decimal OpenAmount { get; set; }
    public int InProgressCount { get; set; }
    public decimal InProgressAmount { get; set; }
    public int ClosedCount { get; set; }
    public decimal ClosedAmount { get; set; }
}

/// <summary>Operational SLA over the last <see cref="Days"/> days: Met ÷ (Met + Breached + Open – Overdue), overall and per milestone.</summary>
public sealed class ArWorkbenchSlaSummary
{
    public int Days { get; set; }
    public decimal? AttainmentPct { get; set; }
    public int Measured { get; set; }
    public bool TargetsConfirmed { get; set; }
    public List<ArWorkbenchSlaMilestoneSummary> Milestones { get; set; } = new();
}

public sealed class ArWorkbenchSlaMilestoneSummary
{
    public string Label { get; set; } = string.Empty;
    public decimal? AttainmentPct { get; set; }
    public int Measured { get; set; }
}

/// <summary>
/// Appeal Success Rate: claims with an appeal follow-up (fix / resolution containing "Appeal") that received an
/// insurance payment dated on or after the first appeal, out of the appealed claims that are decided
/// (paid since the appeal, or financially closed).
/// </summary>
public sealed class ArWorkbenchAppealSummary
{
    public int Appealed { get; set; }
    public int Decided { get; set; }
    public int Won { get; set; }
    public decimal? SuccessRate { get; set; }
}
