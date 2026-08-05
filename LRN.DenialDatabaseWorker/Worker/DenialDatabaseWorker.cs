using System.Data;
using System.Text;
using DenialDatabaseProcessorWorker.Builders;
using DenialDatabaseProcessorWorker.BulkWriters;
using DenialDatabaseProcessorWorker.Models;
using DenialDatabaseProcessorWorker.Normalizers;
using DenialDatabaseProcessorWorker.Notifications;
using DenialDatabaseProcessorWorker.Services;
using DenialDatabaseProcessorWorker.Services.SharePoint;
using DenialDatabaseProcessorWorker.Services.Workflow;
using DenialDatabaseProcessorWorker.Models.Workflow;
using DenialDatabaseProcessorWorker.Utils;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace DenialDatabaseProcessorWorker.Worker;

public sealed class DenialDatabaseWorker : BackgroundService
{
    private readonly ILogger<DenialDatabaseWorker> _logger;
    private readonly ProcessorOptions _options;
    private readonly List<LabConfig> _labs;
    private readonly ITeamsNotifier _teamsNotifier;
    private readonly CsvStepLogger _stepLogger;
    private readonly ExcelTableReader _excelReader;
    private readonly PayerValidationReportRepository _payerValidationRepo;
    private readonly DenialDatabaseBuilder _builder;
    private readonly ExcelWriter _excelWriter;
    private readonly ISharePointUploader _uploader;
    private readonly DenialInsightBuilder _insightBuilder;
    private readonly FileResolver _fileResolver;
    private readonly OutputPathBuilder _outputPathBuilder;
    private readonly DenialAnalysisRunLogRepository _runLogRepo;
    private readonly DenialTaskBoardRepository _denialTaskBoardRepo;
    private readonly IDenialWorkflowApiClient _workflowApiClient;
    private readonly SharePointGraphOptions _spOpt;

