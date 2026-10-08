using System.Globalization;
using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.ViewModels;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Denial Claim Report - denial reporting whose system-of-record is the lab's own claim-level data.
/// One page, three tabs: Monthly Summary, Weekly Summary and Denial Insight.
///
/// <para>The summaries are aggregated in SQL straight from <c>dbo.ClaimLevelData</c> and rendered
/// through the same pivot table the original Denial Summary page uses, so the two look and behave
/// alike. The Denial Insight tab holds the analytical layer the client imports; an insight import
/// never recalculates or overwrites claim-level data.</para>
///
/// <para>The page has no lab picker of its own. It follows the application's header lab selector,
/// resolving through <see cref="LabSelectionHelper"/> exactly as the other content pages do, so a
/// lab chosen anywhere carries onto this page and back off it.</para>
/// </summary>
[Authorize]
public sealed class DenialClaimReportController : Controller
{
    /// <summary>Periods across a pivot. Weekly is the last four weeks, per the reporting spec.</summary>
    private const int MonthlyPeriods = DenialClaimReportExcelBuilder.MonthlyPeriods;
    private const int WeeklyPeriods = DenialClaimReportExcelBuilder.WeeklyPeriods;

    /// <summary>Claim rows per page on the Claim Level tab.</summary>
    /// <summary>
    /// Claim rows per page, held to the offered sizes so a hand-edited URL cannot ask for a page
    /// big enough to pull a lab's whole claim table into memory. An unrecognised value falls back
    /// to the first offered size, which is also what the select shows.
    /// </summary>
    private static int ResolvePageSize(int requested) =>
        DenialClaimLevelTabViewModel.PageSizes.Contains(requested)
            ? requested
            : DenialClaimLevelTabViewModel.PageSizes[0];

    /// <summary>
    /// Roles allowed to import insights, copy Current Week to Previous Week, and edit insight rows.
    /// </summary>
    /// <remarks>
    /// Read from <c>DenialInsight:EditorRoles</c> so a role created through Admin &gt; Roles can be
    /// granted these actions without a code change - which is what kept new roles (Super Admin, Lab
    /// Admin, Account Manager, Client Manager) locked out of Import and Copy to Previous Week.
    /// The defaults below apply only when the setting is absent, so an existing deployment behaves
    /// as before until it opts in.
    /// <para>Matching is case- and space-insensitive: "Lab Admin", "LabAdmin" and "labadmin" are one
    /// role, because the Roles table spells them inconsistently ("Labuser" against "Lab User" in
    /// code).</para>
    /// </remarks>
    /// <remarks>
    /// Lab User is deliberately absent. It was here, which contradicted the role's own definition -
    /// "no write path at all" - and let a Lab User import workbooks and edit insight rows on this
    /// page while LRN.ReportsApi refused them every write on the Denial Workflow side. The role is
    /// view-only in both places now; ViewOnlyRoleFilter enforces it across the whole dashboard.
    /// </remarks>
    private static readonly string[] DefaultEditorRoles =
    [
        "Admin", "LRN Admin", "LRNAdmin",
        "Super Admin", "SuperAdmin",
        "Lab Admin", "LabAdmin",
        "AR Manager", "ARManager",
    ];

    private readonly LabSettings _labSettings;
    private readonly LabConfigOptions _labConfig;
    private readonly IDenialClaimReportRepository _repo;
    private readonly IDenialSummaryRepository _denialLists;
    private readonly IConfiguration _configuration;
    private readonly ILogger<DenialClaimReportController> _logger;

    public DenialClaimReportController(
        LabSettings labSettings,
        LabConfigOptions labConfig,
        IDenialClaimReportRepository repo,
        IDenialSummaryRepository denialLists,
        IConfiguration configuration,
        ILogger<DenialClaimReportController> logger)
    {
        _labSettings = labSettings;
        _labConfig = labConfig;
        _repo = repo;
        _denialLists = denialLists;
        _configuration = configuration;
        _logger = logger;
    }

    private bool IsAdmin =>
        HasRole("Admin") || HasRole("LRN Admin") || HasRole("LRNAdmin") || HasRole("Super Admin");

    private string CurrentUser => User.Identity?.Name?.Trim() is { Length: > 0 } u ? u : "system";

