using System.Text.Json;
using ClaimLineCSVDataCapture.Models;
using ClaimLineCSVDataCapture.Services;
using LRN.ProductionReports.Models;
using LRN.ProductionReports.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;

// ── Configuration ─────────────────────────────────────────────────────────────
var cfg = new ConfigurationBuilder()
    .SetBasePath(AppContext.BaseDirectory)
    .AddJsonFile("appsettings.json", optional: false)
    .Build();

var labConfigFolder = cfg["AppSettings:LabConfigFolder"]
    ?? throw new InvalidOperationException("AppSettings:LabConfigFolder is not configured.");

var labNames = cfg.GetSection("AppSettings:Labs").Get<List<string>>()
    ?? throw new InvalidOperationException("AppSettings:Labs is not configured.");

// ── Load field mappings ───────────────────────────────────────────────────────
var fieldMappingsPath = cfg["AppSettings:FieldMappingsPath"];
if (string.IsNullOrWhiteSpace(fieldMappingsPath) || !File.Exists(fieldMappingsPath))
    fieldMappingsPath = Path.Combine(AppContext.BaseDirectory, "FieldMappings.json");

if (!File.Exists(fieldMappingsPath))
    throw new FileNotFoundException("FieldMappings.json not found. Configure 'AppSettings:FieldMappingsPath' in appsettings.json.", fieldMappingsPath);
var fieldMappingsJson = File.ReadAllText(fieldMappingsPath);
var jsonOptions = new JsonSerializerOptions
{
    PropertyNameCaseInsensitive = true,
    ReadCommentHandling = JsonCommentHandling.Skip,
    AllowTrailingCommas = true,
};

var globalFieldMappings = JsonSerializer.Deserialize<FieldMappingsRoot>(fieldMappingsJson, jsonOptions)
    ?? throw new InvalidOperationException("Failed to deserialize FieldMappings.json.");

// Keep backward-compatible alias — used when a lab has no lab-specific override
var fieldMappings = globalFieldMappings;

var workingFolder = cfg["AppSettings:WorkingFolder"]
    ?? Path.Combine(Path.GetTempPath(), "ClaimLineCSVDataCapture");
Directory.CreateDirectory(workingFolder);

// ── LRNMaster connection (used by sp_GetRecentSuccessRunByLab RunId gate) ──────
var masterConnectionString = cfg.GetConnectionString("DefaultConnection");

// ── Logger ────────────────────────────────────────────────────────────────────
using var log = new ClaimLineCSVDataCapture.Services.AppLogger(cfg);
log.Header("ClaimLineCSVDataCapture — Claim/Line Level CSV Capture");
log.Info($"Log file          : {log.LogFilePath}");
log.Info($"Lab config folder : {labConfigFolder}");
log.Info($"Field mappings    : {fieldMappingsPath}");
log.Info($"Working folder    : {workingFolder}");
log.Info($"  ClaimLevel fields : {fieldMappings.ClaimLevel.Fields.Count}");
log.Info($"  LineLevel fields  : {fieldMappings.LineLevel.Fields.Count}");
log.Info($"Labs configured   : {labNames.Count}");
log.Blank();

// ── Load lab configs ──────────────────────────────────────────────────────────
var labConfigs = LabConfigLoader.LoadAll(labConfigFolder, labNames, log);
var productionReportRepo = new SqlProductionReportRepository(NullLogger<SqlProductionReportRepository>.Instance);
var collectionSummaryRepo = new SqlCollectionSummaryReportRepository(NullLogger<SqlCollectionSummaryReportRepository>.Instance);

int labsProcessed = 0, labsSkipped = 0, labsFailed = 0;
var processedLabNames = new List<string>();

// Report tasks are started per-lab and awaited after the main loop
// so that large-data labs don't block CSV ingestion for other labs.
var reportTasks = new List<(string LabName, string ReportType, Task Task)>();

