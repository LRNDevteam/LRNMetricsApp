namespace LabMetricsDashboard.Models;

/// <summary>
/// One aggregated denial group, straight from the lab's own <c>dbo.ClaimLevelData</c>.
///
/// <para>This is the shape the Monthly and Weekly summaries are built from, and it matches the
/// agreed query exactly: group by payer, common denial code, description and denial date; count
/// DISTINCT claims and sum the insurance balance; keep only rows that carry a denial code and have
/// a balance still outstanding.</para>
///
/// <para>Aggregating in SQL rather than pulling every denied claim into memory matters here - a
/// lab's claim-level table runs to seven figures, while the grouped result is thousands of rows.</para>
/// </summary>
public sealed class DenialSummaryGroup
{
    public string PayerName { get; set; } = string.Empty;

    /// <summary>The common denial code: CO45, PI45 and PR45 all arrive here as 45.</summary>
    public string DenialCodeNormalized { get; set; } = string.Empty;

    public string DenialDescription { get; set; } = string.Empty;
    public DateTime? DenialDate { get; set; }
    public int ClaimCount { get; set; }
    public decimal InsuranceBalance { get; set; }
}

/// <summary>
/// Which tab a Denial Insight row sits on.
/// <para>An explicit column rather than something derived from the week, because moving a row to
/// Previous Week is a deliberate action the user takes - rows stay where they were put until the
/// user moves them, not drifting between tabs as the calendar turns.</para>
/// </summary>
public static class DenialInsightBuckets
{
    /// <summary>What the user most recently imported and is working on.</summary>
    public const string Current = "Current";

    /// <summary>Previously discussed items - the most recent weeks, shown week by week.</summary>
    public const string Previous = "Previous";

    /// <summary>
    /// Older than the weeks Previous keeps. Not a tab: the rows are retained rather than deleted,
    /// so nothing a client wrote is ever lost, but they are out of the working view.
    /// </summary>
    public const string Archive = "Archive";

    /// <summary>How many distinct weeks Previous Week holds before the oldest rolls into Archive.</summary>
    public const int PreviousWeeksRetained = 4;

    /// <summary>The two buckets that have a tab. Archive is storage only.</summary>
    public static bool IsValid(string? bucket) => bucket is Current or Previous;

    public static string Normalize(string? bucket) => IsValid(bucket) ? bucket! : Current;

    public static string Label(string bucket) =>
        bucket == Previous ? "Previous Week" : "Current Week";

    /// <summary>The week a set of insight rows covers, as the Previous Week separators show it.</summary>
    public static string WeekRangeLabel(DateTime weekStart) =>
        weekStart == default
            ? "Undated"
            : $"{weekStart:dd MMM} – {weekStart.AddDays(6):dd MMM yyyy}";
}

/// <summary>
/// One Denial Insight row, held per lab database in <c>dbo.DenialClaimLevelInsight</c> - the
/// client's own analytical layer, imported from their workbook. Kept deliberately separate from the
/// claim-level data it describes: importing insights never recalculates or overwrites claims.
/// </summary>
public sealed class DenialInsightRow
{
    public long Id { get; set; }

    /// <summary>Current or Previous - see <see cref="DenialInsightBuckets"/>.</summary>
    public string Bucket { get; set; } = DenialInsightBuckets.Current;

    /// <summary>Monday of the week these insights describe.</summary>
    public DateTime WeekStart { get; set; }

    /// <summary>Order the client put the rows in. Their workbook is ranked, and the rank is meaningful.</summary>
    public int SortOrder { get; set; }

    public string DenialCode { get; set; } = string.Empty;
    public string DenialCodeNormalized { get; set; } = string.Empty;
    public string DenialDescription { get; set; } = string.Empty;

    /// <summary>"Highest $ Impact - Insurance" on the client's template.</summary>
    public string PayerName { get; set; } = string.Empty;

    public int NoOfDenials { get; set; }
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

/// <summary>What an insight upload or save did, reported back on the page.</summary>
public sealed class DenialInsightUploadResult
{
    public int Inserted { get; set; }
    public int Updated { get; set; }
    public int Skipped { get; set; }
    public List<string> Errors { get; } = new();
}

/// <summary>
/// The outcome of validating an uploaded workbook BEFORE anything is written. Structural problems -
/// a missing mandatory column, an unreadable date - are named to the user instead of half-importing
/// the file.
/// </summary>
public sealed class DenialInsightValidationResult
{
    public bool IsValid => Errors.Count == 0;
    public List<string> Errors { get; } = new();
    public List<string> Warnings { get; } = new();
    public List<DenialInsightRow> Rows { get; } = new();
}
