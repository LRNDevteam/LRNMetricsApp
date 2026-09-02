using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services.RevenuePipeline;

/// <summary>
/// v1.6 mockup calculators (VOL-01 / 01A / 02 / 02A / 02B / RES-01) without EF.
/// Grain is a valid LIS sample counted once; Collected date is the time axis.
/// </summary>
public static class Vol01Rolling28DayCalculator
{
    public static Vol01Response Calculate(DateTime asOfDate, IEnumerable<DailySampleCount> sourceCounts)
    {
        var asOf = asOfDate.Date;
        var currentStart = asOf.AddDays(-27);
        var previousEnd = currentStart.AddDays(-1);
        var previousStart = previousEnd.AddDays(-27);

        var countByDate = sourceCounts
            .GroupBy(x => x.Date.Date)
            .ToDictionary(x => x.Key, x => x.Sum(y => y.Samples));

        var dailyCounts = Enumerable.Range(0, 56)
            .Select(offset => previousStart.AddDays(offset))
            .Select(day => new DailySampleCount(day, countByDate.GetValueOrDefault(day, 0)))
            .ToList();

        var currentTotal = dailyCounts.Where(x => x.Date >= currentStart && x.Date <= asOf).Sum(x => x.Samples);
        var previousTotal = dailyCounts.Where(x => x.Date >= previousStart && x.Date <= previousEnd).Sum(x => x.Samples);
        var absoluteChange = currentTotal - previousTotal;
        decimal? percentChange = previousTotal == 0 ? null : (decimal)currentTotal / previousTotal - 1m;

        var chartPoints = dailyCounts.Select((row, index) =>
        {
            var movingWindow = dailyCounts
                .Skip(Math.Max(0, index - 6))
                .Take(Math.Min(7, index + 1))
                .ToList();
            var movingAverage = movingWindow.Average(x => x.Samples);
            var windowName = row.Date >= currentStart ? "current_28_days" : "previous_28_days";
            return new Vol01DailyPoint(
                row.Date.ToString("yyyy-MM-dd"),
                row.Samples,
                Math.Round((decimal)movingAverage, 1),
                windowName);
        }).ToList();

        var calculationText = percentChange is null
            ? $"{currentTotal:N0} / 0 - 1 = not available"
            : $"{currentTotal:N0} / {previousTotal:N0} - 1 = {percentChange:P1}";

        return new Vol01Response(
            "VOL-01",
            "Rolling 28-Day Sample Volume",
            asOf.ToString("yyyy-MM-dd"),
            new Vol01Window(currentStart.ToString("yyyy-MM-dd"), asOf.ToString("yyyy-MM-dd"), 28),
            new Vol01Window(previousStart.ToString("yyyy-MM-dd"), previousEnd.ToString("yyyy-MM-dd"), 28),
            new Vol01Calculation(
                currentTotal,
                previousTotal,
                absoluteChange,
                percentChange is null ? null : Math.Round(percentChange.Value, 6),
                Math.Round(currentTotal / 28m, 1),
                Math.Round(previousTotal / 28m, 1),
                calculationText),
            chartPoints);
    }
}

