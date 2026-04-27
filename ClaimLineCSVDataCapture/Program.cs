using System.Text.Json;
using ClaimLineCSVDataCapture.Models;
using ClaimLineCSVDataCapture.Services;
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

int labsProcessed = 0, labsSkipped = 0, labsFailed = 0;
var processedLabNames = new List<string>();

foreach (var lab in labConfigs)
{
    log.Info($"[Lab] {lab.LabName} — ClaimLineInsert={lab.ClaimLineInsert}, DBEnabled={lab.DBEnabled}");

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

            // Early skip if same file already loaded
            var liveClaimPath = db.GetLatestSourcePath(lab.LabName, "claimlevel");
            if (string.Equals(liveClaimPath, claimFilePath, StringComparison.OrdinalIgnoreCase))
            {
                log.Info($"  [Claim Level] Already loaded — same file, skipping.");
            }
            else
            {
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

            var livLinePath = db.GetLatestSourcePath(lab.LabName, "linelevel");
            if (string.Equals(livLinePath, lineFilePath, StringComparison.OrdinalIgnoreCase))
            {
                log.Info($"  [Line Level] Already loaded — same file, skipping.");
            }
            else
            {
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
        }

        // ── Augustus Labs production report aggregates ───────────────────────
        // Matches "Augustus_Labs" or "Augustus" lab names.
        // Same isolation pattern as NorthWest — one SP failure does not block others.
        if (lab.LabName.Equals("Augustus_Labs", StringComparison.OrdinalIgnoreCase) ||
            lab.LabName.Equals("Augustus",      StringComparison.OrdinalIgnoreCase))
        {
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
        }

        processedLabNames.Add(lab.LabName);
        labsProcessed++;
    }
    else
    {
        labsSkipped++;
    }

    log.Blank();
}

// ── Final report ──────────────────────────────────────────────────────────────
log.Header("Run complete");
log.Info($"  Processed : {labsProcessed}");
if (processedLabNames.Count > 0)
    log.Info($"  Processed Labs: {string.Join(", ", processedLabNames)}");
log.Info($"  Skipped   : {labsSkipped}");
log.Info($"  Failed    : {labsFailed}");

return labsFailed > 0 ? 1 : 0;

