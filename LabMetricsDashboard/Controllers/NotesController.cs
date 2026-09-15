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
    private readonly ILogger<NotesController> _logger;

    public NotesController(LabSettings labSettings, INotesRepository repo, ILogger<NotesController> logger)
    {
        _labSettings = labSettings;
        _repo = repo;
        _logger = logger;
    }

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
        try { return Json(new { available = await _repo.IsFeatureAvailableAsync(cs, ct) }); }
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
            var rows = await _repo.GetActiveAsync(cs, reportKeyId, weekStart, status, risk, responsibility, search, ct);
            return Json(new { reportKeyId, reportName, rows });
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
            }
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

    private static void TryParseWeekRangeText(
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
            var result = await _repo.DeleteAsync(cs, id, CurrentUser, ct);
            return Json(result);
        }
        catch (Exception ex) { return Fail(ex, "delete note"); }
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
