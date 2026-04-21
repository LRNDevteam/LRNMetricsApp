namespace LabMetricsDashboard.Services;

/// <summary>
/// Resolves the lab-specific <c>WeekRange</c> configuration string into a
/// <see cref="DayOfWeek"/> representing the first day of each week.
/// </summary>
/// <remarks>
/// Supported values (case-insensitive):
/// <list type="bullet">
///   <item><c>Mon to Sun</c> &#8211; weeks start on Monday (default).</item>
///   <item><c>Tue to Mon</c> &#8211; weeks start on Tuesday.</item>
///   <item><c>Wed to Tue</c> &#8211; weeks start on Wednesday.</item>
///   <item><c>Thu to Wed</c> &#8211; weeks start on Thursday.</item>
///   <item><c>Fri to Thu</c> &#8211; weeks start on Friday.</item>
/// </list>
/// Unset / unrecognized values fall back to <see cref="DayOfWeek.Monday"/>.
/// </remarks>
internal static class WeekRangeHelper
{
    public const DayOfWeek DefaultWeekStart = DayOfWeek.Monday;

    public static DayOfWeek ResolveWeekStart(string? weekRange)
    {
        if (string.IsNullOrWhiteSpace(weekRange))
            return DefaultWeekStart;

        return weekRange.Trim().ToLowerInvariant() switch
        {
            "mon to sun" => DayOfWeek.Monday,
            "tue to mon" => DayOfWeek.Tuesday,
            "wed to tue" => DayOfWeek.Wednesday,
            "thu to wed" => DayOfWeek.Thursday,
            "fri to thu" => DayOfWeek.Friday,
            _            => DefaultWeekStart,
        };
    }

    /// <summary>
    /// Returns a friendly display label for the resolved week start
    /// (e.g. <c>"Mon to Sun"</c>). Useful for UI footers / tooltips.
    /// </summary>
    public static string ToDisplayLabel(DayOfWeek weekStart) => weekStart switch
    {
        DayOfWeek.Monday    => "Mon to Sun",
        DayOfWeek.Tuesday   => "Tue to Mon",
        DayOfWeek.Wednesday => "Wed to Tue",
        DayOfWeek.Thursday  => "Thu to Wed",
        DayOfWeek.Friday    => "Fri to Thu",
        DayOfWeek.Saturday  => "Sat to Fri",
        DayOfWeek.Sunday    => "Sun to Sat",
        _                   => "Mon to Sun",
    };
}