foreach (var lab in labConfigs)
{
    log.Header($"Lab: {lab.LabName}");
    log.Info($"  ClaimLineInsert={lab.ClaimLineInsert}  ClaimLineRefresh={lab.ClaimLineRefresh}  DBEnabled={lab.DBEnabled}");

    // ── Gate: skip lab if DBEnabled is false ──────────────────────────────
    if (!lab.DBEnabled)
    {
        log.Warn($"  [SKIP] DBEnabled=false — skipping lab.");
        labsSkipped++;
        continue;
    }

    // ── Gate: only proceed when ClaimLineInsert is enabled ─────────────────
    if (!lab.ClaimLineInsert)
    {
        log.Warn($"  [SKIP] ClaimLineInsert is not enabled — skipping lab.");
        labsSkipped++;
        continue;
    }

    // ── Validate config — check DbConnectionString ────────────────────────
    if (string.IsNullOrWhiteSpace(lab.DbConnectionString))
    {
        log.Warn($"  [SKIP] ClaimLineInsert is enabled but DbConnectionString is not configured — skipping lab.");
        labsSkipped++;
        continue;
    }

    if (string.IsNullOrWhiteSpace(lab.ServerMastersPath))
    {
        log.Warn($"  [SKIP] ServerMastersBasePath or ServerMasterFolderName not configured.");
        labsSkipped++;
        continue;
    }

    if (!Directory.Exists(lab.ServerMastersPath))
    {
        log.Warn($"  [SKIP] Path does not exist: {lab.ServerMastersPath}");
        labsSkipped++;
        continue;
    }

    log.Info($"  CSV source path : {lab.ServerMastersPath}");

    // Resolve field mappings: use lab-specific file when configured and present, else fall back to global
    var labFieldMappingsPath = lab.Paths.LabFieldMappingsPath;
    FieldMappingsRoot labFieldMappings;
    if (!string.IsNullOrWhiteSpace(labFieldMappingsPath) && File.Exists(labFieldMappingsPath))
    {
        log.Info($"  Field mappings    : {labFieldMappingsPath} (lab-specific)");
        var labJson = File.ReadAllText(labFieldMappingsPath);
        labFieldMappings = JsonSerializer.Deserialize<FieldMappingsRoot>(labJson, jsonOptions)
            ?? throw new InvalidOperationException($"Failed to deserialize lab-specific FieldMappings.json for {lab.LabName}.");
    }
    else
    {
        if (!string.IsNullOrWhiteSpace(labFieldMappingsPath))
            log.Warn($"  [FieldMappings] Lab-specific path not found: {labFieldMappingsPath} — using global.");
        labFieldMappings = globalFieldMappings;
    }

    var db = new ClaimLineDbService(lab.DbConnectionString);
    var claimInserted = false;
    var lineInserted = false;

    // ── Gate: validate latest input file's RunId against latest completed RunId ──
    // Before processing the latest files, fetch the latest successfully completed
    // RunId (sp_GetRecentSuccessRunByLab on LRNMaster) and compare it with the RunId
    // prefix of the latest input file. Processing (including ClaimLineRefresh=true)
    // only continues when both RunIds match.
    if (!RunIdGatePassed(lab, masterConnectionString, log))
    {
        labsSkipped++;
        continue;
    }

    // ── Refresh mode: purge existing lab data so the latest file re-inserts cleanly ──
    if (lab.ClaimLineRefresh)
    {
        log.Info($"  [Refresh] ClaimLineRefresh=true — purging existing data for {lab.LabName}…");
        try
        {
            var (purgedClaim, purgedLine, purgedLog) = db.PurgeLabClaimLineData();
            log.Info($"  [Refresh] Purged {purgedClaim} ClaimLevelData row(s), {purgedLine} LineLevelData row(s), {purgedLog} LineClaimFileLogs row(s).");
        }
        catch (Exception ex)
        {
            log.Error($"  [Refresh] Purge failed — {ex.Message}. Skipping lab to avoid partial data.");
            labsFailed++;
            continue;
        }
    }

    // ── Process Claim Level CSV ───────────────────────────────────────────────
    try
    {
        var claimResolved = CsvFileResolver.ResolveLatestClaimLevelWithDiag(
            lab.ServerMastersPath,
            out var claimFailReason, out var claimTotalCsv, out var claimMatchedCsv);
        if (claimResolved is null)
        {
            var diagMsg = claimFailReason switch
            {
                CsvFileResolver.ResolveFailureReason.PathMissing    => $"path does not exist: {lab.ServerMastersPath}",
                CsvFileResolver.ResolveFailureReason.NoCsvFiles     => $"0 CSV files found under: {lab.ServerMastersPath}",
                CsvFileResolver.ResolveFailureReason.NoKeywordMatch => $"{claimTotalCsv} CSV file(s) found but none contain 'Claim Level' or 'ClaimLevel' — under: {lab.ServerMastersPath}",
                _                                                    => $"unknown — {lab.ServerMastersPath}"
            };
            log.Warn($"  [Claim Level] No CSV found — {diagMsg}");
        }
        else
        {
            var (claimFilePath, claimWeekFolder) = claimResolved.Value;
            var claimFileName = Path.GetFileName(claimFilePath);
            log.Info($"  [Claim Level] File        : {claimFileName}");
            log.Info($"  [Claim Level] Week folder : {claimWeekFolder}");

            // Skip if same file already loaded — bypassed when ClaimLineRefresh=true so the
            // latest file is always re-processed (a newer file may have dropped during the run).
            var liveClaimPath = db.GetLatestSourcePath(lab.LabName, "claimlevel");
            if (!lab.ClaimLineRefresh && string.Equals(liveClaimPath, claimFilePath, StringComparison.OrdinalIgnoreCase))
            {
                log.Info($"  [Claim Level] Already loaded — same file, skipping.");
            }
            else
            {
                if (lab.ClaimLineRefresh && liveClaimPath is not null)
                    log.Info($"  [Claim Level] Refresh mode — re-processing (previously loaded: {Path.GetFileName(liveClaimPath)}).");
                var runId = ClaimLineDbService.ExtractRunId(claimFilePath);
                var claimWorkingPath = Path.Combine(workingFolder, Path.GetFileName(claimFilePath));
                try
                {
                    log.Info($"  [Claim Level] Copying to working folder…");
                    File.Copy(claimFilePath, claimWorkingPath, overwrite: true);

                    log.Info($"  [Claim Level] Streaming CSV in batches of {CsvFileReader.DefaultBatchSize}…");
                    var claimBatches = CsvFileReader.ReadCsvBatches(
                        claimWorkingPath, lab.LabName, claimWeekFolder, runId,
                        labFieldMappings.ClaimLevel, claimFilePath);

                    var inserted = db.StreamingInsert(
                        claimBatches, lab.LabName, claimWeekFolder,
                        labFieldMappings.ClaimLevel, claimFilePath,
                        onBatchLoaded: (batch, count) =>
                            log.Info($"  [Claim Level] Batch {batch} loaded — {count} rows."));

                    log.Info(inserted > 0
                        ? $"  [Claim Level] Total inserted : {inserted} rows."
                        : $"  [Claim Level] Already loaded — skipped.");
                    claimInserted = inserted > 0;
                }
                finally
                {
                    if (File.Exists(claimWorkingPath))
                    {
                        File.Delete(claimWorkingPath);
                        log.Info($"  [Claim Level] Working copy deleted.");
                    }
                }
            }
        }
    }
    catch (Exception ex)
    {
        log.Error($"  [Claim Level] {ex.Message}");
        labsFailed++;
    }

    // ── Process Line Level CSV ────────────────────────────────────────────────
    try
    {
        var lineResolved = CsvFileResolver.ResolveLatestLineLevelWithDiag(
            lab.ServerMastersPath,
            out var lineFailReason, out var lineTotalCsv, out var lineMatchedCsv);
        if (lineResolved is null)
        {
            var diagMsg = lineFailReason switch
            {
                CsvFileResolver.ResolveFailureReason.PathMissing    => $"path does not exist: {lab.ServerMastersPath}",
                CsvFileResolver.ResolveFailureReason.NoCsvFiles     => $"0 CSV files found under: {lab.ServerMastersPath}",
                CsvFileResolver.ResolveFailureReason.NoKeywordMatch => $"{lineTotalCsv} CSV file(s) found but none contain 'Line Level' or 'LineLevel' — under: {lab.ServerMastersPath}",
                _                                                    => $"unknown — {lab.ServerMastersPath}"
            };
            log.Warn($"  [Line Level] No CSV found — {diagMsg}");
        }
        else
        {
            var (lineFilePath, lineWeekFolder) = lineResolved.Value;
            var lineFileName = Path.GetFileName(lineFilePath);
            log.Info($"  [Line Level] File        : {lineFileName}");
            log.Info($"  [Line Level] Week folder : {lineWeekFolder}");

            // Skip if same file already loaded — bypassed when ClaimLineRefresh=true so the
            // latest file is always re-processed (a newer file may have dropped during the run).
            var livLinePath = db.GetLatestSourcePath(lab.LabName, "linelevel");
            if (!lab.ClaimLineRefresh && string.Equals(livLinePath, lineFilePath, StringComparison.OrdinalIgnoreCase))
            {
                log.Info($"  [Line Level] Already loaded — same file, skipping.");
            }
            else
            {
                if (lab.ClaimLineRefresh && livLinePath is not null)
                    log.Info($"  [Line Level] Refresh mode — re-processing (previously loaded: {Path.GetFileName(livLinePath)}).");
                var runId = ClaimLineDbService.ExtractRunId(lineFilePath);
                var lineWorkingPath = Path.Combine(workingFolder, Path.GetFileName(lineFilePath));
                try
                {
                    log.Info($"  [Line Level] Copying to working folder…");
                    File.Copy(lineFilePath, lineWorkingPath, overwrite: true);

                    log.Info($"  [Line Level] Streaming CSV in batches of {CsvFileReader.DefaultBatchSize}…");
                    var lineBatches = CsvFileReader.ReadCsvBatches(
                        lineWorkingPath, lab.LabName, lineWeekFolder, runId,
                        labFieldMappings.LineLevel, lineFilePath);

                    var inserted = db.StreamingInsert(
                        lineBatches, lab.LabName, lineWeekFolder,
                        labFieldMappings.LineLevel, lineFilePath,
                        onBatchLoaded: (batch, count) =>
                            log.Info($"  [Line Level] Batch {batch} loaded — {count} rows."));

                    log.Info(inserted > 0
                        ? $"  [Line Level] Total inserted : {inserted} rows."
                        : $"  [Line Level] Already loaded — skipped.");
                    lineInserted = inserted > 0;
                }
                finally
                {
                    if (File.Exists(lineWorkingPath))
                    {
                        File.Delete(lineWorkingPath);
                        log.Info($"  [Line Level] Working copy deleted.");
                    }
                }
            }
        }
    }
    catch (Exception ex)
    {
        log.Error($"  [Line Level] {ex.Message}");
        labsFailed++;
    }

    // ── Clean decimal suffixes from integer columns after both inserts ────────
    if (claimInserted && lineInserted)
    {
        try
        {
            log.Info($"  [Cleanup] Running decimal suffix cleanup for ClaimLevelData…");
            var claimCleaned = db.CleanClaimLevelDecimalSuffixes();
            log.Info($"  [Cleanup] ClaimLevelData — {claimCleaned} row(s) updated.");

            log.Info($"  [Cleanup] Running decimal suffix cleanup for LineLevelData…");
            var lineCleaned = db.CleanLineLevelDecimalSuffixes();
            log.Info($"  [Cleanup] LineLevelData — {lineCleaned} row(s) updated.");
        }
        catch (Exception ex)
        {
            log.Error($"  [Cleanup] Decimal suffix cleanup failed: {ex.Message}");
        }

        // ── Refresh Revenue Dashboard aggregate tables ────────────────────────
        // Populates DashboardKPISummary, DashboardClaimStatusBreakdown,
        // DashboardInsightBreakdown, DashboardMonthlyTrends, DashboardTopCPT,
        // DashboardPayStatusBreakdown, DashboardPanelMonthlyAllowed, and
        // DashboardPayerTypePayments. Logs run status to DashboardRefreshLog.
        try
        {
            log.Info($"  [Dashboard] Refreshing Revenue Dashboard aggregates…");
            var sw = System.Diagnostics.Stopwatch.StartNew();
            db.RefreshDashboard();
            sw.Stop();
            log.Info($"  [Dashboard] Revenue Dashboard refresh complete — {sw.ElapsedMilliseconds} ms.");
        }
        catch (Exception ex)
        {
            log.Error($"  [Dashboard] Revenue Dashboard refresh failed: {ex.Message}");
        }

        // ── NorthWest production report aggregates ────────────────────────────
        // Runs only for the NorthWest lab. Each SP is isolated — one failure
        // does not block the others and does not affect the main ingestion flow.
        if (lab.LabName.Equals("NorthWest", StringComparison.OrdinalIgnoreCase))
        {
            log.Info($"  [NW Reports] Running NorthWest production report SPs…");
            try
            {
                var nwResults = db.RefreshNorthWestProductionReports();
                foreach (var (spName, elapsedMs, error) in nwResults)
                {
                    if (error is null)
                        log.Info($"  [NW Reports] {spName} — OK ({elapsedMs} ms).");
                    else
                        log.Error($"  [NW Reports] {spName} — FAILED ({elapsedMs} ms): {error}");
                }

                var failed = nwResults.Count(r => r.Error is not null);
                var passed = nwResults.Count(r => r.Error is null);
                log.Info($"  [NW Reports] {passed}/{nwResults.Count} SP(s) succeeded.");
                if (failed > 0)
                    log.Warn($"  [NW Reports] {failed} SP(s) failed — see errors above.");
            }
            catch (Exception ex)
            {
                // Unexpected error setting up the connection (not inside an individual SP)
                log.Error($"  [NW Reports] Unexpected error running NorthWest production report SPs: {ex.Message}");
            }

            RunCollectionSummary(log, db, "NW CS", db.RefreshNorthWestCollectionReports);
        }

        // ── Augustus Labs production report aggregates ───────────────────────
        // Matches "Augustus_Labs" or "Augustus" lab names.
        // Same isolation pattern as NorthWest — one SP failure does not block others.
        if (lab.LabName.Equals("Augustus_Labs", StringComparison.OrdinalIgnoreCase) ||
            lab.LabName.Equals("Augustus",      StringComparison.OrdinalIgnoreCase))
        {
            // ── Augustus: build CollectionClaimLevelData staging table ───────────
            // Must run after both ClaimLevel and LineLevel inserts and BEFORE the
            // Production Report and Collection Summary aggregate SPs execute.
            // This table is the source for the Augustus Collection Summary Report.
            // SP: dbo.usp_Create_CollectionClaimLevelData — no parameters.
            log.Info($"  [Aug CollectionClaim] Creating CollectionClaimLevelData staging table…");
            try
            {
                var (ccldElapsed, ccldError) = db.CreateCollectionClaimLevelData();
                if (ccldError is null)
                    log.Info($"  [Aug CollectionClaim] dbo.usp_Create_CollectionClaimLevelData — OK ({ccldElapsed} ms).");
                else
                    log.Error($"  [Aug CollectionClaim] dbo.usp_Create_CollectionClaimLevelData — FAILED ({ccldElapsed} ms): {ccldError}");
            }
            catch (Exception ex)
            {
                log.Error($"  [Aug CollectionClaim] Unexpected error creating CollectionClaimLevelData: {ex.Message}");
            }

            log.Info($"  [Aug Reports] Running Augustus production report SPs…");
            try
            {
                var augResults = db.RefreshAugustusProductionReports();
                foreach (var (spName, elapsedMs, error) in augResults)
                {
                    if (error is null)
                        log.Info($"  [Aug Reports] {spName} — OK ({elapsedMs} ms).");
                    else
                        log.Error($"  [Aug Reports] {spName} — FAILED ({elapsedMs} ms): {error}");
                }

                var failed = augResults.Count(r => r.Error is not null);
                var passed = augResults.Count(r => r.Error is null);
                log.Info($"  [Aug Reports] {passed}/{augResults.Count} SP(s) succeeded.");
                if (failed > 0)
                    log.Warn($"  [Aug Reports] {failed} SP(s) failed — see errors above.");
            }
            catch (Exception ex)
            {
                log.Error($"  [Aug Reports] Unexpected error running Augustus production report SPs: {ex.Message}");
            }

            RunCollectionSummary(log, db, "Aug CS", db.RefreshAugustusCollectionReports);
        }

        // ── Certus Labs production report aggregates ─────────────────────────
        // Matches "Certus" lab name.
        // Same isolation pattern as NorthWest — one SP failure does not block others.
        if (lab.LabName.Equals("Certus", StringComparison.OrdinalIgnoreCase))
        {
            log.Info($"  [Cert Reports] Running Certus production report SPs…");
            try
            {
                var certResults = db.RefreshCertusProductionReports();
                foreach (var (spName, elapsedMs, error) in certResults)
                {
                    if (error is null)
                        log.Info($"  [Cert Reports] {spName} — OK ({elapsedMs} ms).");
                    else
                        log.Error($"  [Cert Reports] {spName} — FAILED ({elapsedMs} ms): {error}");
                }

                var failed = certResults.Count(r => r.Error is not null);
                var passed = certResults.Count(r => r.Error is null);
                log.Info($"  [Cert Reports] {passed}/{certResults.Count} SP(s) succeeded.");
                if (failed > 0)
                    log.Warn($"  [Cert Reports] {failed} SP(s) failed — see errors above.");
            }
            catch (Exception ex)
            {
                log.Error($"  [Cert Reports] Unexpected error running Certus production report SPs: {ex.Message}");
            }

            RunCollectionSummary(log, db, "Cert CS", db.RefreshCertusCollectionReports);
        }

        // ── COVE Labs production report aggregates ────────────────────────────
        // Matches "COVE" lab name.
        // Same isolation pattern as NorthWest — one SP failure does not block others.
        if (lab.LabName.Equals("COVE", StringComparison.OrdinalIgnoreCase))
        {
            log.Info($"  [COVE Reports] Running COVE production report SPs…");
            try
            {
                var coveResults = db.RefreshCoveProductionReports();
                foreach (var (spName, elapsedMs, error) in coveResults)
                {
                    if (error is null)
                        log.Info($"  [COVE Reports] {spName} — OK ({elapsedMs} ms).");
                    else
                        log.Error($"  [COVE Reports] {spName} — FAILED ({elapsedMs} ms): {error}");
                }

                var failed = coveResults.Count(r => r.Error is not null);
                var passed = coveResults.Count(r => r.Error is null);
                log.Info($"  [COVE Reports] {passed}/{coveResults.Count} SP(s) succeeded.");
                if (failed > 0)
                    log.Warn($"  [COVE Reports] {failed} SP(s) failed — see errors above.");
            }
            catch (Exception ex)
            {
                log.Error($"  [COVE Reports] Unexpected error running COVE production report SPs: {ex.Message}");
            }

            RunCollectionSummary(log, db, "COVE CS", db.RefreshCoveCollectionReports);
        }

        // ── Elixir Labs production report aggregates ──────────────────────────
        // Matches "Elixir" lab name.
        // Rule5 variant: FirstBilledDate columns, Wed–Tue week, coding = unbilled.
        if (lab.LabName.Equals("Elixir", StringComparison.OrdinalIgnoreCase))
        {
            log.Info($"  [Elix Reports] Running Elixir production report SPs…");
            try
            {
                var elixResults = db.RefreshElixirProductionReports();
                foreach (var (spName, elapsedMs, error) in elixResults)
                {
                    if (error is null)
                        log.Info($"  [Elix Reports] {spName} — OK ({elapsedMs} ms).");
                    else
                        log.Error($"  [Elix Reports] {spName} — FAILED ({elapsedMs} ms): {error}");
                }

                var failed = elixResults.Count(r => r.Error is not null);
                var passed = elixResults.Count(r => r.Error is null);
                log.Info($"  [Elix Reports] {passed}/{elixResults.Count} SP(s) succeeded.");
                if (failed > 0)
                    log.Warn($"  [Elix Reports] {failed} SP(s) failed — see errors above.");
            }
            catch (Exception ex)
            {
                log.Error($"  [Elix Reports] Unexpected error running Elixir production report SPs: {ex.Message}");
            }

            RunCollectionSummary(log, db, "Elix CS", db.RefreshElixirCollectionReports);
        }

        // ── PCRLabsofAmerica production report aggregates ─────────────────────
        // Matches "PCRLAPSOfAmerica" or "PCRLabsofAmerica" lab name.
        // Rule1 variant: ChargeEnteredDate columns, Thu–Wed week, coding = billed.
        if (lab.LabName.Equals("PCRLAPSOfAmerica",  StringComparison.OrdinalIgnoreCase) ||
            lab.LabName.Equals("PCRLabsofAmerica",  StringComparison.OrdinalIgnoreCase))
        {
            log.Info($"  [PCR Reports] Running PCRLabsofAmerica production report SPs…");
            try
            {
                var pcrResults = db.RefreshPCRLabsProductionReports();
                foreach (var (spName, elapsedMs, error) in pcrResults)
                {
                    if (error is null)
                        log.Info($"  [PCR Reports] {spName} — OK ({elapsedMs} ms).");
                    else
                        log.Error($"  [PCR Reports] {spName} — FAILED ({elapsedMs} ms): {error}");
                }

                var failed = pcrResults.Count(r => r.Error is not null);
                var passed = pcrResults.Count(r => r.Error is null);
                log.Info($"  [PCR Reports] {passed}/{pcrResults.Count} SP(s) succeeded.");
                if (failed > 0)
                    log.Warn($"  [PCR Reports] {failed} SP(s) failed — see errors above.");
            }
            catch (Exception ex)
            {
                log.Error($"  [PCR Reports] Unexpected error running PCRLabsofAmerica production report SPs: {ex.Message}");
            }

            RunCollectionSummary(log, db, "PCR CS", db.RefreshPCRLabsCollectionReports);
        }

        // ── Beech_Tree production report aggregates ───────────────────────────
        // Matches "Beech_Tree" or "BeechTree" lab name.
        // Rule1 variant: ChargeEnteredDate columns, Thu–Wed week, coding = billed.
        if (lab.LabName.Equals("Beech_Tree", StringComparison.OrdinalIgnoreCase) ||
            lab.LabName.Equals("BeechTree",  StringComparison.OrdinalIgnoreCase))
        {
            log.Info($"  [BT Reports] Running BeechTree production report SPs…");
            try
            {
                var btResults = db.RefreshBeechTreeProductionReports();
                foreach (var (spName, elapsedMs, error) in btResults)
                {
                    if (error is null)
                        log.Info($"  [BT Reports] {spName} — OK ({elapsedMs} ms).");
                    else
                        log.Error($"  [BT Reports] {spName} — FAILED ({elapsedMs} ms): {error}");
                }

                var failed = btResults.Count(r => r.Error is not null);
                var passed = btResults.Count(r => r.Error is null);
                log.Info($"  [BT Reports] {passed}/{btResults.Count} SP(s) succeeded.");
                if (failed > 0)
                    log.Warn($"  [BT Reports] {failed} SP(s) failed — see errors above.");
            }
            catch (Exception ex)
            {
                log.Error($"  [BT Reports] Unexpected error running BeechTree production report SPs: {ex.Message}");
            }

            RunCollectionSummary(log, db, "BT CS", db.RefreshBeechTreeCollectionReports);
        }

        // ── RisingTides production report aggregates ──────────────────────────
        // Matches "RisingTides" lab name.
        // Rule1 variant: ChargeEnteredDate columns, Thu–Wed week, coding = billed.
        if (lab.LabName.Equals("RisingTides", StringComparison.OrdinalIgnoreCase))
        {
            log.Info($"  [RT Reports] Running RisingTides production report SPs…");
            try
            {
                var rtResults = db.RefreshRisingTidesProductionReports();
                foreach (var (spName, elapsedMs, error) in rtResults)
                {
                    if (error is null)
                        log.Info($"  [RT Reports] {spName} — OK ({elapsedMs} ms).");
                    else
                        log.Error($"  [RT Reports] {spName} — FAILED ({elapsedMs} ms): {error}");
                }

                var failed = rtResults.Count(r => r.Error is not null);
                var passed = rtResults.Count(r => r.Error is null);
                log.Info($"  [RT Reports] {passed}/{rtResults.Count} SP(s) succeeded.");
                if (failed > 0)
                    log.Warn($"  [RT Reports] {failed} SP(s) failed — see errors above.");
            }
            catch (Exception ex)
            {
                log.Error($"  [RT Reports] Unexpected error running RisingTides production report SPs: {ex.Message}");
            }

            // ── RisingTides Collection Summary aggregates ─────────────────────
            // Pre-computes the data behind the 13 Collection Summary tabs in the
            // LabMetricsDashboard web app. Same isolation pattern — one SP failure
            // does not block the others, and never blocks the main ingestion flow.
            log.Info($"  [RT CS Reports] Running RisingTides Collection Summary SPs…");
            try
            {
                var rtCsResults = db.RefreshRisingTidesCollectionReports();
                foreach (var (spName, elapsedMs, error) in rtCsResults)
                {
                    if (error is null)
                        log.Info($"  [RT CS Reports] {spName} — OK ({elapsedMs} ms).");
                    else
                        log.Error($"  [RT CS Reports] {spName} — FAILED ({elapsedMs} ms): {error}");
                }

                var failed = rtCsResults.Count(r => r.Error is not null);
                var passed = rtCsResults.Count(r => r.Error is null);
                log.Info($"  [RT CS Reports] {passed}/{rtCsResults.Count} SP(s) succeeded.");
                if (failed > 0)
                    log.Warn($"  [RT CS Reports] {failed} SP(s) failed — see errors above.");
            }
            catch (Exception ex)
            {
                log.Error($"  [RT CS Reports] Unexpected error running RisingTides Collection Summary SPs: {ex.Message}");
            }
        }

        // ── PhiLife production report aggregates ─────────────────────────────
        // Matches "PhiLife" lab name.
        // Rule1 variant: ChargeEnteredDate columns, Thu–Wed week, coding = billed.
        if (lab.LabName.Equals("PhiLife", StringComparison.OrdinalIgnoreCase))
        {
            log.Info($"  [Phi Reports] Running PhiLife production report SPs…");
            try
            {
                var phiResults = db.RefreshPhiLifeProductionReports();
                foreach (var (spName, elapsedMs, error) in phiResults)
                {
                    if (error is null)
                        log.Info($"  [Phi Reports] {spName} — OK ({elapsedMs} ms).");
                    else
                        log.Error($"  [Phi Reports] {spName} — FAILED ({elapsedMs} ms): {error}");
                }

                var failed = phiResults.Count(r => r.Error is not null);
                var passed = phiResults.Count(r => r.Error is null);
                log.Info($"  [Phi Reports] {passed}/{phiResults.Count} SP(s) succeeded.");
                if (failed > 0)
                    log.Warn($"  [Phi Reports] {failed} SP(s) failed — see errors above.");
            }
            catch (Exception ex)
            {
                log.Error($"  [Phi Reports] Unexpected error running PhiLife production report SPs: {ex.Message}");
            }

            RunCollectionSummary(log, db, "Phi CS", db.RefreshPhiLifeCollectionReports);

            // ── Executive Summary aggregate refresh ──────────────────────────
            log.Info($"  [Phi ES] Refreshing Executive Summary aggregate (Phi_ES_Data)…");
            try
            {
                var (esMs, esErr) = db.RefreshPhiLifeExecutiveSummary();
                if (esErr is null)
                    log.Info($"  [Phi ES] Phi_ES_Data refreshed in {esMs} ms.");
                else
                    log.Error($"  [Phi ES] Refresh failed ({esMs} ms): {esErr}");
            }
            catch (Exception ex)
            {
                log.Error($"  [Phi ES] Unexpected error refreshing Executive Summary: {ex.Message}");
            }
        }

        // ── InHealthDTR production report aggregates ─────────────────────────
        // Matches "InHealthDTR" lab name.
        if (lab.LabName.Equals("Inhealth_DTR", StringComparison.OrdinalIgnoreCase)
            || lab.LabName.Equals("InHealthDTR", StringComparison.OrdinalIgnoreCase)
            || lab.LabName.Equals("InHealthDTRLRN", StringComparison.OrdinalIgnoreCase))
        {
            log.Info($"  [InH Reports] Running InHealthDTR production report SPs…");
            try
            {
                var inhResults = db.RefreshInHealthDTRProductionReports();
                foreach (var (spName, elapsedMs, error) in inhResults)
                {
                    if (error is null)
                        log.Info($"  [InH Reports] {spName} — OK ({elapsedMs} ms).");
                    else
                        log.Error($"  [InH Reports] {spName} — FAILED ({elapsedMs} ms): {error}");
                }

                var failed = inhResults.Count(r => r.Error is not null);
                var passed = inhResults.Count(r => r.Error is null);
                log.Info($"  [InH Reports] {passed}/{inhResults.Count} SP(s) succeeded.");
                if (failed > 0)
                    log.Warn($"  [InH Reports] {failed} SP(s) failed — see errors above.");
            }
            catch (Exception ex)
            {
                log.Error($"  [InH Reports] Unexpected error running InHealthDTR production report SPs: {ex.Message}");
            }

            RunCollectionSummary(log, db, "IHD CS", db.RefreshInHealthDTRCollectionReports);
        }

        // ── Production Report Excel generation — started in background ─────────
        // Queued here so the main loop continues to the next lab immediately.
        // All tasks are awaited after the loop before the process exits.
        var capturedLab1 = lab; // capture for closure
        reportTasks.Add((lab.LabName, "Production", Task.Run(async () =>
        {
            try
            {
                var reportPath = await GenerateProductionReportExcelAsync(
                    capturedLab1,
                    workingFolder,
                    productionReportRepo,
                    log);
                log.Info($"  [Prod Excel] [{capturedLab1.LabName}] Saved to: {reportPath}");
            }
            catch (Exception ex)
            {
                log.Error($"  [Prod Excel] [{capturedLab1.LabName}] Generation failed: {ex.Message}");
            }
        })));

        if (GetCollectionSummarySpPrefix(lab) is not null)
        {
            var capturedLabCollection = lab;
            var forceCollectionRegenerate = claimInserted || lineInserted;
            reportTasks.Add((lab.LabName, "Collection", Task.Run(async () =>
            {
                try
                {
                    var reportPath = await GenerateCollectionSummaryReportExcelAsync(
                        capturedLabCollection,
                        workingFolder,
                        collectionSummaryRepo,
                        log,
                        forceRegenerate: forceCollectionRegenerate);
                    if (!string.IsNullOrEmpty(reportPath))
                        log.Info($"  [Collection Excel] [{capturedLabCollection.LabName}] Saved to: {reportPath}");
                }
                catch (Exception ex)
                {
                    log.Error($"  [Collection Excel] [{capturedLabCollection.LabName}] Generation failed: {ex.Message}");
                }
            })));
        }

        processedLabNames.Add(lab.LabName);
        labsProcessed++;

        // ── Reset ClaimLineRefresh after a successful full refresh ────────────
        // Only resets when both files were actually inserted (not just skipped),
        // so a failed or partial run keeps the flag true and retries next cycle.
        if (lab.ClaimLineRefresh)
            LabConfigLoader.TryResetClaimLineRefresh(labConfigFolder, lab.LabName, log);
    }
    else
    {
        labsSkipped++;
    }

    // ── Production Report Excel generation (runs regardless of insert outcome) ──
    // Always check whether this week's report exists; generate it if missing.
    // Only queued when no task was already started for this lab above
    // (i.e. when claimInserted && lineInserted was false).
    if (lab.ClaimLineInsert && !string.IsNullOrWhiteSpace(lab.DbConnectionString)
        && !reportTasks.Any(t => t.LabName.Equals(lab.LabName, StringComparison.OrdinalIgnoreCase)
            && t.ReportType.Equals("Production", StringComparison.OrdinalIgnoreCase)))
    {
        var capturedLab2 = lab; // capture for closure
        reportTasks.Add((lab.LabName, "Production", Task.Run(async () =>
        {
            try
            {
                var reportPath = await GenerateProductionReportExcelAsync(
                    capturedLab2,
                    workingFolder,
                    productionReportRepo,
                    log);
                log.Info($"  [Prod Excel] [{capturedLab2.LabName}] Saved to: {reportPath}");
            }
            catch (Exception ex)
            {
                log.Error($"  [Prod Excel] [{capturedLab2.LabName}] Generation failed: {ex.Message}");
            }
        })));
    }

    if (lab.ClaimLineInsert && !string.IsNullOrWhiteSpace(lab.DbConnectionString)
        && GetCollectionSummarySpPrefix(lab) is not null
        && !reportTasks.Any(t => t.LabName.Equals(lab.LabName, StringComparison.OrdinalIgnoreCase)
            && t.ReportType.Equals("Collection", StringComparison.OrdinalIgnoreCase)))
    {
        var capturedLabCollection2 = lab;
        var forceCollectionRegenerate = claimInserted || lineInserted;
        reportTasks.Add((lab.LabName, "Collection", Task.Run(async () =>
        {
            try
            {
                var reportPath = await GenerateCollectionSummaryReportExcelAsync(
                    capturedLabCollection2,
                    workingFolder,
                    collectionSummaryRepo,
                    log,
                    forceRegenerate: forceCollectionRegenerate);
                if (!string.IsNullOrEmpty(reportPath))
                    log.Info($"  [Collection Excel] [{capturedLabCollection2.LabName}] Saved to: {reportPath}");
            }
            catch (Exception ex)
            {
                log.Error($"  [Collection Excel] [{capturedLabCollection2.LabName}] Generation failed: {ex.Message}");
            }
        })));
    }

    log.Blank();
}

