using System.Globalization;
using System.IO.Compression;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.Services.RevenueAnalysis;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Revenue Analysis - the report team's client dashboard (Overview, Trends, Payer, Panel &amp; Billing,
/// CPT, Clinic &amp; Provider, Claim Status, Denial, Source Data) generated from a lab's own Claim Level
/// and Line Level data, live from the lab database or from a weekly snapshot.
/// <para><b>Index</b> is the launcher inside the application: pick the source and DOS window, build,
/// then open each page in its own window (<b>Page</b>, deep-linked by #hash) or download the whole
/// dashboard as one self-contained HTML file for the client.</para>
/// <para>Lab resolution is authorization: only a lab the user can see is accepted, and a stored
/// dashboard is served only to users who can see its lab.</para>
/// </summary>
[Authorize]
public sealed class RevenueAnalysisController : Controller
{
    private readonly LabSettings _labSettings;
    private readonly LabConfigOptions _labConfig;
    private readonly IRevenueAnalysisService _service;
    private readonly IMasterDataSnapshotRepository _snapshots;
    private readonly ILogger<RevenueAnalysisController> _logger;

    public RevenueAnalysisController(
        LabSettings labSettings,
        LabConfigOptions labConfig,
        IRevenueAnalysisService service,
        IMasterDataSnapshotRepository snapshots,
        ILogger<RevenueAnalysisController> logger)
    {
        _labSettings = labSettings;
        _labConfig = labConfig;
        _service = service;
        _snapshots = snapshots;
        _logger = logger;
    }

    private bool IsAdmin =>
        User.IsInRole("Admin") || User.IsInRole("LRN Admin") || User.IsInRole("LRNAdmin")
        || User.IsInRole("Super Admin") || User.IsInRole("SuperAdmin");

    private string CurrentUser => User.Identity?.Name?.Trim() is { Length: > 0 } u ? u : "unknown";

    private List<string> VisibleLabs()
    {
        var claimed = User.Claims.Where(c => c.Type == "LabName").Select(c => c.Value)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        return _labConfig.VisibleLabs(_labSettings.Labs.Keys.ToList(), claimed, IsAdmin)
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
    }

    private bool CanSeeLab(string? labKey) =>
        !string.IsNullOrWhiteSpace(labKey) && VisibleLabs().Contains(labKey, StringComparer.OrdinalIgnoreCase);