    /// <summary>A role key with spaces and punctuation removed, so spelling variants collapse.</summary>
    private static string RoleKey(string? value) =>
        new((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

    /// <summary>
    /// True when the signed-in user holds <paramref name="role"/>, ignoring case and spacing.
    /// <c>User.IsInRole</c> alone is case-insensitive but NOT space-insensitive, so it matches
    /// "Labuser" against "LabUser" and misses "Lab Admin" against "LabAdmin".
    /// </summary>
    private bool HasRole(string role)
    {
        if (string.IsNullOrWhiteSpace(role)) return false;

        // Exact check first: it honours the identity's own RoleClaimType, which a future auth change
        // could remap away from ClaimTypes.Role and would silently break the claim scan below.
        if (User.IsInRole(role)) return true;

        var wanted = RoleKey(role);
        if (wanted.Length == 0) return false;

        var roleClaimType = (User.Identity as System.Security.Claims.ClaimsIdentity)?.RoleClaimType
            ?? System.Security.Claims.ClaimTypes.Role;

        return User.Claims.Any(c =>
            (c.Type == roleClaimType || c.Type == System.Security.Claims.ClaimTypes.Role)
            && RoleKey(c.Value) == wanted);
    }

    private bool CanEditInsights()
    {
        var configured = _configuration.GetSection("DenialInsight:EditorRoles").Get<string[]>();
        var allowed = configured is { Length: > 0 } ? configured : DefaultEditorRoles;
        return allowed.Any(HasRole);
    }

    /// <summary>Labs this user may open - the same visibility rule the rest of the app applies.</summary>
    private List<string> VisibleLabs()
    {
        var all = _labSettings.Labs.Keys.ToList();
        var claimed = User.Claims.Where(c => c.Type == "LabName").Select(c => c.Value)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        return _labConfig.VisibleLabs(all, claimed, IsAdmin).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>
    /// Resolves the lab from the application's own selector - the <c>?lab=</c> parameter it appends,
    /// then the shared cookie, then the user's first lab - and writes the choice back so it carries
    /// to the next page.
    /// </summary>
    /// <remarks>
    /// Lab resolution is authorization, not convenience: only a lab this user can see is ever
    /// accepted, so a hand-edited <c>?lab=</c> cannot reach another lab's claims.
    /// </remarks>
    private bool TryResolveLab(string? lab, out string labName, out string connectionString, out string error)
    {
        labName = string.Empty;
        connectionString = string.Empty;
        error = string.Empty;

        var labs = VisibleLabs();
        if (labs.Count == 0) { error = "No labs are available for your account."; return false; }

        // Only a lab on the visible list is passed through; anything else falls back rather than
        // switching the user to a lab they cannot open.
        var requested = labs.FirstOrDefault(x => string.Equals(x, lab?.Trim(), StringComparison.OrdinalIgnoreCase));
        labName = LabSelectionHelper.Resolve(HttpContext, requested, labs);

        // The header selector reads this back to show which lab is active.
        ViewData["SelectedLab"] = labName;

        if (!_labSettings.Labs.TryGetValue(labName, out var config) || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            error = $"No database connection is configured for '{labName}'.";
            return false;
        }

        connectionString = config.DbConnectionString!;
        return true;
    }

    /// <summary>
    /// The lab's Denial Summary week start: LabConfig:DenialSummaryWeekRange when the lab is listed
    /// (Rising_Tides and Beech_Tree: Fri to Thu, matching their ClaimLevelData WeekFolder), else Wednesday.
    /// </summary>
    private DayOfWeek WeekStartsOnFor(string? labName)
        => _labConfig.GetDenialSummaryWeekStart(labName) ?? SqlDenialClaimReportRepository.DefaultWeekStartsOn;

    /// <summary>
    /// The ClaimLevelData column that dates the lab's denials: LabConfig:DenialSummaryDateColumn
    /// when the lab is listed (Beech_Tree: CheckDate), else null - the Denial Date.
    /// </summary>
    private string? DateColumnFor(string? labName) => _labConfig.GetDenialSummaryDateColumn(labName);

    /// <summary>
    /// The ClaimLevelData column the lab's denied balance is read from: LabConfig:DenialSummaryBalanceColumn
    /// when the lab is listed (AnalyzePathology: TotalInsuranceBalance), else null - InsuranceBalance.
    /// </summary>
    private string? BalanceColumnFor(string? labName) => _labConfig.GetDenialSummaryBalanceColumn(labName);

    // ── The page ──────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Index(string? lab, string? tab, string? bucket,
                                           string? denialCode, string? payerName,
                                           int claimPage, int claimPageSize,
                                           string? listCode,
                                           CancellationToken ct)
    {
        ViewData["PageLabel"] = "Denial Summary";

        var model = new DenialClaimReportViewModel
        {
            ActiveTab = NormalizeTab(tab),
            Insight = new DenialInsightPanelViewModel
            {
                CanEdit = CanEditInsights(),
                Bucket = DenialInsightBuckets.Normalize(bucket),
                CurrentWeekStart = SqlDenialClaimReportRepository.WeekStartOf(DateTime.Today)
            },
            Claims = new DenialClaimLevelTabViewModel
            {
                DenialCode = denialCode?.Trim(),
                PayerName = payerName?.Trim(),
                Page = claimPage <= 0 ? 1 : claimPage,
                PageSize = ResolvePageSize(claimPageSize)
            }
        };

        if (!TryResolveLab(lab, out var labName, out var connectionString, out var error))
        {
            model.Error = error;
            model.CurrentLab = labName;
            model.Insight.CurrentLab = labName;
            model.Claims.CurrentLab = labName;
            return View(model);
        }

        model.CurrentLab = labName;
        model.Insight.CurrentLab = labName;
        model.Claims.CurrentLab = labName;
        var weekStartsOn = WeekStartsOnFor(labName);
        model.Insight.CurrentWeekStart = SqlDenialClaimReportRepository.WeekStartOf(DateTime.Today, weekStartsOn);

        // Travels with the queued download: LRN.ReportWorker does not read LabConfig, so it is
        // told the lab's week here and the Weekly sheet matches the screen.
        ViewData["DenialWeekStartsOn"] = weekStartsOn.ToString();
        var dateColumn = DateColumnFor(labName);
        ViewData["DenialDateColumn"] = dateColumn;
        var balanceColumn = BalanceColumnFor(labName);
        ViewData["DenialBalanceColumn"] = balanceColumn;

        try
        {
            // Labs with Denial Summary SPs: tiles, Monthly and Weekly are computed at claim-file
            // ingest into the lab's aggregate tables and only read here.
            if (LabCollectionPrefix.HasDenialSummary(labName))
            {
                var range = await _repo.GetClaimDataWeekRangeAsync(connectionString, ct);
                model.WeekRange = range.WeekFolder;
                model.RunId = range.RunId;
                await DenialSummarySpPivot.LoadAsync(_denialLists, connectionString,
                    LabCollectionPrefix.GetPrefix(labName), model, ct);
            }
            else
            {
                var groups = await _repo.GetDenialSummaryAsync(connectionString, dateColumn, balanceColumn, ct);

                model.TotalClaims = groups.Sum(g => g.ClaimCount);
                model.TotalInsuranceBalance = groups.Sum(g => g.InsuranceBalance);
                model.DenialCodeCount = groups.Select(g => g.DenialCodeNormalized)
                    .Where(x => !string.IsNullOrWhiteSpace(x))
                    .Distinct(StringComparer.OrdinalIgnoreCase).Count();
                model.PayerCount = groups.Select(g => g.PayerName)
                    .Where(x => !string.IsNullOrWhiteSpace(x))
                    .Distinct(StringComparer.OrdinalIgnoreCase).Count();
                model.UndatedGroups = groups.Count(g => !g.DenialDate.HasValue);

                // The columns are clamped to how far ClaimLevelData is actually loaded, so the weekly
                // summary shows the four weeks the data covers rather than opening a column for a week
                // a stray denial date fell into.
                var weekRange = await _repo.GetClaimDataWeekRangeAsync(connectionString, ct);
                model.WeekRange = weekRange.WeekFolder;
                model.RunId = weekRange.RunId;

                model.Monthly = DenialClaimPivotBuilder.Build(groups, weekly: false, MonthlyPeriods, loadedThrough: weekRange.LoadedThrough);
                model.Weekly = DenialClaimPivotBuilder.Build(groups, weekly: true, WeeklyPeriods, loadedThrough: weekRange.LoadedThrough, weekStartsOn: WeekStartsOnFor(labName));
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Denial Claim Report summary failed for lab {Lab}.", labName);
            model.Error = "The denial summary could not be loaded for this lab.";
        }

        if (LabCollectionPrefix.HasDenialSummary(labName))
        {
            model.HasDenialLists = true;
            model.DenialListSearch = string.IsNullOrWhiteSpace(listCode) ? null : listCode.Trim();
            try
            {
                var prefix = LabCollectionPrefix.GetPrefix(labName);
                var noFilters = new DenialSummaryFilters();
                var allListTask = _denialLists.GetDenialListAsync(connectionString, prefix, noFilters, ct);
                var searchTask = model.DenialListSearch is null
                    ? allListTask
                    : _denialLists.GetDenialListAsync(connectionString, prefix,
                        new DenialSummaryFilters { DenialCodeSearch = model.DenialListSearch }, ct);
                var planTask = _denialLists.GetPlanTypeAsync(connectionString, prefix, noFilters, ct);
                await Task.WhenAll(allListTask, searchTask, planTask);
                model.DenialList = searchTask.Result;
                model.DenialListCodeOptions = allListTask.Result
                    .Where(r => r.RowType == "D")
                    .Select(r => r.DenialCode)
                    .ToList();
                model.PlanType = planTask.Result;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Denial List / Plan Type failed for lab {Lab}.", labName);
                model.Error ??= "The Denial List and Plan Type tabs could not be loaded for this lab.";
            }
        }
        else if (model.ActiveTab is "list" or "plantype")
        {
            model.ActiveTab = "monthly";
        }

        try
        {
            model.Insight.Rows = await _repo.GetInsightsAsync(connectionString, model.Insight.Bucket, ct);
            model.Insight.BucketCounts = new Dictionary<string, int>(
                await _repo.GetInsightCountsAsync(connectionString, ct), StringComparer.Ordinal);
            if (model.Insight.IsEditableTab)
                model.Insight.Categories = await LoadCategoriesAsync(connectionString, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Denial insights failed for lab {Lab}.", labName);
            model.Error ??= "The denial insight rows could not be loaded for this lab.";
        }

        await LoadClaimTabAsync(model.Claims, labName, connectionString, ct);

        return View(model);
    }

    /// <summary>
    /// Downloads the whole report as one workbook: Monthly Summary, Weekly Summary, Denial Insight
    /// and the Denial Claim Level rows, a sheet each.
    /// </summary>
    /// <remarks>
    /// <para>The page's Download button queues this through LRN.ReportWorker (report type
    /// DenialSummary), which streams the claim sheet. This action is the fallback the button uses
    /// when the lab has no report queue, and it builds the same four sheets.</para>
    /// <para>Rebuilds the summaries rather than reusing whatever the last page render held, so the
    /// file is the lab's position now. The Denial Insight sheet exports the tab the user is looking
    /// at - Current or Previous Week - because that is the one they asked to download.</para>
    /// </remarks>
    [HttpGet]
    public async Task<IActionResult> ExportWorkbook(string? lab, string? bucket, CancellationToken ct)
    {
        if (!TryResolveLab(lab, out var labName, out var connectionString, out var error))
            return Redirect(InsightError(error, lab));

        DenialClaimReportViewModel model;
        System.Data.DataTable? claims = null;

        try
        {
            model = await DenialClaimReportExcelBuilder.LoadAsync(
                _repo, connectionString, labName, bucket, WeekStartsOnFor(labName), DateColumnFor(labName),
                BalanceColumnFor(labName), ct);

            var claimQuery = await _repo.BuildDeniedClaimExportQueryAsync(
                connectionString, LabClaimLineColumnCatalog.GetClaimColumns(labName), BalanceColumnFor(labName), ct);
            if (claimQuery is not null)
                claims = await _repo.ReadDeniedClaimsAsync(connectionString, claimQuery, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Denial Summary export failed for lab {Lab}.", labName);
            return Redirect(InsightError("The workbook could not be built for this lab.", labName));
        }

        using var workbook = DenialClaimReportExcelBuilder.Build(model);
        DenialClaimReportExcelBuilder.AddClaimLevelSheet(workbook, claims);

        await using var stream = new MemoryStream();
        workbook.SaveAs(stream);

        var safeLab = string.Join("_", labName.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries));
        return File(stream.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"{safeLab}_DenialSummary_{DateTime.Now:yyyyMMdd}.xlsx");
    }

    /// <summary>
    /// Fills the Claim Level tab, through the same repository the Dashboard's Claim Level page uses
    /// so the columns and rows are identical.
    /// </summary>
    /// <remarks>
    /// Loaded on every request rather than only when the tab is open: the tab is a Bootstrap pane
    /// that is already in the DOM, and fetching it lazily would mean a second round trip for no
    /// benefit on a page that has already paid for the summary query.
    /// </remarks>
    private async Task LoadClaimTabAsync(
        DenialClaimLevelTabViewModel claims, string labName, string connectionString, CancellationToken ct)
    {
        // Denial reporting only ever looks at denied claims with money still outstanding, so the
        // tab carries those two filters whether or not a denial code was clicked. Without them the
        // tab would open on the lab's whole claim table, which is a different page's job.
        // The same per-lab column set the Dashboard's Claim Level page shows.
        var columns = LabClaimLineColumnCatalog.GetClaimColumns(labName);
        claims.DisplayColumns = columns;

        try
        {
            var result = await _repo.GetClaimRowsAsync(
                connectionString, columns, claims.DenialCode, claims.PayerName,
                claims.Page, claims.PageSize, BalanceColumnFor(labName), ct);

            claims.Rows = result.Rows;
            claims.TotalFiltered = result.TotalFiltered;
            claims.TotalAll = result.TotalAll;
            claims.Diagnosis = result.Diagnosis;

            if (result.Diagnosis is { } d)
            {
                // Logged as well as shown: an empty drill-through is the kind of thing a user
                // reports days later, by which time the screen is gone.
                _logger.LogWarning(
                    "Claim Level tab for lab {Lab} returned nothing. Code '{Code}' matched {CodeRows} row(s); "
                    + "insurance '{Payer}' matched {PayerRows}; {Normalized} row(s) carry DenialCodeNormalized. "
                    + "Insurances on the matching claims: {Samples}",
                    labName, claims.DenialCode, d.MatchingCode, claims.PayerName, d.MatchingPayer,
                    d.NormalizedPopulated, string.Join(", ", d.SamplePayers));
            }

            if (result.Columns.Count > 0) claims.DisplayColumns = result.Columns;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Claim Level tab failed for lab {Lab}.", labName);
            claims.Error = "The claim-level rows could not be loaded for this lab.";
        }
    }

    // ── AJAX panels ───────────────────────────────────────────────────────────

    /// <summary>
    /// The Denial Insight panel on its own, for switching Current/Previous Week without reloading
    /// the page. The full page action serves the same content, so the links still work with
    /// JavaScript off.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> InsightPanel(string? lab, string? bucket, CancellationToken ct)
    {
        var panel = new DenialInsightPanelViewModel
        {
            CanEdit = CanEditInsights(),
            Bucket = DenialInsightBuckets.Normalize(bucket),
            CurrentWeekStart = SqlDenialClaimReportRepository.WeekStartOf(DateTime.Today)
        };

        if (!TryResolveLab(lab, out var labName, out var connectionString, out var error))
        {
            panel.CurrentLab = labName;
            return PartialView("_DenialInsightPanel", panel);
        }

        panel.CurrentLab = labName;
        panel.CurrentWeekStart = SqlDenialClaimReportRepository.WeekStartOf(DateTime.Today, WeekStartsOnFor(labName));

        try
        {
            panel.Rows = await _repo.GetInsightsAsync(connectionString, panel.Bucket, ct);
            panel.BucketCounts = new Dictionary<string, int>(
                await _repo.GetInsightCountsAsync(connectionString, ct), StringComparer.Ordinal);
            if (panel.IsEditableTab)
                panel.Categories = await LoadCategoriesAsync(connectionString, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Denial insight panel failed for lab {Lab}.", labName);
        }

        return PartialView("_DenialInsightPanel", panel);
    }

    /// <summary>The Claim Level panel on its own, for filtering and paging without a page reload.</summary>
    [HttpGet]
    public async Task<IActionResult> ClaimsPanel(string? lab, string? denialCode, string? payerName,
                                                 int claimPage, int claimPageSize, CancellationToken ct)
    {
        var claims = new DenialClaimLevelTabViewModel
        {
            DenialCode = denialCode?.Trim(),
            PayerName = payerName?.Trim(),
            Page = claimPage <= 0 ? 1 : claimPage,
            PageSize = ResolvePageSize(claimPageSize)
        };

        if (!TryResolveLab(lab, out var labName, out var connectionString, out var error))
        {
            claims.CurrentLab = labName;
            claims.Error = error;
            return PartialView("_DenialClaimLevelTab", claims);
        }

        claims.CurrentLab = labName;
        await LoadClaimTabAsync(claims, labName, connectionString, ct);

        return PartialView("_DenialClaimLevelTab", claims);
    }

    private static string NormalizeTab(string? tab) => tab?.Trim().ToLowerInvariant() switch
    {
        "weekly" => "weekly",
        "list" => "list",
        "plantype" => "plantype",
        "insight" => "insight",
        "claims" => "claims",
        _ => "monthly"
    };

    // ── Denial Insight: import, edit, delete, copy, export ────────────────────

    /// <summary>
    /// Imports the client's Denial Insight workbook into Current Week. The file is validated in full
    /// BEFORE anything is written: a missing mandatory column or an unreadable date is reported back
    /// and nothing is committed, rather than leaving the table half-updated.
    /// </summary>
    /// <param name="replaceCurrentWeek">
    /// What happens to the insights already on Current Week.
    /// <list type="bullet">
    ///   <item><b>true</b> - they are discarded and the workbook replaces them. This is a correction
    ///   to the week in progress.</item>
    ///   <item><b>false</b> - they roll forward into Previous Week and the workbook becomes the new
    ///   Current Week. This is the weekly cycle, and it is the default because it loses nothing.</item>
    /// </list>
    /// Ignored when <paramref name="bucket"/> is Previous Week.
    /// </param>
    /// <param name="bucket">Which tab the workbook is being imported into - Current or Previous.</param>
    /// <param name="previousMode">
    /// Previous Week only: <b>append</b> (the default) keeps the rows already there and adds the
    /// workbook beside them; <b>override</b> empties Previous Week first. A back-dated week is
    /// normally being topped up rather than rewritten, so append is what an unanswered choice means.
    /// </param>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> UploadInsights(string? lab, IFormFile? insightFile,
                                                    bool replaceCurrentWeek, string? bucket,
                                                    string? previousMode, CancellationToken ct)
    {
        if (!CanEditInsights())
            return Redirect(InsightError("You do not have permission to import denial insights.", lab));

        if (!TryResolveLab(lab, out var labName, out var connectionString, out var error))
            return Redirect(InsightError(error, lab));

        if (insightFile is null || insightFile.Length == 0)
            return Redirect(InsightError("Please choose an Excel file to import.", labName));

        var uploadError = await FileUploadGuard.ValidateExcelAsync(insightFile, 25 * 1024 * 1024, ct);
        if (uploadError != null) return Redirect(InsightError(uploadError, labName));

        DenialInsightValidationResult validation;
        try
        {
            validation = ValidateInsightWorkbook(insightFile);
        }
        catch (Exception ex)
        {
            return Redirect(InsightError($"Import failed: {ex.Message}", labName));
        }

        if (!validation.IsValid)
        {
            return Redirect(InsightError(
                "The workbook does not match the Denial Insight template, so nothing was imported. "
                + string.Join(" ", validation.Errors.Take(5))
                + (validation.Errors.Count > 5 ? $" (+{validation.Errors.Count - 5} more)" : string.Empty),
                labName));
        }

        var targetBucket = DenialInsightBuckets.Normalize(bucket);
        var intoPrevious = targetBucket == DenialInsightBuckets.Previous;

        // Previous Week rows are dated to the week before the one in progress, not to today, or the
        // import would file last week's discussion under this week and land in the wrong group.
        var weekStart = SqlDenialClaimReportRepository.WeekStartOf(DateTime.Today, WeekStartsOnFor(labName));
        if (intoPrevious) weekStart = weekStart.AddDays(-7);

        foreach (var row in validation.Rows)
        {
            row.Bucket = targetBucket;
            row.WeekStart = weekStart;
        }

        if (intoPrevious)
            return await ImportIntoPreviousWeekAsync(
                connectionString, labName, validation, previousMode, weekStart, ct);

        try
        {
            // Either way Current Week ends up holding only the workbook: it is the client's whole
            // picture for the week, so a denial that has dropped out of it must disappear rather
            // than linger from the previous upload. The two modes differ in what happens to the
            // insights that were there - discarded, or rolled forward into Previous Week.
            string outcome;

            if (replaceCurrentWeek)
            {
                var cleared = await _repo.ClearBucketAsync(connectionString, DenialInsightBuckets.Current, ct);
                outcome = cleared > 0
                    ? $" The {cleared:N0} row(s) previously on Current Week were replaced."
                    : string.Empty;
            }
            else
            {
                var rolled = await _repo.RollCurrentToPreviousAsync(connectionString, CurrentUser, ct);
                outcome = rolled.RolledToPrevious > 0
                    ? $" The {rolled.RolledToPrevious:N0} row(s) previously on Current Week moved to Previous Week."
                      + (rolled.Archived > 0
                          ? $" {rolled.Archived:N0} row(s) older than {DenialInsightBuckets.PreviousWeeksRetained} weeks moved to Archive."
                          : string.Empty)
                    : string.Empty;
            }

            var result = await _repo.SaveInsightsAsync(connectionString, validation.Rows, CurrentUser, ct);

            var message = $"Imported {result.Inserted + result.Updated:N0} row(s) into Current Week for {labName}."
                + outcome
                + (result.Skipped > 0 ? $" {result.Skipped:N0} row(s) had no denial code and were skipped." : string.Empty)
                + (result.Errors.Count > 0 ? $" {result.Errors.Count:N0} row(s) failed." : string.Empty)
                + (validation.Warnings.Count > 0 ? " " + string.Join(" ", validation.Warnings.Take(3)) : string.Empty);

            return Redirect(result.Errors.Count > 0 ? InsightError(message, labName) : InsightOk(message, labName));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Denial insight import failed for lab {Lab}.", labName);
            return Redirect(InsightError("The import failed and nothing was saved.", labName));
        }
    }

    /// <summary>
    /// The Previous Week half of <see cref="UploadInsights"/>: the client sends a back-dated week
    /// late, or sends more of a week already loaded.
    /// </summary>
    /// <remarks>
    /// Unlike Current Week, neither mode rolls anything forward - Previous Week is the end of the
    /// line, so there is nowhere for its rows to go. Append leaves every other week there untouched
    /// and upserts on (week, denial code, payer), so re-sending a corrected workbook refreshes those
    /// rows instead of stacking a second copy of them. Override empties the whole tab first, every
    /// retained week of it, which is why the panel says so and the button is red.
    /// </remarks>
    private async Task<IActionResult> ImportIntoPreviousWeekAsync(
        string connectionString, string labName, DenialInsightValidationResult validation,
        string? previousMode, DateTime weekStart, CancellationToken ct)
    {
        var overwrite = string.Equals(previousMode, "override", StringComparison.OrdinalIgnoreCase);

        try
        {
            var outcome = string.Empty;

            if (overwrite)
            {
                var cleared = await _repo.ClearBucketAsync(connectionString, DenialInsightBuckets.Previous, ct);
                outcome = cleared > 0
                    ? $" The {cleared:N0} row(s) previously on Previous Week were deleted first."
                    : string.Empty;
            }

            var result = await _repo.SaveInsightsAsync(connectionString, validation.Rows, CurrentUser, ct);

            var message =
                $"Imported {result.Inserted + result.Updated:N0} row(s) into Previous Week "
                + $"({DenialInsightBuckets.WeekRangeLabel(weekStart)}) for {labName}."
                + outcome
                + (!overwrite && result.Updated > 0
                    ? $" {result.Updated:N0} row(s) already in that week were refreshed."
                    : string.Empty)
                + (result.Skipped > 0 ? $" {result.Skipped:N0} row(s) had no denial code and were skipped." : string.Empty)
                + (result.Errors.Count > 0 ? $" {result.Errors.Count:N0} row(s) failed." : string.Empty)
                + (validation.Warnings.Count > 0 ? " " + string.Join(" ", validation.Warnings.Take(3)) : string.Empty);

            return Redirect(result.Errors.Count > 0
                ? InsightError(message, labName, DenialInsightBuckets.Previous)
                : InsightOk(message, labName, DenialInsightBuckets.Previous));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Denial insight import into Previous Week failed for lab {Lab}.", labName);
            return Redirect(InsightError("The import failed and nothing was saved.", labName,
                                         DenialInsightBuckets.Previous));
        }
    }

    /// <summary>The Category dropdown: the lab's stored categories, or the standard set when it has none.</summary>
    private async Task<IReadOnlyList<string>> LoadCategoriesAsync(string connectionString, CancellationToken ct)
    {
        var stored = await _repo.GetInsightCategoriesAsync(connectionString, ct);
        return stored.Count > 0 ? stored : DenialInsightPanelViewModel.DefaultCategories;
    }

    /// <summary>
    /// Saves one row from the grid's row-level Edit. Only Current Week is editable.
    /// </summary>
    /// <remarks>
    /// Editable / non-editable follows docs/DenialSummary_EditableColumns.xlsx. Denial Codes and
    /// Highest Impact - Insurance are not editable: they are the row's identity (and the claim
    /// drill-through), so they are taken from the stored row and anything posted for them is
    /// ignored. Data is marked Remove - it is not on the grid and keeps what the import stored.
    /// </remarks>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveInsightRow(
        string? lab,
        [FromForm] long id,
        [FromForm] string? denialDescription,
        [FromForm] string? noOfDenials,
        [FromForm] string? totalBalance,
        [FromForm] string? insuranceNoOfDenials,
        [FromForm] string? insuranceBalance,
        [FromForm] string? impactPercentage,
        [FromForm] string? observation,
        [FromForm] string? actionCategory,
        [FromForm] string? action,
        [FromForm] string? feedbackResponse,
        [FromForm] string? responsibility,
        [FromForm] string? discussionDate,
        [FromForm] string? eta,
        [FromForm] string? closedDate,
        [FromForm] string? status,
        CancellationToken ct)
    {
        if (!CanEditInsights())
            return Redirect(InsightError("You do not have permission to edit denial insights.", lab));

        if (!TryResolveLab(lab, out var labName, out var connectionString, out var error))
            return Redirect(InsightError(error, lab));

        // An id that is not a Current Week row is refused rather than written. Previous Week is
        // read-only, and this is the gate that enforces it against a hand-made post.
        var prior = (await _repo.GetInsightsAsync(connectionString, DenialInsightBuckets.Current, ct))
            .FirstOrDefault(r => r.Id == id);
        if (prior is null)
            return Redirect(InsightError("That insight row no longer exists on Current Week.", labName));

        var code = prior.DenialCode;

        var row = new DenialInsightRow
        {
            Id = prior.Id,
            Bucket = prior.Bucket,
            WeekStart = prior.WeekStart,
            SortOrder = prior.SortOrder,
            // Not editable: from the stored row, never from the post.
            DenialCode = prior.DenialCode,
            DenialCodeNormalized = prior.DenialCodeNormalized,
            PayerName = prior.PayerName,
            DenialDescription = denialDescription?.Trim() ?? string.Empty,
            NoOfDenials = (int)ParseNumber(noOfDenials),
            TotalBalance = ParseNumber(totalBalance),
            InsuranceNoOfDenials = (int)ParseNumber(insuranceNoOfDenials),
            InsuranceBalance = ParseNumber(insuranceBalance),
            ImpactPercentage = impactPercentage?.Trim() ?? string.Empty,
            // The editors post HTML; sanitize on the way in, the same as an import does.
            ObservationHtml = DenialInsightRichText.Sanitize(observation),
            Data = prior.Data,
            ActionCategory = actionCategory?.Trim() ?? string.Empty,
            ActionHtml = DenialInsightRichText.Sanitize(action),
            FeedbackResponse = feedbackResponse ?? string.Empty,
            Responsibility = responsibility?.Trim() ?? string.Empty,
            DiscussionDate = ParseDate(discussionDate),
            Eta = ParseDate(eta),
            ClosedDate = ParseDate(closedDate),
            Status = status?.Trim() ?? string.Empty
        };

        var result = await _repo.SaveInsightsAsync(connectionString, [row], CurrentUser, ct);

        return Redirect(result.Errors.Count > 0
            ? InsightError($"Row {code} could not be saved.", labName)
            : InsightOk($"Saved denial insight row {code}.", labName));
    }

    /// <summary>Deletes one insight row.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteInsight(string? lab, long id, string? bucket, CancellationToken ct)
    {
        if (!CanEditInsights())
            return Redirect(InsightError("You do not have permission to delete denial insights.", lab, bucket));

        if (!TryResolveLab(lab, out var labName, out var connectionString, out var error))
            return Redirect(InsightError(error, lab, bucket));

        try
        {
            var deleted = await _repo.DeleteInsightAsync(connectionString, id, ct);

            return Redirect(deleted
                ? InsightOk("Insight row deleted.", labName, bucket)
                : InsightError("That insight row no longer exists - it may already have been deleted.", labName, bucket));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Denial insight row {Id} could not be deleted for lab {Lab}.", id, labName);
            return Redirect(InsightError("The insight row could not be deleted.", labName, bucket));
        }
    }

    /// <summary>
    /// Replaces Previous Week with a copy of Current Week. The confirmation the requirements ask for
    /// is in the view; this action runs only once the user has confirmed.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CopyToPreviousWeek(string? lab, CancellationToken ct)
    {
        if (!CanEditInsights())
            return Redirect(InsightError("You do not have permission to move denial insights.", lab));

        if (!TryResolveLab(lab, out var labName, out var connectionString, out var error))
            return Redirect(InsightError(error, lab));

        try
        {
            var copied = await _repo.CopyCurrentToPreviousAsync(connectionString, CurrentUser, ct);

            return Redirect(copied == 0
                ? InsightError("There were no Current Week insights to copy.", labName)
                : InsightOk($"Copied {copied:N0} insight row(s) to Previous Week. Current Week is unchanged.",
                            labName, DenialInsightBuckets.Previous));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Copy to Previous Week failed for lab {Lab}.", labName);
            return Redirect(InsightError("The insights could not be copied to Previous Week. Nothing was changed.", labName));
        }
    }

    /// <summary>Downloads the open tab as the Denial Insight template, in the shape the import expects.</summary>
    [HttpGet]
    public async Task<IActionResult> ExportInsights(string? lab, string? bucket, CancellationToken ct)
    {
        if (!TryResolveLab(lab, out var labName, out var connectionString, out var error))
            return Redirect(InsightError(error, lab));

        var tab = DenialInsightBuckets.Normalize(bucket);
        var rows = await _repo.GetInsightsAsync(connectionString, tab, ct);

        using var workbook = new XLWorkbook();
        var ws = workbook.Worksheets.Add(DenialInsightTemplate.SheetName);

        // The client's template exactly - header on row 1, data from row 2, same merges - so the
        // file can be filled in and imported straight back.
        DenialInsightTemplate.WriteHeader(ws, 1);

        var row = 2;
        var index = 1;
        foreach (var r in rows)
            DenialInsightTemplate.WriteRow(ws, row++, index++, r);

        if (row > 2)
        {
            var body = ws.Range(1, 1, row - 1, DenialInsightTemplate.LastColumn);
            body.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            body.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        }

        DenialInsightTemplate.SizeColumns(ws);
        ws.SheetView.FreezeRows(1);

        await using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        var safeLab = string.Join("_", labName.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries));
        return File(stream.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"{safeLab}_DenialInsight_{tab}Week_{DateTime.Now:yyyyMMdd}.xlsx");
    }

    // ── Redirect helpers ──────────────────────────────────────────────────────

    private string InsightOk(string message, string? lab, string? bucket = null)
    {
        TempData["DenialClaimReportSuccess"] = message;
        return InsightUrl(lab, bucket);
    }

    private string InsightError(string message, string? lab, string? bucket = null)
    {
        TempData["DenialClaimReportError"] = message;
        return InsightUrl(lab, bucket);
    }

    /// <summary>Back to the page with the Denial Insight tab open, on the sub-tab that was in use.</summary>
    private string InsightUrl(string? lab, string? bucket) =>
        Url.Action(nameof(Index), new
        {
            lab,
            tab = "insight",
            bucket = DenialInsightBuckets.Normalize(bucket)
        }) ?? "/DenialClaimReport";

    /// <summary>A number typed into the row editor; "$1,234.50" and "1234.5" both read, blank is 0.</summary>
    private static decimal ParseNumber(string? value) =>
        decimal.TryParse((value ?? string.Empty).Replace("$", "").Replace(",", "").Trim(),
                         NumberStyles.Number, CultureInfo.InvariantCulture, out var d) ? d : 0m;

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
            result.Errors.Add("No \"Denial Codes\" column was found in any sheet - this does not look like the Denial Insight template.");
            return result;
        }

        var ws = headerRow.Worksheet;

        // Merged header groups store their text only in the left-most cell, which is where that
        // field's data starts - so matching on header text lands on the right column either way.
        // Every column a header appears in, left to right: the v1.0 template carries "# of Denials"
        // twice, so keeping only the first occurrence would lose the insurance-level count.
        var headers = headerRow.CellsUsed()
            .Select(c => new { Name = Key(c.GetString()), Column = c.Address.ColumnNumber })
            .Where(x => x.Name.Length > 0)
            .GroupBy(x => x.Name, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(x => x.Key, x => x.Select(y => y.Column).OrderBy(c => c).ToList(), StringComparer.OrdinalIgnoreCase);

        int? Col(params string[] names) => names.Select(Key)
            .Select(n => headers.TryGetValue(n, out var c) ? c[0] : (int?)null)
            .FirstOrDefault(c => c.HasValue);

        List<int> Cols(params string[] names) => names.Select(Key).Distinct()
            .SelectMany(n => headers.TryGetValue(n, out var c) ? c : new List<int>())
            .Distinct().OrderBy(c => c).ToList();

        var codeCol = Col("Denial Codes", "Denial Code");
        var payerCol = Col("Highest Impact - Insurance", "Highest $ Impact - Insurance", "Insurance", "Payer Name", "Payer");
        var observationCol = Col("Observation", "Observations");

        if (codeCol is null) result.Errors.Add("Mandatory column \"Denial Codes\" is missing.");
        if (payerCol is null) result.Errors.Add("Mandatory column \"Highest Impact - Insurance\" is missing.");
        if (observationCol is null) result.Warnings.Add("No \"Observation\" column was found; observations were left blank.");
        if (result.Errors.Count > 0) return result;

        // "# of Denials" left of the insurance is the code's total; the one right of it, inside the
        // impact group, is that insurance's own count. A pre-v1.0 workbook has only the first.
        var denialCountCols = Cols("# of Denials", "# of Denial", "No of Denials", "No of Denial", "Denial Count");
        int? denialCountCol = denialCountCols.Where(c => c < payerCol).Select(c => (int?)c).FirstOrDefault();
        int? insDenialCountCol = Col("Ins. # of Denials", "Insurance # of Denials", "Ins # of Denials")
            ?? denialCountCols.Where(c => c > payerCol).Select(c => (int?)c).FirstOrDefault();

        var descCol = Col("Descriptions", "Description", "Denial Description");
        var totalBalanceCol = Col("Total Balance ($)", "Total Balance");
        var insBalanceCol = Col("Ins. Balance ($)", "Insurance Balance", "Ins Balance");
        var impactCol = Col("$ Impact (%)", "Impact");
        var dataCol = Col("Data");
        // "Catergory" is how the v1.0 template spells it.
        var categoryCol = Col("Category", "Catergory", "Action Category");
        var actionCol = Col("Action");
        var feedbackCol = Col("Feedback / Response", "Feedback/Response", "Feedback");
        var responsibilityCol = Col("Responsibility");
        var discussionCol = Col("Discussion Date");
        var etaCol = Col("ETA");
        var closedCol = Col("Closed Date");
        var statusCol = Col("Status");

        string Text(int r, int? c) => c.HasValue ? ws.Cell(r, c.Value).GetString().Trim() : string.Empty;
        decimal Num(int r, int? c) => c.HasValue && decimal.TryParse(
            ws.Cell(r, c.Value).GetString().Replace("$", "").Replace(",", "").Replace("%", "").Trim(),
            out var d) ? d : 0m;

        // "$ Impact (%)" is taken as the text the cell DISPLAYS - "57%" stays "57%" - and is not
        // validated. Reading it as a number kept misreading percent-formatted and pasted cells.
        string DisplayedText(int r, int? c)
        {
            if (!c.HasValue) return string.Empty;
            var cell = ws.Cell(r, c.Value);
            if (cell.IsEmpty()) return string.Empty;

            try { return cell.GetFormattedString().Trim(); }
            catch { return cell.GetString().Trim(); }
        }

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
        var order = 0;

        for (var r = headerRow.RowNumber() + 1; r <= lastRow; r++)
        {
            var code = Text(r, codeCol);
            if (string.IsNullOrWhiteSpace(code)) continue;

            // The client's workbook carries a "Previously Discussed Items" banner mid-sheet and a
            // Total row at the end. Neither is a denial, and both would otherwise import as one.
            if (code.Equals("Total", StringComparison.OrdinalIgnoreCase)
                || code.Contains("Previously Discussed", StringComparison.OrdinalIgnoreCase)) continue;

            order++;
            result.Rows.Add(new DenialInsightRow
            {
                SortOrder = order,
                DenialCode = code,
                DenialCodeNormalized = DenialCodeKey.Normalize(code),
                DenialDescription = Text(r, descCol),
                PayerName = Text(r, payerCol),
                NoOfDenials = (int)Num(r, denialCountCol),
                TotalBalance = Num(r, totalBalanceCol),
                InsuranceNoOfDenials = (int)Num(r, insDenialCountCol),
                InsuranceBalance = Num(r, insBalanceCol),
                // An impossible (> 100%) cell is recomputed from the balances; anything else is kept as shown.
                ImpactPercentage = DenialInsightPercent.DisplayText(DisplayedText(r, impactCol), Num(r, insBalanceCol), Num(r, totalBalanceCol)),
                // Rich text, not plain: the analyst's bold and bullets are the point of these columns.
                ObservationHtml = DenialInsightRichText.FromCell(observationCol.HasValue ? ws.Cell(r, observationCol.Value) : null),
                // Stored but not shown on the grid, and never validated.
                Data = Text(r, dataCol),
                ActionCategory = Text(r, categoryCol),
                ActionHtml = DenialInsightRichText.FromCell(actionCol.HasValue ? ws.Cell(r, actionCol.Value) : null),
                FeedbackResponse = Text(r, feedbackCol),
                Responsibility = Text(r, responsibilityCol),
                DiscussionDate = Date(r, discussionCol, "Discussion Date", code),
                Eta = Date(r, etaCol, "ETA", code),
                ClosedDate = Date(r, closedCol, "Closed Date", code),
                Status = Text(r, statusCol)
            });
        }

        if (result.Rows.Count == 0)
            result.Errors.Add("No denial code rows were found under the header row.");

        return result;
    }
}
