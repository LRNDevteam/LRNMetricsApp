using System.Globalization;
using System.Text.RegularExpressions;

namespace LabMetricsDashboard.Models;

/// <summary>
/// Header banner values shared across Production Report–style pages:
/// Billed Week Range, ReportId (RunID), and optional Inserted Date.
/// </summary>
public sealed class AnalysisRangeInfo
{
    public string? WeekFolder { get; init; }
    public string? RunId { get; init; }
    public DateTime? InsertedDateTime { get; init; }

    public bool HasAny =>
        !string.IsNullOrWhiteSpace(WeekFolder)
        || !string.IsNullOrWhiteSpace(RunId)
        || InsertedDateTime.HasValue;

    /// <summary>
    /// Day-of-month from the Billed Week Range <em>end</em> date
    /// (e.g. "06.19.2026 - 06.25.2026" → 25). Used as the comparable
    /// partial-month window on Insight Drill ("first N days").
    /// Returns 0 when <see cref="WeekFolder"/> cannot be parsed
    /// (caller should fall back to CutoffDate / 9).
    /// </summary>
    public int ComparableDayWindow => ResolveComparableDayWindow(WeekFolder, fallback: 0);

    /// <summary>
    /// Date-like tokens: MM.dd.yyyy / M/d/yyyy / yyyy-MM-dd (2- or 4-digit year).
    /// </summary>
    private static readonly Regex DateTokenRegex = new(
        @"\b(?:"
        + @"\d{1,2}[./]\d{1,2}[./]\d{2,4}"   // 06.19.2026, 6/19/26
        + @"|"
        + @"\d{4}-\d{1,2}-\d{1,2}"            // 2026-06-19
        + @")\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly string[] DateFormats =
    [
        "M/d/yyyy", "MM/dd/yyyy", "d/M/yyyy", "dd/MM/yyyy",
        "yyyy-MM-dd", "yyyy/M/d", "yyyy/MM/dd",
        "M/d/yy", "MM/dd/yy",
        "M.d.yyyy", "MM.dd.yyyy",
        "yyyy.M.d", "yyyy.MM.dd",
    ];

    /// <summary>
    /// Parsed Week Range end date (e.g. "07.23.2026 - 07.29.2026" → 2026-07-29).
    /// Null when <see cref="WeekFolder"/> cannot be parsed.
    /// </summary>
    public DateTime? WeekRangeEndDate =>
        TryParseWeekRangeEnd(WeekFolder, out var end) ? end : null;

    /// <summary>
    /// Parses the end date of a week-range string (full date, not just day).
    /// </summary>
    public static bool TryParseWeekRangeEnd(string? weekFolder, out DateTime endDate)
    {
        endDate = default;
        if (string.IsNullOrWhiteSpace(weekFolder))
            return false;

        var matches = DateTokenRegex.Matches(weekFolder);
        for (var i = matches.Count - 1; i >= 0; i--)
        {
            if (TryParseWeekFolderDate(matches[i].Value, out var dt))
            {
                endDate = dt.Date;
                return true;
            }
        }

        var text = weekFolder.Trim()
            .Replace('\u00A0', ' ')
            .Replace('\u2013', '-')
            .Replace('\u2014', '-')
            .Replace('\u2212', '-');

        string endPart;
        var toIdx = text.LastIndexOf(" to ", StringComparison.OrdinalIgnoreCase);
        if (toIdx >= 0)
            endPart = text[(toIdx + 4)..].Trim();
        else
        {
            var dashIdx = text.LastIndexOf('-');
            endPart = dashIdx >= 0 ? text[(dashIdx + 1)..].Trim() : text;
        }

        if (!TryParseWeekFolderDate(endPart, out var endDt))
            return false;

        endDate = endDt.Date;
        return true;
    }

    /// <summary>
    /// Parses the end date of a week-range string and returns its day (1–31).
    /// Returns <paramref name="fallback"/> when the folder cannot be parsed
    /// (default 0 so callers can apply CutoffDate before the final 9 fallback).
    /// </summary>
    public static int ResolveComparableDayWindow(string? weekFolder, int fallback = 0)
    {
        if (TryParseWeekRangeEnd(weekFolder, out var endDt)
            && endDt.Day is >= 1 and <= 31)
            return endDt.Day;

        return fallback;
    }

    /// <summary>
    /// Resolve day window: WeekFolder end day → CutoffDate.Day → <paramref name="fallback"/>.
    /// </summary>
    public static int ResolveComparableDayWindow(
        string? weekFolder, DateTime? cutoffDate, int fallback = 9)
    {
        var fromFolder = ResolveComparableDayWindow(weekFolder, fallback: 0);
        if (fromFolder > 0)
            return fromFolder;

        if (cutoffDate is { } cd && cd.Day is >= 1 and <= 31)
            return cd.Day;

        return fallback is >= 1 and <= 31 ? fallback : 9;
    }

    private static bool TryParseWeekFolderDate(string value, out DateTime dt)
    {
        dt = default;
        if (string.IsNullOrWhiteSpace(value))
            return false;

        var normalized = value.Trim().Replace('.', '/');
        return DateTime.TryParseExact(
                   normalized, DateFormats,
                   CultureInfo.InvariantCulture,
                   DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeLocal,
                   out dt)
               || DateTime.TryParse(
                   normalized, CultureInfo.InvariantCulture,
                   DateTimeStyles.AllowWhiteSpaces, out dt);
    }

    public static AnalysisRangeInfo Empty { get; } = new();
}
