using CaptureDataApp.Services;
using Microsoft.Extensions.Configuration;

// =============================================================================
// CodingMaster capture + aggregates moved to LRN.CodingMaster.Runner (STEP 4).
//
// To RE-ENABLE this CaptureDataApp coding path temporarily:
//   1) Set enableCodingMasterCapture = true below
//   2) Rebuild / run CaptureDataApp
// To keep disabled: leave enableCodingMasterCapture = false
// =============================================================================
// Flip to true only if Runner STEP 4 fails and you need the old CaptureDataApp path.
var enableCodingMasterCapture = false;

var cfg = new ConfigurationBuilder()
    .SetBasePath(AppContext.BaseDirectory)
    .AddJsonFile("appsettings.json", optional: false)
    .Build();

using var log = new AppLogger(cfg);

if (!enableCodingMasterCapture)
{
    log.Header("CaptureDataApp — Coding Validation Capture DISABLED");
    log.Warn("CodingValidated load / financial summary / usp_RefreshCodingAggregates / dashboard JSON");
    log.Warn("now run inside LRN.CodingMaster.Runner STEP 4.");
    log.Warn("Set enableCodingMasterCapture = true in Program.cs to re-enable this app path.");
    return 0;
}

// ── CodingMaster capture + aggregate flow (disabled unless flag above is true) ──
var labConfigFolder = cfg["AppSettings:LabConfigFolder"]
    ?? throw new InvalidOperationException("AppSettings:LabConfigFolder is not configured.");

var labNames = cfg.GetSection("AppSettings:Labs").Get<List<string>>()
    ?? throw new InvalidOperationException("AppSettings:Labs is not configured.");

var masterConnectionString =
    cfg.GetConnectionString("LRNMaster")
    ?? cfg.GetConnectionString("DefaultConnection");

var reportLoggingEnabled = cfg.GetValue("ReportRunLogging:Enabled", true);
var reportLoggingCreatedBy = cfg["ReportRunLogging:CreatedBy"] ?? "CaptureDataApp";

AppDomain.CurrentDomain.UnhandledException += (_, e) =>
{
    try { log.Error($"FATAL — unhandled exception: {e.ExceptionObject}"); } catch { /* best effort */ }
};

var globalRefresh = args.Any(a => a.Equals("DBRefresh", StringComparison.OrdinalIgnoreCase));

log.Header("CaptureDataApp — Coding Validation Capture");
if (globalRefresh) log.Info("Mode              : DBRefresh (global — forced reload of all labs)");
log.Info($"Log file          : {log.LogFilePath}");
log.Info($"Lab config folder : {labConfigFolder}");
log.Info($"Labs configured   : {labNames.Count}");
log.Info($"ReportRunLogging  : {(reportLoggingEnabled ? "Enabled" : "Disabled")}");
log.Blank();

var labConfigs = LabConfigLoader.LoadAll(labConfigFolder, labNames, log);

int labsProcessed = 0, labsSkipped = 0, labsFailed = 0;

