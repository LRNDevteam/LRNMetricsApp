namespace LabMetricsDashboard.Models;

/// <summary>
/// One denied claim row straight out of a lab's own <c>dbo.ClaimLevelData</c>
/// (<c>WHERE DenialCode IS NOT NULL</c>). This is the system-of-record dataset: every weekly and
/// monthly summary metric is calculated from these rows, never from an imported insight workbook.
/// </summary>
public sealed class DenialClaimRow
{
    public string ClaimId { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;

    /// <summary>The common code the raw one rolls up to - CO45/PI45/PR45 all become 45.</summary>
    public string DenialCodeNormalized { get; set; } = string.Empty;

    public string DenialDescription { get; set; } = string.Empty;
    public string DenialClassification { get; set; } = string.Empty;

    /// <summary>
    /// The payer, from <c>PayerName_Raw</c> where the lab has it. The requirements name that column
    /// specifically as the row value for the Top Insurance summaries, so it is preferred over any
    /// mapped or cleaned payer column.
    /// </summary>
    public string PayerName { get; set; } = string.Empty;

    public string PayerNameNormalized { get; set; } = string.Empty;
    public DateTime? DenialDate { get; set; }

    /// <summary>
    /// The lab's own <c>DeniedWeek</c> value, which the weekly summary is built on. Blank where the
    /// lab has no such column - the week is then derived from <see cref="DenialDate"/> instead.
    /// </summary>
    public string DeniedWeek { get; set; } = string.Empty;

    public decimal InsuranceBalance { get; set; }
    public decimal TotalBalance { get; set; }
    public decimal BilledAmount { get; set; }
    public string CptCode { get; set; } = string.Empty;
    public string PanelName { get; set; } = string.Empty;
    public DateTime? DateOfService { get; set; }
}

/// <summary>A selectable reporting period (one month, or one week).</summary>
public sealed class DenialPeriodOption
{
    public DateTime Start { get; set; }
    public DateTime End { get; set; }
    public string Key { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public int DenialCount { get; set; }

    /// <summary>
    /// The lab's own <c>DeniedWeek</c> value this period represents, when the weekly summary is
    /// built from that column rather than from dates. Rows are then matched on this string, so a
    /// lab whose week labels do not line up with Monday-Sunday still groups the way the lab does.
    /// </summary>
    public string? DeniedWeekValue { get; set; }

    /// <summary>True when a claim belongs to this period.</summary>
    public bool Contains(DenialClaimRow row) =>
        DeniedWeekValue is not null
            ? string.Equals(row.DeniedWeek, DeniedWeekValue, StringComparison.OrdinalIgnoreCase)
            : row.DenialDate.HasValue && row.DenialDate.Value.Date >= Start && row.DenialDate.Value.Date <= End;
}

/// <summary>
/// One denial code's metrics within the selected week or month - the grain the requirements
/// define: total claims and insurance balance for the denial, plus the single most impacted payer
/// and that payer's own claim count and balance.
/// </summary>
public sealed class DenialSummaryRow
{
    public string DenialCode { get; set; } = string.Empty;
    public string DenialDescription { get; set; } = string.Empty;
    public string DenialClassification { get; set; } = string.Empty;

    /// <summary>Raw codes that rolled into this one, e.g. "CO45, PR45" - shown so the roll-up is visible.</summary>
    public string RawCodes { get; set; } = string.Empty;

    public int TotalClaims { get; set; }
    public int DenialCount { get; set; }
    public decimal InsuranceBalance { get; set; }
    public decimal TotalBalance { get; set; }

    public string HighlyImpactedPayer { get; set; } = string.Empty;
    public int PayerClaimCount { get; set; }
    public decimal PayerInsuranceBalance { get; set; }
}

/// <summary>
/// Which tab a Denial Insight row sits on.
/// <para>An explicit column rather than something derived from the week, because "Copy Data to
/// Previous Week" is a deliberate action the user takes - the rows have to stay where they were put
/// until the user moves them, not drift between tabs as the calendar turns.</para>
/// </summary>
public static class DenialInsightBuckets
{
    /// <summary>What the user most recently imported and is working on.</summary>
    public const string Current = "Current";

    /// <summary>Copied out of Current, kept for the latest 4 weeks.</summary>
    public const string Previous = "Previous";

    /// <summary>Older than 4 weeks. Read-only history.</summary>
    public const string Archive = "Archive";

    /// <summary>How many weeks stay in Previous before rolling into Archive.</summary>
    public const int PreviousWeeksRetained = 4;

    public static bool IsValid(string? bucket) =>
        bucket is Current or Previous or Archive;

    public static string Normalize(string? bucket) =>
        IsValid(bucket) ? bucket! : Current;
}

/// <summary>
/// One Denial Insight row held per lab database in <c>dbo.DenialInsightClaimLevel</c> - the user's
/// own analytical layer, imported from their workbook. Kept deliberately separate from the
/// claim-level data it describes: importing insights never recalculates or overwrites claims.
/// </summary>
public sealed class DenialInsightClaimLevelRow
{
    public long Id { get; set; }

    /// <summary>Current, Previous or Archive - see <see cref="DenialInsightBuckets"/>.</summary>
    public string Bucket { get; set; } = DenialInsightBuckets.Current;

    /// <summary>Monday of the week these insights describe. Identity, alongside the bucket and code.</summary>
    public DateTime WeekStart { get; set; }

