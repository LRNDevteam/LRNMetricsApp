// See https://aka.ms/new-console-template for more information
using CodingMasterGenerator.Services;
using Microsoft.Extensions.Configuration;

// ── Configuration ─────────────────────────────────────────────────────────────
var configuration = new ConfigurationBuilder()
    .SetBasePath(AppContext.BaseDirectory)
    .AddJsonFile("appsettings.json", optional: false)
    .Build();

var labConfigFolder = configuration["AppSettings:LabConfigFolder"]
    ?? throw new InvalidOperationException("AppSettings:LabConfigFolder is not configured.");

var workingFolder = configuration["AppSettings:WorkingFolder"]
    ?? throw new InvalidOperationException("AppSettings:WorkingFolder is not configured.");

var labNames = configuration.GetSection("AppSettings:Labs").Get<List<string>>()
    ?? throw new InvalidOperationException("AppSettings:Labs is not configured.");

var logFolder = configuration["Logging:LogFolder"]
    ?? Path.Combine(AppContext.BaseDirectory, "Logs");
var retainDays = int.TryParse(configuration["Logging:RetainDays"], out var rd) ? rd : 30;

using var log = new AppLogger(logFolder, retainDays);

log.Header("CodingMaster Generator");
log.Info($"Lab config folder : {labConfigFolder}");
log.Info($"Working folder    : {workingFolder}");
log.Info($"Labs configured   : {labNames.Count}");
log.Info($"Log file          : {log.LogFilePath}");
log.Blank();

// ── Load lab configs ──────────────────────────────────────────────────────────
var labConfigs = LabConfigLoader.LoadAll(labConfigFolder, labNames, log);
log.Blank();

int labsProcessed = 0, labsSkipped = 0, labsFailed = 0;
var overallSw = System.Diagnostics.Stopwatch.StartNew();

foreach (var lab in labConfigs)
{
    log.Info($"[Lab] {lab.LabName}");

    // ── Validate config ───────────────────────────────────────────────────
    if (string.IsNullOrWhiteSpace(lab.ServerMastersPath))
    {
        log.Warn("  [SKIP] ServerMastersBasePath or ServerMasterFolderName not configured.");
        labsSkipped++;
        continue;
    }

    if (string.IsNullOrWhiteSpace(lab.Output.Reports))
    {
        log.Warn("  [SKIP] Output.Reports not configured.");
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

    // ── Step 1: Resolve latest Line Level and Claim Level CSVs ────────────
    var lineResolved = CsvFileResolver.ResolveLatestLineLevel(lab.ServerMastersPath);
    if (lineResolved is null)
    {
        log.Warn($"  [SKIP] No Line Level CSV found under: {lab.ServerMastersPath}");
        labsSkipped++;
        continue;
    }

    var claimResolved = CsvFileResolver.ResolveLatestClaimLevel(lab.ServerMastersPath);

    var (lineCsvPath, weekFolder) = lineResolved.Value;
    var runId = CsvFileResolver.ExtractRunId(lineCsvPath);
    log.Info($"  Line Level CSV : {lineCsvPath}");
    log.Info($"  Claim Level CSV: {claimResolved?.FilePath ?? "(not found)"}");
    log.Info($"  Week folder    : {weekFolder}");
    log.Info($"  RunId          : {runId}");

    // ── Step 2: Check if this RunId was already processed ─────────────────
    var outputFolder = Path.Combine(lab.Output.Reports, "CodingMaster");
    var existingRunId = CsvFileResolver.FindExistingRunId(outputFolder, lab.LabName);
    if (string.Equals(existingRunId, runId, StringComparison.OrdinalIgnoreCase))
    {
        log.Info($"  [SKIP] RunId '{runId}' already processed — skipping.");
        labsSkipped++;
        continue;
    }

    // ── Step 3: Copy CSV to InProgress working folder ─────────────────────
    var inProgressDir = Path.Combine(workingFolder, "InProgress", lab.LabName);
    Directory.CreateDirectory(inProgressDir);

    var workingCsvPath = Path.Combine(inProgressDir, Path.GetFileName(lineCsvPath));
    File.Copy(lineCsvPath, workingCsvPath, overwrite: true);
    log.Info($"  Working copy   : {workingCsvPath}");

    try
    {
        // ── Step 4: Run CodingMasterEngine ────────────────────────────────
        var outputRows = CodingMasterEngine.Generate(workingCsvPath, log);

        if (outputRows.Count == 0)
        {
            log.Warn($"  [SKIP] No output rows generated for '{lab.LabName}'.");
            labsSkipped++;
            continue;
        }

        // ── Step 5: Write Excel to Output.Reports/CodingMaster/ ──────────
        log.Info($"  Output folder  : {outputFolder}");

        var outputPath = CodingMasterExcelWriter.Write(outputRows, outputFolder, lab.LabName, runId);

        log.Success($"  Report generated: {outputPath} ({outputRows.Count:N0} rows)");
        labsProcessed++;
    }
    catch (Exception ex)
    {
        log.Error($"  FAILED: {ex.Message}");
        log.Error($"  {ex.StackTrace ?? ""}");
        labsFailed++;
    }
    finally
    {
        // ── Step 5: Delete InProgress copy ────────────────────────────────
        try
        {
            if (Directory.Exists(inProgressDir))
                Directory.Delete(inProgressDir, recursive: true);
        }
        catch { /* best-effort cleanup */ }
    }

    log.Blank();
}

overallSw.Stop();
log.Blank();
log.Header("Summary");
log.Info($"Processed : {labsProcessed}");
log.Info($"Skipped   : {labsSkipped}");
log.Info($"Failed    : {labsFailed}");
log.Info($"Total time: {overallSw.Elapsed.TotalSeconds:F1}s");

return labsFailed > 0 ? 1 : 0;

