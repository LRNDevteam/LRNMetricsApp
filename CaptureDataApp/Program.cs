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
log.Header("CaptureDataApp — Coding Validation Capture");
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

    // ── Resolve latest report file ────────────────────────────────────────────
    var resolved = ReportFileResolver.ResolveLatest(lab.CodingReportsPath);
    if (resolved is null)
    {
        log.Warn($"  [SKIP] No CodingValidated report found under: {lab.CodingReportsPath}");
        labsSkipped++;
        continue;
    }

    var (filePath, weekFolder) = resolved.Value;
    var currentFileName = Path.GetFileName(filePath);
    log.Info($"  File         : {currentFileName}");
    log.Info($"  Week folder  : {weekFolder}");

    // ── Early skip: SourceFilePath already live in CodingValidation ──────────
    var db = new CodingDbService(lab.DbConnectionString);
    var liveSourcePath = db.GetLatestSourceFilePath(lab.LabName);
    if (string.Equals(liveSourcePath, filePath, StringComparison.OrdinalIgnoreCase))
    {
        log.Info($"  Already loaded — same SourceFilePath, skipping.");
        labsSkipped++;
        log.Blank();
        continue;
    }

    try
    {
        // ── Read Excel ────────────────────────────────────────────────────────
        log.Info($"  Reading Excel…");
        var (rows, summary) = CodingReportExcelReader.Read(filePath, lab.LabName, weekFolder);
        log.Info($"  Read complete : {rows.Count} detail rows, summary parsed.");

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
        bool summaryWritten = db.UpsertFinancialSummary(summary);
        log.Info(summaryWritten
            ? $"  Financial summary upserted."
            : $"  Financial summary already loaded — skipped.");

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