// ── Await all background Production Report tasks ─────────────────────────────
if (reportTasks.Count > 0)
{
    log.Header("Waiting for Production Reports");
    log.Info($"  {reportTasks.Count} report task(s) running in background — waiting for completion…");
    await Task.WhenAll(reportTasks.Select(t => t.Task));
    log.Info("  All Production Report tasks completed.");
}

// ── Final report ──────────────────────────────────────────────────────────────
log.Header("Run complete");
log.Info($"  Processed : {labsProcessed}");
if (processedLabNames.Count > 0)
    log.Info($"  Processed Labs: {string.Join(", ", processedLabNames)}");
log.Info($"  Skipped   : {labsSkipped}");
log.Info($"  Failed    : {labsFailed}");

return labsFailed > 0 ? 1 : 0;


// ─────────────────────────────────────────────────────────────────────────────
// Local helper: RunId validation gate.
// Before processing a lab's latest input files, fetch the latest successfully
// completed RunId (sp_GetRecentSuccessRunByLab on LRNMaster) and compare it with
// the RunId prefix of the latest input file. Returns true when processing should
// continue, false when the lab must be skipped. Applies to both the normal flow
// and the ClaimLineRefresh=true flow. Every step is logged with separators.
// ─────────────────────────────────────────────────────────────────────────────
static bool RunIdGatePassed(
    ClaimLineCSVDataCapture.Models.LabConfig lab,
    string? masterConnectionString,
    ClaimLineCSVDataCapture.Services.AppLogger log)
{
    log.Header($"RunId Validation — {lab.LabName}");

    // Resolve the latest input file (newest of Claim Level / Line Level) and its RunId.
    var claimResolved = CsvFileResolver.ResolveLatestClaimLevel(lab.ServerMastersPath);
    var lineResolved  = CsvFileResolver.ResolveLatestLineLevel(lab.ServerMastersPath);

    string? latestFilePath;
    if (claimResolved is not null && lineResolved is not null)
    {
        var claimWrite = File.GetLastWriteTimeUtc(claimResolved.Value.FilePath);
        var lineWrite  = File.GetLastWriteTimeUtc(lineResolved.Value.FilePath);
        latestFilePath = lineWrite >= claimWrite ? lineResolved.Value.FilePath : claimResolved.Value.FilePath;
    }
    else
    {
        latestFilePath = lineResolved?.FilePath ?? claimResolved?.FilePath;
    }

    if (string.IsNullOrWhiteSpace(latestFilePath))
    {
        log.Warn($"  [RunId Gate] No input file found under: {lab.ServerMastersPath} — proceeding (downstream will report no CSV).");
        log.Header($"RunId Validation — {lab.LabName} — PROCEED (no file)");
        return true;
    }

    var fileRunId = ClaimLineDbService.ExtractRunId(latestFilePath);
    log.Info($"  [RunId Gate] Latest input file     : {Path.GetFileName(latestFilePath)}");
    log.Info($"  [RunId Gate] File RunId            : {fileRunId}");

    // The lab name passed to sp_GetRecentSuccessRunByLab comes from the config key.
    var labParam = lab.FetchLatestCompletedRunIDParameter;
    if (string.IsNullOrWhiteSpace(labParam))
    {
        log.Warn($"  [RunId Gate] FetchLatestCompletedRunIDParameter not configured — skipping RunId validation and proceeding.");
        log.Header($"RunId Validation — {lab.LabName} — PROCEED (not configured)");
        return true;
    }

    if (string.IsNullOrWhiteSpace(masterConnectionString))
    {
        log.Warn($"  [RunId Gate] ConnectionStrings:DefaultConnection (LRNMaster) not configured — skipping RunId validation and proceeding.");
        log.Header($"RunId Validation — {lab.LabName} — PROCEED (no master connection)");
        return true;
    }

    log.Info($"  [RunId Gate] SP                   : sp_GetRecentSuccessRunByLab (LRNMaster)");
    log.Info($"  [RunId Gate] SP parameter @LabName : {labParam}");

    string? completedRunId;
    try
    {
        completedRunId = ClaimLineDbService.GetRecentSuccessRunByLab(masterConnectionString, labParam);
    }
    catch (Exception ex)
    {
        log.Error($"  [RunId Gate] sp_GetRecentSuccessRunByLab failed — {ex.Message}. Skipping lab to avoid processing an unvalidated run.");
        log.Header($"RunId Validation — {lab.LabName} — SKIPPED (SP error)");
        return false;
    }

    log.Info($"  [RunId Gate] Latest completed RunId : {completedRunId ?? "(none)"}");

    if (string.IsNullOrWhiteSpace(completedRunId))
    {
        log.Warn($"  [RunId Gate] [SKIP] No successfully completed RunId returned for '{labParam}' — skipping lab.");
        log.Header($"RunId Validation — {lab.LabName} — SKIPPED (no completed run)");
        return false;
    }

    var matched = string.Equals(fileRunId, completedRunId, StringComparison.OrdinalIgnoreCase);
    log.Info($"  [RunId Gate] Comparison           : File='{fileRunId}'  Completed='{completedRunId}'  =>  {(matched ? "MATCHED" : "NOT MATCHED")}");

    if (matched)
        log.Info($"  [RunId Gate] [PROCEED] RunIds match — starting processing for {lab.LabName}.");
    else
        log.Warn($"  [RunId Gate] [SKIP] RunIds do not match — skipping {lab.LabName} until the completed run aligns with the latest file.");

    log.Header($"RunId Validation — {lab.LabName} — {(matched ? "PASSED" : "SKIPPED")}");
    return matched;
}


