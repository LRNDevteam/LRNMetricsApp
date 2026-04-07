using PredictionAnalysis;
using PredictionAnalysis.Models;
using PredictionAnalysis.Services;
using LRN.Notifications.Abstractions;
using Microsoft.Extensions.Configuration;

var appStart   = DateTime.Now;
var httpClient = new HttpClient();

// ── Attach a single log file FIRST — captures everything including startup errors ─
// Log folder fallback: if appsettings.json fails to load, write next to the exe.
var earlyLogFolder = Path.Combine(AppContext.BaseDirectory, "Logs");
Directory.CreateDirectory(earlyLogFolder);
using var appLog = FileLogger.Attach(earlyLogFolder, "App");

try
{
    var config = new ConfigurationBuilder()
        .SetBasePath(AppContext.BaseDirectory)
        .AddJsonFile("appsettings.json", optional: false, reloadOnChange: false)
        .Build();

    var settings = config.GetSection("AnalysisSettings").Get<AnalysisSettings>()
        ?? throw new InvalidOperationException("AnalysisSettings section missing.");

    var labConfigSettings = config.GetSection("LabConfig").Get<LabConfigSettings>()
        ?? throw new InvalidOperationException("LabConfig section missing.");

    // DB insert is configured per-lab inside each {LabName}.json (EnableDatabaseInsert + DbConnectionString).
    // No global connection string is needed here.

    // ── Now that we have the real log folder, start AppLogger there ───────────
    Directory.CreateDirectory(settings.LogOutputFolderPath);
    AppLogger.Initialize(settings.LogOutputFolderPath);

    // ── Load readme.json ──────────────────────────────────────────────────────
    var readMeJson  = Path.Combine(AppContext.BaseDirectory, "readme.json");
    var readMe      = File.Exists(readMeJson)
        ? System.Text.Json.JsonSerializer.Deserialize<ReadMeSettings>(
              File.ReadAllText(readMeJson),
              new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true })
          ?? new ReadMeSettings()
        : new ReadMeSettings();

    if (readMe.Metrics.Count == 0 && readMe.Ratios.Count == 0)
        Console.WriteLine("[WARN] readme.json not found or empty — Read Me sheet will be blank.");
    else
        Console.WriteLine($"[Config] readme.json loaded: {readMe.Metrics.Count} metrics, {readMe.Ratios.Count} ratios.");

    var teamsEnabled    = config.GetValue<bool>("Notifications:Teams:Enabled");
    var teamsWebhookUrl = config["Notifications:Teams:WebhookUrl"] ?? string.Empty;

    // ── Teams notifier ────────────────────────────────────────────────────────
    ITeamsNotifier teamsNotifier = new SimpleTeamsNotifier(httpClient,
        teamsEnabled ? teamsWebhookUrl : string.Empty);
    var teams = new TeamsNotificationHelper(teamsNotifier);

    // ── Load lab configs ──────────────────────────────────────────────────────
    var labs = LabConfigLoader.LoadAll(labConfigSettings);

    if (labs.Count == 0)
    {
        Console.WriteLine("[ERROR] No lab configs loaded.");
        // Teams alert only when a new file is processed.
        Environment.Exit(1);
    }

    Console.WriteLine($"\n=== Prediction vs Non-Payment Analysis ===");
    Console.WriteLine($"Today's Date : {DateTime.Today:MMMM dd, yyyy}");
    Console.WriteLine($"Labs         : {string.Join(", ", labs.Select(l => l.Config.LabName))}");
    Console.WriteLine($"Teams Alerts : {(teamsEnabled ? "Enabled" : "Disabled")}");
    Console.WriteLine();

    // 1. Application started alert
    await teams.SendAppStarted(labs.Select(l => l.Config.LabName).ToArray());

    // Teams alert only when a new file is processed; no startup alert.

    int labIndex   = 0;
    int labSuccess = 0;
    int labFailed  = 0;
    int labSkipped = 0;

    const string outputMarker = "_Prediction_vs_NonPayment_";
    const string tempSuffix   = "_temp";

    foreach (var (lab, configFilePath) in labs)
    {
        labIndex++;
        string runId             = string.Empty;
        string? processingCopy   = null;

        Console.WriteLine($"\n{"─",60}");
        Console.WriteLine($"[Lab {labIndex}/{labs.Count}] Starting: {lab.LabName}");
        Console.WriteLine($"{"─",60}");

        AppLogger.Log($"[Lab {labIndex}/{labs.Count}] Started : {lab.LabName}");
        // Teams alert only when a new file is processed; no per-lab start alert.

        try
        {
            Console.WriteLine($"[Lab] Input      : {lab.InputFolderPath}");
            Console.WriteLine($"[Lab] Processing : {lab.ProcessingFolderPath}");
            Console.WriteLine($"[Lab] Output     : {lab.OutputFolderPath}");
            Console.WriteLine($"[Lab] Last File  : {lab.LastProcessedFile ?? "(none)"}");

            // ════════════════════════════════════════════════════════════════════
            // STEP 1A — Navigate Input\Year\Month\WeekFolder
            // ════════════════════════════════════════════════════════════════════
            string weekFolderPath, weekFolderName;
            try
            {
                string resolutionNote;
                (weekFolderPath, weekFolderName, resolutionNote) =
                    ExcelReaderService.ResolveLatestFolder(lab.InputFolderPath);
                Console.WriteLine($"[Step 1] Folder resolved   : {resolutionNote}");
                Console.WriteLine($"[Step 1] Week folder       : {weekFolderPath}");
            }
            catch (FileNotFoundException ex)
            {
                Console.WriteLine($"[Step 1] No source files found: {ex.Message}");
                // Teams alert only when a new file is processed.
                labFailed++;
                continue;
            }

            // ════════════════════════════════════════════════════════════════════
            // STEP 1B — Pick latest .xlsx from WeekFolder
            // ════════════════════════════════════════════════════════════════════
            var allInputFiles = Directory
                .GetFiles(weekFolderPath, "*.xlsx", SearchOption.TopDirectoryOnly)
                .Select(f => new FileInfo(f))
                .Where(f => !f.Name.Contains(outputMarker, StringComparison.OrdinalIgnoreCase)
                         && !Path.GetFileNameWithoutExtension(f.Name)
                                 .EndsWith(tempSuffix, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(f => f.LastWriteTime)
                .ToList();

            if (allInputFiles.Count == 0)
            {
                Console.WriteLine($"[Step 1] No source .xlsx files found in: {weekFolderPath}");
                // Teams alert only when a new file is processed.
                labFailed++;
                continue;
            }

            var latestInputFile = allInputFiles[0];
            Console.WriteLine($"[Step 1] Latest file       : {latestInputFile.FullName}");

            // ════════════════════════════════════════════════════════════════════
            // STEP 1C — Skip if same as LastProcessedFile in JSON
            // ════════════════════════════════════════════════════════════════════
            if (!string.IsNullOrWhiteSpace(lab.LastProcessedFile)
                && string.Equals(lab.LastProcessedFile, latestInputFile.FullName,
                                 StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine($"[Step 1] SKIP — file matches LastProcessedFile in JSON: {latestInputFile.Name}");
                Console.WriteLine($"[Step 1]        LastProcessedFile : {lab.LastProcessedFile}");
                // Teams alert only when a new file is processed.
                AppLogger.LogWarn($"[Lab {labIndex}/{labs.Count}] SKIPPED : {lab.LabName} | File: {latestInputFile.Name}");
                labSkipped++;
                continue;
            }

            Console.WriteLine($"[Step 1] New file detected — proceeding with processing.");

            // ── Relative sub-path — derived from ResolveLatestFolder result ───────
            // weekFolderPath = Input\2026\02. February\02.25.2026 - 03.03.2026
            // relativeSub    = 2026\02. February\02.25.2026 - 03.03.2026
            var relativeSub = Path.GetRelativePath(lab.InputFolderPath, weekFolderPath);

            if (string.IsNullOrWhiteSpace(relativeSub) || relativeSub == ".")
                relativeSub = Path.Combine(DateTime.Now.Year.ToString(),
                                           DateTime.Now.ToString("MM. MMMM"),
                                           weekFolderName);

            Console.WriteLine($"[Step 1] Relative sub-path : {relativeSub}");

            // ════════════════════════════════════════════════════════════════════
            // STEP 2 — COPY source file to ProcessingFolderPath (flat, no subfolders)
            // ════════════════════════════════════════════════════════════════════
            processingCopy = Path.Combine(lab.ProcessingFolderPath, latestInputFile.Name);

            // Overwrite any leftover copy from a previous failed run
            if (File.Exists(processingCopy))
            {
                File.Delete(processingCopy);
                Console.WriteLine($"[Step 2] Removed stale Processing copy: {latestInputFile.Name}");
            }

            File.Copy(latestInputFile.FullName, processingCopy);
            Console.WriteLine($"[Step 2] Copied to Processing : {processingCopy}");

            // ════════════════════════════════════════════════════════════════════
            // STEP 3 — Run predictions from the Processing copy
            // ════════════════════════════════════════════════════════════════════
            var labSettings = new AnalysisSettings
            {
                InputFolderPath           = lab.ProcessingFolderPath,  // read from Processing
                OutputFolderPath          = lab.OutputFolderPath,
                LogOutputFolderPath       = settings.LogOutputFolderPath,
                SheetName                 = settings.SheetName,
                Columns                   = settings.Columns,
                ForecastingPIncludeValues = settings.ForecastingPIncludeValues,
                PayStatusDenied           = settings.PayStatusDenied,
                PayStatusAdjusted         = settings.PayStatusAdjusted,
                PayStatusNoResponse       = settings.PayStatusNoResponse,
                PayStatusPaid             = settings.PayStatusPaid,
                TopDenialCodesPerPayer    = settings.TopDenialCodesPerPayer
            };

            List<ClaimRecord> allRecords;
            string sourceFile;

            try
            {
                var tempLabConfig = new LabConfig
                {
                    LabName              = lab.LabName,
                    InputFolderPath      = lab.ProcessingFolderPath,
                    OutputFolderPath     = lab.OutputFolderPath,
                    ProcessingFolderPath = lab.ProcessingFolderPath,
                    LastProcessedFile    = null   // always read the copy
                };

                (allRecords, sourceFile, runId, _) =
                    new ExcelReaderService().LoadLatestReport(labSettings, tempLabConfig);
            }
            catch (FileNotFoundException fnfEx)
            {
                Console.WriteLine($"[Step 3] [WARN] {fnfEx.Message}");
                // Teams alert only when a new file is processed.
                labFailed++;
                continue;
            }

            Console.WriteLine($"[Step 3] Records loaded: {allRecords.Count}");

            // ════════════════════════════════════════════════════════════════════
            // STEP 3B — Persist source rows to DB (exceptions do NOT stop analysis)
            //           DB is opt-in per lab via EnableDatabaseInsert in {LabName}.json
            //           Guard: skip if this exact file path already exists in
            //                  PayerValidationFileLog (e.g. re-run after a crash).
            // ════════════════════════════════════════════════════════════════════
            if (lab.EnableDatabaseInsert)
            {
                if (!string.IsNullOrWhiteSpace(lab.DbConnectionString))
                {
                    var labDbService = new PredictionDbService(lab.DbConnectionString);

                    if (labDbService.FileAlreadyLogged(latestInputFile.FullName, lab.LabName))
                    {
                        AppLogger.LogDb($"[{lab.LabName}] DB insert skipped — file already logged in PayerValidationFileLog.");
                    }
                    else
                    {
                        labDbService.SavePayerValidationData(
                            allRecords, latestInputFile.FullName, runId, weekFolderName, lab.LabName);
                    }
                }
                else
                {
                    AppLogger.LogDbWarn($"[{lab.LabName}] EnableDatabaseInsert=true but DbConnectionString is empty — skipping DB insert.");
                }
            }
            else
            {
                AppLogger.LogDb($"[{lab.LabName}] DB insert disabled (EnableDatabaseInsert=false).");
            }

            var svc              = new AnalysisService(labSettings);
            var predicted        = svc.BuildPredictedPayableDataset(allRecords);
            var working          = svc.BuildWorkingDataset(allRecords);
            var summary          = svc.BuildSummary(predicted, working);
            var denialSum        = svc.BuildDenialSummary(working);
            var denialPivot      = svc.BuildDenialPivot(working, denialSum);
            var aging            = svc.BuildAgingBuckets(working);
            var denialCodeAnalysis = svc.BuildDenialCodeAnalysis(working);
            Console.WriteLine($"[Step 3] Aging rows: {aging.Count}");
            Console.WriteLine($"[Step 3] Denial code analysis rows: {denialCodeAnalysis.Count}");

            // ════════════════════════════════════════════════════════════════════
            // STEP 4 — Write report directly into ProcessingFolderPath
            // ════════════════════════════════════════════════════════════════════
            Console.WriteLine("\n[Step 4] Generating report into Processing folder...");

            var reportInProcessing = new ReportWriterService().WriteReport(
                lab.ProcessingFolderPath,
                summary, denialSum, denialPivot, aging,
                latestInputFile.FullName, predicted, working,
                runId, lab.LabName, weekFolderName,
                readMe, labSettings, denialCodeAnalysis);

            // ════════════════════════════════════════════════════════════════════
            // STEP 5 — Move report  Processing → Output\Year\Month\WeekFolder
            //          Then delete the source copy from ProcessingFolderPath
            // ════════════════════════════════════════════════════════════════════
            Console.WriteLine("\n[Step 5] Moving report to Output folder...");

            var outputSubFolder = Path.Combine(lab.OutputFolderPath, relativeSub);
            Directory.CreateDirectory(outputSubFolder);

            var reportFileName  = Path.GetFileName(reportInProcessing);
            var finalOutputPath = Path.Combine(outputSubFolder, reportFileName);

            // Retry the move in case SharePoint has the output folder open
            const int maxRetries   = 3;
            const int retryDelayMs = 10_000;

            for (int attempt = 1; attempt <= maxRetries; attempt++)
            {
                try
                {
                    File.Move(reportInProcessing, finalOutputPath, overwrite: true);
                    Console.WriteLine($"[Step 5] Report moved → Output:");
                    Console.WriteLine($"         {finalOutputPath}");

                    // ── Write companion summary JSON (same base name, .json extension) ──
                    var jsonOutputPath = SummaryJsonWriter.Write(
                        finalOutputPath, summary, working, labSettings,
                        lab.LabName, runId, weekFolderName);
                    Console.WriteLine($"[Step 5] Summary JSON → Output:");
                    Console.WriteLine($"         {jsonOutputPath}");

                    break;
                }
                catch (IOException ioEx) when (attempt < maxRetries)
                {
                    Console.WriteLine($"[Step 5] [WARN] Move failed — file locked (attempt {attempt}/{maxRetries}): {ioEx.Message}");
                    Console.WriteLine($"[Step 5] Retrying in {retryDelayMs / 1000}s...");
                    await Task.Delay(retryDelayMs);
                }
                catch (IOException ioEx)
                {
                    Console.WriteLine($"[Step 5] [ERROR] Move still failing after {maxRetries} attempts: {ioEx.Message}");
                    throw;
                }
            }

            // ── Clean up source copy from ProcessingFolderPath ────────────────────
            if (processingCopy != null && File.Exists(processingCopy))
            {
                try
                {
                    File.Delete(processingCopy);
                    Console.WriteLine($"[Step 5] Processing source copy deleted: {Path.GetFileName(processingCopy)}");
                    processingCopy = null;
                }
                catch (Exception delEx)
                {
                    Console.WriteLine($"[Step 5] [WARN] Could not delete Processing source copy: {delEx.Message}");
                }
            }

            // ════════════════════════════════════════════════════════════════════
            // Save runtime fields to {LabName}.json
            // ════════════════════════════════════════════════════════════════════
            lab.LastProcessedFile         = latestInputFile.FullName;
            lab.LastProcessedRelativePath = relativeSub;
            lab.LastOutputFilePath        = finalOutputPath;
            LabConfigLoader.SaveLastProcessed(configFilePath, lab);

            Console.WriteLine($"\n[Lab {lab.LabName}] Complete");
            Console.WriteLine($"[Lab {lab.LabName}] Output    : {finalOutputPath}");

            // Only send Teams alert when a new file is processed — includes full summary
            await teams.SendLabCompleted(
                lab.LabName, runId, weekFolderName,
                latestInputFile.Name, finalOutputPath, summary);

            AppLogger.Log($"[Lab {labIndex}/{labs.Count}] SUCCESS : {lab.LabName} | RunId: {runId} | Output: {finalOutputPath}");
            labSuccess++;
        }
        catch (Exception ex)
        {
            // ── Best-effort cleanup of Processing copy on unexpected failure ──────
            if (processingCopy != null && File.Exists(processingCopy))
            {
                try   { File.Delete(processingCopy); }
                catch { /* ignore cleanup errors */ }
            }

            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"\n[ERROR] Lab '{lab.LabName}' failed: {ex.Message}");
            Console.WriteLine(ex.StackTrace);
            Console.ResetColor();

            // 3. Error alert when a lab fails
            await teams.SendLabFailed(lab.LabName, runId, ex.Message);
            AppLogger.LogError($"[Lab {labIndex}/{labs.Count}] FAILED  : {lab.LabName}", ex);
            labFailed++;
        }
    }

    // ── Final summary ─────────────────────────────────────────────────────────────
    Console.WriteLine($"\n=== Run Complete ===");
    Console.WriteLine($"Success : {labSuccess}");
    Console.WriteLine($"Failed  : {labFailed}");
    Console.WriteLine($"Skipped : {labSkipped}");
    Console.WriteLine($"Elapsed : {DateTime.Now - appStart:mm\\:ss}");

    // 4. Application ended alert
    await teams.SendAppStopped(labSuccess, labFailed, DateTime.Now - appStart);

    AppLogger.Flush(labSuccess, labFailed, labSkipped, DateTime.Now - appStart);
}
catch (Exception initEx)
{
    Console.WriteLine($"[FATAL] Initialization error: {initEx.Message}");
    Console.WriteLine(initEx.StackTrace);
}