foreach (var lab in labConfigs)
{
    log.Info($"[Lab] {lab.LabName}");

    var forceRefresh = globalRefresh || lab.DBRefresh;
    if (forceRefresh) log.Info($"  DBRefresh      : ON (forced reload for this lab)");

    if (!lab.DBEnabled || string.IsNullOrWhiteSpace(lab.DbConnectionString))
    {
        log.Warn($"  [SKIP] DBEnabled=false or DbConnectionString not configured.");
        labsSkipped++;
        continue;
    }

    if (string.IsNullOrWhiteSpace(lab.CodingReportsPath))
    {
        log.Warn($"  [SKIP] CodingReportsPath not configured.");
        labsSkipped++;
        continue;
    }

    log.Info($"  Reports path : {lab.CodingReportsPath}");

    var reportLog = new CodingValidationReportRunLogger(
        masterConnectionString,
        reportLoggingEnabled,
        reportLoggingCreatedBy,
        log);

    string filePath = string.Empty;
    string weekFolder = string.Empty;
    string? runId = null;
    string? sourceFileName = null;
    CodingDbService db;

    try
    {
        var resolved = ReportFileResolver.ResolveLatest(lab.CodingReportsPath);
        if (resolved is null)
        {
            log.Warn($"  [SKIP] No CodingValidated report found under: {lab.CodingReportsPath}");
            labsSkipped++;
            continue;
        }

        (filePath, weekFolder) = resolved.Value;
        sourceFileName = Path.GetFileName(filePath);
        runId = Path.GetFileNameWithoutExtension(filePath).Split('_')[0];

        log.Info($"  File         : {sourceFileName}");
        log.Info($"  Week folder  : {weekFolder}");
        log.Info($"  RunId        : {runId}");

        db = new CodingDbService(lab.DbConnectionString);
        var liveSourcePath = db.GetLatestSourceFilePath(lab.LabName);
        if (!forceRefresh && string.Equals(liveSourcePath, filePath, StringComparison.OrdinalIgnoreCase))
        {
            log.Info($"  Already loaded — same SourceFilePath, skipping.");

            try
            {
                var counts = db.RefreshAggregates(lab.LabName, onlyIfEmpty: true);
                if (counts.Count > 0)
                {
                    log.Info($"  Aggregates were empty — refreshed:");
                    foreach (var (aggDataset, aggRows) in counts)
                        log.Info($"    {aggDataset,-12} : {aggRows:N0} rows");

                    reportLog.Begin(runId, lab.LabName, sourceFileName);
                    reportLog.StepInfo(runId, lab.LabName, "AGGREGATES",
                        "Aggregates were empty and have been refreshed for already-loaded file.",
                        sourceFileName);
                    reportLog.CompleteSuccess(runId, lab.LabName,
                        "Already loaded file; aggregates refreshed successfully.",
                        sourceFileName: sourceFileName);
                }
            }
            catch (Exception aggEx)
            {
                log.Warn($"  Aggregate check failed — {aggEx.Message} (run Sql/04_CodingAggregates.sql on this DB).");
                reportLog.Begin(runId, lab.LabName, sourceFileName);
                reportLog.Fail(runId, lab.LabName, "AGGREGATES", aggEx.ToString(), sourceFileName);
            }

            labsSkipped++;
            log.Blank();
            continue;
        }
    }
    catch (Exception preEx)
    {
        log.Error($"  FAILED (pre-check): {preEx.Message}");
        log.Error($"  {preEx.StackTrace ?? ""}");
        if (!string.IsNullOrWhiteSpace(runId))
        {
            reportLog.Begin(runId, lab.LabName, sourceFileName);
            reportLog.Fail(runId, lab.LabName, "PRECHECK", preEx.ToString(), sourceFileName);
        }
        labsFailed++;
        log.Blank();
        continue;
    }

    reportLog.Begin(runId, lab.LabName, sourceFileName);

    try
    {
        log.Info($"  Reading Excel…");
        reportLog.StepInfo(runId, lab.LabName, "READ", "Reading CodingValidated Excel.", sourceFileName);
        var (rows, summary) = CodingReportExcelReader.Read(filePath, lab.LabName, weekFolder, log);
        log.Info($"  Read complete : {rows.Count} detail rows, summary parsed.");
        reportLog.StepInfo(runId, lab.LabName, "READ",
            $"Read complete: {rows.Count} detail rows.", sourceFileName);

        if (forceRefresh && rows.Count > 0)
        {
            var cleared = db.ClearFileLogEntry(rows[0].FileLogId);
            log.Info(cleared
                ? $"  DBRefresh: file-log entry cleared — data will be reloaded (prior rows archived)."
                : $"  DBRefresh: no existing file-log entry — loading as new.");
            reportLog.StepInfo(runId, lab.LabName, "DBREFRESH",
                cleared ? "File-log cleared for reload." : "No existing file-log entry.",
                sourceFileName);
        }

        log.Info($"  Inserting detail rows…");
        reportLog.StepInfo(runId, lab.LabName, "INSERT", "Inserting CodingValidation detail rows.", sourceFileName);
        var inserted = db.InsertDetailRows(rows, lab.LabName, weekFolder);

        if (inserted == 0)
        {
            log.Info($"  Already loaded — skipped (detail rows + financial summary).");
            reportLog.StepInfo(runId, lab.LabName, "INSERT",
                "Already loaded — detail insert skipped.", sourceFileName);

            log.Info($"  Refreshing coding aggregates…");
            reportLog.StepInfo(runId, lab.LabName, "AGGREGATES", "Refreshing coding aggregates.", sourceFileName);
            var skipAggCounts = db.RefreshAggregates(lab.LabName);
            foreach (var (aggDataset, aggRows) in skipAggCounts)
                log.Info($"    {aggDataset,-12} : {aggRows:N0} rows");

            reportLog.CompleteSuccess(runId, lab.LabName,
                "CodingValidated already loaded; aggregates refreshed.",
                rowCount: rows.Count,
                sourceFileName: sourceFileName);

            labsProcessed++;
            log.Blank();
            continue;
        }

        log.Info($"  Inserted : {inserted} rows.");
        reportLog.StepInfo(runId, lab.LabName, "INSERT",
            $"Inserted {inserted} detail rows.", sourceFileName);

        log.Info($"  Upserting financial summary…");
        reportLog.StepInfo(runId, lab.LabName, "FINANCIAL", "Upserting financial summary.", sourceFileName);
        bool summaryWritten = db.UpsertFinancialSummary(summary, forceRefresh);
        log.Info(summaryWritten
            ? $"  Financial summary upserted."
            : $"  Financial summary already loaded — skipped.");
        reportLog.StepInfo(runId, lab.LabName, "FINANCIAL",
            summaryWritten ? "Financial summary upserted." : "Financial summary skipped (already loaded).",
            sourceFileName);

        log.Info($"  Refreshing coding aggregates…");
        reportLog.StepInfo(runId, lab.LabName, "AGGREGATES", "Refreshing coding aggregates.", sourceFileName);
        var aggSw = System.Diagnostics.Stopwatch.StartNew();
        var aggCounts = db.RefreshAggregates(lab.LabName);
        aggSw.Stop();
        foreach (var (aggDataset, aggRows) in aggCounts)
            log.Info($"    {aggDataset,-12} : {aggRows:N0} rows");
        log.Success($"  Aggregates refreshed in {aggSw.Elapsed.TotalSeconds:F1}s.");
        reportLog.StepInfo(runId, lab.LabName, "AGGREGATES",
            $"Aggregates refreshed in {aggSw.Elapsed.TotalSeconds:F1}s.", sourceFileName);

        log.Info($"  Writing dashboard JSON…");
        try
        {
            log.Info($"  Querying YTD insights…");
            var ytdInsights = CodingDashboardDbReader.GetYtdInsights(lab.DbConnectionString);
            log.Info($"  Querying YTD summary…");
            var ytdSummary  = CodingDashboardDbReader.GetYtdSummary(lab.DbConnectionString);
            log.Info($"  Querying WTD insights…");
            var wtdInsights = CodingDashboardDbReader.GetWtdInsights(lab.DbConnectionString);
            log.Info($"  Querying WTD summary…");
            var wtdSummary  = CodingDashboardDbReader.GetWtdSummary(lab.DbConnectionString);
            log.Info($"  Querying validation detail…");
            var valDetail   = CodingDashboardDbReader.GetValidationDetail(lab.DbConnectionString);

            log.Info($"  YTD insights : {ytdInsights.Count} rows | YTD summary : {ytdSummary.Count} rows");
            log.Info($"  WTD insights : {wtdInsights.Count} rows | WTD summary : {wtdSummary.Count} rows");
            log.Info($"  Validation   : {valDetail.Count} rows");

            var jsonPath  = DashboardJsonWriter.Write(
                                filePath, summary,
                                ytdInsights, ytdSummary,
                                wtdInsights, wtdSummary,
                                valDetail);
            var jsonBytes = new FileInfo(jsonPath).Length;
            log.Success($"  JSON written  : {Path.GetFileName(jsonPath)}");
            log.Info($"  JSON path     : {jsonPath}");
            log.Info($"  JSON size     : {jsonBytes:N0} bytes");
            reportLog.StepInfo(runId, lab.LabName, "JSON",
                $"Dashboard JSON written: {Path.GetFileName(jsonPath)}", sourceFileName);
        }
        catch (Exception jsonEx)
        {
            log.Error($"  JSON write failed — {jsonEx.Message}");
            reportLog.StepInfo(runId, lab.LabName, "JSON",
                $"JSON write failed (non-blocking): {jsonEx.Message}", sourceFileName);
        }

        reportLog.CompleteSuccess(runId, lab.LabName,
            $"CodingValidated loaded and aggregates refreshed. Inserted={inserted}.",
            rowCount: inserted,
            sourceFileName: sourceFileName);

        labsProcessed++;
    }
    catch (Exception ex)
    {
        log.Error($"  {ex.Message}");
        reportLog.Fail(runId, lab.LabName, "CAPTURE", ex.ToString(), sourceFileName);
        labsFailed++;
    }

    log.Blank();
}

log.Header("Run complete");
log.Info($"  Processed : {labsProcessed}");
log.Info($"  Skipped   : {labsSkipped}");
log.Info($"  Failed    : {labsFailed}");

return labsFailed > 0 ? 1 : 0;