// ─────────────────────────────────────────────────────────────────────────────
// Local helper: runs a lab's Collection Summary refresher and logs each SP's
// result, mirroring the production-report logging pattern used elsewhere.
// ─────────────────────────────────────────────────────────────────────────────
static void RunCollectionSummary(
    ClaimLineCSVDataCapture.Services.AppLogger log,
    ClaimLineCSVDataCapture.Services.ClaimLineDbService db,
    string tag,
    Func<List<(string SpName, long ElapsedMs, string? Error)>> refresher)
{
    log.Info($"  [{tag}] Running Collection Summary SPs…");
    try
    {
        var results = refresher();
        foreach (var (spName, elapsedMs, error) in results)
        {
            if (error is null)
                log.Info($"  [{tag}] {spName} — OK ({elapsedMs} ms).");
            else
                log.Error($"  [{tag}] {spName} — FAILED ({elapsedMs} ms): {error}");
        }

        var failed = results.Count(r => r.Error is not null);
        var passed = results.Count(r => r.Error is null);
        log.Info($"  [{tag}] {passed}/{results.Count} SP(s) succeeded.");
        if (failed > 0)
            log.Warn($"  [{tag}] {failed} SP(s) failed — see errors above.");
    }
    catch (Exception ex)
    {
        log.Error($"  [{tag}] Unexpected error running Collection Summary SPs: {ex.Message}");
    }
}

