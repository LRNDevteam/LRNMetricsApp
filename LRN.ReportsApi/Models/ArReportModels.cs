namespace LRN.ReportsApi.Models;

/// <summary>
/// RPT-01 - AR Follow-up Activity Detail.
/// Denial Workflow Management | AR Reporting Requirements v1.0, section 3.1.
///
/// Report grain: one row per qualifying activity event per claim or denial line item. A qualifying
/// activity is a work note, workflow status update, action/task completion, follow-up schedule
/// update, escalation, response or rework event (spec section 2.5). Passive navigation produces no
/// row in any source table, so the spec's exclusion of it holds without a special case.
/// </summary>
public sealed class ArActivityReportFilter
{
    public int LabId { get; set; }

    /// <summary>Activity date/time range. Required - the report always runs over a bounded window.</summary>
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }

    /// <summary>As-of instant for due status and aging. Defaults to now; kept so a run is reproducible.</summary>
    public DateTime? AsOf { get; set; }

    public string Analyst { get; set; } = string.Empty;
    public string Manager { get; set; } = string.Empty;
    public string Team { get; set; } = string.Empty;
    public string Payer { get; set; } = string.Empty;
    public string DenialClassification { get; set; } = string.Empty;
    public string ActionCategory { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public string WorkflowStatus { get; set; } = string.Empty;
    public string ReportingBucket { get; set; } = string.Empty;
    public string AgingBucket { get; set; } = string.Empty;
    public string DueStatus { get; set; } = string.Empty;
    public string EscalationStatus { get; set; } = string.Empty;
    public string ActivityType { get; set; } = string.Empty;
    public string ContactMethod { get; set; } = string.Empty;
    public string UpdateSource { get; set; } = string.Empty;
    public string SearchText { get; set; } = string.Empty;

    /// <summary>"Claim" or "Line". Drives which distinct-worked measure the UI leads with.</summary>
    public string Grain { get; set; } = "Claim";

    /// <summary>Spec section 3.1: the most recent qualifying activity at the selected grain.</summary>
    public bool LatestOnly { get; set; }

    /// <summary>none | analyst | manager | classification | action | payer | activityType</summary>
    public string GroupBy { get; set; } = "none";

    public string SortBy { get; set; } = "activityDate";
    public string SortDir { get; set; } = "desc";

    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;

    // Populated by the controller, never bound from the query string.
    public string Role { get; set; } = string.Empty;
    public string UserName { get; set; } = string.Empty;

    /// <summary>
    /// Set by the export endpoint only. An export must contain every filtered row - a paged export
    /// would break the spec's reconciliation requirement (FR-002) - so the page-size clamp is
    /// raised for that one path instead of running the spine query once per page.
    /// </summary>
    public bool IsExport { get; set; }
}

/// <summary>One qualifying activity event. Column groups follow the spec's "Required detail columns" table.</summary>
public sealed class ArActivityEventRow
{
    // -- Identification ------------------------------------------------------------------
    /// <summary>
    /// Synthetic across the three event sources: "H:{HistoryId}", "N:{NoteId}", "E:{EscalationId}".
    /// The tables have independent identity sequences, so a bare id would collide.
    /// </summary>
    public string ActivityId { get; set; } = string.Empty;
    public string SourceType { get; set; } = string.Empty;
    public string ClaimId { get; set; } = string.Empty;
    public string LineItemId { get; set; } = string.Empty;
    public string EncounterNumber { get; set; } = string.Empty;
    public string CptCode { get; set; } = string.Empty;
    public DateTime? DateOfService { get; set; }

