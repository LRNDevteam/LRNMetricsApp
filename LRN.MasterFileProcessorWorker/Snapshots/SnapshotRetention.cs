using System.Globalization;
using System.Text.RegularExpressions;

namespace LRN.MasterFileProcessorWorker.Snapshots;

/// <summary>One dbo.ReportSnapshotRun row, as retention sees it.</summary>
public sealed record SnapshotRunRow(
    long SnapshotRunId,
    string RunId,
    string WeekFolder,
    DateTime SnapshotDate,
    string Status,
    DateTime CreatedOnUtc,
    string? BlobPrefix);

public static class SnapshotRunStatus
{
    public const string InProgress = "InProgress";
    public const string Success = "Success";
    public const string Failed = "Failed";
}

/// <summary>
/// Deterministic storage paths, so a re-run of the same RunId overwrites rather than duplicates:
/// <c>{LabName}/{RunId}_{WeekRange}_{LINELEVEL|CLAIMLEVEL|LIMS}.parquet</c>, e.g.
/// <c>Beech_Tree/R20260213BTL0001_02.06.2026-02.12.2026_LINELEVEL.parquet</c>.
/// </summary>
public static class SnapshotPaths
{
    /// <summary>
    /// <c>{LabName}/{RunId}_{WeekRange}_</c> - the start of every file one run wrote, so retention
    /// deletes a run by this prefix. The trailing '_' keeps R...0001 from matching R...00010.
    /// </summary>
    public static string RunPrefix(string labName, string weekFolder, string runId) =>
        $"{Segment(labName)}/{Segment(runId)}_{WeekRange(weekFolder)}_";

    /// <summary><c>{runPrefix}{reportCode}.parquet</c></summary>
    public static string FilePath(string runPrefix, string reportCode) =>
        $"{runPrefix}{Segment(reportCode)}.parquet";

    /// <summary>"02.06.2026 - 02.12.2026" -> "02.06.2026-02.12.2026": no spaces in the file name.</summary>
    internal static string WeekRange(string? weekFolder)
    {
        var compact = Regex.Replace((weekFolder ?? string.Empty).Trim(), @"\s*-\s*", "-");
        compact = Regex.Replace(compact, @"\s+", "_");
        return Segment(compact);
    }

    /// <summary>Names come from config and SharePoint: keep them readable, but never let one add or climb a level.</summary>
    internal static string Segment(string value)
    {
        var cleaned = (value ?? string.Empty).Replace('/', '_').Replace('\\', '_').Trim();
        return cleaned.Length == 0 || cleaned.Trim('.').Length == 0 ? "_" : cleaned;
    }
}

public static class SnapshotWeek
{
    // "02.06.2026 - 02.12.2026" or "12.29.2025 - 01.04" (end year omitted).
    private static readonly Regex WeekRange = new(
        @"(?<m1>\d{1,2})\.(?<d1>\d{1,2})\.(?<y1>\d{4})\s*-\s*(?<m2>\d{1,2})\.(?<d2>\d{1,2})(?:\.(?<y2>\d{4}))?",
        RegexOptions.Compiled);

    private static readonly Regex SingleDate = new(@"(?<m>\d{1,2})\.(?<d>\d{1,2})\.(?<y>\d{4})", RegexOptions.Compiled);

    /// <summary>
    /// The "data as of" date of a week folder: its END date, which is what users pick a week by and
    /// what retention orders weeks on. Null when the folder name holds no recognisable date.
    /// </summary>
    public static DateTime? AsOfDate(string? weekFolder)
    {
        if (string.IsNullOrWhiteSpace(weekFolder))
            return null;

        var range = WeekRange.Match(weekFolder);
        if (range.Success)
        {
            int m1 = Int(range, "m1"), y1 = Int(range, "y1"), m2 = Int(range, "m2"), d2 = Int(range, "d2");
            int y2 = range.Groups["y2"].Success ? Int(range, "y2") : (m2 < m1 ? y1 + 1 : y1);
            return TryDate(y2, m2, d2);
        }

        var single = SingleDate.Match(weekFolder);
        return single.Success ? TryDate(Int(single, "y"), Int(single, "m"), Int(single, "d")) : null;
    }

    private static int Int(Match m, string group) => int.Parse(m.Groups[group].Value, CultureInfo.InvariantCulture);

    private static DateTime? TryDate(int y, int m, int d) =>
        m is >= 1 and <= 12 && d >= 1 && d <= DateTime.DaysInMonth(y, m) ? new DateTime(y, m, d) : null;
}

/// <summary>
/// Which snapshot runs of one lab to delete. Pure, so it is covered by --selftest.
/// <para>
/// Kept: the latest Success run of each of the <c>keepWeeks</c> most recent week folders; the latest
/// Success run of each of the <c>keepMonthEnd</c> most recent months; the current run; and any
/// non-Success run younger than a day (it may still be in flight on another instance).
/// </para>
/// <para>
/// Everything else goes, including an older run of a kept week: a re-run replaces that week's
/// snapshot rather than adding a second copy of it.
/// </para>
/// </summary>
public static class SnapshotRetention
{
    private static readonly TimeSpan UnfinishedGrace = TimeSpan.FromDays(1);

    public static IReadOnlyList<SnapshotRunRow> SelectExpired(
        IReadOnlyList<SnapshotRunRow> runs, int keepWeeks, int keepMonthEnd, long currentSnapshotRunId, DateTime utcNow)
    {
        keepWeeks = Math.Max(1, keepWeeks);
        keepMonthEnd = Math.Max(0, keepMonthEnd);

        var successNewestFirst = runs
            .Where(r => string.Equals(r.Status, SnapshotRunStatus.Success, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(r => r.SnapshotDate)
            .ThenByDescending(r => r.CreatedOnUtc)
            .ThenByDescending(r => r.SnapshotRunId)
            .ToList();

        var keep = new HashSet<long> { currentSnapshotRunId };

        foreach (var latestOfWeek in successNewestFirst
                     .GroupBy(r => r.WeekFolder.Trim(), StringComparer.OrdinalIgnoreCase)
                     .Select(g => g.First())
                     .Take(keepWeeks))
            keep.Add(latestOfWeek.SnapshotRunId);

        foreach (var latestOfMonth in successNewestFirst
                     .GroupBy(r => (r.SnapshotDate.Year, r.SnapshotDate.Month))
                     .Select(g => g.First())
                     .Take(keepMonthEnd))
            keep.Add(latestOfMonth.SnapshotRunId);

        return runs
            .Where(r => !keep.Contains(r.SnapshotRunId))
            .Where(r => string.Equals(r.Status, SnapshotRunStatus.Success, StringComparison.OrdinalIgnoreCase)
                        || utcNow - r.CreatedOnUtc > UnfinishedGrace)
            .OrderBy(r => r.SnapshotDate)
            .ThenBy(r => r.SnapshotRunId)
            .ToList();
    }
}