static async Task<string> GenerateProductionReportExcelAsync(
    ClaimLineCSVDataCapture.Models.LabConfig lab,
    string workingFolder,
    LRN.ProductionReports.Services.IProductionReportRepository productionReportRepo,
    ClaimLineCSVDataCapture.Services.AppLogger log,
    CancellationToken ct = default)
{
    ArgumentNullException.ThrowIfNull(lab);
    ArgumentNullException.ThrowIfNull(productionReportRepo);
    ArgumentNullException.ThrowIfNull(log);
    ArgumentException.ThrowIfNullOrWhiteSpace(workingFolder);
    ArgumentException.ThrowIfNullOrWhiteSpace(lab.DbConnectionString);

    var (productionRule, weekRule, weekRange) = ResolveProductionSummarySettings(lab);

    log.Info(
        $"  [Prod Excel] Building workbook — Rule={productionRule ?? "Default"}, WeekRule={weekRule ?? "Default"}, WeekRange={weekRange ?? "Mon to Sun"}.");

    // ── Resolve output path before any DB work so we can skip if already generated ──
    var outputFolder = ResolveProductionReportOutputFolder(lab, workingFolder);
    Directory.CreateDirectory(outputFolder);

    var processingFolder = Path.Combine(outputFolder, "Processing");
    Directory.CreateDirectory(processingFolder);

    var safeLabName = SanitizeFileName(lab.LabName);
    var (weekStart, weekEnd) = ResolveCurrentWeekBounds(weekRange);
    var fileName   = $"{safeLabName}_ProductionReport_{weekStart:yyyyMMdd}-{weekEnd:yyyyMMdd}.xlsx";
    var outputPath = Path.Combine(outputFolder, fileName);
    var processingPath = Path.Combine(processingFolder, fileName);

    if (File.Exists(outputPath))
    {
        log.Info($"  [Prod Excel] Report already exists for this week — skipping generation. ({outputPath})");
        return outputPath;
    }

    if (File.Exists(processingPath))
    {
        log.Info($"  [Prod Excel] Removing stale processing file: {processingPath}");
        File.Delete(processingPath);
    }

    var connStr = lab.DbConnectionString;

    // ── Summary tabs (lightweight aggregates) — fetch in parallel ───────────────
    var monthlyTask        = productionReportRepo.GetMonthlyClaimVolumeAsync(connStr, rule: productionRule, ct: ct);
    var weeklyTask         = productionReportRepo.GetWeeklyClaimVolumeAsync(connStr, rule: weekRule, weekRange: weekRange, ct: ct);
    var codingTask         = productionReportRepo.GetCodingAsync(connStr, ct: ct);
    var payerBreakdownTask = productionReportRepo.GetPayerBreakdownAsync(connStr, rule: productionRule, ct: ct);
    var payerPanelTask     = productionReportRepo.GetPayerPanelAsync(connStr, rule: productionRule, ct: ct);
    var unbilledAgingTask  = productionReportRepo.GetUnbilledAgingAsync(connStr, rule: productionRule, ct: ct);
    var cptBreakdownTask   = productionReportRepo.GetCptBreakdownAsync(connStr, ct: ct, rule: productionRule);
    var runInfoTask        = productionReportRepo.GetRunInfoAsync(connStr, ct);

    await Task.WhenAll(
        monthlyTask, weeklyTask, codingTask,
        payerBreakdownTask, payerPanelTask,
        unbilledAgingTask, cptBreakdownTask,
        runInfoTask);

    var monthlyResult       = monthlyTask.Result;
    var weeklyResult        = weeklyTask.Result;
    var codingResult        = codingTask.Result;
    var payerBreakdownResult= payerBreakdownTask.Result;
    var payerPanelResult    = payerPanelTask.Result;
    var unbilledAgingResult = unbilledAgingTask.Result;
    var cptBreakdownResult  = cptBreakdownTask.Result;
    var (reportWeekFolder, reportRunId) = runInfoTask.Result;

    var vm = new ProductionReportViewModel
    {
        SelectedLab = lab.LabName,
        ProductionSummaryRule = productionRule,
        ProductionSummaryWeekRule = weekRule,
        ProductionSummaryWeekRange = weekRange,
        PayerNames = monthlyResult.PayerNames,
        PanelNames = monthlyResult.PanelNames,
        Months = monthlyResult.Months,
        Years = monthlyResult.Years,
        PanelRows = monthlyResult.PanelRows,
        GrandTotalByMonth = monthlyResult.GrandTotalByMonth,
        GrandTotalClaims = monthlyResult.GrandTotalClaims,
        GrandTotalCharges = monthlyResult.GrandTotalCharges,
        WeekColumns = weeklyResult.WeekColumns,
        WeeklyPanelRows = weeklyResult.PanelRows,
        WeeklyGrandTotalByWeek = weeklyResult.GrandTotalByWeek,
        WeeklyGrandTotalClaims = weeklyResult.GrandTotalClaims,
        WeeklyGrandTotalCharges = weeklyResult.GrandTotalCharges,
        CodingPanelRows = codingResult.PanelRows,
        CodingGrandTotalClaims = codingResult.GrandTotalClaims,
        CodingGrandTotalCharges = codingResult.GrandTotalCharges,
        PayerBreakdownMonths = payerBreakdownResult.Months,
        PayerBreakdownYears = payerBreakdownResult.Years,
        PayerBreakdownRows = payerBreakdownResult.PayerRows,
        PayerBreakdownGrandByMonth = payerBreakdownResult.GrandTotalByMonth,
        PayerBreakdownGrandTotal = payerBreakdownResult.GrandTotal,
        PayerPanelColumns = payerPanelResult.PanelColumns,
        PayerPanelRows = payerPanelResult.PayerRows,
        PayerPanelGrandByPanel = payerPanelResult.GrandTotalByPanel,
        PayerPanelGrandTotalClaims = payerPanelResult.GrandTotalClaims,
        PayerPanelGrandTotalCharges = payerPanelResult.GrandTotalCharges,
        UnbilledAgingRows = unbilledAgingResult.PanelRows,
        UnbilledAgingGrandByBucket = unbilledAgingResult.GrandTotalByBucket,
        UnbilledAgingGrandTotalClaims = unbilledAgingResult.GrandTotalClaims,
        UnbilledAgingGrandTotalCharges = unbilledAgingResult.GrandTotalCharges,
        CptBreakdownMonths = cptBreakdownResult.Months,
        CptBreakdownYears = cptBreakdownResult.Years,
        CptBreakdownRows = cptBreakdownResult.CptRows,
        CptBreakdownGrandByMonth = cptBreakdownResult.GrandTotalByMonth,
        CptBreakdownGrandTotalUnits = cptBreakdownResult.GrandTotalUnits,
        CptBreakdownGrandTotalCharges = cptBreakdownResult.GrandTotalCharges,
        ReportWeekFolder = reportWeekFolder,
        ReportRunId = reportRunId,
    };

    // ── Build workbook with summary tabs only and SAVE it to disk first ────────
    // The file on disk becomes the buffer for the raw export sheets — we never
    // hold the full workbook + ClaimLevel + LineLevel in memory at the same time.
    log.Info($"  [Prod Excel] Saving summary-only workbook to processing folder…");
    {
        using var workbook = ProductionReportExcelExportBuilder.CreateWorkbookSummaryOnly(
            vm, lab.LabName, reportWeekFolder, reportRunId);
        workbook.SaveAs(processingPath);
    } // workbook disposed here

    // Force GC so the summary workbook's in-memory state is released before
    // we start loading the file again to append raw data sheets.
    GC.Collect();
    GC.WaitForPendingFinalizers();
    GC.Collect();

    // ── Append raw export sheets ONE BUCKET AT A TIME ──────────────────────────
    // For each bucket: load workbook from disk → add ONE worksheet streamed from
    // SQL → save back to disk → dispose → GC. ClosedXML never holds more than
    // one bucket's worth of cells in memory at a time.
    if (productionReportRepo is LRN.ProductionReports.Services.SqlProductionReportRepository sqlRepo)
    {
        log.Info($"  [Prod Excel] ClaimLevel: appending sheets to processing file {Path.GetFileName(processingPath)}…");
        var claimRows = await sqlRepo.AppendSpExportSheetsToFileAsync(
            processingPath,
            connStr,
            bucketSpName: "dbo.usp_GetClaimLevelExportBuckets",
            dataSpName:   "dbo.usp_GetClaimLevelExportDataByDateRange",
            baseSheetName: "ClaimLevel",
            tabColor: ClosedXML.Excel.XLColor.FromHtml("#2E5984"),
            ct: ct);
        log.Info($"  [Prod Excel] ClaimLevel complete — {claimRows:N0} total rows written to processing file.");

        log.Info($"  [Prod Excel] LineLevel: appending sheets to processing file {Path.GetFileName(processingPath)}…");
        var lineRows = await sqlRepo.AppendSpExportSheetsToFileAsync(
            processingPath,
            connStr,
            bucketSpName: "dbo.usp_GetLineLevelExportBuckets",
            dataSpName:   "dbo.usp_GetLineLevelExportDataByDateRange",
            baseSheetName: "LineLevel",
            tabColor: ClosedXML.Excel.XLColor.FromHtml("#C99B1F"),
            ct: ct);
        log.Info($"  [Prod Excel] LineLevel complete — {lineRows:N0} total rows written to processing file.");

        log.Info($"  [Prod Excel] Moving processing file to final report folder…");
        if (File.Exists(outputPath))
            File.Delete(outputPath);
        File.Move(processingPath, outputPath);
        log.Info($"  [Prod Excel] Final report ready: {outputPath}");
    }
    else
    {
        log.Warn($"  [Prod Excel] Repository is not SqlProductionReportRepository — raw data sheets skipped.");
    }

    return outputPath;
}

