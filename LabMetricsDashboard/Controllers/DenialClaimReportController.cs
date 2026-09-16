using System.Globalization;
using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.ViewModels;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Denial Claim Report - denial reporting whose system-of-record is the lab's own claim-level data
/// (<c>dbo.ClaimLevelData WHERE DenialCode IS NOT NULL</c>). Weekly and monthly summaries are
/// calculated from that dataset and grouped on DenialDate; the Denial Insights tab holds the
/// analytical layer the client imports. The two stay distinct: an insight import never recalculates
/// or overwrites claim-level data.
///
/// Separate from DenialDashboardController by design - nothing here reads or writes that page's
/// tables, so the existing Denial Dashboard is unaffected.
/// </summary>
[Authorize]
public sealed class DenialClaimReportController : Controller
{
    /// <summary>Periods offered in the pickers. Older data is still queryable by URL.</summary>
    private const int MaxPeriodOptions = 26;

    private readonly LabSettings _labSettings;
    private readonly LabConfigOptions _labConfig;
    private readonly IDenialClaimReportRepository _repo;
    private readonly ILogger<DenialClaimReportController> _logger;

    public DenialClaimReportController(
        LabSettings labSettings,
        LabConfigOptions labConfig,
        IDenialClaimReportRepository repo,
        ILogger<DenialClaimReportController> logger)
    {
        _labSettings = labSettings;
        _labConfig = labConfig;
        _repo = repo;
        _logger = logger;
    }

    private bool IsAdmin => User.IsInRole("Admin") || User.IsInRole("LRN Admin") || User.IsInRole("LRNAdmin");

    private string CurrentUser => User.Identity?.Name?.Trim() is { Length: > 0 } u ? u : "system";

    private bool CanEditInsights() =>
        IsAdmin || User.IsInRole("AR Manager") || User.IsInRole("ARManager") || User.IsInRole("Lab User") || User.IsInRole("LabUser");

