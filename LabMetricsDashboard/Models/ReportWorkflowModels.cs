namespace LabMetricsDashboard.Models;

/// <summary>Status of one report within one run, as reported by the workflow tracker.</summary>
public enum ReportRunStatus
{
    /// <summary>This report is not produced for this lab at all — never a failure, always greyed.</summary>
    NotConfigured = 0,
    Success = 1,
    Failed = 2,

    /// <summary>
    /// Available for this lab and expected in this run, but the tracker has no result yet —
    /// the run is still working through it. Shown as a gear, not a cross.
    /// </summary>
    Pending = 3,

    /// <summary>
    /// Pending for longer than <see cref="ReportBoardViewModel.OverdueAfter"/> since the run's
    /// source data landed. The pipeline has almost certainly stalled rather than being slow.
    /// </summary>
    Overdue = 4,
}

/// <summary>
/// One entry in the report catalog: the bridge between a tracker column and the page that shows it.
/// <see cref="TrackerColumn"/> is the join key and must match the SP column name exactly.
/// </summary>
public sealed record ReportCatalogEntry(
    string TrackerColumn,
    string DisplayName,
    string ShortName,
    string Icon,
    string Group,
    string? Controller,
    string? Action,
    string? FeatureFlag,
    string? LinkTab = null,
    // When set, this tile's run status is read from another tracker column instead of its own
    // (e.g. LIMS Master mirrors "LIS Summary": success if LIS Summary succeeded, else failed).
    string? StatusFrom = null,
    // Labs this report is produced for. Null = every lab (subject to FeatureFlag). Matched on a
    // normalised token, so "Cove" also matches the "CoveLRN" database spelling.
    string[]? AllowedLabs = null);

public sealed class LabReportStatus
{
    public required ReportCatalogEntry Catalog { get; init; }
    public ReportRunStatus Status { get; init; }

    /// <summary>Success + a known route + the lab's feature flag on + the user permitted.</summary>
    public bool IsLinkable { get; init; }

    /// <summary>Why the cell is not a link. Surfaced as the cell tooltip.</summary>
    public string? BlockedReason { get; init; }

    /// <summary>The raw tracker value, kept for the tooltip when it is not one of the known states.</summary>
    public string? RawStatus { get; init; }
}

public sealed class LabReportRow
{
    public required string LabDisplayName { get; init; }

    /// <summary>The LabSettings key used for <c>?lab=</c>. Empty when the lab could not be resolved.</summary>
    public required string LabConfigKey { get; init; }

    public bool IsMapped => !string.IsNullOrEmpty(LabConfigKey);
    public string? RunId { get; init; }
    public string? Week { get; init; }
    public DateTime? SyncedOn { get; init; }
    public List<LabReportStatus> Reports { get; init; } = [];

    public int ReadyCount => Reports.Count(r => r.Status == ReportRunStatus.Success);
    public int FailedCount => Reports.Count(r => r.Status == ReportRunStatus.Failed);
    public bool HasFailures => FailedCount > 0;

    /// <summary>Available reports still waiting on this run.</summary>
    public int PendingCount => Reports.Count(r => r.Status == ReportRunStatus.Pending);

    /// <summary>Reports whose run stalled — the ones the page warns about.</summary>
    public int OverdueCount => Reports.Count(r => r.Status == ReportRunStatus.Overdue);
    public bool HasOverdue => OverdueCount > 0;

    /// <summary>
    /// True when this run's source data (LIS / Line Level / Claim Level) all landed, so every
    /// other available report for the lab is expected to follow.
    /// </summary>
    public bool SourcesReady { get; init; }

    /// <summary>Names of the overdue reports, for the page-level warning.</summary>
    public List<string> OverdueReports => Reports
        .Where(r => r.Status == ReportRunStatus.Overdue)
        .Select(r => r.Catalog.DisplayName)
        .ToList();

    /// <summary>Avatar initial for the lab tile.</summary>
    public string Initial => string.IsNullOrWhiteSpace(LabDisplayName) ? "?" : LabDisplayName.Trim()[..1].ToUpperInvariant();
}

public sealed class ReportBoardViewModel
{
    /// <summary>Report columns in display order - catalog order first, then any unknown SP columns.</summary>
    public List<ReportCatalogEntry> Columns { get; init; } = [];

    public List<LabReportRow> Rows { get; init; } = [];
    public DateTime? LastSyncedOn { get; init; }
    public string View { get; init; } = "matrix";     // matrix | cards
    public string Sort { get; init; } = "latest";     // latest | az
    public string Filter { get; init; } = "all";      // all | failed | incomplete

    /// <summary>Set when the tracker call failed; the page renders an error card instead of a blank grid.</summary>
    public string? DataError { get; init; }

    /// <summary>When the cached copy last succeeded, shown alongside <see cref="DataError"/>.</summary>
    public DateTime? LastGoodAt { get; init; }

    public int TotalReady => Rows.Sum(r => r.ReadyCount);
    public int TotalFailed => Rows.Sum(r => r.FailedCount);
    public int TotalPending => Rows.Sum(r => r.PendingCount);
    public int TotalOverdue => Rows.Sum(r => r.OverdueCount);

    /// <summary>
    /// How long a report may stay Pending after its run's source data landed before the board
    /// calls it stalled.
    /// </summary>
    public static readonly TimeSpan OverdueAfter = TimeSpan.FromDays(1);

    /// <summary>Labs with at least one stalled report, for the warning banner.</summary>
    public List<LabReportRow> OverdueRows => Rows.Where(r => r.HasOverdue).ToList();

    /// <summary>Column groups in display order, for the coloured band row above the matrix.</summary>
    public List<(string Group, int Span)> ColumnBands =>
        Columns.Aggregate(new List<(string Group, int Span)>(), (bands, column) =>
        {
            if (bands.Count > 0 && bands[^1].Group == column.Group) bands[^1] = (column.Group, bands[^1].Span + 1);
            else bands.Add((column.Group, 1));
            return bands;
        });
}