static async Task<string> GenerateCollectionSummaryReportExcelAsync(
    ClaimLineCSVDataCapture.Models.LabConfig lab,
    string workingFolder,
    LRN.ProductionReports.Services.ICollectionSummaryReportRepository collectionSummaryRepo,
    ClaimLineCSVDataCapture.Services.AppLogger log,
    bool forceRegenerate,
    CancellationToken ct = default)
{
    ArgumentNullException.ThrowIfNull(lab);
    ArgumentNullException.ThrowIfNull(collectionSummaryRepo);
    ArgumentNullException.ThrowIfNull(log);
    ArgumentException.ThrowIfNullOrWhiteSpace(workingFolder);
    ArgumentException.ThrowIfNullOrWhiteSpace(lab.DbConnectionString);

    // Resolve the SP prefix for this lab (e.g. "NW", "Elix", "Cove").
    // Returns null if the lab has no Collection Summary aggregate SPs deployed.
    var spPrefix = GetCollectionSummarySpPrefix(lab);
    if (spPrefix is null)
    {
        log.Warn($"  [Collection Excel] No Collection Summary SP prefix configured for lab '{lab.LabName}' — skipping.");
        return string.Empty;
    }

    var outputFolder = ResolveCollectionSummaryReportOutputFolder(lab, workingFolder);
    Directory.CreateDirectory(outputFolder);

    var processingFolder = Path.Combine(outputFolder, "Processing");
    Directory.CreateDirectory(processingFolder);

    var safeLabName = SanitizeFileName(lab.LabName);
    var (_, _, weekRange) = ResolveProductionSummarySettings(lab);
    var (weekStart, weekEnd) = ResolveCurrentWeekBounds(weekRange);

    var fileName = $"{safeLabName}_CollectionSummaryReport_{weekStart:yyyyMMdd}-{weekEnd:yyyyMMdd}.xlsx";
    var outputPath = Path.Combine(outputFolder, fileName);
    var processingPath = Path.Combine(processingFolder, fileName);

    if (File.Exists(outputPath) && !forceRegenerate)
    {
        log.Info($"  [Collection Excel] Report already exists for this week — skipping generation. ({outputPath})");
        return outputPath;
    }

    if (File.Exists(processingPath))
    {
        log.Info($"  [Collection Excel] Removing stale processing file: {processingPath}");
        File.Delete(processingPath);
    }

    log.Info(forceRegenerate
        ? $"  [Collection Excel] [{lab.LabName}] New Claim/Line data detected — regenerating workbook."
        : $"  [Collection Excel] [{lab.LabName}] Report missing — generating workbook.");

    var connStr = lab.DbConnectionString;
    var monthlySpName = $"dbo.usp_Get{spPrefix}_CS_MonthlyClaimVolume";
    var weeklySpName  = $"dbo.usp_Get{spPrefix}_CS_WeeklyClaimVolume";

    var monthlyTask = collectionSummaryRepo.GetMonthlyClaimVolumeAsync(connStr, monthlySpName, filters: null, ct);
    var weeklyTask  = collectionSummaryRepo.GetWeeklyClaimVolumeAsync(connStr, weeklySpName, filters: null, ct);

    await Task.WhenAll(monthlyTask, weeklyTask).ConfigureAwait(false);

    using (var workbook = LRN.ProductionReports.Services.CollectionSummaryExcelExportBuilder.CreateWorkbook(
        await monthlyTask.ConfigureAwait(false),
        await weeklyTask.ConfigureAwait(false),
        lab.LabName))
    {
        workbook.SaveAs(processingPath);
    }

    if (File.Exists(outputPath))
        File.Delete(outputPath);
    File.Move(processingPath, outputPath);

    log.Info($"  [Collection Excel] Final report ready: {outputPath}");
    return outputPath;
}

