using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models.Notes;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// JSON API for the generic Notes &amp; Insights component. Report pages
/// (Executive Summary, Production, LIS, Collection) drive the log through
/// these endpoints. Notes are scoped by lab (connection) + Report Name + week.
/// All persistence is delegated to <see cref="INotesRepository"/> (SPs only).
/// </summary>
[Route("Notes")]
public sealed class NotesController : Controller
{
    public static readonly string[] AllowedReports =
    [
        "Executive Summary",
        "Production Report",
        "LIS Report",
        "Collection Report"
    ];

    private readonly LabSettings _labSettings;
    private readonly INotesRepository _repo;
    private readonly INotesImportFileRepository _importFiles;
    private readonly IAnalysisRangeService _analysisRange;
    private readonly IReportSnapshotRequestQueue _snapshotRequests;
    private readonly ILogger<NotesController> _logger;

    public NotesController(LabSettings labSettings, INotesRepository repo, INotesImportFileRepository importFiles,
        IAnalysisRangeService analysisRange, IReportSnapshotRequestQueue snapshotRequests, ILogger<NotesController> logger)
    {
        _labSettings = labSettings;
        _repo = repo;
        _importFiles = importFiles;
        _analysisRange = analysisRange;
        _snapshotRequests = snapshotRequests;
        _logger = logger;
    }

    /// <summary>
    /// Asks LRN.SnapshotGenerator to capture the report's Key Insights for the week (Report Snapshots): the
    /// insights are the users' own, so a save or delete is their only trigger. Executive Summary has none.
    /// </summary>
    private Task RequestInsightSnapshotAsync(string lab, string reportName, string reason) =>
        Services.ReportSnapshots.ReportSnapshotViewContext.ReportCodes.InsightForNotesReport(reportName) is { } code
            ? _snapshotRequests.RequestAsync(lab.Trim(), code, CurrentUser, reason, CancellationToken.None)
            : Task.CompletedTask;

    private sealed record CurrentWeek(DateTime Start, DateTime End, string Text, string? RunId);

    /// <summary>Latest loaded week range of the lab (LineClaimFileLogs); null when unknown.</summary>
    private async Task<CurrentWeek?> GetCurrentWeekAsync(string cs, CancellationToken ct)
    {
        var range = await _analysisRange.GetAsync(cs, ct);
        TryParseWeekRangeText(range.WeekFolder, out var start, out var end);
        if (start is null) return null;
        var s = start.Value.Date;
        var e = (end ?? s).Date;
        if (e < s) e = s;
        var text = string.IsNullOrWhiteSpace(range.WeekFolder) ? FormatWeekText(s, e) : range.WeekFolder.Trim();
        return new CurrentWeek(s, e, text, range.RunId);
    }

    private static string FormatWeekText(DateTime s, DateTime e) =>
        s.Date == e.Date ? s.ToString("MM.dd.yyyy") : $"{s:MM.dd.yyyy} - {e:MM.dd.yyyy}";

    private string CurrentUser => User.Identity?.Name?.Trim() is { Length: > 0 } u ? u : "system";

    internal static bool TryResolveReportName(string? report, out string reportName)
    {
        reportName = "Executive Summary";
        if (string.IsNullOrWhiteSpace(report)) return true;
        var raw = report.Trim();
        var match = AllowedReports.FirstOrDefault(r => r.Equals(raw, StringComparison.OrdinalIgnoreCase));
        if (match is null)
        {
            reportName = raw;
            return false;
        }
        reportName = match;
        return true;
    }

    private bool TryResolveConnection(string? lab, out string connectionString, out string error)
    {
        connectionString = string.Empty;
        error = string.Empty;
        var labName = string.IsNullOrWhiteSpace(lab) ? string.Empty : lab.Trim();
        if (labName.Length == 0) { error = "Lab is required."; return false; }
        if (!_labSettings.Labs.TryGetValue(labName, out var config) || string.IsNullOrWhiteSpace(config.DbConnectionString))
        { error = $"No database connection configured for '{labName}'."; return false; }
        connectionString = config.DbConnectionString;
        return true;
    }

