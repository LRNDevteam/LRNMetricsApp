using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services;

/// <summary>
/// Period and retention rules for Denial Summary snapshots (spec 4g-4i). Pure, so they are tested
/// without a database.
///
/// A weekly snapshot is "the week that just ended", taken on the first scheduler pass on or after
/// the next week's first day. Weeks run Monday-Sunday unless the lab is configured otherwise in
/// DenialSummarySnapshots:WeekStartDayByLab (Rising Tides: Friday-Thursday, matching its
/// ClaimLevelData WeekFolder, e.g. "09.18.2026 - 09.24.2026"). A monthly one is the month that
/// just ended. A missed period is not back-filled: a snapshot is the state at capture time, and a
/// week captured late would present today's numbers under last month's label.
/// </summary>
internal static class DenialSummarySchedule
{
    public static (DateTime Start, DateTime End) LastCompletedWeek(DateTime today, DayOfWeek weekStart = DayOfWeek.Monday)
    {
        var date = today.Date;
        var daysSinceStart = ((int)date.DayOfWeek - (int)weekStart + 7) % 7;
        var thisWeekStart = date.AddDays(-daysSinceStart);
        return (thisWeekStart.AddDays(-7), thisWeekStart.AddDays(-1));
    }

    /// <summary>
    /// The lab's configured first day of the week, matched on lab name (ignoring case, spaces,
    /// '_' and '-') or lab id. Monday when the lab is not configured or the value is not a day name.
    /// </summary>
    public static DayOfWeek WeekStartFor(int labId, string labName, DenialSummarySnapshotOptions options)
    {
        static string Key(string? value) => new((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

        var wanted = new[] { Key(labName), labId.ToString(System.Globalization.CultureInfo.InvariantCulture) };
        foreach (var (key, day) in options.WeekStartDayByLab ?? new Dictionary<string, string>())
        {
            if (wanted.Contains(Key(key)) && Enum.TryParse<DayOfWeek>(day?.Trim(), ignoreCase: true, out var parsed)
                && Enum.IsDefined(parsed))
                return parsed;
        }
        return DayOfWeek.Monday;
    }

    public static (DateTime Start, DateTime End) LastCompletedMonth(DateTime today)
    {
        var firstOfThisMonth = new DateTime(today.Year, today.Month, 1);
        return (firstOfThisMonth.AddMonths(-1), firstOfThisMonth.AddDays(-1));
    }

    public static int RetentionFor(string periodType, DenialSummarySnapshotOptions options) => periodType switch
    {
        DenialSummarySnapshotPeriodTypes.Weekly => options.WeeklyRetention,
        DenialSummarySnapshotPeriodTypes.Monthly => options.MonthlyRetention,
        _ => options.OnDemandRetention
    };

    /// <summary>
    /// The active snapshots to archive: for each period type, everything past the newest N.
    /// A retention of 0 or less keeps everything active rather than archiving it all - a
    /// misconfigured setting should never empty the list.
    /// </summary>
    public static IReadOnlyList<long> SelectForArchive(IEnumerable<DenialSummarySnapshotInfo> snapshots, DenialSummarySnapshotOptions options)
    {
        var archive = new List<long>();

        foreach (var group in snapshots.Where(s => !s.IsArchived).GroupBy(s => s.PeriodType, StringComparer.OrdinalIgnoreCase))
        {
            var keep = RetentionFor(DenialSummarySnapshotPeriodTypes.Canonical(group.Key) ?? group.Key, options);
            if (keep <= 0) continue;

            archive.AddRange(group
                .OrderByDescending(s => s.PeriodStart)
                .ThenByDescending(s => s.CreatedOn)
                .ThenByDescending(s => s.SnapshotId)
                .Skip(keep)
                .Select(s => s.SnapshotId));
        }

        return archive;
    }

    /// <summary>Open / Overdue / Follow-up Due / Completed, as shown on screen and in the workbook.</summary>
    public static string ObservationStatus(DenialSummaryObservation? observation, DateTime today)
    {
        if (observation is null) return string.Empty;
        if (observation.CompletedDate.HasValue) return "Completed";
        if (observation.TargetDate.HasValue && observation.TargetDate.Value.Date < today.Date) return "Overdue";
        if (observation.FollowUpDate.HasValue && observation.FollowUpDate.Value.Date <= today.Date) return "Follow-up Due";

        var hasContent = !string.IsNullOrWhiteSpace(observation.ObservationHtml)
            || !string.IsNullOrWhiteSpace(observation.ResponsiblePerson)
            || observation.TargetDate.HasValue
            || observation.FollowUpDate.HasValue;
        return hasContent ? "Open" : string.Empty;
    }
}
