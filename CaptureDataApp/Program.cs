using CaptureDataApp.Services;
using Microsoft.Extensions.Configuration;

// ── Configuration ─────────────────────────────────────────────────────────────
var cfg = new ConfigurationBuilder()
    .SetBasePath(AppContext.BaseDirectory)
    .AddJsonFile("appsettings.json", optional: false)
    .Build();

var labConfigFolder = cfg["AppSettings:LabConfigFolder"]
    ?? throw new InvalidOperationException("AppSettings:LabConfigFolder is not configured.");

var labNames = cfg.GetSection("AppSettings:Labs").Get<List<string>>()
    ?? throw new InvalidOperationException("AppSettings:Labs is not configured.");

// ── Logger ────────────────────────────────────────────────────────────────────
using var log = new AppLogger(cfg);

// Last-resort logging: if anything escapes the per-lab try/catch blocks,
// write the full exception to the log file before the process terminates
// (otherwise the only trace is a bare KERNELBASE 0xe0434352 event log entry).
AppDomain.CurrentDomain.UnhandledException += (_, e) =>
{
    try { log.Error($"FATAL — unhandled exception: {e.ExceptionObject}"); } catch { /* best effort */ }
};
// ── DBRefresh mode ────────────────────────────────────────────────────────────
// Forces a full reload: the SourceFilePath skip is bypassed, the file-log RunId
// is cleared (prior rows get archived by the bulk-insert proc), the financial
// summary is re-upserted, and the aggregate tables are rebuilt. Use after
// regenerating CodingValidated reports.
//   • Global : "CaptureDataApp.exe DBRefresh"  → all labs
//   • Per-lab: "DBRefresh": true in the lab config JSON
var globalRefresh = args.Any(a => a.Equals("DBRefresh", StringComparison.OrdinalIgnoreCase));

log.Header("CaptureDataApp — Coding Validation Capture");
if (globalRefresh) log.Info("Mode              : DBRefresh (global — forced reload of all labs)");
log.Info($"Log file          : {log.LogFilePath}");
log.Info($"Lab config folder : {labConfigFolder}");
log.Info($"Labs configured   : {labNames.Count}");
log.Blank();

// ── Load lab configs ──────────────────────────────────────────────────────────
var labConfigs = LabConfigLoader.LoadAll(labConfigFolder, labNames, log);

int labsProcessed = 0, labsSkipped = 0, labsFailed = 0;

foreach (var lab in labConfigs)
{
    log.Info($"[Lab] {lab.LabName}");

    // Per-lab OR global DBRefresh
    var forceRefresh = globalRefresh || lab.DBRefresh;
    if (forceRefresh) log.Info($"  DBRefresh      : ON (forced reload for this lab)");

    // ── Validate config ───────────────────────────────────────────────────────
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

    // ── Resolve latest report file + early-skip check ─────────────────────────
    // Wrapped in try/catch so a bad share path or unreachable lab DB fails only
    // this lab instead of crashing the whole process (Event Log 0xe0434352).
    string filePath, weekFolder;
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
        var currentFileName = Path.GetFileName(filePath);
        log.Info($"  File         : {currentFileName}");
        log.Info($"  Week folder  : {weekFolder}");

        // ── Early skip: SourceFilePath already live in CodingValidation ──────
        db = new CodingDbService(lab.DbConnectionString);
        var liveSourcePath = db.GetLatestSourceFilePath(lab.LabName);
        if (!forceRefresh && string.Equals(liveSourcePath, filePath, StringComparison.OrdinalIgnoreCase))
        {
            log.Info($"  Already loaded — same SourceFilePath, skipping.");

            // First-time deployment safety net: if the aggregate tables are still
            // empty (e.g. 04_CodingAggregates.sql was just deployed) populate them
            // now even though no new file was loaded.
            try
            {
                var counts = db.RefreshAggregates(lab.LabName, onlyIfEmpty: true);
                if (counts.Count > 0)
                {
                    log.Info($"  Aggregates were empty — refreshed:");
                    foreach (var (aggDataset, aggRows) in counts)
                        log.Info($"    {aggDataset,-12} : {aggRows:N0} rows");
                }
            }
            catch (Exception aggEx)
            {
                log.Warn($"  Aggregate check failed — {aggEx.Message} (run Sql/04_CodingAggregates.sql on this DB).");
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
        labsFailed++;
        log.Blank();
        continue;
    }

    try
    {
        // ── Read Excel ────────────────────────────────────────────────────────
        log.Info($"  Reading Excel…");
        var (rows, summary) = CodingReportExcelReader.Read(filePath, lab.LabName, weekFolder, log);
        log.Info($"  Read complete : {rows.Count} detail rows, summary parsed.");

        // ── DBRefresh: clear file log so the same RunId reloads ──────────────
        if (forceRefresh && rows.Count > 0)
        {
            var cleared = db.ClearFileLogEntry(rows[0].FileLogId);
            log.Info(cleared
                ? $"  DBRefresh: file-log entry cleared — data will be reloaded (prior rows archived)."
                : $"  DBRefresh: no existing file-log entry — loading as new.");
        }

        // ── Insert to DB ──────────────────────────────────────────────────────
        log.Info($"  Inserting detail rows…");
        var inserted = db.InsertDetailRows(rows, lab.LabName, weekFolder);

        if (inserted == 0)
        {
            log.Info($"  Already loaded — skipped (detail rows + financial summary).");
            labsProcessed++;
            log.Blank();
            continue;
        }

        log.Info($"  Inserted : {inserted} rows.");

        log.Info($"  Upserting financial summary…");
        bool summaryWritten = db.UpsertFinancialSummary(summary, forceRefresh);
        log.Info(summaryWritten
            ? $"  Financial summary upserted."
            : $"  Financial summary already loaded — skipped.");

        // ── Refresh aggregate tables (YTD/WTD Insights + Summary) ────────────
        // Rebuilds CodingAgg_* from CodingValidation via usp_RefreshCodingAggregates
        // so the dashboard (and the JSON sidecar below) read pre-computed values.
        log.Info($"  Refreshing coding aggregates…");
        var aggSw = System.Diagnostics.Stopwatch.StartNew();
        var aggCounts = db.RefreshAggregates(lab.LabName);
        aggSw.Stop();
        foreach (var (aggDataset, aggRows) in aggCounts)
            log.Info($"    {aggDataset,-12} : {aggRows:N0} rows");
        log.Success($"  Aggregates refreshed in {aggSw.Elapsed.TotalSeconds:F1}s.");

        // ── Write JSON sidecar (same path/name as .xlsx, extension → .json) ──
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
        }
        catch (Exception jsonEx)
        {
            log.Error($"  JSON write failed — {jsonEx.Message}");
        }

        labsProcessed++;
    }
    catch (Exception ex)
    {
        log.Error($"  {ex.Message}");
        labsFailed++;
    }

    log.Blank();
}

// ── Final report ──────────────────────────────────────────────────────────────
log.Header("Run complete");
log.Info($"  Processed : {labsProcessed}");
log.Info($"  Skipped   : {labsSkipped}");
log.Info($"  Failed    : {labsFailed}");

// Exit code 1 lets Task Scheduler detect failures (Run result ≠ 0)
return labsFailed > 0 ? 1 : 0;