public static class Vol01DistributionCalculator
{
    public static Vol01DistributionResponse Calculate(
        DateTime asOfDate,
        string dimension,
        IEnumerable<DimensionWindowCount> sourceCounts)
    {
        if (dimension is not ("clinic" or "panel"))
            throw new ArgumentOutOfRangeException(nameof(dimension), "Use clinic or panel.");

        var asOf = asOfDate.Date;
        var currentStart = asOf.AddDays(-27);
        var previousEnd = currentStart.AddDays(-1);
        var previousStart = previousEnd.AddDays(-27);

        var normalized = sourceCounts
            .Select(x => x with
            {
                Name = string.IsNullOrWhiteSpace(x.Name) ? "Unknown / Not provided" : x.Name.Trim()
            })
            .ToList();

        var currentTotal = normalized.Where(x => x.IsCurrent).Sum(x => x.Samples);
        var previousTotal = normalized.Where(x => !x.IsCurrent).Sum(x => x.Samples);

        var rows = normalized
            .GroupBy(x => x.Name, StringComparer.OrdinalIgnoreCase)
            .Select(group =>
            {
                var current = group.Where(x => x.IsCurrent).Sum(x => x.Samples);
                var previous = group.Where(x => !x.IsCurrent).Sum(x => x.Samples);
                var currentShare = currentTotal == 0 ? 0m : (decimal)current / currentTotal;
                var previousShare = previousTotal == 0 ? 0m : (decimal)previous / previousTotal;
                return new Vol01DistributionRow(
                    group.Key,
                    current,
                    previous,
                    current - previous,
                    previous == 0 ? null : Math.Round((decimal)current / previous - 1m, 6),
                    Math.Round(currentShare, 6),
                    Math.Round(previousShare, 6),
                    Math.Round((currentShare - previousShare) * 100m, 3));
            })
            .OrderByDescending(x => x.CurrentSamples + x.PreviousSamples)
            .ThenByDescending(x => x.CurrentSamples)
            .ThenBy(x => x.Name)
            .ToList();

        return new Vol01DistributionResponse(
            "VOL-01A",
            "VOL-01",
            dimension,
            asOf.ToString("yyyy-MM-dd"),
            currentStart.ToString("yyyy-MM-dd"),
            asOf.ToString("yyyy-MM-dd"),
            previousStart.ToString("yyyy-MM-dd"),
            previousEnd.ToString("yyyy-MM-dd"),
            currentTotal,
            previousTotal,
            rows);
    }
}

public static class Vol02MatchedMtdCalculator
{
    public static Vol02Response Calculate(DateTime asOfDate, IEnumerable<DailySampleCount> sourceCounts)
    {
        var asOf = asOfDate.Date;
        var currentMonthStart = new DateTime(asOf.Year, asOf.Month, 1);
        var firstMonthStart = currentMonthStart.AddMonths(-12);
        var cutoffDay = asOf.Day;
        var countByDate = sourceCounts
            .GroupBy(x => x.Date.Date)
            .ToDictionary(x => x.Key, x => x.Sum(y => y.Samples));

        var monthlyData = Enumerable.Range(0, 13)
            .Select(offset => firstMonthStart.AddMonths(offset))
            .Select((monthStart, index) =>
            {
                var matchedDay = Math.Min(cutoffDay, DateTime.DaysInMonth(monthStart.Year, monthStart.Month));
                var windowEnd = monthStart.AddDays(matchedDay - 1);
                var windowDates = Enumerable.Range(0, matchedDay)
                    .Select(dayOffset => monthStart.AddDays(dayOffset))
                    .ToList();
                var total = windowDates.Sum(date => countByDate.GetValueOrDefault(date, 0));
                var observedDates = windowDates.Count(date => countByDate.GetValueOrDefault(date, 0) > 0);
                var period = index == 0 ? "prior_year"
                    : index == 11 ? "previous_month"
                    : index == 12 ? "current_month"
                    : "history";

                return new Vol02MonthlyPoint(
                    monthStart.ToString("yyyy-MM"),
                    monthStart.ToString("yyyy-MM-dd"),
                    windowEnd.ToString("yyyy-MM-dd"),
                    total,
                    matchedDay,
                    observedDates,
                    period);
            })
            .ToList();

        var current = monthlyData[^1].MatchedMtdSamples;
        var previous = monthlyData[^2].MatchedMtdSamples;
        var priorYear = monthlyData[0].MatchedMtdSamples;
        var prior12 = monthlyData.Take(12).Select(x => (decimal)x.MatchedMtdSamples).OrderBy(x => x).ToList();
        var prior12Average = prior12.Average();
        var prior12Median = (prior12[5] + prior12[6]) / 2m;

        static decimal? Variance(int numerator, decimal denominator) =>
            denominator == 0 ? null : numerator / denominator - 1m;

        var previousVariance = Variance(current, previous);
        var priorYearVariance = Variance(current, priorYear);
        var averageVariance = Variance(current, prior12Average);
        var interpretation = previousVariance is >= -0.02m and <= 0.02m
            ? averageVariance >= 0
                ? "Stable versus prior month; above prior-12-month average"
                : "Stable versus prior month; below prior-12-month average"
            : previousVariance > 0 ? "Above prior month" : "Below prior month";

        return new Vol02Response(
            "VOL-02",
            "Matched Month-to-Date Sample Volume",
            asOf.ToString("yyyy-MM-dd"),
            cutoffDay,
            12,
            new Vol02Calculation(
                current,
                previous,
                current - previous,
                previousVariance is null ? null : Math.Round(previousVariance.Value, 6),
                priorYear,
                current - priorYear,
                priorYearVariance is null ? null : Math.Round(priorYearVariance.Value, 6),
                Math.Round(prior12Average, 2),
                Math.Round(prior12Median, 2),
                averageVariance is null ? null : Math.Round(averageVariance.Value, 6),
                interpretation,
                null,
                "Suppressed: authoritative lab schedule is not available"),
            monthlyData);
    }
}

