using System.Security.Claims;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Async report queue endpoints backing the 📄 Reports badge.
///
/// Security model:
///  • global AuthorizeFilter — every action requires a signed-in user;
///  • every query is scoped to RequestedBy = current user (users only ever see
///    their own reports);
///  • downloads additionally require the row's DownloadToken (unguessable GUID),
///    so report IDs cannot be enumerated;
///  • files live outside the web root and are only ever streamed through
///    <see cref="Download"/> — there is no static URL to the file share.
/// </summary>
public class UserReportsController : Controller
{
    private readonly UserReportService _service;
    private readonly ILogger<UserReportsController> _logger;

    public UserReportsController(UserReportService service, ILogger<UserReportsController> logger)
    {
        _service = service;
        _logger  = logger;
    }

    private string UserName => (User.Identity?.Name ?? string.Empty).Trim();

    /// <summary>GET /UserReports — full "My Reports" page (history, error details, actions).</summary>
    [HttpGet]
    public async Task<IActionResult> Index(
        string? reportType,
        string? lab,
        string? search,
        string? sort,
        int page = 1,
        CancellationToken ct = default)
    {
        // Window large enough to realistically cover a user's whole visible history —
        // Completed/Downloaded reports expire after 7 days, so total active reports per
        // user stays small. A small cap here (previously 40/lab, 200 total) caused pages
        // to shift/disappear as new reports pushed older ones out of the fetch window on
        // every reload — this looked like "pagination is broken". Fetch once, page in memory.
        var rows = await _service.GetMyReportsAsync(UserName, ct, perLabTop: 150, totalTake: 1500);

        var reportTypes = rows
            .Select(r => r.ReportType)
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(x => x)
            .ToList();

        var labNames = rows
            .Select(r => r.LabName)
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(x => x)
            .ToList();

        // Capture before filters so the page keeps polling while a filtered-out
        // Queued/Processing report is still generating.
        var hasActive = rows.Any(r => r.Status.IsActive());

        reportType = reportType?.Trim();
        lab = lab?.Trim();
        search = search?.Trim();
        sort = string.IsNullOrWhiteSpace(sort) ? "newest" : sort.Trim().ToLowerInvariant();

        if (!string.IsNullOrWhiteSpace(reportType))
            rows = rows
                .Where(r => string.Equals(r.ReportType, reportType, StringComparison.OrdinalIgnoreCase))
                .ToList();

        if (!string.IsNullOrWhiteSpace(lab))
            rows = rows
                .Where(r => string.Equals(r.LabName, lab, StringComparison.OrdinalIgnoreCase))
                .ToList();

        if (!string.IsNullOrWhiteSpace(search))
            rows = rows
                .Where(r =>
                    r.ReportType.Contains(search, StringComparison.OrdinalIgnoreCase)
                    || r.LabName.Contains(search, StringComparison.OrdinalIgnoreCase)
                    || (!string.IsNullOrWhiteSpace(r.FileName)
                        && r.FileName.Contains(search, StringComparison.OrdinalIgnoreCase)))
                .ToList();

        rows = sort switch
        {
            "oldest" => rows.OrderBy(r => r.RequestedDate).ThenBy(r => r.ReportId).ToList(),
            "name-asc" => rows.OrderBy(r => r.ReportType, StringComparer.OrdinalIgnoreCase)
                .ThenByDescending(r => r.RequestedDate).ToList(),
            "name-desc" => rows.OrderByDescending(r => r.ReportType, StringComparer.OrdinalIgnoreCase)
                .ThenByDescending(r => r.RequestedDate).ToList(),
            "lab" => rows.OrderBy(r => r.LabName, StringComparer.OrdinalIgnoreCase)
                .ThenByDescending(r => r.RequestedDate).ToList(),
            "status" => rows.OrderBy(r => r.Status)
                .ThenByDescending(r => r.RequestedDate).ToList(),
            _ => rows.OrderByDescending(r => r.RequestedDate)
                .ThenByDescending(r => r.ReportId).ToList(),
        };

        const int pageSize = 20;
        var totalResults = rows.Count;
        var totalPages = Math.Max(1, (int)Math.Ceiling(totalResults / (double)pageSize));
        page = Math.Clamp(page, 1, totalPages);
        rows = rows.Skip((page - 1) * pageSize).Take(pageSize).ToList();

        ViewBag.ReportTypes = reportTypes;
        ViewBag.SelectedReportType = reportType ?? string.Empty;
        ViewBag.Labs = labNames;
        ViewBag.SelectedLab = lab ?? string.Empty;
        ViewBag.Search = search ?? string.Empty;
        ViewBag.Sort = sort;
        ViewBag.HasActive = hasActive;
        ViewBag.Page = page;
        ViewBag.PageSize = pageSize;
        ViewBag.TotalResults = totalResults;
        ViewBag.TotalPages = totalPages;
        return View(rows);
    }

