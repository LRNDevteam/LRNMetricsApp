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
    private const int MonthlyPeriods = 12;
    private const int WeeklyPeriods = 4;

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
    private readonly IConfiguration _configuration;
    private readonly ILogger<DenialClaimReportController> _logger;

    public DenialClaimReportController(
        LabSettings labSettings,
        LabConfigOptions labConfig,
        IDenialClaimReportRepository repo,
        IConfiguration configuration,
        ILogger<DenialClaimReportController> logger)
    {
        _labSettings = labSettings;
        _labConfig = labConfig;
        _repo = repo;
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

    // ── The page ──────────────────────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Index(string? lab, string? tab, string? bucket,
                                           string? denialCode, string? payerName,
                                           int claimPage, int claimPageSize,
                                           CancellationToken ct)
    {
        ViewData["PageLabel"] = "Denial Claim Report";

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

        try
        {
            var groups = await _repo.GetDenialSummaryAsync(connectionString, ct);

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
            model.Weekly = DenialClaimPivotBuilder.Build(groups, weekly: true, WeeklyPeriods, loadedThrough: weekRange.LoadedThrough);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Denial Claim Report summary failed for lab {Lab}.", labName);
            model.Error = "The denial summary could not be loaded for this lab.";
        }

        try
        {
            model.Insight.Rows = await _repo.GetInsightsAsync(connectionString, model.Insight.Bucket, ct);
            model.Insight.BucketCounts = new Dictionary<string, int>(
                await _repo.GetInsightCountsAsync(connectionString, ct), StringComparer.Ordinal);
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
    /// Downloads the whole report as one workbook: Monthly Summary, Weekly Summary and Denial
    /// Insight, a sheet each, carrying the page's own colours.
    /// </summary>
    /// <remarks>
    /// Rebuilds the summaries rather than reusing whatever the last page render held, so the file
    /// is the lab's position now. The Denial Insight sheet exports the tab the user is looking at -
    /// Current or Previous Week - because that is the one they asked to download.
    /// </remarks>
    [HttpGet]
    public async Task<IActionResult> ExportWorkbook(string? lab, string? bucket, CancellationToken ct)
    {
        if (!TryResolveLab(lab, out var labName, out var connectionString, out var error))
            return Redirect(InsightError(error, lab));

        var model = new DenialClaimReportViewModel
        {
            CurrentLab = labName,
            Insight = new DenialInsightPanelViewModel
            {
                CurrentLab = labName,
                Bucket = DenialInsightBuckets.Normalize(bucket)
            }
        };

        try
        {
            var groups = await _repo.GetDenialSummaryAsync(connectionString, ct);

            // Same clamp as the page, so the exported workbook and the screen agree on the columns.
            var weekRange = await _repo.GetClaimDataWeekRangeAsync(connectionString, ct);
            model.WeekRange = weekRange.WeekFolder;
            model.RunId = weekRange.RunId;

            model.Monthly = DenialClaimPivotBuilder.Build(groups, weekly: false, MonthlyPeriods, loadedThrough: weekRange.LoadedThrough);
            model.Weekly = DenialClaimPivotBuilder.Build(groups, weekly: true, WeeklyPeriods, loadedThrough: weekRange.LoadedThrough);

            model.Insight.Rows = await _repo.GetInsightsAsync(connectionString, model.Insight.Bucket, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Denial Claim Report export failed for lab {Lab}.", labName);
            return Redirect(InsightError("The workbook could not be built for this lab.", labName));
        }

        using var workbook = DenialClaimReportExcelBuilder.Build(model);

        await using var stream = new MemoryStream();
        workbook.SaveAs(stream);

        var safeLab = string.Join("_", labName.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries));
        return File(stream.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"{safeLab}_DenialClaimReport_{DateTime.Now:yyyyMMdd}.xlsx");
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
                claims.Page, claims.PageSize, ct);

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

        try
        {
            panel.Rows = await _repo.GetInsightsAsync(connectionString, panel.Bucket, ct);
            panel.BucketCounts = new Dictionary<string, int>(
                await _repo.GetInsightCountsAsync(connectionString, ct), StringComparer.Ordinal);
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
    /// </param>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> UploadInsights(string? lab, IFormFile? insightFile,
                                                    bool replaceCurrentWeek, CancellationToken ct)
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

        var weekStart = SqlDenialClaimReportRepository.WeekStartOf(DateTime.Today);
        foreach (var row in validation.Rows)
        {
            row.Bucket = DenialInsightBuckets.Current;
            row.WeekStart = weekStart;
        }

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

    /// <summary>Saves the grid's edits. Only Current Week is editable.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveInsights(
        string? lab,
        [FromForm] long[] ids,
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
            return Redirect(InsightError("You do not have permission to edit denial insights.", lab));

        if (!TryResolveLab(lab, out var labName, out var connectionString, out var error))
            return Redirect(InsightError(error, lab));

        var existing = (await _repo.GetInsightsAsync(connectionString, DenialInsightBuckets.Current, ct))
            .ToDictionary(r => r.Id);

        var rows = new List<DenialInsightRow>();
        for (var i = 0; i < ids.Length; i++)
        {
            var id = ids[i];

            // A posted id that is not a Current Week row is ignored rather than written. Previous
            // Week is read-only, and this is the gate that enforces it against a hand-made post.
            if (!existing.TryGetValue(id, out var prior)) continue;

            rows.Add(new DenialInsightRow
            {
                Id = id,
                Bucket = prior.Bucket,
                WeekStart = prior.WeekStart,
                SortOrder = prior.SortOrder,
                DenialCode = Value(denialCodes, i, prior.DenialCode),
                PayerName = Value(payerNames, i, prior.PayerName),
                // The numeric columns come from the import and are not on the edit grid.
                DenialDescription = prior.DenialDescription,
                NoOfDenials = prior.NoOfDenials,
                TotalBalance = prior.TotalBalance,
                InsuranceBalance = prior.InsuranceBalance,
                ImpactPercentage = prior.ImpactPercentage,
                // The editors post HTML; sanitize on the way in, the same as an import does.
                ObservationHtml = DenialInsightRichText.Sanitize(observations.ElementAtOrDefault(i)),
                ActionCategory = Value(actionCategories, i, string.Empty),
                ActionHtml = DenialInsightRichText.Sanitize(actions.ElementAtOrDefault(i)),
                FeedbackResponse = feedbackResponses.ElementAtOrDefault(i) ?? string.Empty,
                Responsibility = Value(responsibilities, i, string.Empty),
                DiscussionDate = ParseDate(discussionDates.ElementAtOrDefault(i)),
                Eta = ParseDate(etas.ElementAtOrDefault(i)),
                ClosedDate = ParseDate(closedDates.ElementAtOrDefault(i))
            });
        }

        if (rows.Count == 0)
            return Redirect(InsightError("There was nothing to save.", labName));

        var result = await _repo.SaveInsightsAsync(connectionString, rows, CurrentUser, ct);
        var message = $"Saved {result.Updated + result.Inserted:N0} denial insight row(s) for {labName}."
            + (result.Errors.Count > 0 ? $" {result.Errors.Count} row(s) failed." : string.Empty);

        return Redirect(result.Errors.Count > 0 ? InsightError(message, labName) : InsightOk(message, labName));
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
        var ws = workbook.Worksheets.Add(InsightSheetName);

        for (var c = 0; c < TemplateHeaders.Length; c++)
        {
            var cell = ws.Cell(1, c + 1);
            cell.Value = TemplateHeaders[c];
            cell.Style.Font.SetBold();
        }

        var row = 2;
        var index = 1;
        foreach (var r in rows)
        {
            ws.Cell(row, 1).Value = index++;
            ws.Cell(row, 2).Value = r.DenialCode;
            ws.Cell(row, 3).Value = r.DenialDescription;
            ws.Cell(row, 4).Value = r.NoOfDenials;
            ws.Cell(row, 5).Value = r.TotalBalance;
            ws.Cell(row, 6).Value = r.PayerName;
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
        ws.Column(3).Width = 38;
        ws.Column(9).Width = 45;
        ws.Column(11).Width = 45;
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

    private const string InsightSheetName = "Denial Insight";

    /// <summary>
    /// The template's columns, in the client's own workbook order. Denial Codes and the payer are
    /// mandatory; the rest may be blank.
    /// </summary>
    private static readonly string[] TemplateHeaders =
    [
        "#", "Denial Codes", "Descriptions", "# of Denial", "Total Balance ($)",
        "Highest $ Impact - Insurance", "Ins. Balance ($)", "$ Impact (%)", "Observation", "Category",
        "Action", "Feedback / Response", "Responsibility", "Discussion Date", "ETA", "Closed Date"
    ];

    private static string Value(string[] source, int index, string fallback)
    {
        var value = source.ElementAtOrDefault(index)?.Trim();
        return string.IsNullOrWhiteSpace(value) ? fallback : value;
    }

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
        var observationCol = Col("Observation", "Observations");

        if (codeCol is null) result.Errors.Add("Mandatory column \"Denial Codes\" is missing.");
        if (payerCol is null) result.Errors.Add("Mandatory column \"Highest $ Impact - Insurance\" is missing.");
        if (observationCol is null) result.Warnings.Add("No \"Observation\" column was found; observations were left blank.");
        if (result.Errors.Count > 0) return result;

        var descCol = Col("Descriptions", "Description", "Denial Description");
        var denialCountCol = Col("# of Denial", "No of Denial", "Denial Count");
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

        // A percent-formatted Excel cell showing "57%" holds 0.57, so taking the stored number at
        // face value put 0.57 in the database and the page rendered "0.57%".
        //
        // Detecting that is fiddlier than it looks. Excel's BUILT-IN percent formats carry an empty
        // format string and only a NumberFormatId (9 = "0%", 10 = "0.00%"), so checking the format
        // text alone - which is what the first attempt at this did - never fired for the very cells
        // that needed it. Both are checked here.
        decimal Percent(int r, int? c)
        {
            if (!c.HasValue) return 0m;

            var cell = ws.Cell(r, c.Value);
            var value = Num(r, c);
            if (value == 0m) return 0m;

            var format = cell.Style.NumberFormat;
            var isPercentFormatted = format.NumberFormatId is 9 or 10
                                     || (format.Format?.Contains('%') ?? false)
                                     || cell.GetString().Contains('%');

            if (isPercentFormatted && cell.DataType == XLDataType.Number) return value * 100m;

            return DenialInsightPercent.Normalize(value);
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
                InsuranceBalance = Num(r, insBalanceCol),
                ImpactPercentage = Percent(r, impactCol),
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