static (string? Rule, string? WeekRule, string? WeekRange) ResolveProductionSummarySettings(
    ClaimLineCSVDataCapture.Models.LabConfig lab)
{
    ArgumentNullException.ThrowIfNull(lab);

    var configRule = lab.ProductionSummary?.Rule;
    var configWeekRule = !string.IsNullOrWhiteSpace(lab.ProductionSummary?.WeekRule)
        ? lab.ProductionSummary!.WeekRule
        : configRule;
    var configWeekRange = lab.ProductionSummary?.WeekRange;

    if (!string.IsNullOrWhiteSpace(configRule)
        || !string.IsNullOrWhiteSpace(configWeekRule)
        || !string.IsNullOrWhiteSpace(configWeekRange))
    {
        return (configRule, configWeekRule, configWeekRange);
    }

    return lab.LabName switch
    {
        var name when name.Equals("Augustus", StringComparison.OrdinalIgnoreCase)
            || name.Equals("Augustus_Labs", StringComparison.OrdinalIgnoreCase)
                => ("Rule3", "Rule3", null),

        var name when name.Equals("NorthWest", StringComparison.OrdinalIgnoreCase)
                => ("Rule4", "Rule4", "Thu to Wed"),

        var name when name.Equals("Certus", StringComparison.OrdinalIgnoreCase)
                => ("Rule2", "Rule2", null),

        var name when name.Equals("Cove", StringComparison.OrdinalIgnoreCase)
            || name.Equals("COVE", StringComparison.OrdinalIgnoreCase)
                => ("Rule5", "Rule5", null),

        var name when name.Equals("Elixir", StringComparison.OrdinalIgnoreCase)
                => ("Rule5", "Rule5", "Wed to Tue"),

        var name when name.Equals("PCRLabsofAmerica", StringComparison.OrdinalIgnoreCase)
            || name.Equals("PCRLAPSOfAmerica", StringComparison.OrdinalIgnoreCase)
            || name.Equals("Beech_Tree", StringComparison.OrdinalIgnoreCase)
            || name.Equals("BeechTree", StringComparison.OrdinalIgnoreCase)
            || name.Equals("RisingTides", StringComparison.OrdinalIgnoreCase)
            || name.Equals("Rising_Tides", StringComparison.OrdinalIgnoreCase)
            || name.Equals("PhiLife", StringComparison.OrdinalIgnoreCase)
            || name.Equals("Inhealth_DTR", StringComparison.OrdinalIgnoreCase)
                => ("Rule1", "Rule1", "Thu to Wed"),

        _ => (null, null, null),
    };
}

