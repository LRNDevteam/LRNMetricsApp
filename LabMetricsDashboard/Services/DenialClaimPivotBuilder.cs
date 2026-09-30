using System.Globalization;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds the Top Payors &amp; Denials pivot in the shape the client's own workbook uses: an
/// insurance row lettered A, B, C, its top denial codes numbered underneath it, reporting periods
/// across the top, and No. of Claims / Denial Balance in every cell.
///
/// <para>Monthly carries a year band with a per-year subtotal column ("2025 | Total") before the
/// Grand Total, matching the workbook. Weekly shows its four weeks plain - a subtotal band over
/// four weeks of one month would be a column that repeats the total beside it.</para>
///
/// <para>It builds <see cref="BreakdownPivotViewModel"/> so the existing
/// <c>_BreakdownPivotTable</c> partial renders it - the frozen first columns, the collapsible payer
/// groups and the sticky header bands all come free.</para>
/// </summary>
public static class DenialClaimPivotBuilder
{
    /// <summary>
    /// How many payers get a row. The rest are dropped rather than rolled into an "all other" row:
    /// the workbook this mirrors reports the payers that carry the AR, and a catch-all row is not
    /// something anyone works.
    /// </summary>
    public const int DefaultTopPayers = 10;

    /// <summary>
    /// Denial codes shown under each payer. Three, per the reporting spec - the point of the
    /// summary is what to work on next, and a longer list stops being a summary.
    /// </summary>
    public const int DefaultTopDenialsPerPayer = 3;

    /// <summary>Row-label letters for the payers: A, B, C … then AA, AB on the unlikely overflow.</summary>
    private static string PayerLetter(int index)
    {
        var label = string.Empty;
        var n = index;

        do
        {
            label = (char)('A' + n % 26) + label;
            n = n / 26 - 1;
        }
        while (n >= 0);

        return label;
    }

