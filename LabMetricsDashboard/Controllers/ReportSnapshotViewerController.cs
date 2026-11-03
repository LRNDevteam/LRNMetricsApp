using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.Services.ReportSnapshots;
using LabMetricsDashboard.ViewModels;
using LRN.ProductionReports.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Codes = LabMetricsDashboard.Services.ReportSnapshots.ReportSnapshotViewContext.ReportCodes;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Opens one weekly snapshot file (Master Values > Report Snapshots) in its own window. Read-only.
/// <list type="bullet">
///   <item>A report's display copy (ResultSetName PageModel) is shown by the report's own page views -
///         Executive Summary, LIS, Production, Collection, Denial Summary - bound to the view model the
///         page rendered that week, in snapshot mode (<see cref="ReportSnapshotViewContext"/>): no menu,
///         filters or exports, and every lazy tab is served from the snapshot by the actions below.</item>
///   <item>A Parquet file (a report section, or the Line Level / Claim Level / LIMS master data) is shown
///         as a paged table.</item>
/// </list>
/// Nothing here reads a lab database: everything comes from the snapshot container and the LRNMaster index.
/// </summary>
[Authorize]
public sealed class ReportSnapshotViewerController : Controller
{
    private const int DataPageSize = 500;

    private readonly IMasterDataSnapshotRepository _index;
    private readonly IReportPageSnapshotReader _pages;
    private readonly IReportSnapshotFileStore _store;
    private readonly LabSettings _labSettings;
    private readonly LabConfigOptions _labConfig;
    private readonly ILogger<ReportSnapshotViewerController> _logger;

    public ReportSnapshotViewerController(
        IMasterDataSnapshotRepository index,
        IReportPageSnapshotReader pages,
        IReportSnapshotFileStore store,
        LabSettings labSettings,
        LabConfigOptions labConfig,
        ILogger<ReportSnapshotViewerController> logger)
    {
        _index = index;
        _pages = pages;
        _store = store;
        _labSettings = labSettings;
        _labConfig = labConfig;
        _logger = logger;
    }

    /// <summary>Every snapshot file, Parquet included, and the report logic notes: the snapshot admins.</summary>
    private bool CanView => MasterValuesController.CanViewSnapshots(User);

    /// <summary>
    /// A report view of a lab: the snapshot admins for every lab, anyone else (the lab's client users)
    /// for the labs on their LabName claims. The snapshot's LabId is LRNMaster's, the claims carry the
    /// LabConfig:LabsID name of the user's UserLabs ids; the run's own LabName counts as well.
    /// </summary>
    internal static bool CanViewLab(System.Security.Claims.ClaimsPrincipal user, LabConfigOptions labConfig, int labId, string? labName)
    {
        if (MasterValuesController.CanViewSnapshots(user)) return true;
        var claimed = user.Claims.Where(c => c.Type == "LabName").Select(c => c.Value).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var configured = labConfig.GetLabNameById(labId);
        return (configured is not null && claimed.Contains(configured))
               || (!string.IsNullOrWhiteSpace(labName) && claimed.Contains(labName));
    }

    private bool CanViewReport(MasterDataSnapshotFileDetail? file) =>
        file is not null && file.IsPageModel && CanViewLab(User, _labConfig, file.LabId, file.LabName);

    // ── the report, as its page ───────────────────────────────────────────────