    public DenialDatabaseWorker(
        ILogger<DenialDatabaseWorker> logger,
        IOptions<ProcessorOptions> options,
        IOptions<List<LabConfig>> labs,
        CsvStepLogger stepLogger,
        ExcelTableReader excelReader,
        PayerValidationReportRepository payerValidationRepo,
        DenialDatabaseBuilder builder,
        ExcelWriter excelWriter,
        ITeamsNotifier teamsNotifier,
        DenialInsightBuilder insightBuilder,
        FileResolver fileResolver,
        OutputPathBuilder outputPathBuilder,
        DenialAnalysisRunLogRepository runLogRepo,
        DenialTaskBoardRepository denialTaskBoardRepo,
        IDenialWorkflowApiClient workflowApiClient,
        ISharePointUploader uploader,
        IOptions<SharePointGraphOptions> spOpt)
    {
        _logger = logger;
        _options = options.Value;
        _labs = labs.Value;
        _stepLogger = stepLogger;
        _excelReader = excelReader;
        _payerValidationRepo = payerValidationRepo;
        _builder = builder;
        _excelWriter = excelWriter;
        _insightBuilder = insightBuilder;
        _fileResolver = fileResolver;
        _outputPathBuilder = outputPathBuilder;
        _runLogRepo = runLogRepo;
        _denialTaskBoardRepo = denialTaskBoardRepo;
        _workflowApiClient = workflowApiClient;
        _uploader = uploader;
        _spOpt = spOpt.Value;
        _teamsNotifier = teamsNotifier;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (_options.RunOnceOnStartup)
        {
            foreach (var lab in _labs)
                await ProcessLabAsync(lab, stoppingToken);

            _logger.LogInformation("RunOnceOnStartup=true. Worker completed.");
        }
        else
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                foreach (var lab in _labs)
                    await ProcessLabAsync(lab, stoppingToken);

                await Task.Delay(TimeSpan.FromMinutes(_options.IntervalMinutes), stoppingToken);
            }
        }
    }

    private async Task ProcessLabAsync(LabConfig lab, CancellationToken ct)
    {
        string payerPolicySource = "";
        string claimActionMapperFile = "";
        string outFile = "";
        string runId = "";

        try
        {
            claimActionMapperFile = _fileResolver.GetLatestClaimActionMapper(lab);

            if (string.IsNullOrWhiteSpace(claimActionMapperFile) || !File.Exists(claimActionMapperFile))
                throw new FileNotFoundException("Latest claim action mapper file not found.", claimActionMapperFile);

            // Denial rows now come from the lab database, not from the payer policy workbook.
            var sourceRun = await _payerValidationRepo.GetLatestDeniedRunAsync(lab, ct);

            if (sourceRun is null)
            {
                _logger.LogInformation(
                    "No '{PayStatus}' rows found in {Table} for lab {LabName}. Nothing to process.",
                    _options.DeniedPayStatus, _options.PayerValidationReportTable, lab.LabName);
                return;
            }

            runId = sourceRun.RunId;
            payerPolicySource = BuildSourceLabel(lab, sourceRun);

            if (string.IsNullOrWhiteSpace(runId))
                throw new InvalidOperationException($"{_options.PayerValidationReportTable} rows for lab {lab.LabName} have no RunId.");

            if (await _runLogRepo.ExistsAsync(runId))
            {
                _logger.LogInformation("RunId {RunId} already processed. Skipping lab {LabName}.", runId, lab.LabName);
                return;
            }

            var (yearFolder, monthFolder, weekFolder) = _fileResolver.ExtractFolderStructure(
                sourceRun.SourceFullPath,
                sourceRun.WeekFolder,
                sourceRun.InsertedDateTime ?? DateTime.Now);

            outFile = _outputPathBuilder.BuildOutputPath(
                _options.OutputRoot,
                lab.LabName,
                runId,
                yearFolder,
                monthFolder,
                weekFolder,
                createDirectory: _options.GenerateOutputFiles);

            await _stepLogger.LogAsync(lab, "Start", "InProgress", payerPolicySource, claimActionMapperFile, outFile, null, ct);

            // 1. Load existing tasks from the selected LAB database, not LRNMaster.
            // DenialTaskBoard is lab-level, so NorthWest must read from NWL_Lab / NWL_LRN,
            // Augustus from Augustus_LRN, Certus from Certus_LRN, etc.
            var labTaskBoardRepo = new DenialTaskBoardRepository(lab.LabConnectionString);
            var existingTasks = await labTaskBoardRepo.GetExistingTasksAsync(lab.LabId);

            // 2. Load Claim Action Mapper
            await _stepLogger.LogAsync(lab, "Load ClaimActionMapper excel", "InProgress", payerPolicySource, claimActionMapperFile, outFile, null, ct);
            var claimRows = _excelReader.Read(claimActionMapperFile, "Denial Classifier");
            var claimMapperIndex = new ClaimActionMapperIndex(claimRows);
            await _stepLogger.LogAsync(lab, "Load ClaimActionMapper excel", "Completed", payerPolicySource, claimActionMapperFile, outFile, null, ct);

            // 3. Load denied rows from the lab database (PayerValidationReport)
            await _stepLogger.LogAsync(lab, "Load PayerValidationReport denied rows", "InProgress", payerPolicySource, claimActionMapperFile, outFile, null, ct);

            var payerRows = await _payerValidationRepo.GetDeniedRowsAsync(
                lab,
                _options.ProcessLatestRunOnly ? runId : null,
                ct);

            await _stepLogger.LogAsync(lab, "Load PayerValidationReport denied rows", "Completed", payerPolicySource, claimActionMapperFile, outFile,
                $"DeniedRows={payerRows.Count}", ct);

            if (payerRows.Count == 0)
            {
                _logger.LogInformation(
                    "Lab {LabName}: RunId {RunId} returned no '{PayStatus}' rows. Nothing to copy.",
                    lab.LabName, runId, _options.DeniedPayStatus);

                await _stepLogger.LogAsync(lab, "Completed", "Completed", payerPolicySource, claimActionMapperFile, outFile, "No denied rows.", ct);
                return;
            }

            // 4. Normalize + map
            await _stepLogger.LogAsync(lab, "Normalize DenialCode + map fields", "InProgress", payerPolicySource, claimActionMapperFile, outFile, null, ct);
            var (headers, finalRows) = _builder.Build(payerRows, claimMapperIndex);
            ApplyClaimUid(finalRows);

            // Lab-specific insurance amount rule:
            // Augustus (19), Certus (18), and NorthWest (20) must use Billed Amount
            // as Insurance Balance for insight, task-board creation, Excel export, and DB inserts.
            ApplyLabSpecificInsuranceBalanceRule(lab, finalRows);

            await _stepLogger.LogAsync(lab, "Normalize DenialCode + map fields", "Completed", payerPolicySource, claimActionMapperFile, outFile, null, ct);

            // 5. Build insight
            await _stepLogger.LogAsync(lab, "Build insight rows", "InProgress", payerPolicySource, claimActionMapperFile, outFile, null, ct);
            var insight = _insightBuilder.Build(finalRows);
            await _stepLogger.LogAsync(lab, "Build insight rows", "Completed", payerPolicySource, claimActionMapperFile, outFile, null, ct);

            // 6. Build task board
            await _stepLogger.LogAsync(lab, "Build task board rows", "InProgress", payerPolicySource, claimActionMapperFile, outFile, null, ct);
            var taskBuilder = new TaskBoardBuilder(lab.LabId, lab.LabName, runId, existingTasks);
            var taskRows = taskBuilder.Build(finalRows);
            await _stepLogger.LogAsync(lab, "Build task board rows", "Completed", payerPolicySource, claimActionMapperFile, outFile, null, ct);

            var filteredLineRows = finalRows
              .Where(r =>
                  r.TryGetValue("DenialCode_Original", out var originalCode) &&
                  !string.IsNullOrWhiteSpace(originalCode))
              .ToList();

            // 7. Write the xlsx / csv / zip export package.
            // Controlled by DenialDatabaseProcessor:GenerateOutputFiles - when false the worker
            // is a pure SQL copy and produces no files at all.
            string exportPackagePath = "";

            if (_options.GenerateOutputFiles)
            {
                await _stepLogger.LogAsync(lab, "Write DenialDatabase export package", "InProgress", payerPolicySource, claimActionMapperFile, outFile, null, ct);

                var exportResult = _excelWriter.Write(
                                    outFile,
                                    insight.Headers,
                                    insight.Rows,
                                    filteredLineRows,
                                    taskRows,
                                    null,
                                    null);

                exportPackagePath = exportResult.ZipPath;

                await _stepLogger.LogAsync(lab, "Write DenialDatabase export package", "Completed", payerPolicySource, claimActionMapperFile, exportPackagePath, null, ct);
            }
            else
            {
                _logger.LogInformation("GenerateOutputFiles=false. Skipping xlsx/csv/zip export for lab {LabName}.", lab.LabName);
                await _stepLogger.LogAsync(lab, "Write DenialDatabase export package", "Skipped", payerPolicySource, claimActionMapperFile, outFile,
                    "GenerateOutputFiles=false", ct);
            }

            // 8. Convert rows to DataTables (simple, column-per-key)
            var insightTable = ToDataTable(insight.Rows);
            var lineItemTable = DenialLineItemTableBuilder.Build(filteredLineRows,lab,runId);
            var taskBoardTable = ToDataTable(taskRows);

            // 9. Bulk writers (manual, per-lab connection string)
            var insightWriter = new DenialInsightBulkWriter(lab.LabConnectionString);
            var lineItemWriter = new DenialLineItemBulkWriter(lab.LabConnectionString);
            var taskBoardWriter = new DenialTaskBoardBulkWriter(lab.LabConnectionString);

            // 10. Write DB tables into the selected LAB database.
            // DenialTaskBoard must be copied here also; do not depend on Workflow API for this worker run.
            await _stepLogger.LogAsync(lab, "Write Denial insight/line/task-board tables", "InProgress", payerPolicySource, claimActionMapperFile, outFile, null, ct);

            await labTaskBoardRepo.ReconcileBeforeWriteAsync(lab.LabId, lab.LabName, runId, lineItemTable, taskRows, ct);
            await insightWriter.WriteAsync(insightTable, lab, runId);
            await lineItemWriter.WriteAsync(lineItemTable, lab, runId);
            await taskBoardWriter.WriteAsync(taskBoardTable, lab, runId);

            await _stepLogger.LogAsync(lab, "Write Denial insight/line/task-board tables", "Completed", payerPolicySource, claimActionMapperFile, outFile,
                $"InsightRows={insightTable.Rows.Count}, LineRows={lineItemTable.Rows.Count}, TaskBoardRows={taskBoardTable.Rows.Count}", ct);

            // Workflow API sync is disabled in this worker path because task-board rows are bulk copied directly.
            // Keeping both direct bulk copy and API sync can create duplicates or fail when LRN.ReportsApi is not running.
            // If workflow/history processing is required later, call the API from a separate controlled flow after bulk copy.

            // 11. Insert RunLog
            await _runLogRepo.InsertAsync(runId, lab.LabId, exportPackagePath);

            // 12. Upload to SharePoint (only meaningful when the export package was produced)
            if (_options.GenerateOutputFiles && _options.UploadOutputsToSharePoint && !string.IsNullOrWhiteSpace(exportPackagePath))
            {
                await _stepLogger.LogAsync(lab, "Upload to SharePoint", "InProgress", payerPolicySource, claimActionMapperFile, outFile, null, ct);
                await _uploader.UploadIfEnabledAsync(lab, exportPackagePath, DateTime.Now, ct);
                await _stepLogger.LogAsync(lab, "Upload to SharePoint", "Completed", payerPolicySource, claimActionMapperFile, outFile, null, ct);
            }
            else
            {
                await _stepLogger.LogAsync(lab, "Upload to SharePoint", "Skipped", payerPolicySource, claimActionMapperFile, outFile,
                    _options.GenerateOutputFiles ? "UploadOutputsToSharePoint=false" : "GenerateOutputFiles=false", ct);
            }

            await _stepLogger.LogAsync(lab, "Completed", "Completed", payerPolicySource, claimActionMapperFile, outFile, null, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Lab processing failed: {LabName}", lab.LabName);
            await _stepLogger.LogAsync(lab, "Failed", "Failed", payerPolicySource, claimActionMapperFile, outFile, ex.ToString(), ct);
        }
    }

    /// <summary>Human readable "source" used in the step log now that there is no input workbook.</summary>
    private string BuildSourceLabel(LabConfig lab, PayerValidationRun run)
    {
        var database = TryGetDatabaseName(lab.LabConnectionString);
        var table = string.IsNullOrWhiteSpace(database)
            ? _options.PayerValidationReportTable
            : $"{database}.{_options.PayerValidationReportTable}";

        return $"{table} (RunId={run.RunId}, PayStatus={_options.DeniedPayStatus}, Rows={run.DeniedRowCount})";
    }

    private static string TryGetDatabaseName(string connectionString)
    {
        try
        {
            return new SqlConnectionStringBuilder(connectionString).InitialCatalog;
        }
        catch
        {
            return "";
        }
    }

    private static DenialTaskImportRequest BuildWorkflowImportRequest(LabConfig lab, string runId, List<Dictionary<string, string>> taskRows)
    {
        return new DenialTaskImportRequest
        {
            LabId = lab.LabId,
            LabName = lab.LabName,
            RunId = runId,
            Tasks = taskRows.Select(r => new DenialTaskImportRow
            {
                UniqueTrackId = GetValueByAnyKey(r, "UniqueTrackId"),
                ClaimUid = GetValueByAnyKey(r, "ClaimUID"),
                ClaimId = GetValueByAnyKey(r, "Claim ID", "ClaimID"),
                PatientId = GetValueByAnyKey(r, "Patient / Acct #", "PatientId"),
                CptCode = GetValueByAnyKey(r, "CPT Code", "CPTCode"),
                DenialCode = GetValueByAnyKey(r, "Denial Code", "DenialCode"),
                DenialDescription = GetValueByAnyKey(r, "Denial Description", "DenialDescription"),
                DenialClassification = GetValueByAnyKey(r, "Denial Classification", "DenialClassification"),
                ActionCode = GetValueByAnyKey(r, "Action Code", "ActionCode"),
                RecommendedAction = GetValueByAnyKey(r, "Recommended Action", "RecommendedAction"),
                ActionCategory = GetValueByAnyKey(r, "Action Category", "ActionCategory"),
                Task = GetValueByAnyKey(r, "Task"),
                Priority = GetValueByAnyKey(r, "Priority"),
                InsuranceBalance = TryDecimal(GetValueByAnyKey(r, "Insurance Balance", "InsuranceBalance")),
                SlaDays = TryInt(GetValueByAnyKey(r, "SLA (Days)", "SLADays")),
                DateOpened = TryDate(GetValueByAnyKey(r, "Date Opened", "DateOpened")),
                DueDate = TryDate(GetValueByAnyKey(r, "Due Date", "DueDate")),
                DateCompleted = TryDate(GetValueByAnyKey(r, "Date Completed", "DateCompleted")),
                SalesRepname = GetValueByAnyKey(r, "SalesRepname"),
                ClinicName = GetValueByAnyKey(r, "ClinicName"),
                ReferringProvider = GetValueByAnyKey(r, "ReferringProvider"),
                Source = GetValueByAnyKey(r, "Source"),
                PatName = GetValueByAnyKey(r, "Pat name", "PatName", "Patient Name", "PatientName"),
                SubscriberId = GetValueByAnyKey(r, "Subscriber Id", "SubscriberId", "Subscriber ID", "SubscriberID"),
                PayerName = GetValueByAnyKey(r, "Payer Name", "PayerName"),
                PayerNameNormalized = GetValueByAnyKey(r, "PayerName Normalized", "PayerNameNormalized"),
                PayerCode = TryInt(GetValueByAnyKey(r, "Payer Code", "PayerCode")),
                PayerType = GetValueByAnyKey(r, "Payer Type", "PayerType"),
                FirstBilledDate = TryDate(GetValueByAnyKey(r, "First Billed Date", "FirstBilledDate")),
                ChargeEnteredDate = TryDate(GetValueByAnyKey(r, "ChargeEnteredDate")),
                BillingProvider = GetValueByAnyKey(r, "BillingProvider"),
                PanelName = GetValueByAnyKey(r, "Panel Name", "PanelName"),
                DateOfService = TryDate(GetValueByAnyKey(r, "Date of Service", "DateOfService")),
                IcdCodes = GetValueByAnyKey(r, "ICDCodes"),
                CoverageStatus = GetValueByAnyKey(r, "CoverageStatus"),
                IcdComplianceStatus = GetValueByAnyKey(r, "ICDComplianceStatus"),
                DenialValidity = GetValueByAnyKey(r, "DenialValidity")
            }).Where(x => !string.IsNullOrWhiteSpace(x.UniqueTrackId)).ToList()
        };
    }

    private static decimal TryDecimal(string? value) => decimal.TryParse(value, out var parsed) ? parsed : 0;
    private static int? TryInt(string? value) => int.TryParse(value, out var parsed) ? parsed : null;
    private static DateTime? TryDate(string? value) => DateTime.TryParse(value, out var parsed) ? parsed : null;

    private static DataTable ToDataTable(List<Dictionary<string, string>> rows)
    {
        var table = new DataTable();

        if (rows.Count == 0)
            return table;

        // Create columns
        foreach (var key in rows[0].Keys)
            table.Columns.Add(key, typeof(string));

        // Normalized INT column names (SQL names)
        string[] intColumns =
                    {"PaymentDays",
                    "Payment Days"  };

        foreach (var row in rows)
        {
            var dr = table.NewRow();

            foreach (var kv in row)
            {
                var value = kv.Value?.Trim();

                //// Normalize the Excel key so ANY variation matches
                //var normalizedKey = kv.Key
                //	.Replace(" ", "")
                //	.Replace("_", "")
                //	.Replace("-", "")
                //	.Replace("(", "")
                //	.Replace(")", "")
                //	.Trim()
                //	.ToLower();

                // ⭐ FIX 1: Clean percentage values
                if (!string.IsNullOrEmpty(value) && value.EndsWith("%"))
                {
                    var cleaned = value.Replace("%", "");
                    if (decimal.TryParse(cleaned, out var dec))
                        dr[kv.Key] = dec.ToString();
                    else
                        dr[kv.Key] = DBNull.Value;

                    continue;
                }

                // ⭐ FIX 2: Universal INT cleaner (handles ANY Excel variation)
                if (intColumns.Contains(kv.Key))
                {
                    // If Excel put a date → NULL
                    if (DateTime.TryParse(value, out _))
                    {
                        dr[kv.Key] = DBNull.Value;
                        continue;
                    }

                    // If numeric → keep it
                    if (int.TryParse(value, out var intVal))
                    {
                        dr[kv.Key] = intVal;
                        continue;
                    }

                    // Anything else → NULL
                    dr[kv.Key] = DBNull.Value;
                    continue;
                }

                // ⭐ FIX 3: Empty → NULL
                if (string.IsNullOrWhiteSpace(value))
                {
                    dr[kv.Key] = DBNull.Value;
                    continue;
                }

                // Default: keep as string
                if (string.Equals(kv.Key, "Assigned To", StringComparison.OrdinalIgnoreCase) &&
                    string.IsNullOrWhiteSpace(value))
                {
                    dr[kv.Key] = DBNull.Value;
                    continue;
                }

                dr[kv.Key] = value;
            }

            table.Rows.Add(dr);
        }

        return table;
    }

    private static void ApplyLabSpecificInsuranceBalanceRule(LabConfig lab, List<Dictionary<string, string>> rows)
    {
        if (!ShouldUseBilledAmountAsInsuranceBalance(lab) || rows == null || rows.Count == 0)
            return;

        foreach (var row in rows)
        {
            var billedAmount = GetValueByAnyKey(row, "Billed Amount", "BilledAmount");

            // Keep the target Excel-style key because builders/export mapping read "Insurance Balance".
            row["Insurance Balance"] = billedAmount;

            // Keep the SQL-style key in sync in case a later mapper/table builder reads this form.
            row["InsuranceBalance"] = billedAmount;
        }
    }

    private static void ApplyClaimUid(List<Dictionary<string, string>> rows)
    {
        foreach (var row in rows)
        {
            var visitNumber = GetValueByAnyKey(row, "Visit Number", "VisitNumber");
            var accessionNo = GetValueByAnyKey(row, "Accession No", "AccessionNo");
            var dateOfService = GetValueByAnyKey(row, "Date of Service", "DateOfService", "DOS");

            row["ClaimUID"] = BuildClaimUid(visitNumber, accessionNo, dateOfService);
        }
    }

    private static string BuildClaimUid(string? visitNumber, string? accessionNo, string? dateOfService)
    {
        var visit = NormalizeClaimUidPart(visitNumber);
        var accession = NormalizeClaimUidPart(accessionNo);
        var dos = NormalizeDateOfServiceForClaimUid(dateOfService);

        if (string.IsNullOrWhiteSpace(visit) &&
            string.IsNullOrWhiteSpace(accession) &&
            string.IsNullOrWhiteSpace(dos))
        {
            return string.Empty;
        }

        return $"{visit}_{accession}_{dos}";
    }

    private static string NormalizeClaimUidPart(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return string.Empty;

        var text = value.Trim();

        if (text.EndsWith(".00", StringComparison.OrdinalIgnoreCase))
            text = text[..^3];

        return text;
    }

    private static string NormalizeDateOfServiceForClaimUid(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return string.Empty;

        var text = value.Trim();

        return DateTime.TryParse(text, out var parsed)
            ? parsed.ToString("yyyyMMdd")
            : text;
    }

    private static bool ShouldUseBilledAmountAsInsuranceBalance(LabConfig lab)
    {
        if (lab == null)
            return false;

        if (lab.LabId is 18 or 19 or 20)
            return true;

        var labName = lab.LabName?.Trim() ?? string.Empty;

        return labName.Contains("Certus", StringComparison.OrdinalIgnoreCase)
            || labName.Contains("Augustus", StringComparison.OrdinalIgnoreCase)
            || labName.Contains("NorthWest", StringComparison.OrdinalIgnoreCase)
            || labName.Contains("Northwest", StringComparison.OrdinalIgnoreCase)
            || labName.Contains("North West", StringComparison.OrdinalIgnoreCase);
    }

    private static string GetValueByAnyKey(Dictionary<string, string> row, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (row.TryGetValue(key, out var value))
                return value ?? string.Empty;

            var actualKey = row.Keys.FirstOrDefault(k => string.Equals(k, key, StringComparison.OrdinalIgnoreCase));
            if (actualKey != null && row.TryGetValue(actualKey, out value))
                return value ?? string.Empty;
        }

        return string.Empty;
    }

    private Task NotifyFileSynchronizedAsync(string fileType, string remotePath, string localPath, CancellationToken ct)
    {
        var fileName = Path.GetFileName(localPath);
        var remoteUrl = SharePointWebLinkBuilder.TryBuildFileUrl(_spOpt, remotePath);

        var message = new StringBuilder()
            .AppendLine("🟢 File synchronized successfully.\n")
            .AppendLine($"📁 Type: {fileType} \n")
            .AppendLine(string.IsNullOrWhiteSpace(remoteUrl)
                ? $"📁 Source: {remotePath}\n"
                : $"📄 Source: [{fileName}]({remoteUrl})\n")
            .Append($"Destination: {localPath}")
            .ToString();

        return _teamsNotifier.SendAsync("🤖 LRN : Denial Database Processor", message, ct);
    }

    private Task NotifyFileUploadFailedAsync(string fileType, string localFile, string remotePath, Exception ex, CancellationToken ct)
    {
        var fileName = Path.GetFileName(localFile);
        var remoteUrl = SharePointWebLinkBuilder.TryBuildFileUrl(_spOpt, remotePath);

        var message = new StringBuilder()
            .AppendLine("⚠️ File upload failed.\n")
            .AppendLine($"Type: {fileType} \n")
            .AppendLine(string.IsNullOrWhiteSpace(remoteUrl)
                ? $"📁 SharePoint: {remotePath}\n"
                : $"📄 SharePoint: [{fileName}]({remoteUrl})\n")
            .AppendLine($"Source: {localFile} \n")
            .Append($"Error: {ex.Message}")
            .ToString();

        return _teamsNotifier.SendAsync("🤖 LRN : Denial Database Processor", message, ct);
    }
}
