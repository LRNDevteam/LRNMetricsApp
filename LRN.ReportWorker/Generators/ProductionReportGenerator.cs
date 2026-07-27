using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ProductionReports.Models;
using LRN.ProductionReports.Services;
using LRN.ReportQueue.Shared;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async Production Report / Production Summary Report export.
///
/// Mirrors DashboardController.ExportProductionReportExcel (all labs) and
/// ExportNorthWestProductionReportExcel (NorthWest): 7 summary queries in
/// parallel + SQL-pre-split ClaimLevel/LineLevel raw segments, then the same
/// Excel builders. ALWAYS builds live — the sync no-filter "serve the latest
/// pre-generated snapshot" fast path is deliberately NOT replicated, so queued
/// exports always reflect current data and current formatting.
/// NorthWest uses INorthWestProductionSummaryRepository + the NW green-palette
/// builder; Augustus uses IAugustusProductionSummaryRepository for summaries then
/// the standard Excel builder + claim/line streaming; every other lab uses
/// IProductionReportRepository + the standard builder.
/// </summary>
public sealed class ProductionReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.ProductionReport;

    private readonly LabSettings _labSettings;
    private readonly IProductionReportRepository _repo;
    private readonly INorthWestProductionSummaryRepository _nwRepo;
    private readonly IAugustusProductionSummaryRepository _augRepo;
    private readonly ILogger<ProductionReportGenerator> _logger;

    public ProductionReportGenerator(
        LabSettings labSettings,
        IProductionReportRepository repo,
        INorthWestProductionSummaryRepository nwRepo,
        IAugustusProductionSummaryRepository augRepo,
        ILogger<ProductionReportGenerator> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _nwRepo      = nwRepo;
        _augRepo     = augRepo;
        _logger      = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(job.LabName, out var config))
            throw new InvalidOperationException($"Lab '{job.LabName}' is not configured.");
        if (!config.EnableProductionReport || !config.LineClaimEnable
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
            throw new InvalidOperationException($"Production Report is not available for '{job.LabName}'.");

        var connStr = config.DbConnectionString;
        var f = ProductionReportFilters.FromJson(job.FilterDetailsJson);

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }
        await Progress(2);

        // Same date semantics as the synchronous actions.
        var payerArg    = f.PayerNames is { Count: > 0 } ? f.PayerNames : null;
        var panelArg    = f.PanelNames is { Count: > 0 } ? f.PanelNames : null;
        var dosFromArg  = ParseDate(f.DosFrom);
        var dosToArg    = ParseDate(f.DosTo);
        var fbFromArg   = ParseDate(f.FirstBillFrom);
        var fbToArg     = ParseDate(f.FirstBillTo);
        var fbldFromArg = ParseDate(f.FirstBilledFrom);
        var fbldToArg   = ParseDate(f.FirstBilledTo);

        var hasFilters = payerArg is not null || panelArg is not null
            || dosFromArg is not null || dosToArg is not null
            || fbFromArg is not null || fbToArg is not null
            || fbldFromArg is not null || fbldToArg is not null;

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);

        // ALWAYS build live — even with no filters. (Originally this mirrored the sync
        // export's no-filter fast path of copying the newest pre-generated snapshot from
        // the lab's Reports folder, but those snapshots are only as current as the last
        // ClaimLineCSVDataCapture run/binary — a stale or differently-styled workbook
        // was silently re-served with a fresh timestamp. The queue runs in the
        // background, so paying the full build cost here is fine and guarantees the
        // output always reflects current data and current formatting.)
        if (!hasFilters)
            _logger.LogInformation(
                "ProductionReport {ReportId} [{Lab}]: no filters — building live full workbook (snapshot copy disabled).",
                job.ReportId, job.LabName);

        var isNorthWest = job.LabName.Equals("NorthWest", StringComparison.OrdinalIgnoreCase)
                       || job.LabName.Equals("NWL",       StringComparison.OrdinalIgnoreCase);
        var isAugustus = job.LabName.Equals("Augustus_Labs", StringComparison.OrdinalIgnoreCase)
                      || job.LabName.Equals("Augustus",      StringComparison.OrdinalIgnoreCase);

        var tempPath = targetPath + ".tmp";
        try
        {
            var totalRows = isNorthWest
                ? await BuildNorthWestAsync(connStr, job, f, payerArg, panelArg,
                    dosFromArg, dosToArg, fbFromArg, fbToArg, fbldFromArg, fbldToArg, tempPath, Progress, ct)
                : isAugustus
                    ? await BuildAugustusAsync(connStr, job, f, payerArg, panelArg,
                        dosFromArg, dosToArg, fbFromArg, fbToArg, fbldFromArg, fbldToArg, tempPath, Progress, ct)
                    : await BuildStandardAsync(connStr, config, job, f, payerArg, panelArg,
                        dosFromArg, dosToArg, fbFromArg, fbToArg, fbldFromArg, fbldToArg, tempPath, Progress, ct);
            File.Move(tempPath, targetPath, overwrite: true);

            var size = new FileInfo(targetPath).Length;
            _logger.LogInformation(
                "ProductionReport {ReportId} [{Lab}]: {Rows:N0} raw rows, {Size:N0} bytes → {Path}",
                job.ReportId, job.LabName, totalRows, size, targetPath);
            await Progress(100);
            return new GeneratedReportFile(fileName, targetPath, size, totalRows);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { /* ignore */ }
            throw;
        }
    }

    // ── Standard labs — mirrors ExportProductionReportExcel ────────────────────
    private async Task<int> BuildStandardAsync(
        string connStr, LabCsvConfig config, ClaimedReport job, ProductionReportFilters f,
        List<string>? payerArg, List<string>? panelArg,
        DateOnly? dosFrom, DateOnly? dosTo, DateOnly? fbFrom, DateOnly? fbTo,
        DateOnly? fbldFrom, DateOnly? fbldTo,
        string tempPath, Func<byte, Task> progress, CancellationToken ct)
    {
        // Per-lab Production Summary rules (identical to the controller).
        var productionRule = config.ProductionSummary?.Rule;
        var weekRule = !string.IsNullOrWhiteSpace(config.ProductionSummary?.WeekRule)
            ? config.ProductionSummary!.WeekRule
            : productionRule;
        var weekRange = config.ProductionSummary?.WeekRange;

        // Phase 1 — 7 summary queries concurrently.
        var monthlyTask = _repo.GetMonthlyClaimVolumeAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, productionRule, ct);
        var weeklyTask = _repo.GetWeeklyClaimVolumeAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, weekRule, weekRange, ct);
        var codingTask = _repo.GetCodingAsync(connStr, panelArg, ct);
        var payerBreakdownTask = _repo.GetPayerBreakdownAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, productionRule, ct);
        var payerPanelTask = _repo.GetPayerPanelAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, productionRule, ct);
        var unbilledAgingTask = _repo.GetUnbilledAgingAsync(
            connStr, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, productionRule, ct);
        var cptBreakdownTask = _repo.GetCptBreakdownAsync(
            connStr, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);

        await Task.WhenAll(monthlyTask, weeklyTask, codingTask, payerBreakdownTask,
            payerPanelTask, unbilledAgingTask, cptBreakdownTask);
        await progress(35);

        // Phase 2 — run info only. Claim/Line raw sheets are OpenXml-streamed onto
        // disk after the summary workbook is saved (avoids ClosedXML OOM).
        var runInfoTask = _repo.GetRunInfoAsync(connStr, ct);
        await runInfoTask;
        await progress(45);

        var result       = monthlyTask.Result;
        var weeklyResult = weeklyTask.Result;
        var codingResult = codingTask.Result;
        var pbResult     = payerBreakdownTask.Result;
        var pxpResult    = payerPanelTask.Result;
        var uaResult     = unbilledAgingTask.Result;
        var cptResult    = cptBreakdownTask.Result;

        var vm = new ProductionReportViewModel
        {
            AvailableLabs       = _labSettings.Labs.Keys.OrderBy(x => x).ToList(),
            SelectedLab         = job.LabName,
            FilterPayerNames    = f.PayerNames ?? [],
            FilterPanelNames    = f.PanelNames ?? [],
            FilterFirstBillFrom = f.FirstBillFrom,
            FilterFirstBillTo   = f.FirstBillTo,
            FilterDosFrom       = f.DosFrom,
            FilterDosTo         = f.DosTo,
            FilterFirstBilledFrom = f.FirstBilledFrom,
            FilterFirstBilledTo   = f.FirstBilledTo,
            PayerNames          = result.PayerNames,
            PanelNames          = result.PanelNames,
            Months              = result.Months,
            Years               = result.Years,
            PanelRows           = result.PanelRows,
            GrandTotalByMonth   = result.GrandTotalByMonth,
            GrandTotalClaims    = result.GrandTotalClaims,
            GrandTotalCharges   = result.GrandTotalCharges,
            WeekColumns              = weeklyResult.WeekColumns,
            WeeklyPanelRows          = weeklyResult.PanelRows,
            WeeklyGrandTotalByWeek   = weeklyResult.GrandTotalByWeek,
            WeeklyGrandTotalClaims   = weeklyResult.GrandTotalClaims,
            WeeklyGrandTotalCharges  = weeklyResult.GrandTotalCharges,
            CodingPanelRows          = codingResult.PanelRows,
            CodingGrandTotalClaims   = codingResult.GrandTotalClaims,
            CodingGrandTotalCharges  = codingResult.GrandTotalCharges,
            PayerBreakdownMonths     = pbResult.Months,
            PayerBreakdownYears      = pbResult.Years,
            PayerBreakdownRows       = pbResult.PayerRows,
            PayerBreakdownGrandByMonth = pbResult.GrandTotalByMonth,
            PayerBreakdownGrandTotal   = pbResult.GrandTotal,
            PayerPanelColumns           = pxpResult.PanelColumns,
            PayerPanelRows              = pxpResult.PayerRows,
            PayerPanelGrandByPanel      = pxpResult.GrandTotalByPanel,
            PayerPanelGrandTotalClaims  = pxpResult.GrandTotalClaims,
            PayerPanelGrandTotalCharges = pxpResult.GrandTotalCharges,
            UnbilledAgingRows               = uaResult.PanelRows,
            UnbilledAgingGrandByBucket      = uaResult.GrandTotalByBucket,
            UnbilledAgingGrandTotalClaims   = uaResult.GrandTotalClaims,
            UnbilledAgingGrandTotalCharges  = uaResult.GrandTotalCharges,
            CptBreakdownMonths              = cptResult.Months,
            CptBreakdownYears               = cptResult.Years,
            CptBreakdownRows                = cptResult.CptRows,
            CptBreakdownGrandByMonth        = cptResult.GrandTotalByMonth,
            CptBreakdownGrandTotalUnits     = cptResult.GrandTotalUnits,
            CptBreakdownGrandTotalCharges   = cptResult.GrandTotalCharges,
        };

        var (weekFolder, runId) = runInfoTask.Result;
        using (var workbook = ProductionReportExcelExportBuilder.CreateWorkbookSummaryOnly(
            vm, job.LabName, weekFolder, runId))
        {
            using var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None);
            workbook.SaveAs(fs);
        }
        await progress(55);

        var sqlRepo = _repo as SqlProductionReportRepository
            ?? throw new InvalidOperationException("Production report repository must be SqlProductionReportRepository for streamed exports.");

        var claimRows = await sqlRepo.AppendSpExportSheetsToFileAsync(
            tempPath, connStr,
            "dbo.usp_GetClaimLevelExportBuckets",
            "dbo.usp_GetClaimLevelExportDataByDateRange",
            "ClaimLevel", LRN.ProductionReports.Services.ExcelTheme.TabGreen,
            payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo,
            ct: ct);
        await progress(75);

        var lineRows = await sqlRepo.AppendSpExportSheetsToFileAsync(
            tempPath, connStr,
            "dbo.usp_GetLineLevelExportBuckets",
            "dbo.usp_GetLineLevelExportDataByDateRange",
            "LineLevel", LRN.ProductionReports.Services.ExcelTheme.TabGold,
            payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo,
            ct: ct);
        await progress(95);

        return claimRows + lineRows;
    }

    // ── Augustus — summaries via usp_GetAug_*; claim/line via standard SP stream ─
    private async Task<int> BuildAugustusAsync(
        string connStr, ClaimedReport job, ProductionReportFilters f,
        List<string>? payerArg, List<string>? panelArg,
        DateOnly? dosFrom, DateOnly? dosTo, DateOnly? fbFrom, DateOnly? fbTo,
        DateOnly? fbldFrom, DateOnly? fbldTo,
        string tempPath, Func<byte, Task> progress, CancellationToken ct)
    {
        // Phase 1 — 7 summary queries via Augustus SPs (usp_GetAug_*), never NW_*/Rule path.
        var monthlyTask = _augRepo.GetMonthlyAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var weeklyTask = _augRepo.GetWeeklyAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var codingTask = _augRepo.GetCodingAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var payerBreakdownTask = _augRepo.GetPayerBreakdownAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var payerPanelTask = _augRepo.GetPayerByPanelAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var unbilledAgingTask = _augRepo.GetUnbilledAgingAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var cptBreakdownTask = _augRepo.GetCptBreakdownAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);

        await Task.WhenAll(monthlyTask, weeklyTask, codingTask, payerBreakdownTask,
            payerPanelTask, unbilledAgingTask, cptBreakdownTask);
        await progress(35);

        // Phase 2 — run info only. Claim/Line raw sheets are OpenXml-streamed onto
        // disk after the summary workbook is saved (Augustus has no NW-style segments).
        var runInfoTask = _repo.GetRunInfoAsync(connStr, ct);
        await runInfoTask;
        await progress(45);

        var result       = monthlyTask.Result;
        var weeklyResult = weeklyTask.Result;
        var codingResult = codingTask.Result;
        var pbResult     = payerBreakdownTask.Result;
        var pxpResult    = payerPanelTask.Result;
        var uaResult     = unbilledAgingTask.Result;
        var cptResult    = cptBreakdownTask.Result;

        var vm = new ProductionReportViewModel
        {
            AvailableLabs       = _labSettings.Labs.Keys.OrderBy(x => x).ToList(),
            SelectedLab         = job.LabName,
            FilterPayerNames    = f.PayerNames ?? [],
            FilterPanelNames    = f.PanelNames ?? [],
            FilterFirstBillFrom = f.FirstBillFrom,
            FilterFirstBillTo   = f.FirstBillTo,
            FilterDosFrom       = f.DosFrom,
            FilterDosTo         = f.DosTo,
            FilterFirstBilledFrom = f.FirstBilledFrom,
            FilterFirstBilledTo   = f.FirstBilledTo,
            PayerNames          = result.PayerNames,
            PanelNames          = result.PanelNames,
            Months              = result.Months,
            Years               = result.Years,
            PanelRows           = result.PanelRows,
            GrandTotalByMonth   = result.GrandTotalByMonth,
            GrandTotalClaims    = result.GrandTotalClaims,
            GrandTotalCharges   = result.GrandTotalCharges,
            WeekColumns              = weeklyResult.WeekColumns,
            WeeklyPanelRows          = weeklyResult.PanelRows,
            WeeklyGrandTotalByWeek   = weeklyResult.GrandTotalByWeek,
            WeeklyGrandTotalClaims   = weeklyResult.GrandTotalClaims,
            WeeklyGrandTotalCharges  = weeklyResult.GrandTotalCharges,
            CodingPanelRows          = codingResult.PanelRows,
            CodingGrandTotalClaims   = codingResult.GrandTotalClaims,
            CodingGrandTotalCharges  = codingResult.GrandTotalCharges,
            PayerBreakdownMonths     = pbResult.Months,
            PayerBreakdownYears      = pbResult.Years,
            PayerBreakdownRows       = pbResult.PayerRows,
            PayerBreakdownGrandByMonth = pbResult.GrandTotalByMonth,
            PayerBreakdownGrandTotal   = pbResult.GrandTotal,
            PayerPanelColumns           = pxpResult.PanelColumns,
            PayerPanelRows              = pxpResult.PayerRows,
            PayerPanelGrandByPanel      = pxpResult.GrandTotalByPanel,
            PayerPanelGrandTotalClaims  = pxpResult.GrandTotalClaims,
            PayerPanelGrandTotalCharges = pxpResult.GrandTotalCharges,
            UnbilledAgingRows               = uaResult.PanelRows,
            UnbilledAgingGrandByBucket      = uaResult.GrandTotalByBucket,
            UnbilledAgingGrandTotalClaims   = uaResult.GrandTotalClaims,
            UnbilledAgingGrandTotalCharges  = uaResult.GrandTotalCharges,
            CptBreakdownMonths              = cptResult.Months,
            CptBreakdownYears               = cptResult.Years,
            CptBreakdownRows                = cptResult.CptRows,
            CptBreakdownGrandByMonth        = cptResult.GrandTotalByMonth,
            CptBreakdownGrandTotalUnits     = cptResult.GrandTotalUnits,
            CptBreakdownGrandTotalCharges   = cptResult.GrandTotalCharges,
        };

        var (weekFolder, runId) = runInfoTask.Result;
        using (var workbook = ProductionReportExcelExportBuilder.CreateWorkbookSummaryOnly(
            vm, job.LabName, weekFolder, runId))
        {
            using var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None);
            workbook.SaveAs(fs);
        }
        await progress(55);

        var sqlRepo = _repo as SqlProductionReportRepository
            ?? throw new InvalidOperationException("Production report repository must be SqlProductionReportRepository for streamed exports.");

        var claimRows = await sqlRepo.AppendSpExportSheetsToFileAsync(
            tempPath, connStr,
            "dbo.usp_GetClaimLevelExportBuckets",
            "dbo.usp_GetClaimLevelExportDataByDateRange",
            "ClaimLevel", LRN.ProductionReports.Services.ExcelTheme.TabGreen,
            payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo,
            ct: ct);
        await progress(75);

        var lineRows = await sqlRepo.AppendSpExportSheetsToFileAsync(
            tempPath, connStr,
            "dbo.usp_GetLineLevelExportBuckets",
            "dbo.usp_GetLineLevelExportDataByDateRange",
            "LineLevel", LRN.ProductionReports.Services.ExcelTheme.TabGold,
            payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo,
            ct: ct);
        await progress(95);

        return claimRows + lineRows;
    }

    // ── NorthWest — mirrors ExportNorthWestProductionReportExcel ───────────────
    private async Task<int> BuildNorthWestAsync(
        string connStr, ClaimedReport job, ProductionReportFilters f,
        List<string>? payerArg, List<string>? panelArg,
        DateOnly? dosFrom, DateOnly? dosTo, DateOnly? fbFrom, DateOnly? fbTo,
        DateOnly? fbldFrom, DateOnly? fbldTo,
        string tempPath, Func<byte, Task> progress, CancellationToken ct)
    {
        var t1 = _nwRepo.GetMonthlyAsync(connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var t2 = _nwRepo.GetWeeklyAsync(connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var t3 = _nwRepo.GetCodingAsync(connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var t4 = _nwRepo.GetPayerBreakdownAsync(connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var t5 = _nwRepo.GetPayerByPanelAsync(connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var t6 = _nwRepo.GetUnbilledAgingAsync(connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var t7 = _nwRepo.GetCptBreakdownAsync(connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);

        await Task.WhenAll(t1, t2, t3, t4, t5, t6, t7);
        await progress(35);

        var claimSegmentsTask = _nwRepo.GetClaimLevelDataExportSegmentsAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        var lineSegmentsTask = _nwRepo.GetLineLevelDataExportSegmentsAsync(
            connStr, payerArg, panelArg, dosFrom, dosTo, fbFrom, fbTo, fbldFrom, fbldTo, ct);
        await Task.WhenAll(claimSegmentsTask, lineSegmentsTask);

        var claimSegments = claimSegmentsTask.Result;
        var lineSegments  = lineSegmentsTask.Result;
        await progress(70);

        var monthlyResult = t1.Result;
        var weeklyResult  = t2.Result;
        var codingResult  = t3.Result;
        var pbResult      = t4.Result;
        var pxpResult     = t5.Result;
        var uaResult      = t6.Result;
        var cptResult     = t7.Result;

        var vm = new ProductionReportViewModel
        {
            AvailableLabs           = _labSettings.Labs.Keys.OrderBy(x => x).ToList(),
            SelectedLab             = job.LabName,
            FilterPayerNames        = f.PayerNames ?? [],
            FilterPanelNames        = f.PanelNames ?? [],
            FilterFirstBillFrom     = f.FirstBillFrom,
            FilterFirstBillTo       = f.FirstBillTo,
            FilterDosFrom           = f.DosFrom,
            FilterDosTo             = f.DosTo,
            FilterFirstBilledFrom   = f.FirstBilledFrom,
            FilterFirstBilledTo     = f.FirstBilledTo,
            Months                  = monthlyResult.Months,
            Years                   = monthlyResult.Years,
            PanelRows               = monthlyResult.PanelRows,
            GrandTotalByMonth       = monthlyResult.GrandTotalByMonth,
            GrandTotalClaims        = monthlyResult.GrandTotalClaims,
            GrandTotalCharges       = monthlyResult.GrandTotalCharges,
            WeekColumns             = weeklyResult.WeekColumns,
            WeeklyPanelRows         = weeklyResult.PanelRows,
            WeeklyGrandTotalByWeek  = weeklyResult.GrandTotalByWeek,
            WeeklyGrandTotalClaims  = weeklyResult.GrandTotalClaims,
            WeeklyGrandTotalCharges = weeklyResult.GrandTotalCharges,
            CodingPanelRows         = codingResult.PanelRows,
            CodingGrandTotalClaims  = codingResult.GrandTotalClaims,
            CodingGrandTotalCharges = codingResult.GrandTotalCharges,
            PayerBreakdownMonths    = pbResult.Months,
            PayerBreakdownYears     = pbResult.Years,
            PayerBreakdownRows      = pbResult.PayerRows,
            PayerBreakdownGrandByMonth = pbResult.GrandTotalByMonth,
            PayerBreakdownGrandTotal   = pbResult.GrandTotal,
            PayerPanelColumns           = pxpResult.PanelColumns,
            PayerPanelRows              = pxpResult.PayerRows,
            PayerPanelGrandByPanel      = pxpResult.GrandTotalByPanel,
            PayerPanelGrandTotalClaims  = pxpResult.GrandTotalClaims,
            PayerPanelGrandTotalCharges = pxpResult.GrandTotalCharges,
            UnbilledAgingRows               = uaResult.PanelRows,
            UnbilledAgingGrandByBucket      = uaResult.GrandTotalByBucket,
            UnbilledAgingGrandTotalClaims   = uaResult.GrandTotalClaims,
            UnbilledAgingGrandTotalCharges  = uaResult.GrandTotalCharges,
            CptBreakdownMonths              = cptResult.Months,
            CptBreakdownYears               = cptResult.Years,
            CptBreakdownRows                = cptResult.CptRows,
            CptBreakdownGrandByMonth        = cptResult.GrandTotalByMonth,
            CptBreakdownGrandTotalUnits     = cptResult.GrandTotalUnits,
            CptBreakdownGrandTotalCharges   = cptResult.GrandTotalCharges,
        };

        using var workbook = NorthWestProductionSummaryExcelExportBuilder.CreateWorkbook(
            vm, job.LabName, claimSegments, lineSegments, _logger);
        await progress(88);

        using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
            workbook.SaveAs(fs);

        return claimSegments.Sum(s => s.Rows.Count) + lineSegments.Sum(s => s.Rows.Count);
    }

    private static DateOnly? ParseDate(string? value) =>
        DateOnly.TryParse(value, out var d) && d != default ? d : null;
}