    public string DenialCode { get; set; } = string.Empty;
    public string DenialCodeNormalized { get; set; } = string.Empty;
    public string DenialDescription { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public int NoOfDenials { get; set; }
    public int NoOfClaims { get; set; }
    public decimal TotalBalance { get; set; }
    public decimal InsuranceBalance { get; set; }
    public decimal ImpactPercentage { get; set; }

    /// <summary>Sanitized HTML: the workbook's bold / bullets / line breaks are kept, not flattened.</summary>
    public string ObservationHtml { get; set; } = string.Empty;

    public string ActionCategory { get; set; } = string.Empty;

    /// <summary>Sanitized HTML, same as <see cref="ObservationHtml"/>.</summary>
    public string ActionHtml { get; set; } = string.Empty;

    public string FeedbackResponse { get; set; } = string.Empty;
    public string Responsibility { get; set; } = string.Empty;
    public DateTime? DiscussionDate { get; set; }
    public DateTime? Eta { get; set; }
    public DateTime? ClosedDate { get; set; }
    public DateTime? UpdatedOn { get; set; }
    public string UpdatedBy { get; set; } = string.Empty;
}

/// <summary>What an insight upload did, reported back on the page.</summary>
public sealed class DenialInsightUploadResult
{
    public int Inserted { get; set; }
    public int Updated { get; set; }
    public int Skipped { get; set; }
    public List<string> Errors { get; } = new();
}

/// <summary>What "Copy Data to Previous Week" did, reported back on the page.</summary>
public sealed class DenialInsightCopyResult
{
    /// <summary>Rows that did not exist in Previous Week and were copied across.</summary>
    public int Inserted { get; set; }

    /// <summary>Rows already in Previous Week for that week and code, refreshed from Current.</summary>
    public int Updated { get; set; }

    /// <summary>Rows that fell outside the 4-week window and moved to Archive.</summary>
    public int Archived { get; set; }

    public int Copied => Inserted + Updated;
}

/// <summary>
/// The outcome of validating an uploaded workbook BEFORE anything is written. The requirements call
/// for structural problems - a missing mandatory column, an unreadable date - to be named to the
/// user instead of half-importing the file.
/// </summary>
public sealed class DenialInsightValidationResult
{
    public bool IsValid => Errors.Count == 0;
    public List<string> Errors { get; } = new();
    public List<string> Warnings { get; } = new();
    public List<DenialInsightClaimLevelRow> Rows { get; } = new();
}

/// <summary>
/// One cell of a denial summary pivot: the two values the requirements define for every
/// row/period intersection.
/// </summary>
public sealed class DenialPivotCell
{
    /// <summary>Count of DISTINCT Claim IDs, not of denial rows - a claim denied twice counts once.</summary>
    public int ClaimCount { get; set; }

    /// <summary>Sum of Insurance Balance.</summary>
    public decimal TotalBalance { get; set; }

    public bool IsEmpty => ClaimCount == 0 && TotalBalance == 0m;
}

/// <summary>One row of a denial summary pivot - a payer, or a denial code.</summary>
public sealed class DenialPivotRow
{
    /// <summary>The value used for drill-through: the payer name, or the normalized denial code.</summary>
    public string Key { get; set; } = string.Empty;

    public string Label { get; set; } = string.Empty;

    /// <summary>The denial description, on a denial-code pivot. Blank on a payer pivot.</summary>
    public string SubLabel { get; set; } = string.Empty;

    /// <summary>Keyed by <see cref="DenialPeriodOption.Key"/>.</summary>
    public Dictionary<string, DenialPivotCell> Cells { get; } = new(StringComparer.Ordinal);

    public int TotalClaimCount { get; set; }
    public decimal TotalBalance { get; set; }

    public DenialPivotCell CellFor(string periodKey) =>
        Cells.TryGetValue(periodKey, out var cell) ? cell : new DenialPivotCell();
}

/// <summary>
/// A denial summary pivot: rows down the side, reporting periods across the top, Claim Count and
/// Total Balance in every cell - the shape requirements 4 and 5 describe.
/// </summary>
public sealed class DenialPivotTable
{
    public string Title { get; set; } = string.Empty;

    /// <summary>What the row axis is, e.g. "Insurance" or "Denial Code".</summary>
    public string RowHeader { get; set; } = string.Empty;

    /// <summary>Oldest to newest, left to right.</summary>
    public List<DenialPeriodOption> Periods { get; set; } = new();

    /// <summary>Ordered by total Claim Count, descending - the sort the requirements specify.</summary>
    public List<DenialPivotRow> Rows { get; set; } = new();

    public DenialPivotRow Total { get; set; } = new();

    /// <summary>True when <see cref="Rows"/> was cut to the top N and more rows exist behind it.</summary>
    public bool IsTopNFiltered { get; set; }

    public int RowsAvailable { get; set; }
}

/// <summary>The drill-through context a Claim Level Data view was opened with, shown back to the user.</summary>
public sealed class ClaimDrillThroughFilter
{
    public string? DenialCode { get; set; }
    public string? PayerName { get; set; }
    public string? PeriodKey { get; set; }
    public string? PeriodLabel { get; set; }
    public DateTime? PeriodStart { get; set; }
    public DateTime? PeriodEnd { get; set; }

    public bool HasAny => !string.IsNullOrWhiteSpace(DenialCode)
        || !string.IsNullOrWhiteSpace(PayerName)
        || PeriodStart.HasValue;
}
