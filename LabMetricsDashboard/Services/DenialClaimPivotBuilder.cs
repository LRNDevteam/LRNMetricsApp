using System.Globalization;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Turns the aggregated denial groups into the same pivot the Denial Summary page has always shown:
/// an insurance row, its denial codes underneath, reporting periods across the top, and No. of
/// Claims / Insurance Balance in every cell.
///
/// <para>It builds <see cref="BreakdownPivotViewModel"/> so the existing
/// <c>_BreakdownPivotTable</c> partial renders it - the frozen first columns, the collapsible payer
/// groups and the sticky header bands all come free, and the two pages cannot drift apart visually
/// because they are the same table.</para>
/// </summary>
public static class DenialClaimPivotBuilder
{
    /// <summary>
    /// How many payers get their own row. The rest roll into one "All other insurances" row rather
    /// than being dropped, so the column totals still add up to the lab's real position.
    /// </summary>
    public const int DefaultTopPayers = 15;

    /// <summary>
    /// Denial codes shown under each payer. Three, per the reporting spec - the point of the
    /// summary is what to work on next, and a longer list stops being a summary.
    /// </summary>
    public const int DefaultTopDenialsPerPayer = 3;

    private const string OtherPayersLabel = "All other insurances";
    private const string OtherDenialsLabel = "All other denial codes";

    public static BreakdownPivotViewModel Build(
        IReadOnlyList<DenialSummaryGroup> groups,
        bool weekly,
        int maxPeriods,
        int topPayers = DefaultTopPayers,
        int topDenialsPerPayer = DefaultTopDenialsPerPayer)
    {
        var model = new BreakdownPivotViewModel
        {
            SectionTitle = weekly ? "Weekly Summary" : "Monthly Summary",
            GrandTotalTitle = "Grand Total",
            TopPayerCount = topPayers
        };

        // A group with no denial date cannot sit in any period. Counting it in the totals but not in
        // a column would make the row and its cells disagree, so it is left out of the pivot - the
        // page reports how many were dropped.
        var dated = groups.Where(g => g.DenialDate.HasValue && !string.IsNullOrWhiteSpace(g.DenialCodeNormalized)).ToList();
        if (dated.Count == 0) return model;

        var periods = BuildPeriods(dated, weekly, maxPeriods);
        if (periods.Count == 0) return model;

        model.Periods = periods;
        model.HeaderTitle = periods.Count == 1
            ? periods[0].Label
            : $"{periods[0].Label} — {periods[^1].Label}";

        // Only what the columns can show. A group outside the window would otherwise inflate the row
        // total past the sum of its own cells.
        var earliest = periods[0].StartDate;
        var latest = periods[^1].EndDate;
        var inWindow = dated
            .Where(g => g.DenialDate!.Value.Date >= earliest && g.DenialDate.Value.Date <= latest)
            .ToList();

        if (inWindow.Count == 0) return model;

        model.ColumnGroups = BuildColumnGroups(periods, weekly, model.GrandTotalTitle);

        var periodOf = BuildPeriodIndex(periods);

        var payerTotals = inWindow
            .GroupBy(g => Key(g.PayerName), StringComparer.OrdinalIgnoreCase)
            .Select(p => new
            {
                Label = FirstLabel(p.Select(x => x.PayerName), "(no payer)"),
                Balance = p.Sum(x => x.InsuranceBalance),
                Claims = p.Sum(x => x.ClaimCount),
                Groups = p.ToList()
            })
            // Ranked by the payer's total claim count, per the reporting spec. Balance breaks a tie,
            // so two payers on the same count still order by what they are worth.
            .OrderByDescending(p => p.Claims)
            .ThenByDescending(p => p.Balance)
            .ToList();

        var grandBalance = payerTotals.Sum(p => p.Balance);

        var ranked = payerTotals.Take(topPayers).ToList();
        var remainder = payerTotals.Skip(topPayers).SelectMany(p => p.Groups).ToList();

        model.CoveragePercentage = grandBalance <= 0m
            ? 0m
            : Math.Round(ranked.Sum(p => p.Balance) / grandBalance * 100m, 1);

        var rows = new List<BreakdownPivotRow>();
        var index = 0;

        foreach (var payer in ranked)
        {
            index++;
            rows.Add(BuildRow(index.ToString(CultureInfo.InvariantCulture), payer.Label,
                isInsurance: true, payer.Groups, periods, periodOf));

            var denials = payer.Groups
                .GroupBy(g => g.DenialCodeNormalized, StringComparer.OrdinalIgnoreCase)
                .Select(d => new
                {
                    Code = d.Key,
                    Description = FirstLabel(d.Select(x => x.DenialDescription), string.Empty),
                    Claims = d.Sum(x => x.ClaimCount),
                    Balance = d.Sum(x => x.InsuranceBalance),
                    Groups = d.ToList()
                })
                // Same rule as the payer rank above: claim count first, balance to break a tie.
                .OrderByDescending(d => d.Claims)
                .ThenByDescending(d => d.Balance)
                .ToList();

            var shown = denials.Take(topDenialsPerPayer).ToList();
            var rest = denials.Skip(topDenialsPerPayer).SelectMany(d => d.Groups).ToList();

            foreach (var denial in shown)
                rows.Add(BuildRow(string.Empty, DenialLabel(denial.Code, denial.Description),
                                  isInsurance: false, denial.Groups, periods, periodOf));

            if (rest.Count > 0)
                rows.Add(BuildRow(string.Empty, OtherDenialsLabel, isInsurance: false, rest, periods, periodOf));
        }

        if (remainder.Count > 0)
        {
            index++;
            rows.Add(BuildRow(index.ToString(CultureInfo.InvariantCulture), OtherPayersLabel,
                isInsurance: true, remainder, periods, periodOf));
        }

        model.Rows = rows;

        model.TotalsByPeriod = periods
            .Select(p => Cell(inWindow.Where(g => periodOf(g.DenialDate!.Value) == p.Key)))
            .ToList();

        model.GrandTotalClaimCount = inWindow.Sum(g => g.ClaimCount);
        model.GrandTotalBalance = inWindow.Sum(g => g.InsuranceBalance);

        return model;
    }

