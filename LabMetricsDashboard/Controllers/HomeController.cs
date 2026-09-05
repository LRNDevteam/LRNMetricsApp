using System.Diagnostics;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Caching.Memory;

namespace LabMetricsDashboard.Controllers;

public class HomeController : Controller
{
    private static readonly TimeSpan RunInfoCacheDuration = TimeSpan.FromMinutes(5);

    private readonly ILogger<HomeController> _logger;
    private readonly LabSettings _labSettings;
    private readonly LabCsvFileResolver _resolver;
    private readonly IPredictionDbRepository _predictionRepo;
    private readonly Microsoft.Extensions.Caching.Memory.IMemoryCache _cache;

    public HomeController(
        ILogger<HomeController> logger,
        LabSettings labSettings,
        LabCsvFileResolver resolver,
        IPredictionDbRepository predictionRepo,
        Microsoft.Extensions.Caching.Memory.IMemoryCache cache)
    {
        _logger = logger;
        _labSettings = labSettings;
        _resolver = resolver;
        _predictionRepo = predictionRepo;
        _cache = cache;
    }

    public async Task<IActionResult> Index(string? sort, string? lab = null)
    {
        // Non-admin users should never see the Home landing (lab tiles).
        // Send them straight to the Revenue Dashboard.
        if (User?.Identity?.IsAuthenticated == true && !User.IsInRole("Admin"))
        {
            return RedirectToAction("Index", "Dashboard");
        }

        // Persist the navbar lab selection. The Home page previously never wrote the
        // lmd_selected_lab cookie, so switching labs here showed the new lab on this page
        // (via ?lab=) but reverted on the next navigation. Resolving here writes the cookie
        // and sets ViewData["SelectedLab"] so the choice carries to every other page — the
        // same pattern every content controller (Dashboard, CollectionSummary, …) already uses.
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        ViewData["SelectedLab"] = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        var resolvedSort = string.IsNullOrWhiteSpace(sort) ? "latest" : sort;

        // ── Live DB run info for DB-enabled labs (SP: usp_GetPayerValidationRunStats
        //    via ProbeAsync). Fetched in parallel, cached 5 min, failures → null so a
        //    slow/unreachable lab DB can never break or stall the Home page.
        var runInfoTasks = _labSettings.Labs
            .Where(kv => kv.Value.DBEnabled && !string.IsNullOrWhiteSpace(kv.Value.DbConnectionString))
            .ToDictionary(
                kv => kv.Key,
                kv => GetPredictionRunInfoCachedAsync(kv.Key, kv.Value.DbConnectionString!),
                StringComparer.OrdinalIgnoreCase);

        await Task.WhenAll(runInfoTasks.Values);

        var tiles = _labSettings.Labs.Keys
            .OrderBy(name => name)
            .Select(labName =>
            {
                var claimPath        = _resolver.ResolveClaimLevelCsv(labName);
                var linePath         = _resolver.ResolveLineLevelCsv(labName);
                var predictionPath   = _resolver.ResolvePredictionValidationReport(labName);
                var codingMasterPath = _resolver.ResolveCodingMasterReport(labName);

                var labConfig  = _labSettings.Labs.TryGetValue(labName, out var cfg) ? cfg : null;
                var dbEnabled  = labConfig?.DBEnabled == true;
                var lineClaimEnabled = labConfig?.LineClaimEnable == true;

                var runInfo = runInfoTasks.TryGetValue(labName, out var t) ? t.Result : null;

                return new LabTileViewModel
                {
                    LabName               = labName,
                    HasClaimFile          = claimPath        is not null,
                    HasLineFile           = linePath         is not null,
                    HasPredictionFile     = predictionPath   is not null,
                    HasCodingMasterFile   = codingMasterPath is not null,
                    PredictionEnabled     = labConfig?.EnablePrediction == true,
                    DBEnabled             = dbEnabled,
                    CodingEnabled         = dbEnabled && !string.IsNullOrWhiteSpace(labConfig?.Reports),
                    LineClaimEnabled      = lineClaimEnabled,
                    ClaimFilePath         = claimPath,
                    LineFilePath          = linePath,
                    PredictionFilePath    = predictionPath,
                    CodingMasterFilePath  = codingMasterPath,
                    ClaimRunId            = ExtractRunId(claimPath),
                    LineRunId             = ExtractRunId(linePath),
                    PredictionRunId       = ExtractRunId(predictionPath),
                    CodingRunId           = ExtractRunId(codingMasterPath),
                    PredictionDbRunId     = runInfo?.LatestRunId,
                    PredictionDbInsertedAt = runInfo?.LatestRunInsertedAt is { } utc
                        ? DateTime.SpecifyKind(utc, DateTimeKind.Utc).ToLocalTime()
                        : null,
                    WeekRange             = ExtractWeekRange(claimPath),
                    ClaimFileAgeHours     = GetFileAgeHours(claimPath),
                    LineFileAgeHours      = GetFileAgeHours(linePath),
                };
            })
            .ToList();

        if (string.Equals(resolvedSort, "latest", StringComparison.OrdinalIgnoreCase))
        {
            tiles = tiles
                .OrderBy(t => t.ClaimFileAgeHours.HasValue ? 0 : 1)
                .ThenBy(t => t.ClaimFileAgeHours ?? double.MaxValue)
                .ToList();
        }
        // else: already sorted A-Z

        return View(new HomeViewModel { LabTiles = tiles, Sort = resolvedSort });
    }