    [HttpGet("Available")]
    public async Task<IActionResult> Available(string? lab, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out _)) return Json(new { available = false });
        try
        {
            if (!await _repo.IsFeatureAvailableAsync(cs, ct)) return Json(new { available = false });
            if (!await _repo.IsWeekLifecycleEnabledAsync(cs, ct)) return Json(new { available = true, weekLifecycle = false });
            var week = await GetCurrentWeekAsync(cs, ct);
            return Json(new
            {
                available = true,
                weekLifecycle = true,
                currentWeek = week is null ? null : new
                {
                    start = week.Start.ToString("yyyy-MM-dd"),
                    end = week.End.ToString("yyyy-MM-dd"),
                    text = week.Text,
                    runId = week.RunId
                }
            });
        }
        catch { return Json(new { available = false }); }
    }

    [HttpGet("Lookups")]
    public async Task<IActionResult> Lookups(string? lab, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        try
        {
            var lookups = await _repo.GetLookupsAsync(cs, ct);
            return Json(lookups);
        }
        catch (Exception ex) { return Fail(ex, "load lookups"); }
    }

    [HttpGet("Active")]
    public async Task<IActionResult> Active(string? lab, string? report, DateTime? weekStart, string? status, string? risk, string? responsibility, string? search, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        if (!TryResolveReportName(report, out var reportName)) return BadRequest(new { error = $"Unknown report '{report}'." });
        try
        {
            var reportKeyId = await _repo.EnsureReportAsync(cs, reportName, ct);
            var archivedNow = 0;
            string? currentWeekText = null;
            if (await _repo.IsWeekLifecycleEnabledAsync(cs, ct))
            {
                var week = await GetCurrentWeekAsync(cs, ct);
                if (week is not null)
                {
                    archivedNow = await _repo.ArchivePreviousWeeksAsync(cs, reportKeyId, week.Start, week.Text, ct);
                    currentWeekText = week.Text;
                }
            }
            var rows = await _repo.GetActiveAsync(cs, reportKeyId, weekStart, status, risk, responsibility, search, ct);
            return Json(new { reportKeyId, reportName, rows, archivedNow, currentWeekText });
        }
        catch (Exception ex) { return Fail(ex, "load active notes"); }
    }

    [HttpGet("Archived")]
    public async Task<IActionResult> Archived(string? lab, string? report, string? status, string? risk, string? search, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        if (!TryResolveReportName(report, out var reportName)) return BadRequest(new { error = $"Unknown report '{report}'." });
        try
        {
            var reportKeyId = await _repo.EnsureReportAsync(cs, reportName, ct);
            var summary = await _repo.GetArchiveSummaryAsync(cs, reportKeyId, ct);
            var rows = await _repo.GetArchivedAsync(cs, reportKeyId, status, risk, search, ct);
            return Json(new { reportKeyId, reportName, summary, rows });
        }
        catch (Exception ex) { return Fail(ex, "load archived notes"); }
    }

    [HttpGet("Detail")]
    public async Task<IActionResult> Detail(string? lab, int id, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        try
        {
            var note = await _repo.GetByIdAsync(cs, id, ct);
            if (note is null) return NotFound(new { error = "Note not found." });
            return Json(note);
        }
        catch (Exception ex) { return Fail(ex, "load note detail"); }
    }

    [HttpGet("Revisions")]
    public async Task<IActionResult> Revisions(string? lab, int id, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        try
        {
            var rows = await _repo.GetRevisionHistoryAsync(cs, id, ct);
            return Json(rows);
        }
        catch (Exception ex) { return Fail(ex, "load revision history"); }
    }

    [HttpPost("Save")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string? lab, string? report, [FromBody] NoteSaveRequest? req, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        if (req is null)
        {
            var detail = ModelState.Values.SelectMany(v => v.Errors)
                .Select(e => e.ErrorMessage)
                .FirstOrDefault(m => !string.IsNullOrWhiteSpace(m));
            return BadRequest(new
            {
                error = string.IsNullOrWhiteSpace(detail)
                    ? "Missing payload."
                    : $"Invalid payload: {detail}"
            });
        }
        var reportRaw = string.IsNullOrWhiteSpace(report) ? req.ReportName : report;
        if (!TryResolveReportName(reportRaw, out var reportName)) return BadRequest(new { error = $"Unknown report '{reportRaw}'." });
        req.ReportName = reportName;
        NormalizeWeekRange(req);
        try
        {
            NotesResult result;
            if (req.NoteId is null or <= 0)
            {
                var reportKeyId = await _repo.EnsureReportAsync(cs, reportName, ct);
                result = await _repo.InsertAsync(cs, reportKeyId, req, CurrentUser, ct);
            }
            else
            {
                result = await _repo.UpdateAsync(cs, req, CurrentUser, ct);
                if (await _repo.IsWeekLifecycleEnabledAsync(cs, ct))
                    await _repo.SetWeekRangeAsync(cs, req.NoteId!.Value, req.WeekRangeStart!.Value, req.WeekRangeEnd!.Value, req.WeekRangeText, CurrentUser, ct);
            }
            if (result.Success)
                await RequestInsightSnapshotAsync(lab!, reportName, req.NoteId is null or <= 0 ? "Insight added" : "Insight edited");
            return Json(result);
        }
        catch (Exception ex) { return Fail(ex, "save note"); }
    }

    /// <summary>
    /// NotesInsight.WeekRangeStart/End are NOT NULL. When the report page has no
    /// billed-week banner (or the client sent empty dates), default to today so
    /// inserts succeed across Production / Collection / LIS / Executive Summary.
    /// </summary>
    private static void NormalizeWeekRange(NoteSaveRequest req)
    {
        DateTime? parsedStart = null;
        DateTime? parsedEnd = null;
        if (req.WeekRangeStart is null || req.WeekRangeEnd is null)
            TryParseWeekRangeText(req.WeekRangeText, out parsedStart, out parsedEnd);

        if (req.WeekRangeStart is null)
            req.WeekRangeStart = parsedStart ?? DateTime.Today;
        if (req.WeekRangeEnd is null)
            req.WeekRangeEnd = parsedEnd ?? req.WeekRangeStart;

        if (req.WeekRangeEnd < req.WeekRangeStart)
            req.WeekRangeEnd = req.WeekRangeStart;

        if (string.IsNullOrWhiteSpace(req.WeekRangeText))
        {
            var s = req.WeekRangeStart!.Value;
            var e = req.WeekRangeEnd!.Value;
            req.WeekRangeText = s.Date == e.Date
                ? s.ToString("MM.dd.yyyy")
                : $"{s:MM.dd.yyyy} - {e:MM.dd.yyyy}";
        }
    }

    /// <summary>A week range text (10.16.2026 - 10.22.2026, ...) as dates; also LRN.SnapshotGenerator's insights capture.</summary>
    public static void TryParseWeekRangeText(
        string? text, out DateTime? start, out DateTime? end)
    {
        start = null;
        end = null;
        if (string.IsNullOrWhiteSpace(text)) return;

        static DateTime? ToDate(string raw)
        {
            raw = raw.Trim();
            if (DateTime.TryParseExact(raw,
                    ["MM.dd.yyyy", "M.d.yyyy", "MM/dd/yyyy", "M/d/yyyy", "yyyy-MM-dd", "yyyy.MM.dd"],
                    System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.None, out var dt))
                return dt.Date;
            if (DateTime.TryParse(raw, System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.AllowWhiteSpaces, out dt))
                return dt.Date;
            return null;
        }

        var tokens = System.Text.RegularExpressions.Regex.Matches(
            text,
            @"\d{4}[-./]\d{1,2}[-./]\d{1,2}|\d{1,2}[./]\d{1,2}[./]\d{2,4}");
        if (tokens.Count >= 2)
        {
            start = ToDate(tokens[0].Value);
            end = ToDate(tokens[^1].Value);
            return;
        }
        if (tokens.Count == 1)
        {
            start = end = ToDate(tokens[0].Value);
            return;
        }

        var parts = System.Text.RegularExpressions.Regex.Split(text, @"\s*[-–—]\s*|\s+to\s+",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase)
            .Where(p => !string.IsNullOrWhiteSpace(p))
            .ToArray();
        if (parts.Length >= 2)
        {
            start = ToDate(parts[0]);
            end = ToDate(parts[1]);
        }
        else if (parts.Length == 1)
            start = end = ToDate(parts[0]);
    }

    [HttpPost("Delete")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(string? lab, int id, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        try
        {
            // Read first: the report it belonged to decides which insights snapshot to refresh.
            var note = await _repo.GetByIdAsync(cs, id, ct);
            var result = await _repo.DeleteAsync(cs, id, CurrentUser, ct);
            if (result.Success && note is not null)
                await RequestInsightSnapshotAsync(lab!, note.ReportName, "Insight deleted");
            return Json(result);
        }
        catch (Exception ex) { return Fail(ex, "delete note"); }
    }

    /// <summary>The report's Key Insights import workbook: its layout, limited to the template's columns.</summary>
    [HttpGet("ImportTemplate")]
    public async Task<IActionResult> ImportTemplate(string? lab, string? report, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        if (!TryResolveReportName(report, out var reportName)) return BadRequest(new { error = $"Unknown report '{report}'." });
        try
        {
            var columns = await InsightsExcelBuilder.LoadTemplateColumnsAsync(_repo, cs, reportName, ct);
            NotesLookups? lookups = null;
            try { lookups = await _repo.GetLookupsAsync(cs, ct); }
            catch (Exception ex) { _logger.LogWarning(ex, "Notes: lookups unavailable for the import template; using default statuses."); }
            var bytes = KeyInsightsImportWorkbook.BuildTemplate(reportName, columns, lookups);
            return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                KeyInsightsImportWorkbook.TemplateFileName(reportName));
        }
        catch (Exception ex) { return Fail(ex, "build the import template"); }
    }

    /// <summary>
    /// Imports a filled-in Key Insights workbook as new insights for the current week. The whole file
    /// is validated first: any row problem rejects the import and nothing is written. With
    /// <paramref name="replace"/>, the week's existing insights are deleted before the rows are added.
    /// </summary>
    [HttpPost("Import")]
    [ValidateAntiForgeryToken]
    [RequestSizeLimit(26 * 1024 * 1024)]
    public async Task<IActionResult> Import(string? lab, string? report, IFormFile? file, bool replace,
        DateTime? weekStart, DateTime? weekEnd, string? weekText, string? runId, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        if (!TryResolveReportName(report, out var reportName)) return BadRequest(new { error = $"Unknown report '{report}'." });
        if (file is null || file.Length == 0) return BadRequest(new { error = "Choose an Excel file to import." });
        var uploadError = await FileUploadGuard.ValidateExcelAsync(file, 25 * 1024 * 1024, ct);
        if (uploadError is not null) return BadRequest(new { error = uploadError });

        try
        {
            var week = new NoteSaveRequest { WeekRangeStart = weekStart, WeekRangeEnd = weekEnd, WeekRangeText = weekText, ReportRunId = runId };
            if (await _repo.IsWeekLifecycleEnabledAsync(cs, ct) && await GetCurrentWeekAsync(cs, ct) is { } current)
            {
                week.WeekRangeStart = current.Start;
                week.WeekRangeEnd = current.End;
                week.WeekRangeText = current.Text;
                week.ReportRunId ??= current.RunId;
            }
            NormalizeWeekRange(week);

            NotesLookups? lookups = null;
            try { lookups = await _repo.GetLookupsAsync(cs, ct); }
            catch (Exception ex) { _logger.LogWarning(ex, "Notes: lookups unavailable for import; using default status codes."); }

            byte[] content;
            await using (var upload = file.OpenReadStream())
            using (var buffer = new MemoryStream())
            {
                await upload.CopyToAsync(buffer, ct);
                content = buffer.ToArray();
            }

            KeyInsightsImportWorkbook.ImportResult parsed;
            try
            {
                using var stream = new MemoryStream(content, writable: false);
                parsed = KeyInsightsImportWorkbook.Parse(stream, reportName, lookups, week.WeekRangeStart!.Value);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Notes: import workbook could not be read.");
                return BadRequest(new { error = "The file could not be read as an Excel workbook (.xlsx)." });
            }
            if (parsed.Errors.Count > 0)
                return BadRequest(new { error = "Nothing was imported. Fix these rows and import again.", errors = parsed.Errors, warnings = parsed.Warnings });

            var reportKeyId = await _repo.EnsureReportAsync(cs, reportName, ct);
            var replaced = 0;
            if (replace)
            {
                var existing = await _repo.GetActiveAsync(cs, reportKeyId, ct: ct);
                foreach (var note in existing.Where(n => n.ArchiveStatus != "Archived"
                             && n.WeekRangeStart?.Date == week.WeekRangeStart!.Value.Date))
                {
                    if ((await _repo.DeleteAsync(cs, note.NoteId, CurrentUser, ct)).Success) replaced++;
                }
            }

            var imported = 0;
            var failures = new List<string>();
            foreach (var row in parsed.Rows)
            {
                row.ReportName = reportName;
                row.ReportRunId = week.ReportRunId;
                row.WeekRangeStart = week.WeekRangeStart;
                row.WeekRangeEnd = week.WeekRangeEnd;
                row.WeekRangeText = week.WeekRangeText;
                var result = await _repo.InsertAsync(cs, reportKeyId, row, CurrentUser, ct);
                if (result.Success) imported++;
                else failures.Add(result.Message ?? "Insert failed.");
            }

            var warnings = parsed.Warnings.ToList();
            if (imported > 0)
            {
                try
                {
                    await _importFiles.SaveAsync(cs, reportName, Path.GetFileName(file.FileName), file.ContentType, content,
                        week.WeekRangeText, week.WeekRangeStart, week.ReportRunId, replace ? "Replace" : "Append",
                        imported, replaced, CurrentUser, ct);
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Notes: imported workbook {File} could not be stored for {Report}.", file.FileName, reportName);
                    warnings.Add("The insights were imported, but the workbook could not be stored for download.");
                }
            }

            if (imported > 0 || replaced > 0)
                await RequestInsightSnapshotAsync(lab!, reportName, "Insights imported");
            return Json(new { imported, replaced, failed = failures.Count, errors = failures, warnings, weekText = week.WeekRangeText });
        }
        catch (Exception ex) { return Fail(ex, "import insights"); }
    }

    /// <summary>The report's imported Key Insights workbooks, newest first.</summary>
    [HttpGet("ImportFiles")]
    public async Task<IActionResult> ImportFiles(string? lab, string? report, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        if (!TryResolveReportName(report, out var reportName)) return BadRequest(new { error = $"Unknown report '{report}'." });
        try
        {
            var files = await _importFiles.ListAsync(cs, reportName, 100, ct);
            return Json(new { files });
        }
        catch (Exception ex) { return Fail(ex, "load imported files"); }
    }

    /// <summary>Downloads an imported workbook exactly as it was uploaded.</summary>
    [HttpGet("ImportFile")]
    public async Task<IActionResult> ImportFile(string? lab, int id, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        if (id <= 0) return BadRequest(new { error = "File id is required." });
        try
        {
            var file = await _importFiles.GetAsync(cs, id, ct);
            if (file is null) return NotFound(new { error = "Imported file not found." });
            return File(file.Content, file.ContentType, file.FileName);
        }
        catch (Exception ex) { return Fail(ex, "download the imported file"); }
    }

    [HttpGet("Templates")]
    public async Task<IActionResult> Templates(string? lab, string? report, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        if (!TryResolveReportName(report, out var reportName)) return BadRequest(new { error = $"Unknown report '{report}'." });
        try
        {
            var reportKeyId = await _repo.EnsureReportAsync(cs, reportName, ct);
            var templates = await _repo.GetTemplatesByReportAsync(cs, reportKeyId, ct);
            foreach (var t in templates) t.ReportName = reportName;
            return Json(new { reportKeyId, reportName, templates });
        }
        catch (Exception ex) { return Fail(ex, "load templates"); }
    }

    [HttpPost("TemplateSave")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> TemplateSave(string? lab, [FromBody] NotesTemplateSaveRequest req, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        if (req is null || string.IsNullOrWhiteSpace(req.TemplateName))
            return BadRequest(new { error = "Template name is required." });
        if (!TryResolveReportName(req.ReportName, out var reportName))
            return BadRequest(new { error = $"Unknown report '{req.ReportName}'." });
        req.ReportName = reportName;
        try
        {
            var reportKeyId = await _repo.EnsureReportAsync(cs, reportName, ct);
            var result = await _repo.UpsertTemplateAsync(cs, reportKeyId, req, CurrentUser, ct);
            return Json(result);
        }
        catch (Exception ex) { return Fail(ex, "save template"); }
    }

    [HttpPost("TemplateColumnSave")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> TemplateColumnSave(string? lab, [FromBody] NotesTemplateColumnSaveRequest req, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        if (req is null || req.TemplateId <= 0 || string.IsNullOrWhiteSpace(req.ColumnName))
            return BadRequest(new { error = "Template, column name and type are required." });
        var type = req.ColumnType?.Trim() ?? "Text";
        if (type is not ("Text" or "Date" or "Dropdown"))
            return BadRequest(new { error = "Column type must be Text, Date or Dropdown." });
        req.ColumnType = type;
        try
        {
            var result = await _repo.UpsertTemplateColumnAsync(cs, req, ct);
            return Json(result);
        }
        catch (Exception ex) { return Fail(ex, "save template column"); }
    }

    [HttpPost("TemplateColumnDelete")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> TemplateColumnDelete(string? lab, int id, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        if (id <= 0) return BadRequest(new { error = "Column id is required." });
        try
        {
            var result = await _repo.DeleteTemplateColumnAsync(cs, id, ct);
            return Json(result);
        }
        catch (Exception ex) { return Fail(ex, "delete template column"); }
    }

    private IActionResult Fail(Exception ex, string action)
    {
        _logger.LogError(ex, "Notes: failed to {Action}.", action);
        return StatusCode(500, new { error = $"Unable to {action}. {ex.Message}" });
    }
}
