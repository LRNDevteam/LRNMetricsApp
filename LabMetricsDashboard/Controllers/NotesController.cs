using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models.Notes;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// JSON API for the generic Notes &amp; Insights component. The Executive
/// Summary page (and any future report page) drives its Notes callout,
/// active log, archive, detail modal and revision history through these
/// endpoints. Notes are scoped by lab (connection) + Report Name + week.
///
/// All persistence is delegated to <see cref="INotesRepository"/>, which
/// invokes stored procedures only.
/// </summary>
[Route("Notes")]
public sealed class NotesController : Controller
{
    private const string ReportName = "Executive Summary";
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

    // GET /Notes/Available?lab=Cove  → { available: true|false }
    // The feature is only enabled on lab databases where the Insights schema exists.
    [HttpGet("Available")]
    public async Task<IActionResult> Available(string? lab, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out _)) return Json(new { available = false });
        try { return Json(new { available = await _repo.IsFeatureAvailableAsync(cs, ct) }); }
        catch { return Json(new { available = false }); }
    }

    // GET /Notes/Lookups?lab=Cove
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

    // GET /Notes/Active?lab=Cove&status=&risk=&search=
    [HttpGet("Active")]
    public async Task<IActionResult> Active(string? lab, DateTime? weekStart, string? status, string? risk, string? responsibility, string? search, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        try
        {
            var reportKeyId = await _repo.EnsureReportAsync(cs, ReportName, ct);
            var rows = await _repo.GetActiveAsync(cs, reportKeyId, weekStart, status, risk, responsibility, search, ct);
            return Json(new { reportKeyId, rows });
        }
        catch (Exception ex) { return Fail(ex, "load active notes"); }
    }

    // GET /Notes/Archived?lab=Cove&status=&risk=&search=
    [HttpGet("Archived")]
    public async Task<IActionResult> Archived(string? lab, string? status, string? risk, string? search, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        try
        {
            var reportKeyId = await _repo.EnsureReportAsync(cs, ReportName, ct);
            var summary = await _repo.GetArchiveSummaryAsync(cs, reportKeyId, ct);
            var rows = await _repo.GetArchivedAsync(cs, reportKeyId, status, risk, search, ct);
            return Json(new { reportKeyId, summary, rows });
        }
        catch (Exception ex) { return Fail(ex, "load archived notes"); }
    }

    // GET /Notes/Detail?lab=Cove&id=123
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

    // GET /Notes/Revisions?lab=Cove&id=123
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

    // POST /Notes/Save?lab=Cove  (body = NoteSaveRequest). Insert when NoteId null, else update.
    [HttpPost("Save")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string? lab, [FromBody] NoteSaveRequest req, CancellationToken ct)
    {
        if (!TryResolveConnection(lab, out var cs, out var err)) return BadRequest(new { error = err });
        if (req is null) return BadRequest(new { error = "Missing payload." });
        req.ReportName = ReportName;
        try
        {
            NotesResult result;
            if (req.NoteId is null or <= 0)
            {
                var reportKeyId = await _repo.EnsureReportAsync(cs, ReportName, ct);
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

    // POST /Notes/Delete?lab=Cove&id=123
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

    private IActionResult Fail(Exception ex, string action)
    {
        _logger.LogError(ex, "Notes: failed to {Action}.", action);
        return StatusCode(500, new { error = $"Unable to {action}. {ex.Message}" });
    }
}