    public static BreakdownPivotViewModel Build(
        IReadOnlyList<DenialSummaryGroup> groups,
        bool weekly,
        int maxPeriods,
        int topPayers = DefaultTopPayers,
        int topDenialsPerPayer = DefaultTopDenialsPerPayer,
        DateTime? loadedThrough = null)
    {
        var model = new BreakdownPivotViewModel
        {
            SectionTitle = weekly ? "Weekly Summary" : "Monthly Summary",
            GrandTotalTitle = "Grand Total",
            TopPayerCount = topPayers
        };

        if (groups.Count == 0) return model;

        // WHICH COLUMNS TO OPEN is decided from the dated, coded rows only: an undated row belongs
        // to no period, and a stray denial date must not open a column of its own.
        var dated = groups.Where(g => g.DenialDate.HasValue && !string.IsNullOrWhiteSpace(g.DenialCodeNormalized)).ToList();

        // Applied BEFORE the columns are picked, so the newest column is the newest week the claim
        // data actually covers rather than the newest week a stray denial date happens to fall in.
        // Without this the weekly summary opened a "16 Sep - 22 Sep" column while ClaimLevelData was
        // only loaded through "09.09.2026 - 09.15.2026", and the oldest real week fell off the end.
        if (loadedThrough is { } cutoff)
        {
            var loaded = dated.Where(g => g.DenialDate!.Value.Date <= cutoff.Date).ToList();
            if (loaded.Count > 0) dated = loaded;
        }

        var months = BuildBasePeriods(dated, weekly, maxPeriods);

        // Monthly gains a subtotal column per year; weekly stays as its four weeks.
        var columns = new List<PivotColumn>(weekly ? months : WithYearTotals(months));

        // WHICH ROWS ARE COUNTED is every group the page's tiles count. Rows the columns above
        // cannot hold - no denial date, older than the window, or denied after the load reached -
        // used to be dropped, which is why the footer read 3,730 claims under a "Denied Claims"
        // tile of 3,744. Monthly shows them in one "Other Periods" column, so nothing leaves the
        // report unseen and its footer matches the tile.
        //
        // Weekly is a report on the weeks it shows: an "Other Weeks" column was most of the claims
        // under a heading that names no week, and folding them silently into the Total made the
        // Total disagree with the columns beside it. So weekly works on the displayed weeks only -
        // row totals, footer, payer ranking and the AR coverage all describe those weeks, and its
        // footer is deliberately smaller than the page's all-time Denied Claims tile.
        bool InAnyPeriod(DenialSummaryGroup g) =>
            g.DenialDate.HasValue
            && months.Any(m => g.DenialDate.Value.Date >= m.Start && g.DenialDate.Value.Date <= m.End);

        if (weekly)
        {
            groups = groups.Where(InAnyPeriod).ToList();
            if (groups.Count == 0) return model;
        }
        else if (groups.Any(g => !InAnyPeriod(g)))
        {
            columns.Add(new PivotColumn(
                "other",
                "Other Periods",
                DateTime.MinValue, DateTime.MaxValue, Year: 0, IsYearTotal: false,
                IsOther: true,
                Matcher: g => !InAnyPeriod(g)));
        }

        model.Periods = columns.Select(c => c.ToPeriod()).ToList();
        model.ColumnGroups = BuildColumnGroups(columns, weekly, model.GrandTotalTitle);

        var payerTotals = groups
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

        // "Covering N% of the AR" in the caption - the share of the balance these payers hold.
        model.CoveragePercentage = grandBalance <= 0m
            ? 0m
            : Math.Round(ranked.Sum(p => p.Balance) / grandBalance * 100m, 0);

        model.HeaderTitle = $"Top Payors & Denials | Covering {model.CoveragePercentage:0}% of the AR | Denial Posted Date";

        var rows = new List<BreakdownPivotRow>();
        var payerIndex = 0;
        var denialNumber = 0;

        foreach (var payer in ranked)
        {
            rows.Add(BuildRow(PayerLetter(payerIndex++), payer.Label, isInsurance: true,
                              payer.Groups, columns));

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
                .Take(topDenialsPerPayer)
                .ToList();

            foreach (var denial in denials)
            {
                // The numbering runs continuously down the whole table, as it does in the workbook -
                // it is a reference for "row 14", not a rank within the payer.
                rows.Add(BuildRow((++denialNumber).ToString(CultureInfo.InvariantCulture),
                                  DenialLabel(denial.Code, denial.Description),
                                  isInsurance: false, denial.Groups, columns));
            }
        }

        model.Rows = rows;

        // Totals cover EVERY payer in the window, not just the top-N rows listed above them. The
        // footer is read as "what the lab is carrying this period", so a total that silently
        // excluded payer 11 onwards under-reported the AR - and the rows are a ranked extract of
        // the data, never a claim to be all of it. The caption already says what share the listed
        // payers hold ("Covering N% of the AR"), which is where that number belongs.
        model.TotalsByPeriod = columns.Select(c => Cell(c.Rows(groups))).ToList();
        model.GrandTotalClaimCount = groups.Sum(g => g.ClaimCount);
        model.GrandTotalBalance = groups.Sum(g => g.InsuranceBalance);

        return model;
    }

    // ── Columns ───────────────────────────────────────────────────────────────

    /// <summary>
    /// One column pair in the pivot: either a real reporting period, or a year subtotal that
    /// aggregates the periods of that year which are on screen.
    /// </summary>
    private sealed record PivotColumn(
        string Key, string Label, DateTime Start, DateTime End, int Year, bool IsYearTotal,
        bool IsOther = false,
        Func<DenialSummaryGroup, bool>? Matcher = null)
    {
        /// <summary>
        /// The groups this column covers: its date range, or - for the "Other" column, which is
        /// defined by what the dated columns could not hold - whatever its matcher accepts.
        /// </summary>
        public IReadOnlyList<DenialSummaryGroup> Rows(IEnumerable<DenialSummaryGroup> source) =>
            source.Where(Matcher ?? (g => g.DenialDate.HasValue
                                          && g.DenialDate.Value.Date >= Start
                                          && g.DenialDate.Value.Date <= End)).ToList();

        public BreakdownPivotPeriod ToPeriod() => new()
        {
            Key = Key,
            Label = Label,
            StartDate = Start,
            EndDate = End,
            Year = Year,
            Month = IsYearTotal ? null : Start.Month,
            IsYearTotal = IsYearTotal
        };
    }