public static class Vol02aCalculator
{
    public static Vol02aResponse Calculate(DateTime asOfDate, IEnumerable<MonthlyCategoryCount> source)
    {
        var asOf = asOfDate.Date;
        var selected = new DateTime(asOf.Year, asOf.Month, 1);
        var months = Enumerable.Range(0, 13).Select(i => selected.AddMonths(i - 12).ToString("yyyy-MM")).ToList();
        var comparison = selected.AddMonths(-1).ToString("yyyy-MM");
        var rows = source
            .Select(x => x with
            {
                Category = string.IsNullOrWhiteSpace(x.Category) ? "Unknown / Unassigned" : x.Category.Trim()
            })
            .Where(x => months.Contains(x.Month))
            .ToList();

        Vol02aDimension Build(string dimension)
        {
            var dimensionRows = rows.Where(x => x.Dimension.Equals(dimension, StringComparison.OrdinalIgnoreCase)).ToList();
            var categoryNames = dimensionRows.Select(x => x.Category).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            decimal MonthTotal(string month) => dimensionRows.Where(x => x.Month == month).Sum(x => x.Samples);
            var currentTotal = MonthTotal(months[^1]);
            var comparisonTotal = MonthTotal(comparison);
            var categories = categoryNames.Select(name =>
            {
                var trend = months.Select(month => new Vol02aTrendPoint(month,
                    dimensionRows
                        .Where(x => x.Month == month && x.Category.Equals(name, StringComparison.OrdinalIgnoreCase))
                        .Sum(x => x.Samples))).ToList();
                var current = trend[^1].Samples;
                var prior = trend.First(x => x.Month == comparison).Samples;
                var currentShare = currentTotal == 0 ? 0 : current / currentTotal;
                var priorShare = comparisonTotal == 0 ? 0 : prior / comparisonTotal;
                return new Vol02aCategory(
                    name, current, prior, current - prior,
                    prior == 0 ? null : Math.Round(current / prior - 1m, 6),
                    Math.Round(currentShare, 6), Math.Round(priorShare, 6),
                    Math.Round((currentShare - priorShare) * 100m, 4), trend);
            }).OrderByDescending(x => x.CurrentSamples + x.ComparisonSamples).ThenBy(x => x.Category).ToList();
            return new Vol02aDimension(categories.Count, currentTotal, comparisonTotal, categories);
        }

        var clinic = Build("clinic");
        var panel = Build("panel");
        var totals = months.ToDictionary(
            month => month,
            month => rows.Where(x => x.Dimension.Equals("clinic", StringComparison.OrdinalIgnoreCase) && x.Month == month)
                .Sum(x => x.Samples));
        return new Vol02aResponse(
            "VOL-02A", "VOL-02", months[^1], comparison, asOf.Day, totals,
            new Dictionary<string, Vol02aDimension>(StringComparer.OrdinalIgnoreCase)
            {
                ["clinic"] = clinic,
                ["panel"] = panel,
            });
    }
}

