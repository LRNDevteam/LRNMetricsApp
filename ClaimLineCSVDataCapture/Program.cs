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
var fieldMappings = JsonSerializer.Deserialize<FieldMappingsRoot>(fieldMappingsJson, new JsonSerializerOptions
{
    PropertyNameCaseInsensitive = true,
    ReadCommentHandling = JsonCommentHandling.Skip,
    AllowTrailingCommas = true,
}) ?? throw new InvalidOperationException("Failed to deserialize FieldMappings.json.");

var workingFolder = cfg["AppSettings:WorkingFolder"]
    ?? Path.Combine(Path.GetTempPath(), "ClaimLineCSVDataCapture");
Directory.CreateDirectory(workingFolder);

// ── Logger ────────────────────────────────────────────────────────────────────
using var log = new AppLogger(cfg);
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

    var db = new ClaimLineDbService(lab.DbConnectionString);
    bool anyProcessed = false;

    // ── Process Claim Level CSV ───────────────────────────────────────────────
    try
    {
        var claimResolved = CsvFileResolver.ResolveLatestClaimLevel(lab.ServerMastersPath);
        if (claimResolved is null)
        {
            log.Warn($"  [Claim Level] No CSV found under: {lab.ServerMastersPath}");
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
                        fieldMappings.ClaimLevel, claimFilePath);

                    var inserted = db.StreamingInsert(
                        claimBatches, lab.LabName, claimWeekFolder,
                        fieldMappings.ClaimLevel, claimFilePath,
                        onBatchLoaded: (batch, count) =>
                            log.Info($"  [Claim Level] Batch {batch} loaded — {count} rows."));

                    log.Info(inserted > 0
                        ? $"  [Claim Level] Total inserted : {inserted} rows."
                        : $"  [Claim Level] Already loaded — skipped.");
                    anyProcessed = inserted > 0;
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
        var lineResolved = CsvFileResolver.ResolveLatestLineLevel(lab.ServerMastersPath);
        if (lineResolved is null)
        {
            log.Warn($"  [Line Level] No CSV found under: {lab.ServerMastersPath}");
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
                        fieldMappings.LineLevel, lineFilePath);

                    var inserted = db.StreamingInsert(
                        lineBatches, lab.LabName, lineWeekFolder,
                        fieldMappings.LineLevel, lineFilePath,
                        onBatchLoaded: (batch, count) =>
                            log.Info($"  [Line Level] Batch {batch} loaded — {count} rows."));

                    log.Info(inserted > 0
                        ? $"  [Line Level] Total inserted : {inserted} rows."
                        : $"  [Line Level] Already loaded — skipped.");
                    anyProcessed = anyProcessed || inserted > 0;
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

    if (anyProcessed)
        labsProcessed++;
    else
        labsSkipped++;

    log.Blank();
}

// ── Final report ──────────────────────────────────────────────────────────────
log.Header("Run complete");
log.Info($"  Processed : {labsProcessed}");
log.Info($"  Skipped   : {labsSkipped}");
log.Info($"  Failed    : {labsFailed}");

return labsFailed > 0 ? 1 : 0;