static string ResolveProductionReportOutputFolder(
    ClaimLineCSVDataCapture.Models.LabConfig lab,
    string workingFolder)
{
    ArgumentNullException.ThrowIfNull(lab);
    ArgumentException.ThrowIfNullOrWhiteSpace(workingFolder);

    var baseFolder = !string.IsNullOrWhiteSpace(lab.Output.Reports)
        ? lab.Output.Reports
        : Path.Combine(workingFolder, "ProductionReports", SanitizeFileName(lab.LabName));

    return Path.Combine(baseFolder, "Production Report");
}

static string ResolveCollectionSummaryReportOutputFolder(
    ClaimLineCSVDataCapture.Models.LabConfig lab,
    string workingFolder)
{
    ArgumentNullException.ThrowIfNull(lab);
    ArgumentException.ThrowIfNullOrWhiteSpace(workingFolder);

    var baseFolder = !string.IsNullOrWhiteSpace(lab.Output.Reports)
        ? lab.Output.Reports
        : Path.Combine(workingFolder, "CollectionSummaryReports", SanitizeFileName(lab.LabName));

    return Path.Combine(baseFolder, "Collection Summary Report");
}

static bool IsNorthWestLab(ClaimLineCSVDataCapture.Models.LabConfig lab)
{
    ArgumentNullException.ThrowIfNull(lab);
    return lab.LabName.Equals("NorthWest", StringComparison.OrdinalIgnoreCase)
        || lab.LabName.Equals("Northwest", StringComparison.OrdinalIgnoreCase)
        || lab.LabName.Equals("NorthWest_Labs", StringComparison.OrdinalIgnoreCase)
        || lab.LabName.Equals("Northwest_Labs", StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// Maps a lab name to the SP prefix used by its Collection Summary stored procedures
/// (e.g. "NW", "Elix", "Cove"). Returns <c>null</c> for labs without Collection Summary SPs.
/// Keep in sync with <c>ClaimLineDbService.BuildCollectionSummarySpList</c> and
/// <c>LabMetricsDashboard.Services.LabCollectionPrefix</c>.
/// </summary>
static string? GetCollectionSummarySpPrefix(ClaimLineCSVDataCapture.Models.LabConfig lab)
{
    ArgumentNullException.ThrowIfNull(lab);
    var name = lab.LabName;
    if (name.Equals("NorthWest",        StringComparison.OrdinalIgnoreCase) ||
        name.Equals("Northwest",         StringComparison.OrdinalIgnoreCase) ||
        name.Equals("NorthWest_Labs",    StringComparison.OrdinalIgnoreCase)) return "NW";
    if (name.Equals("Augustus",         StringComparison.OrdinalIgnoreCase) ||
        name.Equals("Augustus_Labs",     StringComparison.OrdinalIgnoreCase)) return "Aug";
    if (name.Equals("BeechTree",        StringComparison.OrdinalIgnoreCase) ||
        name.Equals("Beech_Tree",        StringComparison.OrdinalIgnoreCase)) return "BT";
    if (name.Equals("Certus",           StringComparison.OrdinalIgnoreCase)) return "Cert";
    if (name.Equals("Cove",             StringComparison.OrdinalIgnoreCase)) return "Cove";
    if (name.Equals("Elixir",           StringComparison.OrdinalIgnoreCase)) return "Elix";
    if (name.Equals("PCRLabsofAmerica", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("PCR_Labs_of_America", StringComparison.OrdinalIgnoreCase)) return "PCR";
    if (name.Equals("PhiLife",          StringComparison.OrdinalIgnoreCase) ||
        name.Equals("Phi_Life",          StringComparison.OrdinalIgnoreCase)) return "Phi";
    if (name.Equals("RisingTides",      StringComparison.OrdinalIgnoreCase) ||
        name.Equals("Rising_Tides",      StringComparison.OrdinalIgnoreCase)) return "RT";
    if (name.Equals("Inhealth_DTR",     StringComparison.OrdinalIgnoreCase) ||
        name.Equals("InHealthDTR",       StringComparison.OrdinalIgnoreCase) ||
        name.Equals("InHealthDTRLRN",    StringComparison.OrdinalIgnoreCase)) return "IHD";
    return null;
}

static string SanitizeFileName(string name)
{
    ArgumentException.ThrowIfNullOrWhiteSpace(name);

    return string.Join("_", name.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
}

/// <summary>
/// Returns the start and end of the current week based on the lab's week-range setting.
/// E.g. weekRange="Thu to Wed" and today=Monday-2026-05-11 → (2026-05-07, 2026-05-13).
/// </summary>
static (DateOnly WeekStart, DateOnly WeekEnd) ResolveCurrentWeekBounds(string? weekRange)
{
    // Mirrors WeekRangeHelper.ResolveWeekStart — kept here to avoid exposing the internal class.
    var weekStartDay = weekRange?.Trim().ToLowerInvariant() switch
    {
        "mon to sun" => DayOfWeek.Monday,
        "tue to mon" => DayOfWeek.Tuesday,
        "wed to tue" => DayOfWeek.Wednesday,
        "thu to wed" => DayOfWeek.Thursday,
        "fri to thu" => DayOfWeek.Friday,
        _            => DayOfWeek.Monday,
    };

    var today     = DateOnly.FromDateTime(DateTime.Today);
    var offset    = ((int)today.DayOfWeek - (int)weekStartDay + 7) % 7;
    var weekStart = today.AddDays(-offset);
    return (weekStart, weekStart.AddDays(6));
}