public static class Vol02bCalculator
{
    public static Vol02bResponse Calculate(DateTime asOfDate, IEnumerable<DailySampleCount> sourceCounts)
    {
        var asOf = asOfDate.Date;
        var countByDate = sourceCounts
            .GroupBy(x => x.Date.Date)
            .ToDictionary(x => x.Key, x => x.Sum(y => y.Samples));

        static decimal? Ratio(int samples, int observedDates) =>
            observedDates == 0 ? null : Math.Round(samples / (decimal)observedDates, 2);
        static decimal? Variance(decimal? current, decimal? previous) =>
            current is null || previous is null || previous == 0
                ? null
                : Math.Round(current.Value / previous.Value - 1m, 6);

        Vol02bPeriodPoint BuildPeriod(DateTime start, DateTime end)
        {
            var elapsedDates = (end - start).Days + 1;
            var dates = Enumerable.Range(0, elapsedDates).Select(offset => start.AddDays(offset)).ToList();
            var samples = dates.Sum(date => countByDate.GetValueOrDefault(date));
            var observedDates = dates.Count(date => countByDate.GetValueOrDefault(date) > 0);
            return new Vol02bPeriodPoint(
                start.ToString("yyyy-MM-dd"), end.ToString("yyyy-MM-dd"), samples,
                elapsedDates, observedDates, Ratio(samples, observedDates));
        }

        var current28 = BuildPeriod(asOf.AddDays(-27), asOf);
        var previous28 = BuildPeriod(asOf.AddDays(-55), asOf.AddDays(-28));
        var currentMonthStart = new DateTime(asOf.Year, asOf.Month, 1);
        var firstMonthStart = currentMonthStart.AddMonths(-12);
        var cutoffDay = asOf.Day;

        var monthlyData = Enumerable.Range(0, 13).Select(offset => firstMonthStart.AddMonths(offset))
            .Select((monthStart, index) =>
            {
                var elapsedDates = Math.Min(cutoffDay, DateTime.DaysInMonth(monthStart.Year, monthStart.Month));
                var dates = Enumerable.Range(0, elapsedDates).Select(day => monthStart.AddDays(day)).ToList();
                var samples = dates.Sum(date => countByDate.GetValueOrDefault(date));
                var observedDates = dates.Count(date => countByDate.GetValueOrDefault(date) > 0);
                var period = index == 0 ? "prior_year"
                    : index == 11 ? "previous_month"
                    : index == 12 ? "current_month"
                    : "history";
                return new Vol02bMonthlyPoint(
                    monthStart.ToString("yyyy-MM"), samples, elapsedDates,
                    observedDates, Ratio(samples, observedDates), period);
            }).ToList();

        return new Vol02bResponse(
            "VOL-02B", "VOL-02", "Samples per LIS-Observed Collection Date",
            "Supplemental volume normalization; not a standalone executive chart",
            asOf.ToString("yyyy-MM-dd"), current28, previous28,
            Variance(current28.SamplesPerLisObservedDate, previous28.SamplesPerLisObservedDate), monthlyData,
            "An LIS-observed collection date is not proof of a complete lab operating day. Do not interpret this ratio as staff productivity or laboratory capacity.");
    }
}

public static class Res01ResultingTimelinessCalculator
{
    private sealed record PreparedSample(DateTime CollectedDate, DateTime? ReportedDate)
    {
        public decimal? LagDays => ReportedDate is null
            ? null
            : (decimal)(ReportedDate.Value.Date - CollectedDate.Date).TotalDays;
    }

    public static Res01Response Calculate(
        DateTime asOfDate,
        IEnumerable<Res01SampleRecord> source,
        int? openOlderThan10Override = null)
    {
        var asOf = asOfDate.Date;
        var eligibleThrough = asOf.AddDays(-10);
        var daysSinceSunday = ((int)eligibleThrough.DayOfWeek + 7) % 7;
        var currentEnd = eligibleThrough.AddDays(-daysSinceSunday);
        var currentStart = currentEnd.AddDays(-27);
        var previousEnd = currentStart.AddDays(-1);
        var previousStart = previousEnd.AddDays(-27);

        var prepared = source
            .Where(x => x.Collected.Date >= previousStart && x.Collected.Date <= asOf)
            .Select(x =>
            {
                DateTime? reported = x.Reported is { } r && r.Date <= asOf ? r.Date : null;
                return new PreparedSample(x.Collected.Date, reported);
            })
            .ToList();

        var weekly = Enumerable.Range(0, 8)
            .Select(index => previousStart.AddDays(index * 7))
            .Select(weekStart => BuildWeek(
                weekStart,
                prepared.Where(x => x.CollectedDate >= weekStart && x.CollectedDate <= weekStart.AddDays(6)),
                weekStart >= currentStart ? "current" : "previous"))
            .ToList();

        var current = prepared.Where(x => x.CollectedDate >= currentStart && x.CollectedDate <= currentEnd).ToList();
        var previous = prepared.Where(x => x.CollectedDate >= previousStart && x.CollectedDate <= previousEnd).ToList();
        var currentSummary = Summarize(current);
        var previousSummary = Summarize(previous);

        var openOlderThan10 = openOlderThan10Override ?? source.Count(x =>
            x.Collected.Date < asOf.AddDays(-10) && (x.Reported is null || x.Reported.Value.Date > asOf));

        return new Res01Response(
            "RES-01+RES-02",
            "Resulting Timeliness",
            asOf.ToString("yyyy-MM-dd"),
            new Res01Headline(
                currentStart.ToString("yyyy-MM-dd"),
                currentEnd.ToString("yyyy-MM-dd"),
                currentSummary.Eligible,
                currentSummary.WithinD10,
                currentSummary.Rate,
                previousSummary.Rate,
                Math.Round((currentSummary.Rate - previousSummary.Rate) * 100m, 2),
                currentSummary.Median,
                currentSummary.P75,
                currentSummary.P90,
                currentSummary.P95,
                openOlderThan10),
            weekly);
    }