    /// <summary>Labs this user may open - the same visibility rule the rest of the app applies.</summary>
    private List<string> VisibleLabs()
    {
        var all = _labSettings.Labs.Keys.ToList();
        var claimed = User.Claims.Where(c => c.Type == "LabName").Select(c => c.Value)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        return _labConfig.VisibleLabs(all, claimed, IsAdmin).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>
    /// Lab resolution is authorization, not convenience: an unassigned lab never resolves, so a
    /// hand-edited drill-through URL cannot reach another lab's claims.
    /// </summary>
    private bool TryResolveLab(string? lab, out string labName, out string connectionString, out string? masterConnectionString, out string error)
    {
        labName = string.Empty;
        connectionString = string.Empty;
        masterConnectionString = null;
        error = string.Empty;

        var labs = VisibleLabs();
        if (labs.Count == 0) { error = "No labs are available for your account."; return false; }

        labName = labs.FirstOrDefault(x => string.Equals(x, lab?.Trim(), StringComparison.OrdinalIgnoreCase)) ?? labs[0];

        if (!_labSettings.Labs.TryGetValue(labName, out var config) || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            error = $"No database connection is configured for '{labName}'.";
            return false;
        }

        connectionString = config.DbConnectionString!;
        masterConnectionString = config.MasterDbConnectionString;
        return true;
    }

    // ── Weekly / Monthly denial summary ───────────────────────────────────────

    /// <summary>
    /// How many denial codes the Top Denial pivot shows before the "show all" toggle - requirement
    /// 4k / 5k, "filter the Top 3 Denial Code by Claim Count".
    /// </summary>
    private const int TopDenialCodes = 3;

    /// <summary>How many periods sit across the top of a pivot before it gets unreadable.</summary>
    private const int MaxPivotPeriods = 6;

    [HttpGet]
    public async Task<IActionResult> Index(string? lab, string? grain, string? period, bool showAll, CancellationToken ct)
    {
        var model = new DenialClaimReportViewModel
        {
            Labs = VisibleLabs(),
            Grain = string.Equals(grain, "weekly", StringComparison.OrdinalIgnoreCase) ? "weekly" : "monthly",
            ShowAllDenials = showAll
        };

        if (!TryResolveLab(lab, out var labName, out var connectionString, out var masterConnectionString, out var error))
        {
            model.Error = error;
            model.CurrentLab = labName;
            return View(model);
        }

        model.CurrentLab = labName;

        try
        {
            var claims = await _repo.GetDenialClaimsAsync(connectionString, ct);
            var descriptions = await _repo.GetDescriptionsAsync(connectionString, masterConnectionString, ct);

            model.TotalDenials = claims.Count;
            model.TotalClaims = DistinctClaims(claims);
            model.TotalInsuranceBalance = claims.Sum(x => x.InsuranceBalance);

            // The two filters every summary in the requirements is built on: a blank denial code is
            // not a denial, and a claim with nothing outstanding is not an open one.
            var reportable = claims.Where(IsReportable).ToList();
            model.ExcludedDenials = claims.Count - reportable.Count;

            var weekly = model.Grain == "weekly";
            model.UsesDeniedWeekColumn = weekly && reportable.Any(x => !string.IsNullOrWhiteSpace(x.DeniedWeek));

            model.Periods = BuildPeriods(reportable, model.Grain);

            var selected = model.Periods.FirstOrDefault(p => string.Equals(p.Key, period, StringComparison.OrdinalIgnoreCase))
                           ?? model.Periods.FirstOrDefault();
            model.SelectedPeriod = selected;

            // Newest periods, then flipped so the pivot reads oldest-to-newest left to right.
            var pivotPeriods = model.Periods.Take(MaxPivotPeriods).Reverse().ToList();

            model.TopInsurance = BuildPayerPivot(reportable, pivotPeriods);
            model.TopDenial = BuildDenialPivot(reportable, pivotPeriods, descriptions,
                showAll ? int.MaxValue : TopDenialCodes);

            if (selected is not null)
                model.Summary = BuildDenialSummary(reportable.Where(selected.Contains).ToList(), descriptions);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Denial Claim Report failed for lab {Lab}.", labName);
            model.Error = "The denial claim data could not be loaded for this lab.";
        }

        return View(model);
    }

    /// <summary>
    /// Requirements 4b/4c and 5b/5c: exclude a blank denial code, and keep only rows with an
    /// insurance balance above zero. Applied once, before any summary is built, so every figure on
    /// the page counts the same population.
    /// </summary>
    private static bool IsReportable(DenialClaimRow row) =>
        !string.IsNullOrWhiteSpace(row.DenialCodeNormalized) && row.InsuranceBalance > 0m;

    private static int DistinctClaims(IEnumerable<DenialClaimRow> rows) => rows
        .Select(x => x.ClaimId)
        .Where(x => !string.IsNullOrWhiteSpace(x))
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .Count();

    /// <summary>
    /// The periods the lab actually has denials in: months from Denial Date, weeks from the lab's
    /// own DeniedWeek column where it has one.
    /// </summary>
    /// <remarks>
    /// The weekly summary is specified against DeniedWeek, and a lab's week labels do not
    /// necessarily line up with Monday-Sunday, so that column wins when it is populated. Grouping on
    /// a derived week instead would quietly disagree with the lab's own reporting. Where the column
    /// is absent or empty the week is derived from Denial Date, which keeps the page working rather
    /// than showing an empty weekly view.
    /// </remarks>
    internal static List<DenialPeriodOption> BuildPeriods(IReadOnlyList<DenialClaimRow> rows, string grain)
    {
        var weekly = string.Equals(grain, "weekly", StringComparison.OrdinalIgnoreCase);

        if (weekly && rows.Any(x => !string.IsNullOrWhiteSpace(x.DeniedWeek)))
        {
            return rows
                .Where(x => !string.IsNullOrWhiteSpace(x.DeniedWeek))
                .GroupBy(x => x.DeniedWeek.Trim(), StringComparer.OrdinalIgnoreCase)
                .Select(g =>
                {
                    // Ordered by the dates behind the label, because a week label does not sort.
                    var dates = g.Where(x => x.DenialDate.HasValue).Select(x => x.DenialDate!.Value.Date).ToList();
                    return new DenialPeriodOption
                    {
                        DeniedWeekValue = g.Key,
                        Start = dates.Count > 0 ? dates.Min() : DateTime.MinValue,
                        End = dates.Count > 0 ? dates.Max() : DateTime.MinValue,
                        Key = g.Key,
                        Label = g.Key,
                        DenialCount = g.Count()
                    };
                })
                .OrderByDescending(p => p.Start)
                .ThenByDescending(p => p.Key, StringComparer.OrdinalIgnoreCase)
                .Take(MaxPeriodOptions)
                .ToList();
        }

        return rows
            .Where(x => x.DenialDate.HasValue)
            .GroupBy(x => weekly ? WeekStart(x.DenialDate!.Value) : MonthStart(x.DenialDate!.Value))
            .Select(g =>
            {
                var end = weekly ? g.Key.AddDays(6) : g.Key.AddMonths(1).AddDays(-1);
                return new DenialPeriodOption
                {
                    Start = g.Key,
                    End = end,
                    Key = g.Key.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                    Label = weekly
                        ? $"{g.Key:dd MMM} - {end:dd MMM yyyy}"
                        : g.Key.ToString("MMMM yyyy", CultureInfo.InvariantCulture),
                    DenialCount = g.Count()
                };
            })
            .OrderByDescending(p => p.Start)
            .Take(MaxPeriodOptions)
            .ToList();
    }

    /// <summary>
    /// Top Insurance: rows are PayerName_Raw, columns are the reporting periods, every cell carries
    /// Claim Count and Total Balance. Ordered by claim count, per requirements 4d/4g and 5d/5g.
    /// </summary>
    internal static DenialPivotTable BuildPayerPivot(
        IReadOnlyList<DenialClaimRow> rows, IReadOnlyList<DenialPeriodOption> periods)
    {
        var groups = rows
            .Where(x => !string.IsNullOrWhiteSpace(x.PayerName))
            .GroupBy(x => x.PayerNameNormalized, StringComparer.OrdinalIgnoreCase)
            .Select(g => (Key: g.First().PayerName, Label: g.First().PayerName, SubLabel: string.Empty, Rows: g.ToList()));

        return BuildPivot("Top Insurance by Claim Count", "Insurance", groups, periods, int.MaxValue);
    }

    /// <summary>
    /// Top Denial: rows are the common denial code, columns are the reporting periods. Cut to the
    /// top <paramref name="topN"/> codes by claim count - requirement 4k / 5k.
    /// </summary>
    internal static DenialPivotTable BuildDenialPivot(
        IReadOnlyList<DenialClaimRow> rows,
        IReadOnlyList<DenialPeriodOption> periods,
        DenialDescriptionLookup descriptions,
        int topN)
    {
        var groups = rows
            .GroupBy(x => x.DenialCodeNormalized, StringComparer.OrdinalIgnoreCase)
            .Select(g => (
                Key: g.Key,
                Label: g.Key,
                SubLabel: ResolveDescription(g.Key, g, descriptions),
                Rows: g.ToList()));

        return BuildPivot("Top Denial by Claim Count", "Denial Code", groups, periods, topN);
    }

    private static DenialPivotTable BuildPivot(
        string title,
        string rowHeader,
        IEnumerable<(string Key, string Label, string SubLabel, List<DenialClaimRow> Rows)> groups,
        IReadOnlyList<DenialPeriodOption> periods,
        int topN)
    {
        var all = groups
            .Select(g =>
            {
                var row = new DenialPivotRow
                {
                    Key = g.Key,
                    Label = g.Label,
                    SubLabel = g.SubLabel,
                    // The row total counts DISTINCT claims across the whole range, so a claim
                    // appearing in two periods is not double counted here even though each period's
                    // own cell counts it.
                    TotalClaimCount = DistinctClaims(g.Rows),
                    TotalBalance = g.Rows.Sum(x => x.InsuranceBalance)
                };

                foreach (var period in periods)
                {
                    var inPeriod = g.Rows.Where(period.Contains).ToList();
                    if (inPeriod.Count == 0) continue;

                    row.Cells[period.Key] = new DenialPivotCell
                    {
                        ClaimCount = DistinctClaims(inPeriod),
                        TotalBalance = inPeriod.Sum(x => x.InsuranceBalance)
                    };
                }

                return row;
            })
            .OrderByDescending(r => r.TotalClaimCount)
            .ThenByDescending(r => r.TotalBalance)
            .ToList();

        var shown = topN >= all.Count ? all : all.Take(topN).ToList();

        // The total row sums what is SHOWN, so the column figures and the total agree on screen.
        var total = new DenialPivotRow
        {
            Label = "Total",
            TotalClaimCount = shown.Sum(r => r.TotalClaimCount),
            TotalBalance = shown.Sum(r => r.TotalBalance)
        };

        foreach (var period in periods)
        {
            var cells = shown.Select(r => r.CellFor(period.Key)).ToList();
            total.Cells[period.Key] = new DenialPivotCell
            {
                ClaimCount = cells.Sum(c => c.ClaimCount),
                TotalBalance = cells.Sum(c => c.TotalBalance)
            };
        }

        return new DenialPivotTable
        {
            Title = title,
            RowHeader = rowHeader,
            Periods = periods.ToList(),
            Rows = shown,
            Total = total,
            IsTopNFiltered = shown.Count < all.Count,
            RowsAvailable = all.Count
        };
    }

    /// <summary>
    /// One row per common denial code within the period: total distinct claims and insurance balance
    /// for the denial, then the single most impacted payer by balance, with that payer's own claim
    /// count and balance. Codes are rolled up first (CO45/PI45/PR45 -> 45) so the row and the
    /// drill-through it links to describe the same population.
    /// </summary>
    internal static List<DenialSummaryRow> BuildDenialSummary(
        IReadOnlyList<DenialClaimRow> rows,
        DenialDescriptionLookup descriptions)
    {
        return rows
            .Where(x => !string.IsNullOrWhiteSpace(x.DenialCodeNormalized))
            .GroupBy(x => x.DenialCodeNormalized, StringComparer.OrdinalIgnoreCase)
            .Select(g =>
            {
                var payer = g
                    .Where(x => !string.IsNullOrWhiteSpace(x.PayerName))
                    .GroupBy(x => x.PayerNameNormalized, StringComparer.OrdinalIgnoreCase)
                    .Select(p => new
                    {
                        Name = p.First().PayerName,
                        Balance = p.Sum(x => x.InsuranceBalance),
                        Claims = DistinctClaims(p)
                    })
                    // Claim count, not balance: requirement 4d/5d names the claim count as the sort
                    // for the top insurance, and the "highest impact" payer has to agree with it.
                    .OrderByDescending(p => p.Claims)
                    .ThenByDescending(p => p.Balance)
                    .FirstOrDefault();

                return new DenialSummaryRow
                {
                    DenialCode = g.Key,
                    DenialDescription = ResolveDescription(g.Key, g, descriptions),
                    DenialClassification = g.Select(x => x.DenialClassification)
                        .FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)) ?? string.Empty,
                    RawCodes = string.Join(", ", g.Select(x => x.DenialCode)
                        .Where(x => !string.IsNullOrWhiteSpace(x))
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)),
                    DenialCount = g.Count(),
                    TotalClaims = DistinctClaims(g),
                    InsuranceBalance = g.Sum(x => x.InsuranceBalance),
                    TotalBalance = g.Sum(x => x.TotalBalance),
                    HighlyImpactedPayer = payer?.Name ?? string.Empty,
                    PayerClaimCount = payer?.Claims ?? 0,
                    PayerInsuranceBalance = payer?.Balance ?? 0m
                };
            })
            .OrderByDescending(r => r.TotalClaims)
            .ThenByDescending(r => r.InsuranceBalance)
            .ToList();
    }

    /// <summary>
    /// The description for a common denial code, through the four-step cascade.
    /// </summary>
    /// <remarks>
    /// Tried against each RAW code that rolled into this group before the normalized code, because
    /// the cascade's first two steps are raw-code matches and a group built from CO45 has to get the
    /// chance to match a master row stored as CO45. The description already on the claim row - which
    /// the Master File Processor wrote using the same cascade - is the last resort, so a lab whose
    /// master has since lost a code still shows what it showed at import time.
    /// </remarks>
    private static string ResolveDescription(
        string normalizedCode,
        IEnumerable<DenialClaimRow> rows,
        DenialDescriptionLookup descriptions)
    {
        var claims = rows as IReadOnlyList<DenialClaimRow> ?? rows.ToList();

        foreach (var rawCode in claims.Select(x => x.DenialCode)
                                      .Where(x => !string.IsNullOrWhiteSpace(x))
                                      .Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (descriptions.Resolve(rawCode) is { Length: > 0 } fromRaw) return fromRaw;
        }

        if (descriptions.Resolve(normalizedCode) is { Length: > 0 } fromNormalized) return fromNormalized;

        return claims.Select(x => x.DenialDescription).FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)) ?? string.Empty;
    }

    private static DateTime MonthStart(DateTime date) => new(date.Year, date.Month, 1);

    private static DateTime WeekStart(DateTime date)
    {
        var d = date.Date;
        var daysSinceMonday = ((int)d.DayOfWeek + 6) % 7;
        return d.AddDays(-daysSinceMonday);
    }

    // ── Claim Level Data (drill-through target) ───────────────────────────────

    /// <summary>
    /// The claim-level population behind a metric. Opened from a denial code, a claim count or a
    /// payer balance, carrying the filter context that reproduces exactly that population; the view
    /// shows the active filters and links back.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> ClaimData(string? lab, string? denialCode, string? payerName, string? grain, string? period, string? from, string? bucket, CancellationToken ct)
    {
        var model = new DenialClaimDataViewModel
        {
            Labs = VisibleLabs(),
            ReturnTo = string.Equals(from, "insights", StringComparison.OrdinalIgnoreCase) ? "insights" : "summary",
            Grain = string.Equals(grain, "weekly", StringComparison.OrdinalIgnoreCase) ? "weekly" : "monthly",
            Bucket = DenialInsightBuckets.Normalize(bucket)
        };

        if (!TryResolveLab(lab, out var labName, out var connectionString, out var masterConnectionString, out var error))
        {
            model.Error = error;
            model.CurrentLab = labName;
            return View(model);
        }

        model.CurrentLab = labName;

        var filter = new ClaimDrillThroughFilter
        {
            DenialCode = string.IsNullOrWhiteSpace(denialCode) ? null : DenialCodeKey.Normalize(denialCode),
            PayerName = string.IsNullOrWhiteSpace(payerName) ? null : payerName.Trim(),
            PeriodKey = period
        };

        try
        {
            var claims = await _repo.GetDenialClaimsAsync(connectionString, ct);
            var descriptions = await _repo.GetDescriptionsAsync(connectionString, masterConnectionString, ct);

            // The same two filters the summaries use, so a drill-through returns exactly the rows
            // the number on the previous screen was counted from.
            IEnumerable<DenialClaimRow> filtered = claims.Where(IsReportable);

            if (!string.IsNullOrWhiteSpace(filter.DenialCode))
            {
                var code = filter.DenialCode;
                filtered = filtered.Where(x => string.Equals(x.DenialCodeNormalized, code, StringComparison.OrdinalIgnoreCase));
                model.DenialDescription = descriptions.Resolve(code) ?? string.Empty;
            }

            if (!string.IsNullOrWhiteSpace(filter.PayerName))
            {
                // Matched on the normalized payer key so a display-name variation still resolves.
                var payerKey = DenialCodeKey.NormalizePayer(filter.PayerName);
                filtered = filtered.Where(x => string.Equals(x.PayerNameNormalized, payerKey, StringComparison.OrdinalIgnoreCase));
            }

            if (!string.IsNullOrWhiteSpace(period))
            {
                var weekly = string.Equals(model.Grain, "weekly", StringComparison.OrdinalIgnoreCase);

                if (DateTime.TryParse(period, CultureInfo.InvariantCulture, DateTimeStyles.None, out var periodStart))
                {
                    var periodEnd = weekly ? periodStart.AddDays(6) : periodStart.AddMonths(1).AddDays(-1);

                    filter.PeriodStart = periodStart;
                    filter.PeriodEnd = periodEnd;
                    filter.PeriodLabel = weekly
                        ? $"{periodStart:dd MMM} - {periodEnd:dd MMM yyyy}"
                        : periodStart.ToString("MMMM yyyy", CultureInfo.InvariantCulture);

                    filtered = filtered.Where(x => x.DenialDate.HasValue
                        && x.DenialDate.Value.Date >= periodStart && x.DenialDate.Value.Date <= periodEnd);
                }
                else
                {
                    // Not a date, so it is one of the lab's own DeniedWeek labels - matched as the
                    // string it is rather than guessed at.
                    var week = period.Trim();
                    filter.PeriodLabel = week;
                    filtered = filtered.Where(x => string.Equals(x.DeniedWeek, week, StringComparison.OrdinalIgnoreCase));
                }
            }

            var list = filtered.OrderByDescending(x => x.InsuranceBalance).ToList();
            model.Claims = list;
            model.TotalClaims = DistinctClaims(list);
            model.TotalInsuranceBalance = list.Sum(x => x.InsuranceBalance);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Claim Level Data drill-through failed for lab {Lab}.", labName);
            model.Error = "The claim-level data could not be loaded for this lab.";
        }

        model.Filter = filter;
        return View(model);
    }

    // ── Denial Insights ───────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Insights(string? lab, string? bucket, CancellationToken ct)
    {
        var model = new DenialInsightClaimLevelViewModel
        {
            Labs = VisibleLabs(),
            CanEdit = CanEditInsights(),
            Bucket = DenialInsightBuckets.Normalize(bucket),
            CurrentWeekStart = SqlDenialClaimReportRepository.WeekStartOf(DateTime.Today)
        };

        if (!TryResolveLab(lab, out var labName, out var connectionString, out _, out var error))
        {
            model.Error = error;
            model.CurrentLab = labName;
            return View(model);
        }

        model.CurrentLab = labName;

        try
        {
            model.Rows = await _repo.GetInsightsAsync(connectionString, model.Bucket, ct);

            // Every tab's count, so the user can see where their data is without opening each one.
            foreach (var name in new[] { DenialInsightBuckets.Current, DenialInsightBuckets.Previous, DenialInsightBuckets.Archive })
            {
                model.BucketCounts[name] = name == model.Bucket
                    ? model.Rows.Count
                    : (await _repo.GetInsightsAsync(connectionString, name, ct)).Count;
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Denial Insight Claim Level failed for lab {Lab}.", labName);
            model.Error = "The denial insight rows could not be loaded for this lab.";
        }

        return View(model);
    }

    /// <summary>
    /// Copies the Current Week insights into Previous Week and rolls anything past the 4-week
    /// window into Archive. The confirmation the requirements ask for is in the view - this action
    /// only runs once the user has already confirmed.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CopyToPreviousWeek(string? lab, CancellationToken ct)
    {
        if (!CanEditInsights())
        {
            TempData["DenialClaimReportError"] = "You do not have permission to move denial insights.";
            return RedirectToAction(nameof(Insights), new { lab });
        }

        if (!TryResolveLab(lab, out var labName, out var connectionString, out _, out var error))
        {
            TempData["DenialClaimReportError"] = error;
            return RedirectToAction(nameof(Insights), new { lab });
        }

        try
        {
            var result = await _repo.CopyCurrentToPreviousAsync(connectionString, CurrentUser, ct);

            TempData["DenialClaimReportSuccess"] = result.Copied == 0
                ? "There were no Current Week insights to copy."
                : $"Copied {result.Copied:N0} insight row(s) to Previous Week "
                  + $"({result.Inserted:N0} added, {result.Updated:N0} refreshed). "
                  + (result.Archived > 0
                      ? $"{result.Archived:N0} row(s) older than {DenialInsightBuckets.PreviousWeeksRetained} weeks moved to Archive. "
                      : string.Empty)
                  + "Current Week is unchanged.";
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Copy to Previous Week failed for lab {Lab}.", labName);
            TempData["DenialClaimReportError"] = "The insights could not be copied to Previous Week. Nothing was changed.";
        }

        return RedirectToAction(nameof(Insights), new { lab = labName, bucket = DenialInsightBuckets.Previous });
    }

    /// <summary>
    /// Imports the client's Denial Insight workbook. The file is validated in full BEFORE anything is
    /// written: a missing mandatory column or an unreadable date is reported back and nothing is
    /// committed, rather than leaving the table half-updated.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> UploadInsights(string? lab, IFormFile? insightFile, CancellationToken ct)
    {
        if (!CanEditInsights())
        {
            TempData["DenialClaimReportError"] = "You do not have permission to import denial insights.";
            return RedirectToAction(nameof(Insights), new { lab });
        }

        if (!TryResolveLab(lab, out var labName, out var connectionString, out _, out var error))
        {
            TempData["DenialClaimReportError"] = error;
            return RedirectToAction(nameof(Insights), new { lab });
        }

        if (insightFile is null || insightFile.Length == 0)
        {
            TempData["DenialClaimReportError"] = "Please choose an Excel file to import.";
            return RedirectToAction(nameof(Insights), new { lab = labName });
        }

        var uploadError = await FileUploadGuard.ValidateExcelAsync(insightFile, 25 * 1024 * 1024, ct);
        if (uploadError != null)
        {
            TempData["DenialClaimReportError"] = uploadError;
            return RedirectToAction(nameof(Insights), new { lab = labName });
        }

        DenialInsightValidationResult validation;
        try
        {
            validation = ValidateInsightWorkbook(insightFile);
        }
        catch (Exception ex)
        {
            TempData["DenialClaimReportError"] = $"Import failed: {ex.Message}";
            return RedirectToAction(nameof(Insights), new { lab = labName });
        }

        if (!validation.IsValid)
        {
            TempData["DenialClaimReportError"] =
                "The workbook does not match the Denial Insight template, so nothing was imported. "
                + string.Join(" ", validation.Errors.Take(5))
                + (validation.Errors.Count > 5 ? $" (+{validation.Errors.Count - 5} more)" : string.Empty);
            return RedirectToAction(nameof(Insights), new { lab = labName });
        }

        // An import always lands on Current Week - requirement 6d. The user moves it on with
        // "Copy Data to Previous Week" when they are ready, not on import.
        var weekStart = SqlDenialClaimReportRepository.WeekStartOf(DateTime.Today);
        foreach (var row in validation.Rows)
        {
            row.Bucket = DenialInsightBuckets.Current;
            row.WeekStart = weekStart;
        }

        var result = await _repo.SaveInsightsAsync(connectionString, validation.Rows, CurrentUser, ct);

        var message = $"Imported {validation.Rows.Count:N0} row(s) into Current Week for {labName}: {result.Inserted:N0} added, {result.Updated:N0} updated"
            + (result.Skipped > 0 ? $", {result.Skipped:N0} skipped" : string.Empty)
            + (result.Errors.Count > 0 ? $", {result.Errors.Count:N0} failed." : ".")
            + (validation.Warnings.Count > 0 ? " " + string.Join(" ", validation.Warnings.Take(3)) : string.Empty);

        TempData[result.Errors.Count > 0 ? "DenialClaimReportError" : "DenialClaimReportSuccess"] = message;
        return RedirectToAction(nameof(Insights), new { lab = labName });
    }

    /// <summary>Saves the grid's edits - whatever is on screen wins for those rows.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveInsights(
        string? lab,
        [FromForm] string[] denialCodes,
        [FromForm] string[] payerNames,
        [FromForm] string[] observations,
        [FromForm] string[] actionCategories,
        [FromForm] string[] actions,
        [FromForm] string[] feedbackResponses,
        [FromForm] string[] responsibilities,
        [FromForm] string[] discussionDates,
        [FromForm] string[] etas,
        [FromForm] string[] closedDates,
        CancellationToken ct)
    {
        if (!CanEditInsights())
        {
            TempData["DenialClaimReportError"] = "You do not have permission to edit denial insights.";
            return RedirectToAction(nameof(Insights), new { lab });
        }

        if (!TryResolveLab(lab, out var labName, out var connectionString, out _, out var error))
        {
            TempData["DenialClaimReportError"] = error;
            return RedirectToAction(nameof(Insights), new { lab });
        }

        // Only Current Week is editable: Previous and Archive are the record of what was said at
        // the time, so an edit posted against them is rejected rather than silently applied.
        var existing = (await _repo.GetInsightsAsync(connectionString, DenialInsightBuckets.Current, ct))
            .ToDictionary(r => $"{r.DenialCode}|{r.PayerName}", StringComparer.OrdinalIgnoreCase);

        var weekStart = existing.Values.Select(r => r.WeekStart).DefaultIfEmpty(
            SqlDenialClaimReportRepository.WeekStartOf(DateTime.Today)).Max();

        var rows = new List<DenialInsightClaimLevelRow>();
        for (var i = 0; i < denialCodes.Length; i++)
        {
            var code = denialCodes.ElementAtOrDefault(i)?.Trim();
            if (string.IsNullOrWhiteSpace(code)) continue;

            var payer = payerNames.ElementAtOrDefault(i) ?? string.Empty;
            var row = new DenialInsightClaimLevelRow
            {
                Bucket = DenialInsightBuckets.Current,
                WeekStart = weekStart,
                DenialCode = code,
                PayerName = payer,
                // The editors post HTML; sanitize on the way in, the same as an import does.
                ObservationHtml = DenialInsightRichText.Sanitize(observations.ElementAtOrDefault(i)),
                ActionCategory = actionCategories.ElementAtOrDefault(i) ?? string.Empty,
                ActionHtml = DenialInsightRichText.Sanitize(actions.ElementAtOrDefault(i)),
                FeedbackResponse = feedbackResponses.ElementAtOrDefault(i) ?? string.Empty,
                Responsibility = responsibilities.ElementAtOrDefault(i) ?? string.Empty,
                DiscussionDate = ParseDate(discussionDates.ElementAtOrDefault(i)),
                Eta = ParseDate(etas.ElementAtOrDefault(i)),
                ClosedDate = ParseDate(closedDates.ElementAtOrDefault(i))
            };

            // The edit grid does not carry the numeric columns - keep whatever the import put there.
            if (existing.TryGetValue($"{row.DenialCode}|{row.PayerName}", out var prior))
            {
                row.WeekStart = prior.WeekStart;
                row.DenialDescription = prior.DenialDescription;
                row.NoOfDenials = prior.NoOfDenials;
                row.NoOfClaims = prior.NoOfClaims;
                row.TotalBalance = prior.TotalBalance;
                row.InsuranceBalance = prior.InsuranceBalance;
                row.ImpactPercentage = prior.ImpactPercentage;
            }

            rows.Add(row);
        }

        var result = await _repo.SaveInsightsAsync(connectionString, rows, CurrentUser, ct);
        TempData[result.Errors.Count > 0 ? "DenialClaimReportError" : "DenialClaimReportSuccess"] =
            $"Saved {result.Updated + result.Inserted:N0} denial insight row(s) for {labName}."
            + (result.Errors.Count > 0 ? $" {result.Errors.Count} row(s) failed." : string.Empty);

        return RedirectToAction(nameof(Insights), new { lab = labName });
    }

    /// <summary>Downloads the Denial Insight template - this tab's rows, in the shape the import expects.</summary>
    [HttpGet]
    public async Task<IActionResult> ExportInsights(string? lab, string? bucket, CancellationToken ct)
    {
        if (!TryResolveLab(lab, out var labName, out var connectionString, out _, out var error))
        {
            TempData["DenialClaimReportError"] = error;
            return RedirectToAction(nameof(Insights), new { lab });
        }

        var tab = DenialInsightBuckets.Normalize(bucket);
        var rows = await _repo.GetInsightsAsync(connectionString, tab, ct);

        using var workbook = new XLWorkbook();
        var ws = workbook.Worksheets.Add(InsightSheetName);

        for (var c = 0; c < TemplateHeaders.Length; c++)
        {
            var cell = ws.Cell(1, c + 1);
            cell.Value = TemplateHeaders[c];
            cell.Style.Font.SetBold();
        }

        var row = 2;
        foreach (var r in rows)
        {
            ws.Cell(row, 1).Value = r.DenialCode;
            ws.Cell(row, 2).Value = r.DenialDescription;
            ws.Cell(row, 3).Value = r.PayerName;
            ws.Cell(row, 4).Value = r.NoOfDenials;
            ws.Cell(row, 5).Value = r.NoOfClaims;
            ws.Cell(row, 6).Value = r.TotalBalance;
            ws.Cell(row, 7).Value = r.InsuranceBalance;
            ws.Cell(row, 8).Value = r.ImpactPercentage;
            ws.Cell(row, 9).Value = DenialInsightRichText.ToPlainText(r.ObservationHtml);
            ws.Cell(row, 10).Value = r.ActionCategory;
            ws.Cell(row, 11).Value = DenialInsightRichText.ToPlainText(r.ActionHtml);
            ws.Cell(row, 12).Value = r.FeedbackResponse;
            ws.Cell(row, 13).Value = r.Responsibility;
            if (r.DiscussionDate.HasValue) ws.Cell(row, 14).Value = r.DiscussionDate.Value;
            if (r.Eta.HasValue) ws.Cell(row, 15).Value = r.Eta.Value;
            if (r.ClosedDate.HasValue) ws.Cell(row, 16).Value = r.ClosedDate.Value;
            ws.Cell(row, 9).Style.Alignment.WrapText = true;
            ws.Cell(row, 11).Style.Alignment.WrapText = true;
            row++;
        }

        ws.Columns().AdjustToContents();
        ws.Column(9).Width = 45;
        ws.Column(11).Width = 45;

        await using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        var safeLab = string.Join("_", labName.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries));
        return File(stream.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"{safeLab}_DenialInsightTemplate_{tab}_{DateTime.Now:yyyyMMdd}.xlsx");
    }

    private const string InsightSheetName = "Denial Insights";

    /// <summary>The template's columns. The first three are mandatory; the rest may be blank.</summary>
    private static readonly string[] TemplateHeaders =
    [
        "Denial Codes", "Descriptions", "Highest $ Impact - Insurance", "# of Denial", "# of Claims",
        "Total Balance ($)", "Ins. Balance ($)", "$ Impact (%)", "Observation", "Category", "Action",
        "Feedback / Response", "Responsibility", "Discussion Date", "ETA", "Closed Date"
    ];

    private static DateTime? ParseDate(string? value) => DateTime.TryParse(value, out var parsed) ? parsed : null;

    /// <summary>
    /// Reads and validates the workbook without writing anything. Structural problems (no denial code
    /// header, no rows) fail the import; per-row problems (an unreadable date) are collected as
    /// warnings so one bad cell does not reject an otherwise good file.
    /// </summary>
    private static DenialInsightValidationResult ValidateInsightWorkbook(IFormFile file)
    {
        var result = new DenialInsightValidationResult();

        using var stream = file.OpenReadStream();
        using var workbook = new XLWorkbook(stream);

        static string Key(string s) => new(s.Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

        IXLRow? headerRow = null;
        foreach (var sheet in workbook.Worksheets)
        {
            headerRow = sheet.RowsUsed().Take(200).FirstOrDefault(r =>
                r.CellsUsed().Any(c => Key(c.GetString()) is "DENIALCODES" or "DENIALCODE"));
            if (headerRow is not null) break;
        }

        if (headerRow is null)
        {
            result.Errors.Add("No \"Denial Code\" column was found in any sheet - this does not look like the Denial Insight template.");
            return result;
        }

        var ws = headerRow.Worksheet;

        // Merged header groups store their text only in the left-most cell, which is where that
        // field's data starts - so matching on header text lands on the right column either way.
        var headers = headerRow.CellsUsed()
            .Select(c => new { Name = Key(c.GetString()), Column = c.Address.ColumnNumber })
            .Where(x => x.Name.Length > 0)
            .GroupBy(x => x.Name, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(x => x.Key, x => x.First().Column, StringComparer.OrdinalIgnoreCase);

        int? Col(params string[] names) => names.Select(Key)
            .Select(n => headers.TryGetValue(n, out var c) ? c : (int?)null)
            .FirstOrDefault(c => c.HasValue);

        var codeCol = Col("Denial Codes", "Denial Code");
        var payerCol = Col("Highest $ Impact - Insurance", "Insurance", "Payer Name", "Payer");
        var observationCol = Col("Observation");

        if (codeCol is null) result.Errors.Add("Mandatory column \"Denial Codes\" is missing.");
        if (payerCol is null) result.Errors.Add("Mandatory column \"Highest $ Impact - Insurance\" (payer) is missing.");
        if (observationCol is null) result.Warnings.Add("No \"Observation\" column was found; observations were left unchanged.");
        if (result.Errors.Count > 0) return result;

        var descCol = Col("Descriptions", "Description", "Denial Description");
        var denialCountCol = Col("# of Denial", "No of Denial", "Denial Count");
        var claimCountCol = Col("# of Claims", "No of Claims", "Claim Count");
        var totalBalanceCol = Col("Total Balance ($)", "Total Balance");
        var insBalanceCol = Col("Ins. Balance ($)", "Insurance Balance", "Ins Balance");
        var impactCol = Col("$ Impact (%)", "Impact");
        var categoryCol = Col("Category", "Action Category");
        var actionCol = Col("Action");
        var feedbackCol = Col("Feedback / Response", "Feedback/Response", "Feedback");
        var responsibilityCol = Col("Responsibility");
        var discussionCol = Col("Discussion Date");
        var etaCol = Col("ETA");
        var closedCol = Col("Closed Date");

        string Text(int r, int? c) => c.HasValue ? ws.Cell(r, c.Value).GetString().Trim() : string.Empty;
        decimal Num(int r, int? c) => c.HasValue && decimal.TryParse(
            ws.Cell(r, c.Value).GetString().Replace("$", "").Replace(",", "").Replace("%", "").Trim(),
            out var d) ? d : 0m;

        DateTime? Date(int r, int? c, string columnName, string code)
        {
            if (!c.HasValue) return null;
            var cell = ws.Cell(r, c.Value);
            if (cell.IsEmpty()) return null;
            if (cell.DataType == XLDataType.DateTime) return cell.GetDateTime();

            var raw = cell.GetString().Trim();
            if (raw.Length == 0 || raw == "-") return null;
            if (DateTime.TryParse(raw, out var parsed)) return parsed;

            result.Warnings.Add($"Row {r} ({code}): \"{raw}\" in {columnName} is not a date and was left blank.");
            return null;
        }

        var lastRow = ws.LastRowUsed()?.RowNumber() ?? headerRow.RowNumber();

        for (var r = headerRow.RowNumber() + 1; r <= lastRow; r++)
        {
            var code = Text(r, codeCol);
            if (string.IsNullOrWhiteSpace(code) || code.Equals("Total", StringComparison.OrdinalIgnoreCase)) continue;

            result.Rows.Add(new DenialInsightClaimLevelRow
            {
                DenialCode = code,
                DenialCodeNormalized = DenialCodeKey.Normalize(code),
                DenialDescription = Text(r, descCol),
                PayerName = Text(r, payerCol),
                NoOfDenials = (int)Num(r, denialCountCol),
                NoOfClaims = (int)Num(r, claimCountCol),
                TotalBalance = Num(r, totalBalanceCol),
                InsuranceBalance = Num(r, insBalanceCol),
                ImpactPercentage = Num(r, impactCol),
                // Rich text, not plain: the analyst's bold and bullets are the point of these columns.
                ObservationHtml = DenialInsightRichText.FromCell(observationCol.HasValue ? ws.Cell(r, observationCol.Value) : null),
                ActionCategory = Text(r, categoryCol),
                ActionHtml = DenialInsightRichText.FromCell(actionCol.HasValue ? ws.Cell(r, actionCol.Value) : null),
                FeedbackResponse = Text(r, feedbackCol),
                Responsibility = Text(r, responsibilityCol),
                DiscussionDate = Date(r, discussionCol, "Discussion Date", code),
                Eta = Date(r, etaCol, "ETA", code),
                ClosedDate = Date(r, closedCol, "Closed Date", code)
            });
        }

        if (result.Rows.Count == 0)
            result.Errors.Add("No denial code rows were found under the header row.");

        return result;
    }
}