    /// <summary>A report snapshot (its PageModel file <paramref name="id"/>) in the report's own page.</summary>
    [HttpGet]
    public async Task<IActionResult> Report(long id, CancellationToken ct)
    {
        var file = await _index.GetFileAsync(id, ct);
        if (file is null) return Unavailable("This snapshot file is no longer in the index. It may have been removed by retention or replaced by a re-run.");
        if (!file.IsPageModel) return CanView ? RedirectToAction(nameof(Data), new { id }) : Forbid();
        if (!CanViewReport(file)) return Forbid();

        ReportPageSnapshotFile page;
        try
        {
            page = await _pages.ReadAsync(file.SnapshotFileId, file.BlobPath, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Report snapshot {FileId} ({Path}) could not be read.", id, file.BlobPath);
            return Unavailable($"The snapshot file could not be read: {ex.Message}", file);
        }

        var runPages = await RunPageModelsAsync(file.SnapshotRunId, ct);
        var context = Context(file, page, runPages);
        ViewData[ReportSnapshotViewContext.ViewDataKey] = context;

        switch (file.ReportCode)
        {
            case Codes.ExecutiveSummary when page.BoundModel is PhiExecutiveSummaryViewModel es:
                es.AvailableLabs = [];
                ViewData["AnalysisRange"] = new AnalysisRangeInfo
                {
                    WeekFolder = es.ReportWeekFolder ?? page.WeekFolder,
                    RunId = es.ReportRunId ?? page.RunId,
                    InsertedDateTime = es.ReportInsertedDateTime
                };
                return View("~/Views/ExecutiveSummary/Index.cshtml", es);

            case Codes.LisSummary when page.BoundModel is LisSummaryResult lis:
                ViewData["SelectedLab"] = page.LabKey;
                ViewData["PageLabel"] = "LIS Summary";
                return View("~/Views/LisSummary/Index.cshtml", new LisSummaryPageViewModel
                {
                    Filters = new LisSummaryFilters(),
                    CurrentLabName = page.LabKey,
                    ConfiguredLabKey = page.LabKey,
                    RunId = page.RunId,
                    WeekLabel = page.WeekFolder,
                    AnalysisRange = new AnalysisRangeInfo { WeekFolder = page.WeekFolder, RunId = page.RunId, SourceFileName = lis.SourceFileName },
                    Result = lis,
                    FilterOptions = new([], [], [], [], [])
                });

            case Codes.ProductionSummary when page.BoundModel is ProductionReportViewModel prod:
                // The page's own lazy tabs, served by ProductionPane below; the key is this file.
                ViewData["PrCacheKey"] = id.ToString();
                ViewData["AnalysisRange"] = new AnalysisRangeInfo { WeekFolder = page.WeekFolder, RunId = page.RunId };
                return View("~/Views/Dashboard/ProductionSummaryReport.cshtml", prod);

            case Codes.CollectionSummary when page.BoundModel is CollectionSummaryViewModel coll:
                ViewData["SelectedLab"] = page.LabKey;
                ViewData["PageLabel"] = "Collection Summary";
                return View("~/Views/CollectionSummary/Index.cshtml", PrepareCollection(coll, page.LabKey));

            case Codes.DenialSummary:
            case Codes.DenialInsight:
                return View("~/Views/DenialClaimReport/Index.cshtml",
                    await DenialModelAsync(file, page, runPages, DenialInsightBuckets.Current, ct));

            // A report's Key Insights on their own (Report Snapshots > Insights): the report page's panel, read-only.
            case Codes.LisInsight or Codes.ProductionInsight or Codes.CollectionInsight when page.BoundModel is ReportInsightsSnapshotModel insights:
                ViewData["SelectedLab"] = page.LabKey;
                ViewData["PageLabel"] = context.ReportTitle;
                return View("Insights", new LabMetricsDashboard.Models.Notes.ReportInsightsPanelModel
                {
                    Lab = page.LabKey,
                    ReportName = insights.ReportName,
                    RunId = insights.RunId ?? page.RunId,
                    WeekText = insights.WeekText ?? page.WeekFolder
                });

            default:
                return Unavailable($"The {ReportSnapshotViewContext.Title(file.ReportCode)} snapshot holds {page.ModelType}, which has no report view.", file);
        }
    }

    // ── lazy tabs, as the live pages load them ────────────────────────────────

    /// <summary>One Production tab (the page's ProductionSummaryReportTab, from the snapshot).</summary>
    [HttpGet]
    public async Task<IActionResult> ProductionPane(string key, string pane, CancellationToken ct)
    {
        if (!long.TryParse(key, out var id) || string.IsNullOrWhiteSpace(pane) || pane.Length > 60) return BadRequest();

        var (file, page) = await LoadAsync(id, Codes.ProductionSummary, ct);
        if (file is not null && !CanViewReport(file)) return Forbid();
        if (page?.BoundModel is not ProductionReportViewModel prod) return StatusCode(404, "This snapshot is no longer available.");

        ViewData[ReportSnapshotViewContext.ViewDataKey] = Context(file!, page, new Dictionary<string, long>());
        ViewData["PrPaneOnly"] = pane;
        return PartialView("~/Views/Dashboard/ProductionReport.cshtml", prod);
    }

    /// <summary>The Production banner (ProductionSummaryReportMeta): the snapshot's week and run, no filter lists.</summary>
    [HttpGet]
    public async Task<IActionResult> ProductionMeta(string key, CancellationToken ct)
    {
        if (!long.TryParse(key, out var id)) return BadRequest();
        var file = await _index.GetFileAsync(id, ct);
        if (file is not null && !CanViewReport(file)) return Forbid();
        return Json(new
        {
            payers = Array.Empty<string>(),
            panels = Array.Empty<string>(),
            weekFolder = file?.WeekFolder,
            runId = file?.RunId,
            inserted = (string?)null
        });
    }

    /// <summary>One Collection tab (the page's GetTabPartial, from the snapshot's view model).</summary>
    [HttpGet]
    public async Task<IActionResult> CollectionTab(long id, string tab, CancellationToken ct)
    {
        var (file, page) = await LoadAsync(id, Codes.CollectionSummary, ct);
        if (file is not null && !CanViewReport(file)) return Forbid();
        if (page?.BoundModel is not CollectionSummaryViewModel coll) return Content(
            "<div class='alert alert-warning m-3'>This snapshot is no longer available.</div>", "text/html");

        ViewData[ReportSnapshotViewContext.ViewDataKey] = Context(file!, page, new Dictionary<string, long>());
        var vm = PrepareCollection(coll, page.LabKey);
        var lab = vm.SelectedLab;
        const string Tabs = "~/Views/CollectionSummary/";

        switch (tab?.ToLowerInvariant())
        {
            case "mcv":
                ViewData["CsPaneOnly"] = "mcv";
                return PartialView(Tabs + "Index.cshtml", vm);
            case "top5":
                ViewData["CsPaneOnly"] = "top5";
                return PartialView(Tabs + "Index.cshtml", vm);
            case "top5grid":
                return PartialView(Tabs + "_CsTabTop5Grid.cshtml", vm);
            case "wcv":
                return PartialView(Tabs + "_CsTabWcv.cshtml", vm);
            case "panelavg":
                return LabCollectionPrefix.ShowsPanelAverage(lab) ? PartialView(Tabs + "_CsTabPanelAvg.cshtml", vm) : Content(string.Empty);
            case "avgpay":
                if (vm.ShowAvgPaymentsByDateBasis) ViewData["AvgPayBasis"] = AvgPaymentsDateBasis.CheckDate;
                ViewData["AvgPayMonths"] = 6;
                return PartialView(Tabs + "_CsTabAvgPayments.cshtml", vm);
            case "avgpaydos":
                ViewData["AvgPayMonths"] = 6;
                ViewData["AvgPayBasis"] = AvgPaymentsDateBasis.DateOfService;
                return PartialView(Tabs + "_CsTabAvgPayments.cshtml", vm);
            case "avgpay3":
                if (!LabCollectionPrefix.ShowsAvgPaymentsLast3Months(lab)) return Content(string.Empty);
                ViewData["AvgPayMonths"] = 3;
                return PartialView(Tabs + "_CsTabAvgPayments.cshtml", vm);
            case "aging":
                return PartialView(Tabs + "_CsTabAging.cshtml", vm);
            case "panelpay":
                return PartialView(Tabs + "_CsTabPanelPay.cshtml", vm);
            case "inspctpay":
                return PartialView(Tabs + "_CsTabInsPctPay.cshtml", vm);
            case "insvspay":
                return PartialView(Tabs + "_CsTabInsVsPay.cshtml", vm);
            case "cptpctpay":
                return PartialView(Tabs + "_CsTabCptPctPay.cshtml", vm);
            case "statussummary":
                return PartialView(Tabs + "_CsTabStatusSummary.cshtml", vm);
            case "whpanel":
                return LabCollectionPrefix.IsNorthWest(lab) ? PartialView(Tabs + "_CsTabWomensHealth.cshtml", vm) : Content(string.Empty);
            case "genidavg":
                return PartialView(Tabs + "_CsTabGeneticsVsIdAvg.cshtml", vm);
            case "provider":
                return PartialView(Tabs + "_CsTabProvider.cshtml", vm);
            default:
                return BadRequest($"Unknown tab: {tab}");
        }
    }

    /// <summary>The Collection banner (GetMeta): the snapshot's week and run, no filter lists.</summary>
    [HttpGet]
    public async Task<IActionResult> CollectionMeta(long id, CancellationToken ct)
    {
        var file = await _index.GetFileAsync(id, ct);
        if (file is not null && !CanViewReport(file)) return Forbid();
        return Json(new
        {
            payers = Array.Empty<string>(),
            panels = Array.Empty<string>(),
            weekFolder = file?.WeekFolder,
            runId = file?.RunId,
            inserted = (string?)null
        });
    }

    /// <summary>The Denial Insight panel for a bucket (the page's InsightPanel), from the run's DENIALINSIGHT snapshot.</summary>
    [HttpGet]
    public async Task<IActionResult> InsightPanel(long id, string? bucket, CancellationToken ct)
    {
        var file = await _index.GetFileAsync(id, ct);
        if (file is null || !file.IsPageModel) return NotFound();
        if (!CanViewReport(file)) return Forbid();

        var page = await _pages.ReadAsync(file.SnapshotFileId, file.BlobPath, ct);
        var runPages = await RunPageModelsAsync(file.SnapshotRunId, ct);
        ViewData[ReportSnapshotViewContext.ViewDataKey] = Context(file, page, runPages);
        var model = await DenialModelAsync(file, page, runPages, DenialInsightBuckets.Normalize(bucket), ct);
        return PartialView("~/Views/DenialClaimReport/_DenialInsightPanel.cshtml", model.Insight);
    }

    /// <summary>
    /// A Key Insights snapshot (LISINSIGHT / PRODINSIGHT / COLLINSIGHT) as the panel's JSON - its rows and templates,
    /// the shape the live Notes API returns - for the read-only Key Insights &amp; Highlights panel.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> InsightRows(long id, CancellationToken ct)
    {
        var file = await _index.GetFileAsync(id, ct);
        if (file is null || !file.IsPageModel || !IsInsightCode(file.ReportCode)) return NotFound(new { error = "These insights are no longer available." });
        if (!CanViewReport(file)) return Forbid();
        try
        {
            var page = await _pages.ReadAsync(file.SnapshotFileId, file.BlobPath, ct);
            if (page.BoundModel is not ReportInsightsSnapshotModel insights) return NotFound(new { error = "These insights are no longer available." });
            return Json(new { reportName = insights.ReportName, weekText = insights.WeekText, templates = insights.Templates, rows = insights.Rows });
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Insights snapshot {FileId} ({Path}) could not be read.", id, file.BlobPath);
            return StatusCode(500, new { error = "The saved insights could not be read." });
        }
    }

    private static bool IsInsightCode(string reportCode) =>
        reportCode is Codes.LisInsight or Codes.ProductionInsight or Codes.CollectionInsight;

    // ── download: the report's own workbook, queued ───────────────────────────

    /// <summary>
    /// Queues the report snapshot <paramref name="id"/> as a download (ReportTypes.ReportSnapshot): LRN.ReportWorker
    /// writes the report's Excel workbook from the snapshot and it appears in the Reports panel. Everything the
    /// worker needs is resolved here from the index, after the lab check.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> QueueDownload(long id, [FromServices] UserReportService reports, CancellationToken ct)
    {
        var file = await _index.GetFileAsync(id, ct);
        if (file is null || !file.IsPageModel) return NotFound(new { message = "This snapshot is no longer available." });
        if (!CanViewReport(file)) return Forbid();
        if (IsInsightCode(file.ReportCode)) return BadRequest(new { message = "Key Insights have no workbook of their own. Download the report instead." });

        var runPages = await RunPageModelsAsync(file.SnapshotRunId, ct);
        // The Denial Insight upload is a tab of the Denial Summary workbook, not a workbook of its own.
        if (file.ReportCode == Codes.DenialInsight)
        {
            file = runPages.TryGetValue(Codes.DenialSummary, out var summaryId) ? await _index.GetFileAsync(summaryId, ct) : null;
            if (file is null) return BadRequest(new { message = "This week has no Denial Summary snapshot to download the Denial Insight with." });
        }
        string? insightPath = null;
        if (file.ReportCode == Codes.DenialSummary && runPages.TryGetValue(Codes.DenialInsight, out var insightId))
            insightPath = (await _index.GetFileAsync(insightId, ct))?.BlobPath;

        // The queue lives in the lab's own database: its LabSettings key.
        var lab = new[] { _labConfig.GetLabNameById(file.LabId), file.LabName }
            .FirstOrDefault(l => !string.IsNullOrWhiteSpace(l) && reports.ResolveConnectionString(l!) is not null);
        if (lab is null) return BadRequest(new { message = $"Downloads are not available for {file.LabName}: its report queue is not set up." });

        var filters = new LRN.ReportQueue.Shared.ReportSnapshotFilters(
            file.SnapshotFileId, file.ReportCode, file.BlobPath, insightPath, file.RunId, file.WeekFolder);
        var userName = (User.Identity?.Name ?? "").Trim();
        int? userId = int.TryParse(User.FindFirst(System.Security.Claims.ClaimTypes.NameIdentifier)?.Value, out var uid) ? uid : null;
        try
        {
            var reportId = await reports.QueueAsync(lab, LRN.ReportQueue.Shared.ReportTypes.ReportSnapshot, userName, userId, filters.ToJson(), ct);
            return Json(new { reportId, status = "Queued" });
        }
        catch (LRN.ReportQueue.Shared.DuplicateReportRequestException)
        {
            return Conflict(new { message = "This report is already being prepared for you. Check the Reports panel." });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex)
        {
            _logger.LogError(ex, "Report snapshot {FileId} could not be queued on {Lab}.", id, lab);
            return StatusCode(500, new { message = "The download could not be queued. Please try again." });
        }
    }

    // ── compare two weeks ─────────────────────────────────────────────────────

    /// <summary>Two weeks of the same report of one lab, compared (Report Snapshots &gt; Compare).</summary>
    [HttpGet]
    public async Task<IActionResult> CompareData(long a, long b, CancellationToken ct)
    {
        var fileA = await _index.GetFileAsync(a, ct);
        var fileB = await _index.GetFileAsync(b, ct);
        if (fileA is null || fileB is null || !fileA.IsPageModel || !fileB.IsPageModel)
            return NotFound(new { message = "One of the two snapshots is no longer available." });
        if (!CanViewReport(fileA) || !CanViewReport(fileB)) return Forbid();
        if (fileA.LabId != fileB.LabId || !string.Equals(fileA.ReportCode, fileB.ReportCode, StringComparison.OrdinalIgnoreCase))
            return BadRequest(new { message = "Only two weeks of the same report and lab can be compared." });

        try
        {
            var pageA = await _pages.ReadAsync(fileA.SnapshotFileId, fileA.BlobPath, ct);
            var pageB = await _pages.ReadAsync(fileB.SnapshotFileId, fileB.BlobPath, ct);
            if (pageA.BoundModel is null || pageB.BoundModel is null || pageA.BoundModel.GetType() != pageB.BoundModel.GetType())
                return BadRequest(new { message = "These two snapshots hold different report versions and cannot be compared." });

            var comparison = ReportSnapshotComparer.Compare(pageA.BoundModel, pageB.BoundModel);
            object Side(MasterDataSnapshotFileDetail f, ReportPageSnapshotFile p) => new
            {
                fileId = f.SnapshotFileId, weekFolder = f.WeekFolder, runId = f.RunId,
                snapshotDate = f.SnapshotDate, capturedOnUtc = p.CapturedOnUtc
            };
            return Json(new
            {
                reportCode = fileA.ReportCode,
                title = ReportSnapshotViewContext.Title(fileA.ReportCode),
                lab = string.IsNullOrWhiteSpace(pageB.LabName) ? fileB.LabName : pageB.LabName,
                a = Side(fileA, pageA),
                b = Side(fileB, pageB),
                totals = comparison.Totals,
                sections = comparison.Sections
            });
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Report snapshots {A} and {B} could not be compared.", a, b);
            return StatusCode(500, new { message = $"The snapshots could not be read: {ex.Message}" });
        }
    }

    // ── a Parquet file, as a table ────────────────────────────────────────────

    [HttpGet]
    public async Task<IActionResult> Data(long id, int page = 1, CancellationToken ct = default)
    {
        var file = await _index.GetFileAsync(id, ct);
        if (file is null) return CanView ? Unavailable("This snapshot file is no longer in the index. It may have been removed by retention or replaced by a re-run.") : Forbid();
        if (file.IsPageModel) return RedirectToAction(nameof(Report), new { id });
        // The lab's own Line Level / Claim Level / LIMS data (Report Snapshots); every other Parquet file, the
        // report sections, stays with the snapshot admins.
        if (!CanView && !(IsMasterData(file) && CanViewLab(User, _labConfig, file.LabId, file.LabName))) return Forbid();

        ViewData[ReportSnapshotViewContext.ViewDataKey] = Context(file, null, new Dictionary<string, long>());
        page = Math.Max(1, page);
        try
        {
            var bytes = await _store.ReadAsync(file.BlobPath, ct);
            var table = await ParquetTableReader.ReadPageAsync(bytes, (long)(page - 1) * DataPageSize, DataPageSize, ct);
            ViewData["Title"] = $"{ReportSnapshotViewContext.Title(file.ReportCode)} {file.ResultSetName} - {file.LabName}";
            return View(new ReportSnapshotDataViewModel { File = file, Table = table, Page = page, PageSize = DataPageSize });
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Snapshot Parquet file {FileId} ({Path}) could not be read.", id, file.BlobPath);
            return Unavailable($"The snapshot file could not be read: {ex.Message}", file);
        }
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    private static bool IsMasterData(MasterDataSnapshotFileDetail file) =>
        Codes.MasterData.Contains(file.ReportCode, StringComparer.OrdinalIgnoreCase)
        && string.Equals(file.ResultSetName, "Data", StringComparison.OrdinalIgnoreCase);

    private IActionResult Unavailable(string message, MasterDataSnapshotFileDetail? file = null)
    {
        if (file is not null)
            ViewData[ReportSnapshotViewContext.ViewDataKey] = Context(file, null, new Dictionary<string, long>());
        ViewData["Title"] = "Snapshot unavailable";
        return View("Unavailable", message);
    }

    /// <summary>The run's report display copies, by ReportCode (newest file when a report was captured twice).</summary>
    private async Task<Dictionary<string, long>> RunPageModelsAsync(long snapshotRunId, CancellationToken ct) =>
        (await _index.GetFilesAsync(snapshotRunId, ct))
            .Where(f => f.ResultSetName == SqlMasterDataSnapshotRepository.PageModelResultSet)
            .GroupBy(f => f.ReportCode, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.Max(f => f.SnapshotFileId), StringComparer.OrdinalIgnoreCase);

    private async Task<(MasterDataSnapshotFileDetail? File, ReportPageSnapshotFile? Page)> LoadAsync(long id, string reportCode, CancellationToken ct)
    {
        var file = await _index.GetFileAsync(id, ct);
        if (file is null || !file.IsPageModel || !string.Equals(file.ReportCode, reportCode, StringComparison.OrdinalIgnoreCase))
            return (file, null);
        return (file, await _pages.ReadAsync(file.SnapshotFileId, file.BlobPath, ct));
    }

    private ReportSnapshotViewContext Context(MasterDataSnapshotFileDetail file, ReportPageSnapshotFile? page, IReadOnlyDictionary<string, long> runPages)
    {
        var highlights = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (page is not null)
        {
            // The tabs as captured with this Executive Summary; their reports are the run's own snapshots.
            foreach (var tab in page.HighlightTabs)
                if (runPages.TryGetValue(tab.ReportCode, out var fileId))
                    highlights[tab.ReportCode] = Url.Action(nameof(Report), new { id = fileId, embed = 1, embedTabs = tab.EmbedTabs })!;
        }

        return new ReportSnapshotViewContext
        {
            FileId = file.SnapshotFileId,
            SnapshotRunId = file.SnapshotRunId,
            ReportCode = file.ReportCode,
            ResultSetName = file.IsPageModel ? null : file.ResultSetName,
            LabName = string.IsNullOrWhiteSpace(page?.LabName) ? file.LabName : page.LabName,
            RunId = file.RunId,
            WeekFolder = file.WeekFolder,
            CapturedOnUtc = page?.CapturedOnUtc ?? file.CreatedOn,
            Trigger = page?.Trigger,
            // Stored procedure names and builds are LRN's own notes, not the client's.
            LogicChanges = CanView ? page?.LogicChanges ?? [] : [],
            ViewerBasePath = Url.Content("~/ReportSnapshotViewer/"),
            ProductionPaneUrl = Url.Action(nameof(ProductionPane)),
            ProductionMetaUrl = Url.Action(nameof(ProductionMeta)),
            CollectionTabUrl = Url.Action(nameof(CollectionTab), new { id = file.SnapshotFileId }),
            CollectionMetaUrl = Url.Action(nameof(CollectionMeta), new { id = file.SnapshotFileId }),
            InsightPanelUrlTemplate = Url.Action(nameof(InsightPanel), new { id = file.SnapshotFileId, bucket = "__bucket__" }),
            HighlightUrls = highlights,
            InsightsUrl = InsightsFileOf(file, runPages) is { } insightsId ? Url.Action(nameof(InsightRows), new { id = insightsId }) : null
        };
    }

    /// <summary>The run's Key Insights snapshot of the report shown (or the insights file itself); null when none was captured.</summary>
    private static long? InsightsFileOf(MasterDataSnapshotFileDetail file, IReadOnlyDictionary<string, long> runPages) =>
        IsInsightCode(file.ReportCode) ? file.SnapshotFileId
        : Codes.InsightFor(file.ReportCode) is { } code && runPages.TryGetValue(code, out var id) ? id
        : null;

    /// <summary>
    /// What the live Collection Index sets besides the data (the export builder the snapshot comes from
    /// fills only the data): the tabs load lazily, from <see cref="CollectionTab"/>.
    /// </summary>
    private CollectionSummaryViewModel PrepareCollection(CollectionSummaryViewModel vm, string labKey)
    {
        if (string.IsNullOrWhiteSpace(vm.SelectedLab)) vm.SelectedLab = labKey;
        vm.AvailableLabs = [];
        vm.LazyLoadTabs = true;
        vm.ShowInsuranceVsPayment = true;
        vm.IsAggregateMode = false;
        vm.SupportsAggregateMode = LabCollectionPrefix.GetPrefix(vm.SelectedLab) is not null;
        if (vm.CollectionSummaryRule is null && _labSettings.Labs.TryGetValue(vm.SelectedLab, out var config))
            vm.CollectionSummaryRule = config.CollectionSummary?.Rule;
        return vm;
    }

    /// <summary>
    /// The Denial Summary page for the run: its DENIALSUMMARY snapshot (Monthly, Weekly, lists) with the
    /// run's DENIALINSIGHT snapshot as the Denial Insight tab - the two are captured separately because the
    /// insight rows are the client's upload. Opening the Denial Insight file opens the same page on that tab.
    /// </summary>
    private async Task<DenialClaimReportViewModel> DenialModelAsync(
        MasterDataSnapshotFileDetail file, ReportPageSnapshotFile page, IReadOnlyDictionary<string, long> runPages,
        string bucket, CancellationToken ct)
    {
        var lab = page.LabKey;
        DenialClaimReportViewModel model;
        DenialInsightSnapshotModel? insight = null;

        if (page.BoundModel is DenialClaimReportViewModel summary)
            model = summary;
        else
        {
            insight = page.BoundModel as DenialInsightSnapshotModel;
            model = await ReadRunReportAsync<DenialClaimReportViewModel>(runPages, Codes.DenialSummary, ct)
                    ?? new DenialClaimReportViewModel { CurrentLab = lab, WeekRange = file.WeekFolder, RunId = file.RunId };
        }
        insight ??= await ReadRunReportAsync<DenialInsightSnapshotModel>(runPages, Codes.DenialInsight, ct);

        if (string.IsNullOrWhiteSpace(model.CurrentLab)) model.CurrentLab = lab;
        model.ActiveTab = file.ReportCode == Codes.DenialInsight ? "insight" : "monthly";
        model.Insight = new DenialInsightPanelViewModel
        {
            CurrentLab = model.CurrentLab,
            CanEdit = false,
            Bucket = bucket,
            Rows = insight is null ? [] : bucket == DenialInsightBuckets.Previous ? insight.PreviousWeek : insight.CurrentWeek,
            BucketCounts = insight?.BucketCounts ?? new Dictionary<string, int>(StringComparer.Ordinal),
            CurrentWeekStart = insight?.CurrentWeekStart ?? SqlDenialClaimReportRepository.WeekStartOf(file.SnapshotDate)
        };

        ViewData["DenialWeekStartsOn"] = (_labConfig.GetDenialSummaryWeekStart(lab) ?? SqlDenialClaimReportRepository.DefaultWeekStartsOn).ToString();
        ViewData["DenialDateColumn"] = _labConfig.GetDenialSummaryDateColumn(lab);
        ViewData["DenialBalanceColumn"] = _labConfig.GetDenialSummaryBalanceColumn(lab);
        ViewData["PageLabel"] = "Denial Summary";
        return model;
    }

    private async Task<T?> ReadRunReportAsync<T>(IReadOnlyDictionary<string, long> runPages, string reportCode, CancellationToken ct) where T : class
    {
        if (!runPages.TryGetValue(reportCode, out var fileId)) return null;
        var file = await _index.GetFileAsync(fileId, ct);
        if (file is null) return null;
        try
        {
            return (await _pages.ReadAsync(file.SnapshotFileId, file.BlobPath, ct)).BoundModel as T;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex, "Report snapshot {FileId} ({Code}) could not be read for the Denial Summary view.", fileId, reportCode);
            return null;
        }
    }
}

public sealed class ReportSnapshotDataViewModel
{
    public required MasterDataSnapshotFileDetail File { get; init; }
    public required ParquetTablePage Table { get; init; }
    public int Page { get; init; }
    public int PageSize { get; init; }
    public int TotalPages => PageSize <= 0 ? 1 : Math.Max(1, (int)Math.Ceiling(Table.TotalRows / (double)PageSize));
}