    private int? UserId =>
        int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var id) ? id : null;

    /// <summary>POST /UserReports/Queue — creates the request; generation happens in LRN.ReportWorker.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Queue(
        [FromForm] string lab,
        [FromForm] string reportType,
        [FromForm] string? filterDetails,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(lab) || string.IsNullOrWhiteSpace(reportType))
            return BadRequest(new { message = "lab and reportType are required." });

        // Normalize/validate filters through the shared contracts — malformed JSON is
        // rejected here, never at generation time. Canonical type name is stored.
        string canonicalType;
        string? filterJson;
        try
        {
            (canonicalType, filterJson) = reportType.ToLowerInvariant() switch
            {
                "payerpolicyvalidation" => (ReportTypes.PayerPolicyValidation,
                    PayerPolicyValidationFilters.FromJson(filterDetails).ToJson()),
                "predictionanalysis" => (ReportTypes.PredictionAnalysis,
                    PredictionAnalysisFilters.FromJson(filterDetails).ToJson()),
                "forecastingsummary" => (ReportTypes.ForecastingSummary,
                    ForecastingSummaryFilters.FromJson(filterDetails).ToJson()),
                "collectionreport" => (ReportTypes.CollectionReport,
                    CollectionReportFilters.FromJson(filterDetails).ToJson()),
                "claimleveldetails" => (ReportTypes.ClaimLevelDetails,
                    ClaimLevelDetailsFilters.FromJson(filterDetails).ToJson()),
                "lineleveldetails" => (ReportTypes.LineLevelDetails,
                    LineLevelDetailsFilters.FromJson(filterDetails).ToJson()),
                "productionreport" or "productionsummary" or "productionsummaryreport" => (ReportTypes.ProductionReport,
                    ProductionReportFilters.FromJson(filterDetails).ToJson()),
                "executivesummary" => (ReportTypes.ExecutiveSummary,
                    ExecutiveSummaryFilters.FromJson(filterDetails).ToJson()),
                "revenuedashboard" or "dashboard" => (ReportTypes.RevenueDashboard,
                    RevenueDashboardFilters.FromJson(filterDetails).ToJson()),
                "clinicsummary" => (ReportTypes.ClinicSummary,
                    ClinicSalesRepSummaryFilters.FromJson(filterDetails).ToJson()),
                "salesrepsummary" => (ReportTypes.SalesRepSummary,
                    ClinicSalesRepSummaryFilters.FromJson(filterDetails).ToJson()),
                "codingsummary" => (ReportTypes.CodingSummary,
                    CodingSummaryFilters.FromJson(filterDetails).ToJson()),
                "lissummary" or "limsmaster" => (ReportTypes.LisSummary,
                    LisSummaryReportFilters.FromJson(filterDetails).ToJson()),
                "denialdashboard" or "denialreport" => (ReportTypes.DenialDashboard,
                    DenialDashboardReportFilters.FromJson(filterDetails).ToJson()),
                // Cross-lab: these two are queued against ReportQueueLabs.Master, not a real lab.
                "cptlookup" => (ReportTypes.CptLookup,
                    CptLookupReportFilters.FromJson(filterDetails).ToJson()),
                "panellookup" => (ReportTypes.PanelLookup,
                    CptLookupReportFilters.FromJson(filterDetails).ToJson()),
                _ => throw new NotSupportedException($"Unknown report type '{reportType}'."),
            };
        }
        catch (System.Text.Json.JsonException)
        {
            return BadRequest(new { message = "filterDetails is not valid JSON." });
        }
        catch (NotSupportedException ex)
        {
            return BadRequest(new { message = ex.Message });
        }

        try
        {
            var reportId = await _service.QueueAsync(
                lab, canonicalType, UserName, UserId, filterJson, ct);

            return Json(new { reportId, status = "Queued" });
        }
        catch (DuplicateReportRequestException)
        {
            return Conflict(new { message = "This report is already being generated for you. Check the Reports badge." });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 208 or 2812)
        {
            // 208 = Invalid object name (UserReqReports table missing)
            // 2812 = Could not find stored procedure (queue procs not deployed)
            _logger.LogError(ex, "Queue failed ({Lab}, {Type}) for {User}: queue objects missing.", lab, reportType, UserName);
            return StatusCode(500, new
            {
                message = $"Report queue is not set up on lab '{lab}'. Deploy SQL_Scripts/UserReqReports (01 schema + 02 procs) to that lab database, then try again.",
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Queue failed ({Lab}, {Type}) for {User}.", lab, reportType, UserName);
            return StatusCode(500, new { message = "Could not queue the report. Please try again." });
        }
    }

    /// <summary>GET /UserReports/Summary — badge + panel data (polled by _Layout).</summary>
    [HttpGet]
    public async Task<IActionResult> Summary(CancellationToken ct)
    {
        // Compact fan-out: newest-first, capped per lab — keeps the navbar panel fast.
        var rows = await _service.GetMyReportsAsync(
            UserName, ct, perLabTop: 15, totalTake: 45, newestFirst: true);
        var recentRows = rows.Take(15).ToList();

        return Json(new
        {
            // Badge counts from the recent window (panel + a bit of headroom).
            ready      = rows.Count(r => r.Status == ReportStatus.Completed),
            inProgress = rows.Count(r => r.Status.IsActive()),
            failed     = rows.Count(r => r.Status == ReportStatus.Failed),
            // Report-type breakdown (recent window) — powers the pill row in the navbar panel.
            byType = rows
                .GroupBy(r => r.ReportType)
                .Select(g => new { type = g.Key, count = g.Count() })
                .OrderByDescending(g => g.count),
            // Navbar panel: latest 15 requested; full history is on My Reports.
            reports = recentRows.Select(r => new
            {
                r.ReportId,
                r.ReportType,
                lab           = r.LabName,
                requestedDate = r.RequestedDate.ToString("MM/dd/yyyy HH:mm"),
                status        = r.Status.DisplayName(),
                statusCode    = (int)r.Status,
                fileName      = r.FileName,
                fileSizeMb    = r.FileSizeBytes is > 0 ? Math.Round(r.FileSizeBytes.Value / 1048576.0, 1) : (double?)null,
                rowCount      = r.ReportRowCount,
                expiryDate    = r.ExpiryDate?.ToString("MM/dd/yyyy"),
                progress      = r.Status == ReportStatus.Processing ? r.ProgressPercent : null,
                error         = r.Status == ReportStatus.Failed ? r.ErrorMessage : null,
                downloadUrl   = r.Status.IsDownloadable()
                    ? Url.Action(nameof(Download), new { lab = r.LabName, id = r.ReportId, token = r.DownloadToken })
                    : null,
            }),
        });
    }

    /// <summary>
    /// POST /UserReports/Download?lab=…&id=…&token=…
    /// Auth + ownership + token verified against the lab DB; file streamed
    /// (never redirected/exposed), then status → Downloaded.
    ///
    /// POST rather than GET for two reasons: a GET cannot carry an antiforgery token, and
    /// this action is not a pure read — MarkDownloadedAsync below flips the row to Downloaded
    /// and increments DownloadCount, so it must not be reachable by a cross-site request that
    /// merely causes the browser to navigate. lab/id/token still bind from the query string.
    /// Trigger it with lrnPostDownload(url) rather than a plain link.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Download(string lab, long id, Guid token, CancellationToken ct)
    {
        // Whole action wrapped — GetForDownloadAsync/GetFilePathAsync/MarkDownloadedAsync
        // are raw SQL against the LAB's own database (not LRNMaster); a transient failure,
        // timeout, or contention on that lab's DB (e.g. a large concurrent ClaimLevel/LineLevel
        // export saturating a busy lab like NorthWest) must not surface as a blank ASP.NET
        // Core error page — log the real exception and fail with a message the user can act on.
        try
        {
            var row = await _service.GetForDownloadAsync(lab, id, UserName, token, ct);
            if (row is null)
                return NotFound("Report not found, expired, or not yours.");

            var filePath = await _service.GetFilePathAsync(lab, id, UserName, token, ct);
            if (string.IsNullOrWhiteSpace(filePath))
            {
                _logger.LogWarning("Report {ReportId}: no FilePath stored in {Lab} DB.", id, lab);
                return NotFound("The report file is no longer available. Please generate it again.");
            }

            // IMPORTANT: do NOT pre-check with File.Exists — it returns FALSE both when the
            // file is genuinely gone AND when the IIS app-pool identity merely lacks folder
            // permission, which hides the real problem. Open directly and let the exception
            // type tell us which case it actually is.
            FileStream stream;
            try
            {
                stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read,
                    bufferSize: 81920, useAsync: true);
            }
            catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
            {
                // Genuinely not there AT THIS PATH from the web server's point of view.
                // If the worker runs on a different machine (or writes to a local drive the
                // web server can't see), the stored path is only valid on the WORKER's box —
                // ReportStorage:RootPath must be a shared location visible to both.
                _logger.LogError(ex,
                    "Report {ReportId}: file not found from web server at {Path} (machine {Machine}). " +
                    "If the ReportWorker runs on another machine or writes to a local-only drive, " +
                    "point ReportStorage:RootPath (worker) at a share the web server can also read.",
                    id, filePath, Environment.MachineName);
                return NotFound("The report file is no longer available. Please generate it again.");
            }
            catch (UnauthorizedAccessException ex)
            {
                // The IIS app-pool identity lacks Read permission on the storage folder
                // (the worker's service account writes fine — it's a different identity).
                _logger.LogError(ex,
                    "Report {ReportId}: IIS app pool cannot READ {Path} — grant Read to the app pool identity on the ReportStorage root.",
                    id, filePath);
                return StatusCode(500, "The report file exists but the web application does not have permission to read it. " +
                    "Ask an administrator to grant the IIS app pool Read access to the report storage folder.");
            }
            catch (IOException ex)
            {
                // e.g. file locked by another process, disk error, path too long, network share unreachable.
                _logger.LogError(ex, "Report {ReportId}: could not open {Path} for download.", id, filePath);
                return StatusCode(500, "The report file could not be opened right now. Please try again in a moment.");
            }

            // Best-effort: a failure recording the download must not block delivering the
            // file the user already successfully opened.
            try
            {
                await _service.MarkDownloadedAsync(lab, id, ct);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Report {ReportId}: could not record download timestamp (lab={Lab}).", id, lab);
            }

            return File(stream,
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                row.FileName ?? $"{row.ReportType}.xlsx");
        }
        catch (Microsoft.Data.SqlClient.SqlException ex)
        {
            _logger.LogError(ex,
                "Report {ReportId}: SQL error resolving download on lab '{Lab}' (error {Number}).",
                id, lab, ex.Number);
            return StatusCode(500,
                $"Could not reach the '{lab}' database to verify this download right now. " +
                "This can happen if a large report is currently generating for that lab. Please try again shortly.");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Report {ReportId}: unexpected error during download (lab={Lab}).", id, lab);
            return StatusCode(500, "Something went wrong preparing this download. Please try again.");
        }
    }

    /// <summary>POST /UserReports/Delete — user removes a report from their panel; file deleted immediately.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete([FromForm] string lab, [FromForm] long id, CancellationToken ct) =>
        await _service.DeleteAsync(lab, id, UserName, ct)
            ? Json(new { ok = true })
            : NotFound(new { message = "Report not found or cannot be deleted." });

    /// <summary>POST /UserReports/Retry — re-queues a Failed report.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Retry([FromForm] string lab, [FromForm] long id, CancellationToken ct) =>
        await _service.RetryAsync(lab, id, UserName, ct)
            ? Json(new { ok = true, status = "Queued" })
            : NotFound(new { message = "Report not found or is not in a failed state." });

    /// <summary>POST /UserReports/Cancel — kills a Queued or Processing report.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel([FromForm] string lab, [FromForm] long id, CancellationToken ct) =>
        await _service.CancelAsync(lab, id, UserName, ct)
            ? Json(new { ok = true, status = "Cancelled" })
            : NotFound(new { message = "Report not found or is not Queued/Processing." });
}