    // -- Classification ------------------------------------------------------------------
    public string PayerName { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;
    public string DenialClassification { get; set; } = string.Empty;
    public string DenialReason { get; set; } = string.Empty;
    public string WorkflowStatus { get; set; } = string.Empty;
    /// <summary>Stable reporting bucket from dbo.DenialStatusBucketMap - never a status name embedded in report code.</summary>
    public string ReportingBucket { get; set; } = string.Empty;
    public string AgingBucket { get; set; } = string.Empty;
    public string Priority { get; set; } = string.Empty;

    // -- Assignment ----------------------------------------------------------------------
    public string AnalystName { get; set; } = string.Empty;
    public string ManagerName { get; set; } = string.Empty;
    public string TeamName { get; set; } = string.Empty;
    public DateTime? AssignedOn { get; set; }
    public string AssignedBy { get; set; } = string.Empty;

    // -- Activity ------------------------------------------------------------------------
    public DateTime ActivityDate { get; set; }
    public string ActivityDateKey { get; set; } = string.Empty;
    public string Author { get; set; } = string.Empty;
    public string ActivityType { get; set; } = string.Empty;
    public string ContactMethod { get; set; } = string.Empty;
    public string NoteText { get; set; } = string.Empty;
    /// <summary>True when NoteText was withheld from a client-facing role rather than being empty.</summary>
    public bool NoteMasked { get; set; }

    // -- Workflow change -----------------------------------------------------------------
    public string PreviousStatus { get; set; } = string.Empty;
    public string NewStatus { get; set; } = string.Empty;
    public string StatusReason { get; set; } = string.Empty;

    // -- Action --------------------------------------------------------------------------
    public string ActionCategory { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public bool ActionCompleted { get; set; }
    public DateTime? ActionCompletedOn { get; set; }
    public string ActionCompletedBy { get; set; } = string.Empty;
    public string ActionCompletedDateLabel { get; set; } = string.Empty;
    /// <summary>
    /// True when completion came from a real dbo.DenialActionCompletionEvent row, false when it was
    /// read off the current DenialTaskBoard flag. Surfaced so an operational completion figure is
    /// never presented as event-backed when it is not.
    /// </summary>
    public bool ActionCompletionIsEvent { get; set; }

    // -- Follow-up -----------------------------------------------------------------------
    public DateTime? NextFollowUpDate { get; set; }
    public string FollowUpCategory { get; set; } = string.Empty;
    public DateTime? OriginalFollowUpDate { get; set; }
    public int RescheduleCount { get; set; }
    /// <summary>
    /// Due status of the follow-up date carried by THIS activity row, evaluated against the as-of
    /// date. Spec section 3.1: historical due dates in activity rows are audit snapshots; current
    /// overdue backlog belongs to RPT-05, not here.
    /// </summary>
    public string DueStatus { get; set; } = string.Empty;

    // -- Escalation ----------------------------------------------------------------------
    public bool Escalated { get; set; }
    public string EscalationId { get; set; } = string.Empty;
    public string EscalationReason { get; set; } = string.Empty;
    public string EscalationRecipient { get; set; } = string.Empty;
    public string EscalationStatus { get; set; } = string.Empty;

    // -- Financial -----------------------------------------------------------------------
    public decimal OriginalCharge { get; set; }
    public decimal BalanceSnapshot { get; set; }
    /// <summary>
    /// False when BalanceSnapshot fell back to the CURRENT task-board balance because the event
    /// predates per-event snapshot capture. The UI and the export both mark those rows.
    /// </summary>
    public bool BalanceIsSnapshot { get; set; }

    // -- Audit ---------------------------------------------------------------------------
    public string UpdateSource { get; set; } = string.Empty;
    public string UploadBatchId { get; set; } = string.Empty;
    public string RunId { get; set; } = string.Empty;
    public string CreatedBy { get; set; } = string.Empty;
}

/// <summary>Spec section 3.1 "Summary measures and formulas". Every measure is labelled by its own grain.</summary>
public sealed class ArActivitySummary
{
    /// <summary>COUNT(activity_event_id) - all qualifying event rows after filters.</summary>
    public int ActivityEvents { get; set; }

    /// <summary>COUNT DISTINCT (claim_id, analyst_id, activity_date).</summary>
    public int DistinctClaimDaysWorked { get; set; }

    /// <summary>COUNT DISTINCT (line_item_id, analyst_id, activity_date).</summary>
    public int DistinctLineDaysWorked { get; set; }

    /// <summary>Distinct claims touched in the whole period, regardless of how many days.</summary>
    public int DistinctClaimsWorked { get; set; }
    public int DistinctLinesWorked { get; set; }
    public int DistinctAnalysts { get; set; }

    /// <summary>Completed action events in the window. Event-backed count and flag-derived count are kept apart.</summary>
    public int ActionsCompleted { get; set; }
    public int ActionsCompletedFromEvents { get; set; }

    /// <summary>SUM of one balance per distinct claim/analyst/activity date - never the same balance per note.</summary>
    public decimal BalanceWorked { get; set; }

    /// <summary>COUNT(escalation_event_id WHERE event_type = Raised). A response is a separate event.</summary>
    public int EscalationsRaised { get; set; }
    public int NotesRecorded { get; set; }
    public int StatusChanges { get; set; }

    /// <summary>Rows whose balance is the current figure rather than a captured snapshot.</summary>
    public int RowsWithFallbackBalance { get; set; }
}

/// <summary>An aggregate row for the By Analyst / By Classification / By Action grouping tabs.</summary>
public sealed class ArActivityGroupRow
{
    public string GroupKey { get; set; } = string.Empty;
    public string GroupLabel { get; set; } = string.Empty;
    public int ActivityEvents { get; set; }
    public int DistinctClaimDaysWorked { get; set; }
    public int DistinctLineDaysWorked { get; set; }
    public int DistinctClaims { get; set; }
    public int ActionsCompleted { get; set; }
    public int EscalationsRaised { get; set; }
    public decimal BalanceWorked { get; set; }
}

/// <summary>FR-001 report run metadata. Displayed on screen and written into every export.</summary>
public sealed class ArReportRunMetadata
{
    public string ReportCode { get; set; } = string.Empty;
    public string ReportName { get; set; } = string.Empty;
    public string RunId { get; set; } = string.Empty;
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
    public string GeneratedBy { get; set; } = string.Empty;
    public string GeneratedByRole { get; set; } = string.Empty;
    public DateTime GeneratedOn { get; set; }
    public DateTime AsOf { get; set; }
    /// <summary>Last successful workflow data refresh (the latest denial analysis run for the lab).</summary>
    public DateTime? DataRefreshedOn { get; set; }
    public string DataRefreshRunId { get; set; } = string.Empty;
    public string Grain { get; set; } = string.Empty;
    /// <summary>"Internal Management" or "Client-facing (restricted)" - drives note masking.</summary>
    public string RoleView { get; set; } = string.Empty;
    public bool InternalNotesVisible { get; set; }
    public IReadOnlyList<ArAppliedFilter> AppliedFilters { get; set; } = Array.Empty<ArAppliedFilter>();
    /// <summary>
    /// FR-011: measures whose source data is not captured yet, with the dependency named. Shown
    /// rather than silently omitted.
    /// </summary>
    public IReadOnlyList<string> UnavailableMeasures { get; set; } = Array.Empty<string>();
}

public sealed class ArAppliedFilter
{
    public string Label { get; set; } = string.Empty;
    public string Value { get; set; } = string.Empty;
}

public sealed class ArActivityReportResult
{
    public ArReportRunMetadata Metadata { get; set; } = new();
    public ArActivitySummary Summary { get; set; } = new();
    public PagedResult<ArActivityEventRow> Detail { get; set; } = new();
    public IReadOnlyList<ArActivityGroupRow> Groups { get; set; } = Array.Empty<ArActivityGroupRow>();
    /// <summary>
    /// Empty-state reason (spec section 2.6): distinguishes "no records matched filters" from
    /// "data unavailable" so an empty grid is never ambiguous.
    /// </summary>
    public string EmptyStateReason { get; set; } = string.Empty;
}

/// <summary>Dropdown values for the report's own filter bar, sourced from the lab's real data + config tables.</summary>
public sealed class ArActivityFilterOptions
{
    public IReadOnlyList<string> Analysts { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> Managers { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> Teams { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> Payers { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> DenialClassifications { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ActionCategories { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> Tasks { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> WorkflowStatuses { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ReportingBuckets { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> AgingBuckets { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> DueStatuses { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> EscalationStatuses { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ActivityTypes { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> ContactMethods { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> FollowUpCategories { get; set; } = Array.Empty<string>();
    public IReadOnlyList<string> UpdateSources { get; set; } = Array.Empty<string>();
}

/// <summary>One claim's full activity timeline - the drill-down target of the detail grid.</summary>
public sealed class ArActivityTimelineRow
{
    public string ActivityId { get; set; } = string.Empty;
    public DateTime ActivityDate { get; set; }
    public string ActivityType { get; set; } = string.Empty;
    public string Author { get; set; } = string.Empty;
    public string LineItemId { get; set; } = string.Empty;
    public string CptCode { get; set; } = string.Empty;
    public string PreviousStatus { get; set; } = string.Empty;
    public string NewStatus { get; set; } = string.Empty;
    public string NoteText { get; set; } = string.Empty;
    public bool NoteMasked { get; set; }
    public string UpdateSource { get; set; } = string.Empty;
    public string RunId { get; set; } = string.Empty;
}

public sealed class ArReportCatalogItem
{
    public string ReportCode { get; set; } = string.Empty;
    public string ReportName { get; set; } = string.Empty;
    public string Grain { get; set; } = string.Empty;
    public string Purpose { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string StatusNote { get; set; } = string.Empty;
    public string RouteKey { get; set; } = string.Empty;
    public int SortOrder { get; set; }
}

public sealed class ArReportSavedView
{
    public int SavedViewId { get; set; }
    public string ReportCode { get; set; } = "RPT-01";
    public int LabId { get; set; }
    public string OwnerUserName { get; set; } = string.Empty;
    public string ViewName { get; set; } = string.Empty;
    public string FiltersJson { get; set; } = string.Empty;
    public bool IsDefault { get; set; }
    public DateTime UpdatedOn { get; set; }
}

public sealed class ArReportSavedViewRequest
{
    public int LabId { get; set; }
    public string ViewName { get; set; } = string.Empty;
    public string FiltersJson { get; set; } = string.Empty;
    public bool IsDefault { get; set; }
}

/// <summary>Analyst -> manager/team, resolved from LRNMaster.dbo.LabUsers (AR Reporting GAP-2).</summary>
public sealed record ArAnalystOrg(string UserName, string DisplayName, string ManagerUserName, string TeamName);
