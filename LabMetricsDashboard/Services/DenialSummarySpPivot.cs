using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Lays the Monthly / Weekly rows of <c>usp_Get{prefix}_DenialMonthly / _DenialWeekly</c> out as the
/// <see cref="BreakdownPivotViewModel"/> the page grid and the Excel sheets render. Every number,
/// rank, label and order comes from the SP; this only places the SP cells.
/// </summary>
public static class DenialSummarySpPivot
{
    public static BreakdownPivotViewModel ToPivot(DenialPeriodResult result, bool weekly)
    {
        var model = new BreakdownPivotViewModel
        {
            SectionTitle = weekly ? "Weekly Summary" : "Monthly Summary",
            GrandTotalTitle = "Grand Total",
            TopPayerCount = DenialClaimPivotBuilder.DefaultTopPayers
        };

        var total = result.GrandTotal;
        var listed = result.Rows.Where(r => r.RowType is "P" or "C").ToList();
        var columns = result.Columns.Where(c => c.PeriodType != "A").ToList();
        if (total is null || listed.Count == 0 || columns.Count == 0) return model;

        model.Periods = columns.Select(c =>
        {
            var cell = total.Cells.GetValueOrDefault(c.PeriodKey);
            var start = cell?.PeriodStart ?? DateTime.MinValue;
            return new BreakdownPivotPeriod
            {
                Key = c.PeriodKey,
                Label = c.PeriodLabel,
                StartDate = start,
                EndDate = cell?.PeriodEnd ?? start,
                Year = c.PeriodYear ?? start.Year,
                Month = c.PeriodType == "Y" ? null : start.Month,
                IsYearTotal = c.PeriodType == "Y"
            };
        }).ToList();

        if (!weekly)
        {
            model.ColumnGroups = model.Periods
                .GroupBy(p => p.Year)
                .Select(g => new BreakdownPivotColumnGroup { Label = g.Key.ToString(System.Globalization.CultureInfo.InvariantCulture), ColumnSpan = g.Count() * 2 })
                .ToList();
        }
        model.ColumnGroups.Add(new BreakdownPivotColumnGroup { Label = model.GrandTotalTitle, ColumnSpan = 2 });

        model.Rows = listed.Select(r =>
        {
            var all = r.Cells.GetValueOrDefault(string.Empty);
            return new BreakdownPivotRow
            {
                IndexLabel = r.IndexLabel,
                Label = r.RowLabel,
                IsInsuranceRow = r.RowType == "P",
                Cells = columns.Select(c => Cell(r.Cells.GetValueOrDefault(c.PeriodKey))).ToList(),
                TotalClaimCount = all?.ClaimCount ?? 0,
                TotalBalance = all?.TotalInsuranceBalance ?? 0m
            };
        }).ToList();

        var grand = total.Cells.GetValueOrDefault(string.Empty);
        model.TotalsByPeriod = columns.Select(c => Cell(total.Cells.GetValueOrDefault(c.PeriodKey))).ToList();
        model.GrandTotalClaimCount = grand?.ClaimCount ?? 0;
        model.GrandTotalBalance = grand?.TotalInsuranceBalance ?? 0m;
        model.CoveragePercentage = grand?.CoveragePct ?? 0m;
        model.HeaderTitle = $"Top Payors & Denials | Covering {model.CoveragePercentage:0}% of the AR | Denial Posted Date";

        return model;
    }

    /// <summary>
    /// Fills the tiles and the Monthly / Weekly pivots of a lab with Denial Summary SPs - the page and
    /// both Excel builds (direct and LRN.ReportWorker) call this, so all three read the same SPs.
    /// </summary>
    public static async Task LoadAsync(
        IDenialSummaryRepository repo, string connectionString, string prefix,
        DenialClaimReportViewModel model, CancellationToken ct)
    {
        var none = new DenialSummaryFilters();
        var tilesTask = repo.GetSummaryTilesAsync(connectionString, prefix, ct);
        var monthlyTask = repo.GetMonthlyAsync(connectionString, prefix, none, ct);
        var weeklyTask = repo.GetWeeklyAsync(connectionString, prefix, none, ct);
        await Task.WhenAll(tilesTask, monthlyTask, weeklyTask);

        var tiles = tilesTask.Result;
        model.TotalClaims = tiles.DeniedClaims;
        model.TotalInsuranceBalance = tiles.InsuranceBalance;
        model.DenialCodeCount = tiles.DenialCodes;
        model.PayerCount = tiles.Insurances;
        model.UndatedGroups = tiles.UndatedGroups;

        model.Monthly = ToPivot(monthlyTask.Result, weekly: false);
        model.Weekly = ToPivot(weeklyTask.Result, weekly: true);
    }

    private static BreakdownPivotCell Cell(DenialPeriodRow? row) => new()
    {
        ClaimCount = row?.ClaimCount ?? 0,
        DenialBalance = row?.TotalInsuranceBalance ?? 0m
    };
}