    /// <summary>
    /// The newest <paramref name="maxPeriods"/> periods the lab has denials in, oldest first.
    /// </summary>
    /// <remarks>
    /// Built from the periods that actually carry data rather than from a calendar range, so a lab
    /// with a gap in its history does not get empty columns taking up the width.
    /// </remarks>
    private static List<PivotColumn> BuildBasePeriods(
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
                return new PivotColumn(
                    start.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                    weekly ? $"{start:dd MMM} - {end:dd MMM}" : start.ToString("MMM", CultureInfo.InvariantCulture),
                    start, end, start.Year, IsYearTotal: false);
            })
            .ToList();
    }

    /// <summary>
    /// Inserts a "2025 | Total" column after the last month of each year.
    /// <para>The subtotal covers only the months on screen, not the whole calendar year - so a view
    /// showing Nov and Dec reports a 2025 total of Nov + Dec, which is what the two columns beside
    /// it add up to.</para>
    /// </summary>
    private static List<PivotColumn> WithYearTotals(IReadOnlyList<PivotColumn> months)
    {
        var columns = new List<PivotColumn>();

        foreach (var year in months.Select(m => m.Year).Distinct().OrderBy(y => y))
        {
            var inYear = months.Where(m => m.Year == year).ToList();
            columns.AddRange(inYear);

            columns.Add(new PivotColumn(
                $"total-{year}",
                $"{year} | Total",
                inYear[0].Start,
                inYear[^1].End,
                year,
                IsYearTotal: true));
        }

        return columns;
    }

    /// <summary>
    /// The band above the period headers: the year on a monthly pivot, spanning its months and that
    /// year's subtotal column. The partial renders it only when a year-total column is present, so
    /// weekly gets nothing and needs nothing.
    /// </summary>
    private static List<BreakdownPivotColumnGroup> BuildColumnGroups(
        IReadOnlyList<PivotColumn> columns, bool weekly, string grandTotalTitle)
    {
        var groups = new List<BreakdownPivotColumnGroup>();

        if (!weekly)
        {
            foreach (var year in columns.Where(c => !c.IsOther).Select(c => c.Year).Distinct().OrderBy(y => y))
            {
                groups.Add(new BreakdownPivotColumnGroup
                {
                    Label = year.ToString(CultureInfo.InvariantCulture),
                    ColumnSpan = columns.Count(c => !c.IsOther && c.Year == year) * 2
                });
            }

            // The Other column belongs to no year, so it gets its own band rather than being
            // counted into one - a year band two columns too wide shifts every header after it.
            if (columns.Any(c => c.IsOther))
                groups.Add(new BreakdownPivotColumnGroup { Label = "Other", ColumnSpan = 2 });
        }

        groups.Add(new BreakdownPivotColumnGroup { Label = grandTotalTitle, ColumnSpan = 2 });
        return groups;
    }

    // ── Rows ──────────────────────────────────────────────────────────────────

    private static BreakdownPivotRow BuildRow(
        string indexLabel,
        string label,
        bool isInsurance,
        IReadOnlyList<DenialSummaryGroup> groups,
        IReadOnlyList<PivotColumn> columns)
    {
        return new BreakdownPivotRow
        {
            IndexLabel = indexLabel,
            Label = label,
            IsInsuranceRow = isInsurance,
            Cells = columns.Select(c => Cell(c.Rows(groups))).ToList(),
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
    /// A denial row's label: the code, then its description - "M127 - Missing patient medical
    /// record for this service."
    /// </summary>
    /// <remarks>
    /// The Master File Processor writes DenialDescription already prefixed with the code, because a
    /// multi-code claim needs each description paired with the code it belongs to. Prepending the
    /// code again produced "M127 - M127 - Missing...", so a description that already opens with the
    /// code is used as it stands.
    /// </remarks>
    private static string DenialLabel(string code, string description)
    {
        // A claim can reach here before the Master File Processor has normalised its code. It is
        // still the payer's claim and still in the totals, so it gets a row that says so rather
        // than a blank label.
        if (string.IsNullOrWhiteSpace(code))
            return string.IsNullOrWhiteSpace(description) ? "(no denial code)" : description.Trim();

        if (string.IsNullOrWhiteSpace(description)) return code;

        var text = description.Trim();

        return text.StartsWith(code, StringComparison.OrdinalIgnoreCase)
            ? text
            : $"{code} - {text}";
    }

    private static string Key(string? value) =>
        new((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

    private static string FirstLabel(IEnumerable<string> candidates, string fallback) =>
        candidates.FirstOrDefault(x => !string.IsNullOrWhiteSpace(x))?.Trim() is { Length: > 0 } found
            ? found
            : fallback;
}