    // GET /RevenueAnalysis?lab=Cove
    public async Task<IActionResult> Index(string? lab, CancellationToken ct)
    {
        var labs = VisibleLabs();
        var vm = new RevenueAnalysisIndexViewModel { AvailableLabs = labs };
        if (labs.Count == 0)
        {
            vm.Error = "No labs are available for your account.";
            return View(vm);
        }

        var requested = labs.FirstOrDefault(x => string.Equals(x, lab?.Trim(), StringComparison.OrdinalIgnoreCase));
        var labKey = LabSelectionHelper.Resolve(HttpContext, requested, labs);
        ViewData["SelectedLab"] = labKey;

        vm.LabKey = labKey;
        vm.LabDisplayName = _labConfig.DisplayNameFor(labKey);
        _labSettings.Labs.TryGetValue(labKey, out var config);
        vm.LiveAvailable = !string.IsNullOrWhiteSpace(config?.DbConnectionString);
        if (!vm.LiveAvailable) vm.LiveUnavailableReason = "No database connection is configured for this lab.";

        // Default window: January of last year through today - the same shape as the report team's file.
        var today = DateOnly.FromDateTime(DateTime.Today);
        vm.DefaultFrom = new DateOnly(today.Year - 1, 1, 1);
        vm.DefaultTo = today;

        try
        {
            var weeks = await _snapshots.GetReportWeeksAsync(12, ct);
            if (weeks is not null)
            {
                vm.Snapshots = weeks
                    .Where(w => RevenueAnalysisService.LabMatches(w.LabName, labKey, vm.LabDisplayName))
                    .Where(w => w.Reports.Any(r => r.IsData && Is(r.ReportCode, "CLAIMLEVEL"))
                                && w.Reports.Any(r => r.IsData && Is(r.ReportCode, "LINELEVEL")))
                    .OrderByDescending(w => w.SnapshotDate)
                    .Select(w => new RevenueAnalysisSnapshotOption(
                        w.SnapshotRunId,
                        $"Week {w.WeekFolder} (as of {w.SnapshotDate:MM/dd/yyyy})",
                        w.Reports.FirstOrDefault(r => Is(r.ReportCode, "CLAIMLEVEL"))?.RowCount ?? 0))
                    .ToList();
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Snapshot weeks unavailable for Revenue Analysis ({Lab}).", labKey);
            vm.SnapshotError = "Weekly snapshots could not be listed right now.";
        }

        vm.Recent = _service.ListForLab(labKey);
        return View(vm);
    }

    private static bool Is(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    // POST /RevenueAnalysis/Generate  (allowed for view-only roles: building a report is reading)
    [HttpPost]
    [ValidateAntiForgeryToken]
    public IActionResult Generate(string? lab, string? source, string? dosFrom, string? dosTo, bool refresh = false)
    {
        if (!CanSeeLab(lab)) return Json(new { ok = false, error = "You do not have access to that lab." });
        var labKey = VisibleLabs().First(x => string.Equals(x, lab!.Trim(), StringComparison.OrdinalIgnoreCase));

        DateOnly? from = ParseDate(dosFrom), to = ParseDate(dosTo);
        if (from is { } f && to is { } t && f > t) (from, to) = (to, from);

        RevenueAnalysisSourceKind kind;
        long? runId = null;
        string? connection = null;
        if (string.Equals(source, "live", StringComparison.OrdinalIgnoreCase))
        {
            kind = RevenueAnalysisSourceKind.Live;
            _labSettings.Labs.TryGetValue(labKey, out var config);
            connection = config?.DbConnectionString;
            if (string.IsNullOrWhiteSpace(connection))
                return Json(new { ok = false, error = "No database connection is configured for this lab." });
        }
        else if (source is not null && source.StartsWith("snapshot:", StringComparison.OrdinalIgnoreCase)
                 && long.TryParse(source["snapshot:".Length..], NumberStyles.None, CultureInfo.InvariantCulture, out var id))
        {
            kind = RevenueAnalysisSourceKind.Snapshot;
            runId = id;
        }
        else
        {
            return Json(new { ok = false, error = "Choose a data source." });
        }

        var job = _service.Start(new RevenueAnalysisRequest
        {
            LabKey = labKey,
            LabDisplayName = _labConfig.DisplayNameFor(labKey),
            Source = kind,
            ConnectionString = connection,
            SnapshotRunId = runId,
            DosFrom = from,
            DosTo = to,
            Refresh = refresh,
            RequestedBy = CurrentUser,
        });
        return Json(new { ok = true, jobId = job.Id });
    }

    // GET /RevenueAnalysis/Status?id=...
    [HttpGet]
    public IActionResult Status(string? id)
    {
        var job = _service.GetJob(id ?? "");
        if (job is null || !string.Equals(job.RequestedBy, CurrentUser, StringComparison.OrdinalIgnoreCase))
            return Json(new { state = "missing", message = "This build is no longer tracked. Generate again." });

        RevenueAnalysisMeta? meta = job.Token is { } token ? _service.GetMeta(token) : null;
        return Json(new
        {
            state = job.State.ToString().ToLowerInvariant(),
            message = job.Message,
            error = job.Error,
            token = job.Token,
            reused = job.Reused,
            meta = meta is null ? null : Describe(meta),
        });
    }

    /// <summary>The launcher's summary of one built dashboard.</summary>
    internal static object Describe(RevenueAnalysisMeta m) => new
    {
        token = m.Token,
        source = m.SourceLabel,
        claims = m.Claims,
        lines = m.Lines,
        dos = $"{(m.DosFrom ?? m.DataDosMin):MM/dd/yyyy} – {(m.DosTo ?? m.DataDosMax):MM/dd/yyyy}",
        sizeMb = Math.Round(m.UncompressedBytes / 1048576.0, 1),
        generated = m.GeneratedOnUtc.ToLocalTime().ToString("MMM d, h:mm tt", CultureInfo.InvariantCulture),
        by = m.GeneratedBy,
        warnings = m.Warnings,
        unmatchedLines = m.UnmatchedLinesSkipped,
    };

    // GET /RevenueAnalysis/Page/{token}#payer - the dashboard itself, opened in its own window.
    [HttpGet("RevenueAnalysis/Page/{token}")]
    public IActionResult Page(string token)
    {
        var (meta, path, denied) = Resolve(token);
        if (denied is not null) return denied;

        // The page is self-contained (inline script and styles, inline handlers, Google Fonts) and
        // talks to nothing, so it gets its own policy: everything inline, no network at all.
        Response.Headers["Content-Security-Policy"] =
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline' https://fonts.googleapis.com; " +
            "font-src https://fonts.gstatic.com data:; img-src data: blob:; connect-src 'none'; base-uri 'none'; " +
            "form-action 'none'; object-src 'none'; frame-ancestors 'self'";
        Response.Headers.CacheControl = "private, max-age=3600";
        Response.Headers.Vary = "Accept-Encoding";

        var acceptsGzip = Request.Headers.AcceptEncoding.ToString().Contains("gzip", StringComparison.OrdinalIgnoreCase);
        if (acceptsGzip)
        {
            Response.Headers.ContentEncoding = "gzip";
            return PhysicalFile(path!, "text/html; charset=utf-8");
        }
        return File(new GZipStream(System.IO.File.OpenRead(path!), CompressionMode.Decompress), "text/html; charset=utf-8");
    }

    // GET /RevenueAnalysis/Download/{token} - the same page as one .html file to send to the client.
    [HttpGet("RevenueAnalysis/Download/{token}")]
    public IActionResult Download(string token)
    {
        var (meta, path, denied) = Resolve(token);
        if (denied is not null) return denied;
        return File(new GZipStream(System.IO.File.OpenRead(path!), CompressionMode.Decompress),
            "text/html; charset=utf-8", meta!.DownloadFileName);
    }

    private (RevenueAnalysisMeta? Meta, string? Path, IActionResult? Denied) Resolve(string token)
    {
        var meta = _service.GetMeta(token);
        var path = _service.GetFilePath(token);
        if (meta is null || path is null)
            return (null, null, NotFound("This dashboard has expired. Generate it again from Revenue Analysis."));
        if (!CanSeeLab(meta.LabKey))
            return (null, null, Forbid());
        return (meta, path, null);
    }

    private static DateOnly? ParseDate(string? value) =>
        DateOnly.TryParseExact(value?.Trim(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d : null;
}

public sealed record RevenueAnalysisSnapshotOption(long SnapshotRunId, string Label, long ClaimRows);

public sealed class RevenueAnalysisIndexViewModel
{
    public List<string> AvailableLabs { get; set; } = [];
    public string LabKey { get; set; } = "";
    public string LabDisplayName { get; set; } = "";
    public bool LiveAvailable { get; set; }
    public string? LiveUnavailableReason { get; set; }
    public List<RevenueAnalysisSnapshotOption> Snapshots { get; set; } = [];
    public string? SnapshotError { get; set; }
    public DateOnly DefaultFrom { get; set; }
    public DateOnly DefaultTo { get; set; }
    public IReadOnlyList<RevenueAnalysisMeta> Recent { get; set; } = [];
    public string? Error { get; set; }
}