    public static IReadOnlyList<Res01AgingBucket> Aging(
        DateTime asOfDate,
        IEnumerable<Res01SampleRecord> source)
    {
        var asOf = asOfDate.Date;
        var buckets = new (string Label, int Lo, int Hi)[]
        {
            ("0-2", 0, 2),
            ("3-5", 3, 5),
            ("6-10", 6, 10),
            ("11-14", 11, 14),
            ("15+", 15, int.MaxValue),
        };
        var counts = buckets.ToDictionary(b => b.Label, _ => 0);
        foreach (var row in source)
        {
            if (row.Collected.Date > asOf) continue;
            if (row.Reported is { } reported && reported.Date <= asOf) continue;
            var age = (asOf - row.Collected.Date).Days;
            foreach (var b in buckets)
            {
                if (age >= b.Lo && age <= b.Hi)
                {
                    counts[b.Label]++;
                    break;
                }
            }
        }
        return buckets.Select(b => new Res01AgingBucket(b.Label, counts[b.Label])).ToList();
    }

    private static Res01WeeklyCohort BuildWeek(
        DateTime weekStart,
        IEnumerable<PreparedSample> rows,
        string comparisonWindow)
    {
        var summary = Summarize(rows.ToList());
        return new Res01WeeklyCohort(
            weekStart.ToString("yyyy-MM-dd"),
            weekStart.AddDays(6).ToString("yyyy-MM-dd"),
            summary.Eligible,
            summary.WithinD10,
            summary.Rate,
            summary.Median,
            summary.P75,
            summary.P90,
            summary.P95,
            summary.Unresolved,
            comparisonWindow);
    }

    private static (int Eligible, int WithinD10, decimal Rate, int Unresolved,
        decimal? Median, decimal? P75, decimal? P90, decimal? P95) Summarize(
        IReadOnlyCollection<PreparedSample> rows)
    {
        var validLags = rows
            .Select(x => x.LagDays)
            .Where(x => x is >= 0)
            .Select(x => x!.Value)
            .OrderBy(x => x)
            .ToList();
        var withinD10 = rows.Count(x => x.LagDays is >= 0 and <= 10);
        var rate = rows.Count == 0 ? 0m : Math.Round((decimal)withinD10 / rows.Count, 4);

        return (
            rows.Count,
            withinD10,
            rate,
            rows.Count(x => x.ReportedDate is null),
            Percentile(validLags, .50m),
            Percentile(validLags, .75m),
            Percentile(validLags, .90m),
            Percentile(validLags, .95m));
    }

    private static decimal? Percentile(IReadOnlyList<decimal> ordered, decimal percentile)
    {
        if (ordered.Count == 0) return null;
        var position = (ordered.Count - 1) * percentile;
        var lower = (int)Math.Floor(position);
        var upper = (int)Math.Ceiling(position);
        if (lower == upper) return ordered[lower];
        var fraction = position - lower;
        return Math.Round(ordered[lower] + (ordered[upper] - ordered[lower]) * fraction, 2);
    }
}