    private static BreakdownPivotRow BuildRow(
        string indexLabel,
        string label,
        bool isInsurance,
        IReadOnlyList<DenialSummaryGroup> groups,
        IReadOnlyList<BreakdownPivotPeriod> periods,
        Func<DateTime, string?> periodOf)
    {
        var byPeriod = groups
            .GroupBy(g => periodOf(g.DenialDate!.Value))
            .Where(g => g.Key is not null)
            .ToDictionary(g => g.Key!, g => Cell(g), StringComparer.Ordinal);

        return new BreakdownPivotRow
        {
            IndexLabel = indexLabel,
            Label = label,
            IsInsuranceRow = isInsurance,
            Cells = periods
                .Select(p => byPeriod.TryGetValue(p.Key, out var cell) ? cell : new BreakdownPivotCell())
                .ToList(),
            TotalClaimCount = groups.Sum(g => g.ClaimCount),
            TotalBalance = groups.Sum(g => g.InsuranceBalance)
        };
    }

    private static BreakdownPivotCell Cell(IEnumerable<DenialSummaryGroup> groups)
    {
        var list = groups as IReadOnlyList<DenialSummaryGroup> ?? groups.ToList();
        return new BreakdownPivotCell
        {
            ClaimCount = list.Sum(g => g.ClaimCount),
            DenialBalance = list.Sum(g => g.InsuranceBalance)
        };
    }

