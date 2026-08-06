using System.Reflection;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Report Control Board - the landing page that shows every report produced by each lab's latest
/// run, and links straight to the ones that succeeded.
///
/// This is a new page alongside the original Home landing (which probes the file share and is left
/// untouched). Data comes from LRN.ReportsApi, which owns the usp_ReportsWorkflowTracker_Pivot call.
/// </summary>
public sealed class ReportBoardController : Controller
{
    private readonly IReportBoardApiClient _api;
    private readonly ILabNameResolver _labResolver;
    private readonly LabSettings _labSettings;
    private readonly IMenuService _menuService;
    private readonly ILogger<ReportBoardController> _logger;

    public ReportBoardController(
        IReportBoardApiClient api,
        ILabNameResolver labResolver,
        LabSettings labSettings,
        IMenuService menuService,
        ILogger<ReportBoardController> logger)
    {
        _api = api;
        _labResolver = labResolver;
        _labSettings = labSettings;
        _menuService = menuService;
        _logger = logger;
    }

    // Feature flags are named on LabCsvConfig; the catalog stores the property name, so the lookup
    // is reflective. Cached because it runs once per (report x lab) cell.
    private static readonly Dictionary<string, PropertyInfo> FlagProperties =
        typeof(LabCsvConfig).GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Where(p => p.PropertyType == typeof(bool))
            .ToDictionary(p => p.Name, StringComparer.OrdinalIgnoreCase);

    private bool IsAdmin => User.IsInRole("Admin") || User.IsInRole("LRN Admin") || User.IsInRole("LRNAdmin");

    [HttpGet]
    public async Task<IActionResult> Index(string? view, string? sort, string? filter, bool refresh = false, CancellationToken ct = default)
    {
        var resolvedView = string.Equals(view, "cards", StringComparison.OrdinalIgnoreCase) ? "cards" : "matrix";
        var resolvedSort = string.Equals(sort, "az", StringComparison.OrdinalIgnoreCase) ? "az" : "latest";
        var resolvedFilter = filter?.ToLowerInvariant() switch
        {
            "failed" => "failed",
            "incomplete" => "incomplete",
            _ => "all"
        };

        var fetch = await _api.GetLatestAsync(refresh, ct);
        var columns = ReportCatalog.Order(fetch.Data?.ReportColumns ?? []);

        // One permission check per report page rather than per cell.
        var routeAllowed = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (var column in columns.Where(c => c.Controller is not null && c.Action is not null))
        {
            var key = $"{column.Controller}/{column.Action}";
            if (routeAllowed.ContainsKey(key)) continue;
            routeAllowed[key] = await _menuService.CanAccessAsync(User, null, column.Controller, column.Action, ct);
        }

        var visibleLabs = VisibleLabKeys();
        var rows = new List<LabReportRow>();

        foreach (var apiRow in fetch.Data?.Rows ?? [])
        {
            var configKey = _labResolver.Resolve(apiRow.Lab);

            // An unmapped lab is a configuration gap worth seeing, but only an admin can act on it -
            // and for anyone else we cannot prove the lab is one of theirs, so it stays hidden.
            if (configKey is null && !IsAdmin) continue;
            if (configKey is not null && !visibleLabs.Contains(configKey)) continue;

            var labConfig = configKey is not null && _labSettings.Labs.TryGetValue(configKey, out var cfg) ? cfg : null;

            rows.Add(new LabReportRow
            {
                LabDisplayName = string.IsNullOrWhiteSpace(apiRow.Lab) ? (configKey ?? "Unknown lab") : apiRow.Lab!,
                LabConfigKey = configKey ?? string.Empty,
                RunId = apiRow.RunId,
                Week = apiRow.Week,
                SyncedOn = apiRow.SyncedOnDate,
                Reports = columns
                    .Select(column => BuildCell(column, apiRow, labConfig, configKey, routeAllowed))
                    .ToList()
            });
        }

        rows = Sort(rows, resolvedSort);

        var model = new ReportBoardViewModel
        {
            Columns = columns,
            Rows = rows,
            LastSyncedOn = rows.Select(r => r.SyncedOn).Where(d => d.HasValue).Max(),
            View = resolvedView,
            Sort = resolvedSort,
            Filter = resolvedFilter,
            DataError = fetch.Error,
            LastGoodAt = fetch.Error is not null ? fetch.FetchedAt : null
        };

        return View(model);
    }

    /// <summary>
    /// Why a run failed: pipeline errors (LRN_Error_Log) plus the run's Error entries
    /// (ReportRunIdInfoLog). Every Failed cell on the board links here.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> RunErrors(string? runId, string? lab, string? labName, string? report, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(runId))
            return View(new RunErrorsViewModel { RunId = string.Empty, Result = new RunErrorsResult { LoadError = "No run was specified." } });

        // Deliberately not filtered by lab: a RunId belongs to exactly one lab by construction (it
        // carries the lab short code), while LRN_Error_Log stores the pipeline's own spelling of the
        // lab name - filtering on our key would silently return nothing.
        var result = await _api.GetRunErrorsAsync(runId, null, report, ct);