    [Microsoft.AspNetCore.Authorization.AllowAnonymous]
    public IActionResult Privacy() => View();

    /// <summary>
    /// Returns the lab's latest prediction run info (RunId + inserted timestamp),
    /// cached for <see cref="RunInfoCacheDuration"/>. Never throws — any DB error
    /// is logged and cached as null so one bad lab DB cannot slow the Home page
    /// on every request.
    /// </summary>
    private Task<PredictionDbDiagnostic?> GetPredictionRunInfoCachedAsync(string labName, string connectionString)
    {
        return _cache.GetOrCreateAsync<PredictionDbDiagnostic?>($"HomeTile_PredRunInfo_{labName}", async entry =>
        {
            entry.AbsoluteExpirationRelativeToNow = RunInfoCacheDuration;
            try
            {
                // Do not pass HttpContext.RequestAborted: a client disconnect / request
                // abort mid-probe previously surfaced as TaskCanceledException noise and
                // could leave Home waiting on WhenAll while SQL work was canceled.
                // ProbeAsync applies its own short connect/command/budget timeouts.
                var diag = await _predictionRepo.ProbeAsync(connectionString, CancellationToken.None);
                return diag.IsReady ? diag : null;
            }
            catch (OperationCanceledException ex)
            {
                _logger.LogWarning(ex,
                    "Home tile: prediction run info probe canceled/timed out for lab '{LabName}'.", labName);
                return null;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Home tile: prediction run info lookup failed for lab '{LabName}'.", labName);
                return null;
            }
        });
    }

    /// <summary>
    /// Extracts RunId from a file path by taking the prefix before the first underscore.
    /// </summary>
    private static string? ExtractRunId(string? filePath)
    {
        if (string.IsNullOrWhiteSpace(filePath)) return null;
        var name = Path.GetFileNameWithoutExtension(filePath);
        if (string.IsNullOrEmpty(name)) return null;
        var idx = name.IndexOf('_');
        return idx > 0 ? name[..idx] : name;
    }

    /// <summary>
    /// Returns the total hours since the file was last written, or null if the file doesn't exist.
    /// </summary>
    private static double? GetFileAgeHours(string? filePath)
    {
        if (string.IsNullOrWhiteSpace(filePath) || !System.IO.File.Exists(filePath)) return null;
        return (DateTime.Now - System.IO.File.GetLastWriteTime(filePath)).TotalHours;
    }

    /// <summary>
    /// Extracts the week date range from a file name.
    /// E.g. "20260403R0251_PCR Labs of America_Claim Level_03.26.2026 to 04.01.2026.csv"
    /// returns "03.26.2026 to 04.01.2026".
    /// </summary>
    private static string? ExtractWeekRange(string? filePath)
    {
        if (string.IsNullOrWhiteSpace(filePath)) return null;
        var name = Path.GetFileNameWithoutExtension(filePath);
        if (string.IsNullOrEmpty(name)) return null;
        var lastUnderscore = name.LastIndexOf('_');
        if (lastUnderscore < 0 || lastUnderscore >= name.Length - 1) return null;
        var range = name[(lastUnderscore + 1)..];
        return range.Contains("to", StringComparison.OrdinalIgnoreCase) ? range : null;
    }

    [ResponseCache(Duration = 0, Location = ResponseCacheLocation.None, NoStore = true)]
    [Microsoft.AspNetCore.Authorization.AllowAnonymous]
    public IActionResult Error()
    {
        var requestId = Activity.Current?.Id ?? HttpContext.TraceIdentifier;

        // Capture the exception that triggered the error page and log it to file.
        var exFeature = HttpContext.Features.Get<IExceptionHandlerPathFeature>();
        if (exFeature is not null)
        {
            var canceled = exFeature.Error is OperationCanceledException;
            if (canceled)
                _logger.LogWarning(exFeature.Error,
                    "Request canceled | Path={OriginalPath} | RequestId={RequestId}",
                    exFeature.Path, requestId);
            else
                _logger.LogError(exFeature.Error,
                    "Error page reached | Path={OriginalPath} | RequestId={RequestId}",
                    exFeature.Path, requestId);

            if (IsBackgroundDataPath(exFeature.Path))
            {
                if (canceled)
                {
                    Response.StatusCode = StatusCodes.Status204NoContent;
                    return new EmptyResult();
                }

                if (IsJsonDataPath(exFeature.Path))
                    return Json(new { error = true, requestId });

                Response.StatusCode = StatusCodes.Status500InternalServerError;
                return Content(
                    "<div class=\"alert alert-warning border-0 shadow-sm m-3\">Failed to load this section. Please refresh the page.</div>",
                    "text/html");
            }
        }

        return View(new ErrorViewModel { RequestId = requestId });
    }

    private static bool IsBackgroundDataPath(string? path)
    {
        if (string.IsNullOrEmpty(path)) return false;
        return path.Contains("/GetMeta", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/GetSummary", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/GetTable", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/GetTabPartial", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/FilterOptions", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/ProductionSummaryReportTab", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/ProductionSummaryReportMeta", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/FirstPaintClient", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsJsonDataPath(string? path)
    {
        if (string.IsNullOrEmpty(path)) return false;
        return path.Contains("/GetMeta", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/FilterOptions", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/ProductionSummaryReportMeta", StringComparison.OrdinalIgnoreCase)
            || path.Contains("/FirstPaintClient", StringComparison.OrdinalIgnoreCase);
    }
}