    /// <summary>
    /// The newest <paramref name="maxPeriods"/> periods the lab has denials in, oldest first.
    /// </summary>
    /// <remarks>
    /// Built from the periods that actually carry data rather than from a calendar range, so a lab
    /// with a gap in its history does not get empty columns taking up the width.
    /// </remarks>
    private static List<BreakdownPivotPeriod> BuildPeriods(
        IReadOnlyList<DenialSummaryGroup> groups, bool weekly, int maxPeriods)
    {
        return groups
            .Select(g => weekly
                ? SqlDenialClaimReportRepository.WeekStartOf(g.DenialDate!.Value)
                : new DateTime(g.DenialDate!.Value.Year, g.DenialDate.Value.Month, 1))
            .Distinct()
            .OrderByDescending(d => d)
            .Take(maxPeriods)
            .OrderBy(d => d)
            .Select(start =>
            {
                var end = weekly ? start.AddDays(6) : start.AddMonths(1).AddDays(-1);
                return new BreakdownPivotPeriod
                {
                    Key = start.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                    Label = weekly
                        ? $"{start:dd MMM} - {end:dd MMM}"
                        : start.ToString("MMM yyyy", CultureInfo.InvariantCulture),
                    StartDate = start,
                    EndDate = end,
                    Year = start.Year,
                    Month = weekly ? null : start.Month,
                    IsYearTotal = false
                };
            })
            .ToList();
    }

    /// <summary>
    /// The band above the period headers: the year on a monthly pivot, the month on a weekly one.
    /// <para>The partial only renders this band when a period reports <c>IsYearTotal</c>, which none
    /// of these do, so it is supplied for the Excel export and left unrendered on screen.</para>
    /// </summary>
    private static List<BreakdownPivotColumnGroup> BuildColumnGroups(
        IReadOnlyList<BreakdownPivotPeriod> periods, bool weekly, string grandTotalTitle)
    {
        var groups = new List<BreakdownPivotColumnGroup>();
        string? current = null;

        foreach (var period in periods)
        {
            var label = weekly
                ? period.StartDate.ToString("MMM yyyy", CultureInfo.InvariantCulture)
                : period.Year.ToString(CultureInfo.InvariantCulture);

            if (label == current && groups.Count > 0)
            {
                groups[^1].ColumnSpan += 2;
                continue;
            }

            groups.Add(new BreakdownPivotColumnGroup { Label = label, ColumnSpan = 2 });
            current = label;
        }

        groups.Add(new BreakdownPivotColumnGroup { Label = grandTotalTitle, ColumnSpan = 2 });
        return groups;
    }

    /// <summary>Maps a denial date onto its period key, or null when it falls outside the window.</summary>
    private static Func<DateTime, string?> BuildPeriodIndex(IReadOnlyList<BreakdownPivotPeriod> periods)
    {
        var byKey = periods.ToDictionary(
            p => p.Key,
            p => (p.StartDate, p.EndDate),
            StringComparer.Ordinal);

        var ordered = periods.Select(p => p.Key).ToList();

        return date =>
        {
            foreach (var key in ordered)
            {
                var (start, end) = byKey[key];
                if (date.Date >= start && date.Date <= end) return key;
            }
            return null;
        };
    }

    /// <summary>
    /// A denial row's label: the code, then its description.
    /// </summary>
    /// <remarks>
    /// The Master File Processor writes DenialDescription already prefixed with the code
    /// ("M127 - Missing patient medical record..."), because a multi-code claim needs each
    /// description paired with the code it belongs to. Prepending the code again produced
    /// "M127 — M127 - Missing patient medical record...", so a description that already opens with
    /// the code is used as it stands.
    /// </remarks>
    private static string DenialLabel(string code, string description)
    {
        if (string.IsNullOrWhiteSpace(description)) return code;

        var text = description.Trim();

        return text.StartsWith(code, StringComparison.OrdinalIgnoreCase)
            ? text
            : $"{code} — {text}";
    }

    private static string Key(string? value) =>
        new((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

    private static string FirstLabel(IEnumerable<string> candidates, string fallback) =>
        candidates.FirstOrDefault(x => !string.IsNullOrWhiteSpace(x))?.Trim() is { Length: > 0 } found
            ? found
            : fallback;
}