        return View(new RunErrorsViewModel
        {
            RunId = runId,
            LabConfigKey = lab,
            LabDisplayName = string.IsNullOrWhiteSpace(labName) ? lab : labName,
            ReportName = report,
            Result = result
        });
    }

    /// <summary>
    /// Downloads the run's Error log as a CSV — the board's error link points here. Backed by
    /// usp_ReportRunIdInfoLog_Get @Runid = &lt;runId&gt;, @logtype = 'Error'. If the file cannot be
    /// produced (API down, no rows), fall back to the on-screen error page so the click is never dead.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> RunErrorsCsv(string? runId, string? lab, string? labName, string? report, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(runId))
            return RedirectToAction(nameof(Index));

        var csv = await _api.GetRunErrorsCsvAsync(runId, null, ct);
        if (csv is null || csv.Content.Length == 0)
            return RedirectToAction(nameof(RunErrors), new { runId, lab, labName, report });

        return File(csv.Content, csv.ContentType, csv.FileName);
    }

    private LabReportStatus BuildCell(
        ReportCatalogEntry column,
        ReportBoardApiRow apiRow,
        LabCsvConfig? labConfig,
        string? configKey,
        IReadOnlyDictionary<string, bool> routeAllowed)
    {
        // A tile may derive its status from another report (StatusFrom) — LIMS Master mirrors
        // "LIS Summary": success when LIS Summary succeeded for this run, otherwise failed.
        var statusKey = column.StatusFrom ?? column.TrackerColumn;
        apiRow.Statuses.TryGetValue(statusKey, out var raw);
        var status = ParseStatus(raw);

        string? blocked = null;
        var linkable = status == ReportRunStatus.Success;

        if (!linkable)
        {
            blocked = status switch
            {
                ReportRunStatus.Failed => "This report failed in the latest run.",
                ReportRunStatus.Pending => "This report is still running.",
                _ => "Not produced for this lab."
            };
        }
        else if (column.Controller is null || column.Action is null)
        {
            linkable = false;
            blocked = "No page is mapped to this report yet.";
        }
        else if (configKey is null)
        {
            linkable = false;
            blocked = "Lab not mapped to a configuration.";
        }
        else if (!IsFeatureEnabled(column.FeatureFlag, labConfig))
        {
            linkable = false;
            blocked = "This feature is not enabled for the selected lab.";
        }
        else if (!routeAllowed.GetValueOrDefault($"{column.Controller}/{column.Action}", true))
        {
            linkable = false;
            blocked = "Your role does not have access to this page.";
        }

        return new LabReportStatus
        {
            Catalog = column,
            Status = status,
            IsLinkable = linkable,
            BlockedReason = blocked,
            RawStatus = raw
        };
    }

    /// <summary>Tracker values are free text; anything unrecognised is treated as not produced.</summary>
    internal static ReportRunStatus ParseStatus(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return ReportRunStatus.NotConfigured;
        var value = raw.Trim();
        if (value.Equals("Success", StringComparison.OrdinalIgnoreCase)) return ReportRunStatus.Success;
        if (value.Equals("Failed", StringComparison.OrdinalIgnoreCase)) return ReportRunStatus.Failed;
        if (value.Equals("Pending", StringComparison.OrdinalIgnoreCase)
            || value.Equals("In Progress", StringComparison.OrdinalIgnoreCase)
            || value.Equals("InProgress", StringComparison.OrdinalIgnoreCase)) return ReportRunStatus.Pending;
        return ReportRunStatus.NotConfigured;
    }

    /// <summary>No flag means the page is always available; an unknown flag name is treated as off.</summary>
    internal static bool IsFeatureEnabled(string? flagName, LabCsvConfig? config)
    {
        if (string.IsNullOrWhiteSpace(flagName)) return true;
        if (config is null) return false;
        return FlagProperties.TryGetValue(flagName, out var property)
               && property.GetValue(config) is true;
    }

    private static List<LabReportRow> Sort(List<LabReportRow> rows, string sort)
        => sort == "az"
            ? rows.OrderBy(r => r.LabDisplayName, StringComparer.OrdinalIgnoreCase).ToList()
            // Newest sync first, and within a sync date the labs that need attention lead.
            : rows.OrderByDescending(r => r.SyncedOn ?? DateTime.MinValue)
                  .ThenByDescending(r => r.HasFailures)
                  .ThenBy(r => r.LabDisplayName, StringComparer.OrdinalIgnoreCase)
                  .ToList();

    /// <summary>Admins see every lab; everyone else sees the labs on their LabName claims.</summary>
    private HashSet<string> VisibleLabKeys()
    {
        var all = _labSettings.Labs.Keys.ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (IsAdmin) return all;

        var claimed = User.Claims
            .Where(c => c.Type == "LabName")
            .Select(c => c.Value)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        all.IntersectWith(claimed);
        return all;
    }
}

public sealed class RunErrorsViewModel
{
    public required string RunId { get; init; }
    public string? LabConfigKey { get; init; }
    public string? LabDisplayName { get; init; }
    public string? ReportName { get; init; }
    public required RunErrorsResult Result { get; init; }
}
