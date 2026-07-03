using Common.Logging;
using LRN.ExcelValidator.Models;
using LRN.ExcelValidator.Services;
using LRN.Notifications.Abstractions;
using LRN.Notifications.Models;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using static SharePointDownloader;
using LRN.SharePointClient.Models;

public sealed class MasterFileProcessorWorker : BackgroundService
{
	private sealed class OutputUploadResult
	{
		public string Summary { get; set; } = "SKIPPED";
		public SharePointPublishedFile? ClaimFile { get; set; }
		public SharePointPublishedFile? LineFile { get; set; }
	}

	private readonly ILogger<MasterFileProcessorWorker> _logger;   // console/eventlog
	private readonly ILoggerService _fileLog;                      // log4net file (only what we write)
	private readonly ImportOptions _opt;
	private readonly SharePointDownloader _sp;
	private readonly MasterFileProcessorFileStatusStore _status;
	private readonly IExcelSchemaValidator _schemaValidator;
	private readonly IColumnSchemaLoader _schemaLoader;
	private readonly IProcessLogService _processLog;
	private readonly ITeamsNotifier _teamsNotifier;
	private readonly ModeMedianReportPublisher _modeMedianPublisher;
	private readonly IConfiguration _configuration;

	private ColumnSchema? _commonLineSchema;
	private ColumnSchema? _commonClaimSchema;

	private Dictionary<string, StandardCsvExporter.InsuranceMasterEntry>? _insuranceMaster;

	public MasterFileProcessorWorker(
		ILogger<MasterFileProcessorWorker> logger,
		ILoggerService fileLog,
		IOptions<ImportOptions> options,
		SharePointDownloader sp,
		MasterFileProcessorFileStatusStore status,
		IExcelSchemaValidator schemaValidator,
		IColumnSchemaLoader schemaLoader,
		IProcessLogService processLog,
		ITeamsNotifier teamsNotifier,
		ModeMedianReportPublisher modeMedianPublisher,
		IConfiguration configuration)
	{
		_logger = logger;
		_fileLog = fileLog;
		_opt = options.Value;
		_sp = sp;
		_status = status;
		_schemaValidator = schemaValidator;
		_schemaLoader = schemaLoader;
		_processLog = processLog;
		_teamsNotifier = teamsNotifier;
		_modeMedianPublisher = modeMedianPublisher;
		_configuration = configuration;

	}

	protected override async Task ExecuteAsync(CancellationToken stoppingToken)
	{
		EnsureFolders();

		_logger.LogInformation("Worker started. SharePoint.Enabled={Enabled}", _opt.SharePoint.Enabled);
		_fileLog.Info($"Worker started. SharePoint.Enabled={_opt.SharePoint.Enabled}");

		////await TrySendTeamNotificationAsync("Test : Master File Processor", string.Join(Environment.NewLine, "Message : This is test"), stoppingToken);

		while (!stoppingToken.IsCancellationRequested)
		{
			try
			{
				if (_opt.SharePoint.Enabled)
				{
					await ProcessSharePointOnceAsync(stoppingToken);
				}
				else
				{
					_logger.LogWarning("SharePoint is disabled. Nothing to do.");
					_fileLog.Warn("SharePoint is disabled. Nothing to do.");
				}
			}
			catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
			{
				// graceful shutdown
			}
			catch (Exception ex)
			{
				_logger.LogError(ex, "Top-level worker loop error.");
				_fileLog.Error("Top-level worker loop error.", ex);
			}

			try
			{
				await Task.Delay(TimeSpan.FromSeconds(Math.Max(10, _opt.PollSeconds)), stoppingToken);
			}
			catch (OperationCanceledException) { }
		}
	}

	private void EnsureFolders()
	{
		if (string.IsNullOrWhiteSpace(_opt.WatchFolder))
			_opt.WatchFolder = Path.Combine(AppContext.BaseDirectory, "LRN-Input");

		if (string.IsNullOrWhiteSpace(_opt.ErrorFolder))
			_opt.ErrorFolder = Path.Combine(AppContext.BaseDirectory, "error");

		if (string.IsNullOrWhiteSpace(_opt.ReportOutputsRoot))
			_opt.ReportOutputsRoot = Path.Combine(AppContext.BaseDirectory, "LabReportOutputs");

		Directory.CreateDirectory(_opt.WatchFolder);
		//Directory.CreateDirectory(_opt.ErrorFolder);
		Directory.CreateDirectory(_opt.ReportOutputsRoot);
		Directory.CreateDirectory(Path.Combine(AppContext.BaseDirectory, "logs"));
	}

	private async Task ProcessSharePointOnceAsync(CancellationToken ct)
	{
		var runLocalNow = DateTime.Now;

		// Daily master processor log (local)
		var masterLogFolder = Path.Combine(_opt.ReportOutputsRoot, "Logs", "Master File Processor");

		// Load COMMON schemas once (used for standardized CSV output)
		_commonLineSchema ??= _schemaLoader.LoadFromFile(ResolvePath(_opt.CommonLineLevelSchemaJsonPath));
		_commonClaimSchema ??= _schemaLoader.LoadFromFile(ResolvePath(_opt.CommonClaimLevelSchemaJsonPath));

		// Load Insurance Master once (required for Global_Payer_ID and normalized PayerName)
		if (_insuranceMaster == null)
		{
			var configuredPath = ResolvePath(_opt.InsuranceMasterCsvPath); // keep same option name for now
			var insPath = InsuranceMasterExcelReader.ResolveLatestInsuranceMasterPath(configuredPath);

			if (!string.IsNullOrWhiteSpace(insPath))
			{
				_insuranceMaster = InsuranceMasterExcelReader.LoadInsuranceMasterFromExcel(insPath);

				_logger.LogInformation(
					"Loaded Insurance Master: {Count} payer rows from latest Excel file {Path}",
					_insuranceMaster.Count,
					insPath);

				_fileLog.Info($"Loaded Insurance Master: {_insuranceMaster.Count} payer rows from latest Excel file {insPath}");
			}
			else
			{
				_logger.LogWarning("Insurance master Excel file not found. Global_Payer_ID and PayerName normalization will be blank.");
				_fileLog.Warn("Insurance master Excel file not found. Global_Payer_ID and PayerName normalization will be blank.");

				_insuranceMaster = new Dictionary<string, StandardCsvExporter.InsuranceMasterEntry>(StringComparer.OrdinalIgnoreCase);
			}
		}

		// Resolve driveId once (needed for status log upload even when selected is null)
		string? siteDriveId = null;
		try
		{
			siteDriveId = await _sp.TryGetDriveIdAsync(ct);
		}
		catch (Exception ex)
		{
			_fileLog.Error("Failed to resolve SharePoint driveId.", ex);
		}

		foreach (var lab in _opt.Labs)
		{
			ct.ThrowIfCancellationRequested();

			// One unique RunID per lab-run
			var runCtx = await _processLog.StartRunAsync(
				labName: lab.LabName,
				pipelineName: "LRN.MasterFileProcessor",
				triggerType: "Schedule",
				triggeredBy: Environment.UserName,
				ct: ct);

			var runRow = new RunLogRow
			{
				RunID = runCtx.RunId,
				LabName = lab.LabName,
				PipelineName = "LRN.MasterFileProcessor",
				TriggerType = "Schedule",
				TriggeredBy = Environment.UserName,
				StartTimeIST = runCtx.StartTimeIST,
				OverallStatus = "IN_PROGRESS",
				LatestMasterFileFound = "NO",
				MandatoryColumnCheck = "SKIPPED",
				SplitOutputWrittenToSharePoint = "SKIPPED",
				PayerPolicyValidationStatus = "PENDING",
				CodingValidationStatus = "PENDING",
				AveragesProcessStatus = "PENDING",
				OutputsCopiedToSharePoint = "PENDING",
				MasterSyncPerformed = "PENDING",
				TotalErrors = 0,
				TotalWarnings = 0
			};

			SharePointDownloader.SelectedFile? selected = null;
			int stepSeq = 0;
			StepLogRow? activeStep = null;
			ModeMedianReportPublisher.ModeMedianPublishResult? modeMedianPublishResult = null;

			try
			{
				// STEP 10: Find latest eligible SharePoint file
				stepSeq = 10;
				var step10 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Find Latest Master File",
					StepCategory = "Ingestion",
					SourceSystem = "SharePoint",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS"
				};
				activeStep = step10;
				await _processLog.StepStartAsync(runCtx, step10, ct);

				var lookup = await _sp.TryGetLatestFileForLabAsync(lab, runLocalNow.Year, ct);
				selected = lookup.File;

				step10.EndTimeIST = _processLog.NowIST();
				step10.Status = selected == null ? "SKIPPED" : "SUCCESS";
				step10.PathOut = selected?.SharePointPath;
				step10.FileNameOut = selected?.Name;
				step10.ErrorMessage = selected == null ? lookup.Message : null;
				await _processLog.StepEndAsync(runCtx, step10, ct);
				activeStep = null;

				if (selected == null)
				{
					_logger.LogInformation("Lab {LabId}: {Message}", lab.LabId, lookup.Message);
					_fileLog.Info($"Lab {lab.LabId}: {lookup.Message}");

					runRow.OverallStatus = "SKIPPED";
					runRow.LatestMasterFileFound = "NO";
					runRow.Notes = lookup.Message;
					await _processLog.CompleteRunAsync(runCtx, runRow, ct);

					MasterProcessorLogCsv.Append(
						folder: masterLogFolder,
						localNow: runLocalNow,
						labId: lab.LabId,
						labName: lab.LabName,
						sourceFileName: "",
						sourceFileLocation: "",
						status: "Skipped",
						message: lookup.Message ?? "no eligible SharePoint file found",
						claimOutput: "",
						lineOutput: "");

					await TryWriteAndUploadFileStatusLogAsync(
						lab,
						selected,
						siteDriveId,
						status: "Skipped",
						outputLocation: "",
						logMessage: lookup.Message ?? "no eligible SharePoint file found",
						ct: ct);

					if (lookup.Status == SharePointDownloader.LatestFileLookupStatus.NoFileInCurrentWeekFolder)
					{
						await NotifyNoRecentFileFoundInLatestWeekFolderAsync(
							lab,
							lookup.MonthFolderName,
							lookup.WeekFolderName,
							ct);
					}
					else
					{
						await NotifyNoLatestFileFoundAsync(lab, ct);
					}

					continue;
				}

				runRow.LatestMasterFileFound = "YES";
				runRow.InputMasterSharePointPath = selected.SharePointPath;
				runRow.InputMasterFileName = selected.Name;
				runRow.InputMasterFileModifiedTime = selected.LastModifiedUtc?.ToLocalTime().DateTime;

				// STEP 15: Check already processed
				stepSeq = 15;
				var step15 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Check Already Processed",
					StepCategory = "Validation",
					SourceSystem = "SQL",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS",
					FileNameIn = selected.Name,
					PathIn = selected.SharePointPath
				};
				activeStep = step15;
				await _processLog.StepStartAsync(runCtx, step15, ct);

				var alreadyProcessed = await _status.IsProcessedAsync(
					selected.LabId,
					selected.DriveId,
					selected.ItemId,
					selected.ETagKey,
					ct);

				step15.EndTimeIST = _processLog.NowIST();
				step15.Status = alreadyProcessed ? "SKIPPED" : "SUCCESS";
				step15.ErrorMessage = alreadyProcessed ? "already processed (etag unchanged)" : null;
				await _processLog.StepEndAsync(runCtx, step15, ct);
				activeStep = null;

				if (alreadyProcessed)
				{
					_logger.LogInformation("Lab {LabId}: already processed, skipping: {File}", lab.LabId, selected.Name);
					_fileLog.Info($"Lab {lab.LabId}: already processed, skipping: {selected.Name}");

					runRow.OverallStatus = "SKIPPED";
					runRow.LatestMasterFileFound = "YES";
					runRow.Notes = "already processed (etag unchanged)";
					await _processLog.CompleteRunAsync(runCtx, runRow, ct);

					MasterProcessorLogCsv.Append(
						folder: masterLogFolder,
						localNow: runLocalNow,
						labId: lab.LabId,
						labName: lab.LabName,
						sourceFileName: selected.Name,
						sourceFileLocation: selected.SharePointPath,
						status: "Skipped",
						message: "already processed (etag unchanged)",
						claimOutput: "",
						lineOutput: "");

					await TryWriteAndUploadFileStatusLogAsync(
						lab,
						selected,
						siteDriveId,
						status: "Skipped",
						outputLocation: "",
						logMessage: "already processed (etag unchanged)",
						ct: ct);

					// IMPORTANT FIX:
					// Do not skip LIMS import just because the billing/master file eTag was already processed.
					// LIMS is a separate sibling file and may need to be reloaded while testing or when only LIMS changed.
					if (ParseBool(GetLabConfigValue(lab, "LimsSqlImportEnabled"), false))
					{
						var (limsMonthFolder, limsWeekFolder) = ParseMonthAndDateFolder(selected.SharePointPath);
						var limsYearFolder = TryParseYearFromSharePointPath(selected.SharePointPath)
							?? DateTime.Now.ToString("yyyy", CultureInfo.InvariantCulture);
						var limsRawMasterFolder = Path.Combine(_opt.WatchFolder, GetLabOutputPrefix(lab), limsYearFolder, limsMonthFolder, limsWeekFolder);
						Directory.CreateDirectory(limsRawMasterFolder);

						_logger.LogInformation("Lab {LabId}: master file already processed, but LIMS SQL import is enabled. Checking sibling LIMS file.", lab.LabId);
						_fileLog.Info($"Lab {lab.LabId}: master file already processed, but LIMS SQL import is enabled. Checking sibling LIMS file.");

						await TryDownloadSiblingRawMasterAsync(lab, selected, limsRawMasterFolder, runCtx.RunId, ct);
					}

					var (clientPaidMonthFolder, clientPaidWeekFolder) = ParseMonthAndDateFolder(selected.SharePointPath);
					var clientPaidYearFolder = TryParseYearFromSharePointPath(selected.SharePointPath)
						?? DateTime.Now.ToString("yyyy", CultureInfo.InvariantCulture);
					var clientPaidOutFolder = Path.Combine(_opt.WatchFolder, GetLabOutputPrefix(lab), clientPaidYearFolder, clientPaidMonthFolder, clientPaidWeekFolder);
					await TrySyncClientPaidFileAsync(lab, selected, clientPaidOutFolder, runCtx.RunId, ct);

					continue;
				}

				await _status.UpsertStatusAsync(
					selected.LabId, selected.DriveId, selected.ItemId, selected.ETagKey,
					selected.Name, selected.SharePointPath, selected.LastModifiedUtc,
					status: "IN_PROGRESS",
					statusMessage: "Downloading from SharePoint",
					processedAtUtc: null,
					ct: ct);

				// STEP 20: Download XLSX
				stepSeq = 20;
				var step20 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Download Master File",
					StepCategory = "Ingestion",
					SourceSystem = "SharePoint",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS",
					FileNameIn = selected.Name,
					PathIn = selected.SharePointPath
				};
				activeStep = step20;
				await _processLog.StepStartAsync(runCtx, step20, ct);

				// --------------------------------------------------------------------
				// NEW PATH LOGIC (matches SharePoint input structure)
				// SharePoint input example:
				// Data Analysis/Beech Tree/2026/02.February/02.06.2026 - 02.12.2026/Beech Tree_Production Report.xlsx
				// We extract:
				//   monthFolder = "02.February"
				//   weekFolder  = "02.06.2026 - 02.12.2026"
				// --------------------------------------------------------------------
				var (monthFolder, weekFolder) = ParseMonthAndDateFolder(selected.SharePointPath);

				// Lab prefix (Beech_Tree style) used for local folder + file names
				var labPrefix = GetLabOutputPrefix(lab); // e.g. Beech_Tree

				var yearFolder = TryParseYearFromSharePointPath(selected.SharePointPath)
					?? DateTime.Now.ToString("yyyy", CultureInfo.InvariantCulture);

				// PROCESSED OUTPUTS (Claim/Line) go under WatchFolder (LRN-Input):
				// D:\LRN\Automation\LRN-Input\Beech_Tree\2026\02.February\02.06.2026 - 02.12.2026\Beech_Tree_LineLevel.csv
				var processedOutFolder = Path.Combine(_opt.WatchFolder, labPrefix, yearFolder, monthFolder, weekFolder);
				Directory.CreateDirectory(processedOutFolder);

				var rawMasterFolder = processedOutFolder;

				var sourceDateLabel = NormalizeWeekFolderForFileName(weekFolder);

				// Move previous output files for same lab + same week into Obsolete
				ArchiveExistingWeekOutputFiles(processedOutFolder, lab.LabName, sourceDateLabel);

				var claimOutFileName = BuildProcessedOutputFileName(runCtx.RunId, lab.LabName, "Claim Level", sourceDateLabel);
				var lineOutFileName = BuildProcessedOutputFileName(runCtx.RunId, lab.LabName, "Line Level", sourceDateLabel);
				var modeMedianOutFileName = BuildModeMedianOutputFileName(runCtx.RunId, lab.LabName, sourceDateLabel);

				var claimOutPath = Path.Combine(processedOutFolder, claimOutFileName);
				var lineOutPath = Path.Combine(processedOutFolder, lineOutFileName);
				var modeMedianOutPath = Path.Combine(processedOutFolder, modeMedianOutFileName);

				// RAW ROOT (no lab folder):
				// D:\LRN\Automation\LRN-RAWFILE\02.February\02.06.2026 - 02.12.2026\
				var rawRoot = Path.Combine(_opt.ReportOutputsRoot, "LRN-RAWFILE", monthFolder, weekFolder);
				Directory.CreateDirectory(rawRoot);

				// Download XLSX into RAW ROOT
				var stagingFileName = $"{labPrefix}_{SanitizeFileName(selected.Name)}";
				var stagingPath = Path.Combine(rawRoot, stagingFileName);
				var productionRawMasterPath = Path.Combine(rawMasterFolder, SanitizeFileName(selected.Name));

				_logger.LogInformation("Lab {LabId}: downloading {SpPath} -> {Local}", lab.LabId, selected.SharePointPath, stagingPath);
				_fileLog.Info($"Lab {lab.LabId}: downloading {selected.SharePointPath} -> {stagingPath}");

				await DownloadSharePointFileWithRetryAsync(selected.DriveId, selected.ItemId, stagingPath, ct);

				File.Copy(stagingPath, productionRawMasterPath, overwrite: true);

				_logger.LogInformation(
					"Lab {LabId}: Production raw master copied to WatchFolder week folder -> {Path}",
					lab.LabId,
					productionRawMasterPath);

				_fileLog.Info($"Lab {lab.LabId}: Production raw master copied to WatchFolder week folder -> {productionRawMasterPath}");

				if (!await TryDownloadSiblingRawMasterAsync(lab, selected, rawMasterFolder, runCtx.RunId, ct))
					throw new InvalidOperationException("Required LIMS master file was not available in the same SharePoint week folder as the production master file.");

				await TrySyncClientPaidFileAsync(lab, selected, processedOutFolder, runCtx.RunId, ct);

				// Update file size after download
				try
				{
					var fi = new FileInfo(stagingPath);
					runRow.InputMasterFileSizeMB = Math.Round((decimal)fi.Length / (1024m * 1024m), 2);
				}
				catch { }

				step20.EndTimeIST = _processLog.NowIST();
				step20.Status = "SUCCESS";
				step20.FileNameOut = Path.GetFileName(stagingPath);
				step20.PathOut = stagingPath;
				await _processLog.StepEndAsync(runCtx, step20, ct);
				activeStep = null;

				// STEP 30: Validate XLSX
				stepSeq = 30;
				var step30 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Validate Downloaded XLSX",
					StepCategory = "Validation",
					SourceSystem = "Local",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS",
					FileNameIn = Path.GetFileName(stagingPath),
					PathIn = stagingPath
				};
				activeStep = step30;
				await _processLog.StepStartAsync(runCtx, step30, ct);
				XlsxFileValidator.ValidateDownloadedXlsxOrThrow(stagingPath);
				step30.EndTimeIST = _processLog.NowIST();
				step30.Status = "SUCCESS";
				await _processLog.StepEndAsync(runCtx, step30, ct);
				activeStep = null;

				// -------- Column validation --------
				var lineSchemaPath = ResolvePath(!string.IsNullOrWhiteSpace(lab.LineLevelSchemaJsonPath)
					? lab.LineLevelSchemaJsonPath!
					: _opt.LineLevelSchemaJsonPath);

				var claimSchemaPath = ResolvePath(!string.IsNullOrWhiteSpace(lab.ClaimLevelSchemaJsonPath)
					? lab.ClaimLevelSchemaJsonPath!
					: _opt.ClaimLevelSchemaJsonPath);

				// STEP 40: Schema validation
				stepSeq = 40;
				var step40 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Validate Mandatory Columns",
					StepCategory = "Validation",
					SourceSystem = "Local",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS",
					FileNameIn = Path.GetFileName(stagingPath),
					PathIn = stagingPath
				};
				activeStep = step40;
				await _processLog.StepStartAsync(runCtx, step40, ct);

				var effectiveLineCandidates = GetEffectiveLineSheetCandidates(lab);
				var lineValidation = _schemaValidator.Validate(stagingPath, effectiveLineCandidates, lineSchemaPath);
				var claimValidation = _schemaValidator.Validate(stagingPath, _opt.ClaimSheetName, claimSchemaPath);

				if (!lineValidation.IsValid || !claimValidation.IsValid)
				{
					var msg = BuildSchemaErrorMessage(lineValidation, claimValidation, effectiveLineCandidates, _opt.ClaimSheetName);

					_logger.LogError("Lab {LabId}: schema validation failed for file {File}. {Msg}", lab.LabId, selected.Name, msg);
					_fileLog.Error($"Lab {lab.LabId}: schema validation failed for {selected.Name}. {msg}");

					await _status.UpsertStatusAsync(
						selected.LabId, selected.DriveId, selected.ItemId, selected.ETagKey,
						selected.Name, selected.SharePointPath, selected.LastModifiedUtc,
						status: "ERROR",
						statusMessage: msg,
						processedAtUtc: null,
						ct: ct,
						errorLogInfo: msg);

					//await TryWriteAndUploadFileStatusLogAsync(lab, selected, siteDriveId, status: "Failed", outputLocation: _opt.ErrorFolder, logMessage: msg, ct: ct);

					step40.EndTimeIST = _processLog.NowIST();
					step40.Status = "FAILED";
					step40.ErrorCode = "SCHEMA_VALIDATION_FAILED";
					step40.ErrorMessage = msg;
					await _processLog.StepEndAsync(runCtx, step40, ct);
					activeStep = null;

					// Error_Log entry
					await _processLog.LogErrorAsync(runCtx, new ErrorLogRow
					{
						Severity = "ERROR",
						StepName = step40.StepName,
						ErrorCode = "SCHEMA_VALIDATION_FAILED",
						ErrorSummary = msg,
						MissingColumns = string.Join(" | ",
							new[]
							{
								lineValidation.MissingRequiredColumns.Count > 0 ? $"LineLevel: {string.Join(", ", lineValidation.MissingRequiredColumns)}" : "",
								claimValidation.MissingRequiredColumns.Count > 0 ? $"ClaimLevel: {string.Join(", ", claimValidation.MissingRequiredColumns)}" : ""
							}.Where(x => !string.IsNullOrWhiteSpace(x))),
						SheetName = string.Join(" | ",
							new[]
							{
								lineValidation.SheetUsed != null ? $"LineLevel={lineValidation.SheetUsed}" : "",
								claimValidation.SheetUsed != null ? $"ClaimLevel={claimValidation.SheetUsed}" : ""
							}.Where(x => !string.IsNullOrWhiteSpace(x))),
						FileName = selected.Name,
						FilePath = selected.SharePointPath,
						RecommendedAction = "Fix missing columns in the master file or update lab schema aliases.",
						OwnerTeam = "LRN",
						Status = "OPEN"
					}, ct);
					runRow.TotalErrors += 1;
					runRow.OverallStatus = "FAILED";
					runRow.MandatoryColumnCheck = "FAIL";
					runRow.Notes = msg;
					await _processLog.CompleteRunAsync(runCtx, runRow, ct);

					//MoveToErrorFolder(stagingPath, msg);
					await NotifyProcessingErrorAsync(lab, msg, selected.Name, selected.SharePointPath, ct);
					continue;
				}

				step40.EndTimeIST = _processLog.NowIST();
				step40.Status = "SUCCESS";
				await _processLog.StepEndAsync(runCtx, step40, ct);
				activeStep = null;
				runRow.MandatoryColumnCheck = "PASS";

				// Load LAB schemas for preferred header mapping / composite expressions during standardization
				var labLineSchema = _schemaLoader.LoadFromFile(lineSchemaPath);
				var labClaimSchema = _schemaLoader.LoadFromFile(claimSchemaPath);

				// RAW intermediate exports (Excel -> CSV) stored under RAW ROOT (no lab folder)
				var baseName = SanitizeFileName(Path.GetFileNameWithoutExtension(selected.Name));
				var lineRawPath = Path.Combine(rawRoot, $"{labPrefix}_{baseName}_LineLevel_RAW.csv");
				var claimRawPath = Path.Combine(rawRoot, $"{labPrefix}_{baseName}_ClaimLevel_RAW.csv");

				await _status.UpsertStatusAsync(
					selected.LabId, selected.DriveId, selected.ItemId, selected.ETagKey,
					selected.Name, selected.SharePointPath, selected.LastModifiedUtc,
					status: "IN_PROGRESS",
					statusMessage: $"Exporting ClaimLevel + LineLevel to CSV. Output={processedOutFolder}",
					processedAtUtc: null,
					ct: ct);

				var sw = Stopwatch.StartNew();

				// STEP 50: LineLevel RAW export
				stepSeq = 50;
				var step50 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Export LineLevel RAW CSV",
					StepCategory = "Transform",
					SourceSystem = "Local",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS",
					FileNameIn = Path.GetFileName(stagingPath),
					PathIn = stagingPath,
					FileNameOut = Path.GetFileName(lineRawPath),
					PathOut = lineRawPath
				};
				activeStep = step50;
				await _processLog.StepStartAsync(runCtx, step50, ct);
				var lineSheetNames = effectiveLineCandidates
					.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

				if (lineSheetNames.Length > 1)
				{
					var sheetSourcePairs = lineSheetNames
						.Select(s => (SheetName: s, SourceValue: ExtractSourceLabel(s)))
						.ToArray();
					await ExcelCsvExporter.ExportMultiSheetCombinedToCsvAsync(stagingPath, sheetSourcePairs, "Source", lineRawPath, ct);
				}
				else
				{
					await ExcelCsvExporter.ExportSingleSheetToCsvAsync(stagingPath, effectiveLineCandidates, lineRawPath, ct);
				}

				step50.EndTimeIST = _processLog.NowIST();
				step50.Status = "SUCCESS";
				await _processLog.StepEndAsync(runCtx, step50, ct);
				activeStep = null;
				_logger.LogInformation("Lab {LabId}: LineLevel RAW CSV export done -> {Path}", lab.LabId, lineRawPath);
				_fileLog.Info($"Lab {lab.LabId}: LineLevel RAW CSV export -> {lineRawPath}");

				// STEP 60: LineLevel STANDARD CSV
				stepSeq = 60;
				var step60 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Generate LineLevel STANDARD CSV",
					StepCategory = "Transform",
					SourceSystem = "Local",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS",
					FileNameIn = Path.GetFileName(lineRawPath),
					PathIn = lineRawPath,
					FileNameOut = Path.GetFileName(lineOutPath),
					PathOut = lineOutPath
				};
				activeStep = step60;
				await _processLog.StepStartAsync(runCtx, step60, ct);

				var lineAugmentation = StandardCsvExporter.BuildAugmentationContext(
						lab.LabName,
						true,
						ResolvePanelMasterFilePath(lab));

				StandardCsvExporter.Generate(
					sourceCsvPath: lineRawPath,
					headerRow: _commonLineSchema!.HeaderRow,
					outputCsvPath: lineOutPath,
					commonSchema: _commonLineSchema!,
					labId: lab.LabId,
					labName: lab.LabName,
					sourceFileName: selected.Name,
					ingestedOnLocal: DateTime.Now,
					labSchema: labLineSchema,
					insuranceMaster: _insuranceMaster,
					augmentation: lineAugmentation);



				step60.EndTimeIST = _processLog.NowIST();
				step60.Status = "SUCCESS";
				await _processLog.StepEndAsync(runCtx, step60, ct);
				activeStep = null;

				_logger.LogInformation("Lab {LabId}: LineLevel STANDARD CSV generated -> {Path}", lab.LabId, lineOutPath);
				_fileLog.Info($"Lab {lab.LabId}: LineLevel STANDARD CSV -> {lineOutPath}");

				try
				{
					modeMedianPublishResult = await _modeMedianPublisher.PublishAsync(
						runCtx.RunId,
						lab.LabName,
						sourceDateLabel,
						lineOutPath,
						ct);

					_logger.LogInformation(
						"Median/Mode publish result for lab {LabId}: {Summary}",
						lab.LabId,
						modeMedianPublishResult.Summary);

					_fileLog.Info(
						$"Median/Mode publish result for lab {lab.LabId}: {modeMedianPublishResult.Summary}");
				}
				catch (Exception ex)
				{
					_logger.LogWarning(
						ex,
						"Median/Mode publish failed for lab {LabId}",
						lab.LabId);

					_fileLog.Error(
						$"Median/Mode publish failed for lab {lab.LabId}",
						ex);
				}

				// STEP 70: ClaimLevel RAW export
				stepSeq = 70;
				var step70 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Export ClaimLevel RAW CSV",
					StepCategory = "Transform",
					SourceSystem = "Local",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS",
					FileNameIn = Path.GetFileName(stagingPath),
					PathIn = stagingPath,
					FileNameOut = Path.GetFileName(claimRawPath),
					PathOut = claimRawPath
				};
				activeStep = step70;
				await _processLog.StepStartAsync(runCtx, step70, ct);
				await ExcelCsvExporter.ExportSingleSheetToCsvAsync(stagingPath, _opt.ClaimSheetName, claimRawPath, ct);
				step70.EndTimeIST = _processLog.NowIST();
				step70.Status = "SUCCESS";
				await _processLog.StepEndAsync(runCtx, step70, ct);
				activeStep = null;
				_logger.LogInformation("Lab {LabId}: ClaimLevel RAW CSV export done -> {Path}", lab.LabId, claimRawPath);
				_fileLog.Info($"Lab {lab.LabId}: ClaimLevel RAW CSV export -> {claimRawPath}");

				// STEP 80: ClaimLevel STANDARD CSV
				stepSeq = 80;
				var step80 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Generate ClaimLevel STANDARD CSV",
					StepCategory = "Transform",
					SourceSystem = "Local",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS",
					FileNameIn = Path.GetFileName(claimRawPath),
					PathIn = claimRawPath,
					FileNameOut = Path.GetFileName(claimOutPath),
					PathOut = claimOutPath
				};
				activeStep = step80;
				await _processLog.StepStartAsync(runCtx, step80, ct);

				var claimAugmentation = StandardCsvExporter.BuildAugmentationContext(
							lab.LabName,
							false,
							ResolvePanelMasterFilePath(lab));

				StandardCsvExporter.Generate(
							sourceCsvPath: claimRawPath,
							headerRow: _commonClaimSchema!.HeaderRow,
							outputCsvPath: claimOutPath,
							commonSchema: _commonClaimSchema!,
							labId: lab.LabId,
							labName: lab.LabName,
							sourceFileName: selected.Name,
							ingestedOnLocal: DateTime.Now,
							labSchema: labClaimSchema,
							insuranceMaster: _insuranceMaster,
							augmentation: claimAugmentation);

				StandardCsvExporter.EnrichClaimLevelWithLineLevelCptSummary(
					claimCsvPath: claimOutPath,
					lineCsvPath: lineOutPath,
					targetColumnName: ResolveClaimLevelCptSummaryColumnName(claimSchemaPath));

				if (ShouldCopyClaimStatusToLineLevel(lab))
				{
					StandardCsvExporter.CopyClaimStatusFromClaimLevelToLineLevel(
						claimCsvPath: claimOutPath,
						lineCsvPath: lineOutPath);
				}

				step80.EndTimeIST = _processLog.NowIST();
				step80.Status = "SUCCESS";
				await _processLog.StepEndAsync(runCtx, step80, ct);
				activeStep = null;
				runRow.SplitOutputWrittenToSharePoint = "YES";

				_logger.LogInformation("Lab {LabId}: ClaimLevel STANDARD CSV generated -> {Path}", lab.LabId, claimOutPath);
				_fileLog.Info($"Lab {lab.LabId}: ClaimLevel STANDARD CSV -> {claimOutPath}");

				sw.Stop();



				// Cleanup RAW CSVs unless configured to keep
				if (!_opt.KeepRawCsvExports)
				{
					TryDelete(lineRawPath);
					TryDelete(claimRawPath);
				}

				// STEP 90: FileStatus CSV log (local + optional upload)
				stepSeq = 90;
				var step90 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Write File Status Log",
					StepCategory = "Publish",
					SourceSystem = "SharePoint",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS"
				};
				activeStep = step90;
				await _processLog.StepStartAsync(runCtx, step90, ct);
				await TryWriteAndUploadFileStatusLogAsync(lab, selected, siteDriveId, status: "Completed", outputLocation: processedOutFolder, logMessage: "imported", ct: ct);
				step90.EndTimeIST = _processLog.NowIST();
				step90.Status = "SUCCESS";
				await _processLog.StepEndAsync(runCtx, step90, ct);
				activeStep = null;

				// STEP 100: Upload standardized outputs to SharePoint
				stepSeq = 100;
				var step100 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Upload Outputs to SharePoint",
					StepCategory = "Publish",
					SourceSystem = "SharePoint",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS",
					FileNameIn = $"{Path.GetFileName(claimOutPath)} | {Path.GetFileName(lineOutPath)} | {Path.GetFileName(modeMedianOutPath)}",
					PathIn = processedOutFolder
				};
				activeStep = step100;
				await _processLog.StepStartAsync(runCtx, step100, ct);
				var outputUploadResult = await TryUploadOutputsAsync(
												lab,
												selected,
												runLocalNow,
												claimOutPath,
												lineOutPath,
												modeMedianOutPath,
												ct);

				step100.EndTimeIST = _processLog.NowIST();
				step100.Status = outputUploadResult.Summary.StartsWith("UPLOADED", StringComparison.OrdinalIgnoreCase)
					? "SUCCESS"
					: "WARNING";
				step100.ErrorMessage = outputUploadResult.Summary;
				await _processLog.StepEndAsync(runCtx, step100, ct);
				activeStep = null;

				runRow.OutputsCopiedToSharePoint =
					outputUploadResult.Summary.StartsWith("UPLOADED", StringComparison.OrdinalIgnoreCase) ? "YES" :
					outputUploadResult.Summary.StartsWith("SKIPPED", StringComparison.OrdinalIgnoreCase) ? "SKIPPED" :
					"NO";

				if (step100.Status == "WARNING" &&
					!outputUploadResult.Summary.StartsWith("SKIPPED", StringComparison.OrdinalIgnoreCase))
				{
					await _processLog.LogErrorAsync(runCtx, new ErrorLogRow
					{
						Severity = "WARNING",
						StepName = step100.StepName,
						ErrorCode = "OUTPUT_UPLOAD_WARNING",
						ErrorSummary = outputUploadResult.Summary,
						FileName = selected.Name,
						FilePath = selected.SharePointPath,
						RecommendedAction = "Verify SharePoint output folder path/permissions and retry upload if needed.",
						OwnerTeam = "LRN",
						Status = "OPEN"
					}, ct);

					runRow.TotalWarnings += 1;
				}

				// STEP 110: Mark status PROCESSED (SQL)
				stepSeq = 110;
				var step110 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Mark File PROCESSED",
					StepCategory = "Sync",
					SourceSystem = "SQL",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS",
					FileNameIn = selected.Name,
					PathIn = selected.SharePointPath
				};
				activeStep = step110;
				await _processLog.StepStartAsync(runCtx, step110, ct);

				// Mark PROCESSED
				await _status.UpsertStatusAsync(
					selected.LabId, selected.DriveId, selected.ItemId, selected.ETagKey,
					selected.Name, selected.SharePointPath, selected.LastModifiedUtc,
					status: "PROCESSED",
statusMessage: $"Saved LineLevel='{lineOutPath}', ClaimLevel='{claimOutPath}', ModeMedian='{modeMedianOutPath}'. OutputUpload={outputUploadResult.Summary}.", processedAtUtc: DateTimeOffset.UtcNow,
					ct: ct);

				step110.EndTimeIST = _processLog.NowIST();
				step110.Status = "SUCCESS";
				await _processLog.StepEndAsync(runCtx, step110, ct);
				activeStep = null;

				// Daily master processor log row (client requirement)
				MasterProcessorLogCsv.Append(
					folder: masterLogFolder,
					localNow: runLocalNow,
					labId: lab.LabId,
					labName: lab.LabName,
					sourceFileName: selected.Name,
					sourceFileLocation: selected.SharePointPath,
					status: "Completed",
message: $"imported; ModeMedian='{modeMedianOutPath}'; {outputUploadResult.Summary}", claimOutput: claimOutPath,
					lineOutput: lineOutPath);

				_fileLog.Info($"Lab {lab.LabId}: PROCESSED {selected.Name}.");

				// STEP 120: Archive RAW XLSX
				stepSeq = 120;
				var step120 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Archive RAW XLSX",
					StepCategory = "Publish",
					SourceSystem = "Local",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS",
					FileNameIn = Path.GetFileName(stagingPath),
					PathIn = stagingPath
				};
				activeStep = step120;
				await _processLog.StepStartAsync(runCtx, step120, ct);

				// Archive RAW XLSX after success:
				// D:\LRN\Automation\LRN-RAWFILE\Archive\02.February\02.06.2026 - 02.12.2026\<file>.xlsx
				try
				{
					var archiveFolder = Path.Combine(_opt.ReportOutputsRoot, "LRN-RAWFILE", "Archive", monthFolder, weekFolder);
					Directory.CreateDirectory(archiveFolder);

					var dest = Path.Combine(archiveFolder, Path.GetFileName(stagingPath));

					if (File.Exists(stagingPath))
						File.Move(stagingPath, dest, overwrite: true);

					_fileLog.Info($"Archived raw XLSX: {dest}");
					step120.FileNameOut = Path.GetFileName(dest);
					step120.PathOut = dest;
					step120.Status = "SUCCESS";
				}
				catch (Exception ex)
				{
					_fileLog.Error("Failed to archive raw XLSX.", ex);
					step120.Status = "WARNING";
					step120.ErrorCode = "ARCHIVE_FAILED";
					step120.ErrorMessage = ex.Message;

					try
					{
						await _processLog.LogErrorAsync(runCtx, new ErrorLogRow
						{
							Severity = "WARNING",
							StepName = step120.StepName,
							ErrorCode = "ARCHIVE_FAILED",
							ErrorSummary = ex.Message,
							FileName = Path.GetFileName(stagingPath),
							FilePath = stagingPath,
							RecommendedAction = "Check disk permissions/locks for archive folder and retry.",
							OwnerTeam = "LRN",
							Status = "OPEN"
						}, ct);
						runRow.TotalWarnings += 1;
					}
					catch { }
				}
				finally
				{
					step120.EndTimeIST = _processLog.NowIST();
					await _processLog.StepEndAsync(runCtx, step120, ct);
					activeStep = null;
				}

				// STEP 130: Optional SharePoint move
				stepSeq = 130;
				var step130 = new StepLogRow
				{
					StepSeq = stepSeq,
					StepName = "Move Source File to Processed Folder",
					StepCategory = "Publish",
					SourceSystem = "SharePoint",
					StartTimeIST = _processLog.NowIST(),
					Status = "IN_PROGRESS",
					FileNameIn = selected.Name,
					PathIn = selected.SharePointPath
				};
				activeStep = step130;
				await _processLog.StepStartAsync(runCtx, step130, ct);

				var processedFolderId = await _sp.TryResolveProcessedFolderIdAsync(ct);
				if (!string.IsNullOrWhiteSpace(processedFolderId))
				{
					await _sp.MoveItemAsync(selected.DriveId, selected.ItemId, processedFolderId!, ct);
					_fileLog.Info($"Lab {lab.LabId}: moved SharePoint file to processed folder.");
					step130.Status = "SUCCESS";
				}
				else
				{
					step130.Status = "SKIPPED";
					step130.ErrorMessage = "Processed folder not configured or not resolved.";
				}
				step130.EndTimeIST = _processLog.NowIST();
				await _processLog.StepEndAsync(runCtx, step130, ct);
				activeStep = null;

				runRow.OverallStatus = "SUCCESS";
				runRow.Notes = $"Saved LineLevel='{lineOutPath}', ClaimLevel='{claimOutPath}', ModeMedian='{modeMedianOutPath}'. OutputUpload={outputUploadResult.Summary}."; await _processLog.CompleteRunAsync(runCtx, runRow, ct);
				await NotifyCompletedAsync(
							lab,
							claimOutPath,
							lineOutPath,
							outputUploadResult.ClaimFile,
							outputUploadResult.LineFile,
							modeMedianPublishResult,
							ct);
			}
			catch (OperationCanceledException) when (ct.IsCancellationRequested)
			{
				throw;
			}
			catch (Exception ex)
			{
				// If a step was started but not ended, mark it as FAILED
				try
				{
					if (activeStep != null && string.Equals(activeStep.Status, "IN_PROGRESS", StringComparison.OrdinalIgnoreCase))
					{
						activeStep.EndTimeIST = _processLog.NowIST();
						activeStep.Status = "FAILED";
						activeStep.ErrorCode ??= "STEP_FAILED";
						activeStep.ErrorMessage ??= ex.Message;
						activeStep.ErrorDetail ??= ex.ToString();
						await _processLog.StepEndAsync(runCtx, activeStep, ct);
					}
				}
				catch { }

				_logger.LogError(ex, "Lab {LabId}: error processing SharePoint file.", lab.LabId);
				_fileLog.Error($"Lab {lab.LabId}: error processing SharePoint file.", ex);

				if (selected != null)
				{
					await _status.UpsertStatusAsync(
						selected.LabId, selected.DriveId, selected.ItemId, selected.ETagKey,
						selected.Name, selected.SharePointPath, selected.LastModifiedUtc,
						status: "ERROR",
						statusMessage: ex.Message,
						processedAtUtc: null,
						ct: ct,
						errorLogInfo: ex.ToString());
				}

				// Error_Log entry for unexpected exceptions
				try
				{
					await _processLog.LogErrorAsync(runCtx, new ErrorLogRow
					{
						Severity = "ERROR",
						StepName = stepSeq > 0 ? $"Step {stepSeq}" : "Unhandled",
						ErrorCode = "UNHANDLED_EXCEPTION",
						ErrorSummary = ex.Message,
						FileName = selected?.Name,
						FilePath = selected?.SharePointPath,
						RecommendedAction = "Check ErrorDetail and fix the underlying failure, then rerun.",
						OwnerTeam = "LRN",
						Status = "OPEN"
					}, ct);
					runRow.TotalErrors += 1;
				}
				catch { }

				try
				{
					runRow.OverallStatus = "FAILED";
					runRow.Notes = ex.Message;
					await _processLog.CompleteRunAsync(runCtx, runRow, ct);
				}
				catch { }

				await TryWriteAndUploadFileStatusLogAsync(lab, selected, siteDriveId, status: "Failed", outputLocation: _opt.ErrorFolder, logMessage: ex.Message, ct: ct);

				MasterProcessorLogCsv.Append(
					folder: masterLogFolder,
					localNow: runLocalNow,
					labId: lab.LabId,
					labName: lab.LabName,
					sourceFileName: selected?.Name ?? "",
					sourceFileLocation: selected?.SharePointPath ?? "",
					status: "Failed",
					message: ex.Message,
					claimOutput: "",
					lineOutput: "");

				await NotifyProcessingErrorAsync(lab, ex.Message, selected?.Name, selected?.SharePointPath, ct);
			}
		}

		// Upload the daily master processor log once per run (client requirement)
		await TryUploadMasterProcessorLogAsync(runLocalNow, masterLogFolder, ct);
	}

	private async Task NotifyNoLatestFileFoundAsync(LabFileMap lab, CancellationToken ct)
	{
		var title = $"Master File Processor - No Latest File Found For Lab {lab.LabName}";
		var message = string.IsNullOrWhiteSpace(lab.SharePointRootPath)
			? "No latest eligible master file was found for processing."
			: $"No latest eligible master file was found under {lab.SharePointRootPath}.";

		await TrySendTeamNotificationAsync(title, message, ct);
	}

	private async Task NotifyProcessingErrorAsync(LabFileMap lab, string errorMessage, string? fileName, string? filePath, CancellationToken ct)
	{
		var title = "LRN : Master File Processor";

		var parts = new List<string>
		{
			$"⚠️ Error while processing files for the {lab.LabName} lab."
		};

		if (!string.IsNullOrWhiteSpace(fileName))
			parts.Add($"📄 File: {fileName}");

		if (!string.IsNullOrWhiteSpace(filePath))
			parts.Add($"📁 Source: {filePath}");

		parts.Add($"❌ Error: {errorMessage}");

		await TrySendTeamNotificationAsync(title, string.Join(Environment.NewLine + Environment.NewLine, parts), ct);
	}

	private async Task NotifyCompletedAsync(
	LabFileMap lab,
	string claimOutPath,
	string lineOutPath,
	SharePointPublishedFile? claimPublishedFile,
	SharePointPublishedFile? linePublishedFile,
	ModeMedianReportPublisher.ModeMedianPublishResult? modeMedianPublishResult,
	CancellationToken ct)
	{
		var title = "LRN : Master File Processor";

		var claimDownloadPath = ResolveNotificationUrl(claimPublishedFile, claimOutPath);
		var lineDownloadPath = ResolveNotificationUrl(linePublishedFile, lineOutPath);

		var medianDownloadPath = ResolvePublishedDownloadPath(
			modeMedianPublishResult?.MedianSharePointStatus,
			modeMedianPublishResult?.MedianLocalPath);

		var modeDownloadPath = ResolvePublishedDownloadPath(
			modeMedianPublishResult?.ModeSharePointStatus,
			modeMedianPublishResult?.ModeLocalPath);

		var lines = new List<string>
	{
		$"🟢 Files generated for the {lab.LabName} lab.",
		"Please download the files from the links below:",
		BuildDownloadLine("Claim Level", Path.GetFileName(claimOutPath), claimDownloadPath),
		BuildDownloadLine("Line Level", Path.GetFileName(lineOutPath), lineDownloadPath)
	};

		if (!string.IsNullOrWhiteSpace(modeMedianPublishResult?.MedianLocalPath))
			lines.Add(BuildDownloadLine("Median", Path.GetFileName(modeMedianPublishResult.MedianLocalPath), medianDownloadPath));

		if (!string.IsNullOrWhiteSpace(modeMedianPublishResult?.ModeLocalPath))
			lines.Add(BuildDownloadLine("Mode", Path.GetFileName(modeMedianPublishResult.ModeLocalPath), modeDownloadPath));

		await TrySendTeamNotificationAsync(title, string.Join(Environment.NewLine + Environment.NewLine, lines), ct);
	}

	private static string ResolveNotificationUrl(SharePointPublishedFile? publishedFile, string fallbackLocalPath)
	{
		if (!string.IsNullOrWhiteSpace(publishedFile?.NotificationUrl))
			return publishedFile.NotificationUrl!;

		return fallbackLocalPath;
	}

	private static string BuildDownloadLine(string label, string fileName, string downloadPath)
	{
		if (Uri.TryCreate(downloadPath, UriKind.Absolute, out _))
			return $"📄 {label}: [{fileName}]({downloadPath})";

		return $"📄 {label}: {fileName}{Environment.NewLine}Path: {downloadPath}";
	}

	private static string ResolvePublishedDownloadPath(string? sharePointStatus, string? fallbackLocalPath)
	{
		const string uploadedUrlPrefix = "UPLOADED_URL -> ";

		if (!string.IsNullOrWhiteSpace(sharePointStatus) &&
			sharePointStatus.StartsWith(uploadedUrlPrefix, StringComparison.OrdinalIgnoreCase))
		{
			return sharePointStatus.Substring(uploadedUrlPrefix.Length).Trim();
		}

		return fallbackLocalPath ?? string.Empty;
	}

	private static string CombineNotificationPath(string folderOrPath, string fileName)
	{
		if (string.IsNullOrWhiteSpace(folderOrPath))
			return fileName;

		var normalizedFolder = folderOrPath.Replace('\\', '/');
		if (normalizedFolder.EndsWith(fileName, StringComparison.OrdinalIgnoreCase))
			return normalizedFolder;

		if (normalizedFolder.Contains('/'))
			return normalizedFolder.TrimEnd('/') + "/" + fileName;

		return Path.Combine(folderOrPath, fileName);
	}

	private string ToSharePointNotificationUrl(string pathOrUrl)
	{
		if (string.IsNullOrWhiteSpace(pathOrUrl))
			return string.Empty;

		var normalized = pathOrUrl.Replace('\\', '/').Trim();

		if (Uri.TryCreate(normalized, UriKind.Absolute, out _))
			return normalized;

		if (Regex.IsMatch(normalized, @"^[a-zA-Z]:/"))
			return normalized;

		var sharePointSection = GetSharePointNotificationSection();
		var hostname = sharePointSection["Hostname"];
		var sitePath = sharePointSection["SitePath"];
		var driveName = sharePointSection["DriveName"] ?? "Shared Documents";

		if (string.IsNullOrWhiteSpace(hostname) || string.IsNullOrWhiteSpace(sitePath))
			return normalized;

		var relativePath = NormalizeDriveRelativePath(normalized, driveName);
		var host = hostname!.StartsWith("http", StringComparison.OrdinalIgnoreCase)
			? hostname.TrimEnd('/')
			: "https://" + hostname.Trim().TrimEnd('/');

		var encodedPath = JoinUrlSegments(sitePath!, driveName, relativePath);
		return host + "/" + encodedPath;
	}

	private IConfigurationSection GetSharePointNotificationSection()
	{
		var root = _configuration.GetSection("SharePoint");
		if (root.Exists())
			return root;

		return _configuration.GetSection("MasterFileProcessor:SharePoint");
	}

	private static string NormalizeDriveRelativePath(string path, string driveName)
	{
		if (string.IsNullOrWhiteSpace(path))
			return string.Empty;

		var normalized = path.Replace('\\', '/').Trim().Trim('/');
		var markers = new[]
		{
			driveName.Trim('/'),
			"Shared Documents"
		};

		foreach (var marker in markers.Where(x => !string.IsNullOrWhiteSpace(x)))
		{
			var prefix = marker + "/";
			if (normalized.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
				return normalized.Substring(prefix.Length).Trim('/');
		}

		return normalized;
	}

	private static string JoinUrlSegments(params string[] parts)
	{
		return string.Join(
			"/",
			parts
				.Where(p => !string.IsNullOrWhiteSpace(p))
				.SelectMany(p => p.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries))
				.Select(Uri.EscapeDataString));
	}

	private async Task TrySendTeamNotificationAsync(string title, string message, CancellationToken ct)
	{
		if (!IsTeamsNotificationEnabled())
		{
			_fileLog.Info($"Teams notification skipped by config. Title='{title}'");
			return;
		}

		try
		{
			await _teamsNotifier.SendAsync(new TeamsNotification
			{
				Title = title,
				Message = message
			}, ct);

			_fileLog.Info($"Teams notification sent. Title='{title}'");
		}
		catch (Exception ex)
		{
			_logger.LogWarning(ex, "Failed to send Teams notification. Title={Title}", title);
			_fileLog.Warn($"Failed to send Teams notification. Title='{title}'. Error='{ex.Message}'");
		}
	}

	private static string ResolveNotificationOutputLocation(string outputUploadResult, string processedOutFolder)
	{
		const string uploadedPrefix = "UPLOADED -> ";

		if (!string.IsNullOrWhiteSpace(outputUploadResult) &&
			outputUploadResult.StartsWith(uploadedPrefix, StringComparison.OrdinalIgnoreCase))
		{
			return outputUploadResult.Substring(uploadedPrefix.Length).Trim();
		}

		return processedOutFolder;
	}

	private static string BuildSchemaErrorMessage(
		LRN.ExcelValidator.Models.SchemaValidationResult lineValidation,
		LRN.ExcelValidator.Models.SchemaValidationResult claimValidation,
		string lineCandidates,
		string claimCandidates)
	{
		var parts = new List<string>();

		if (lineValidation.SheetUsed == null)
			parts.Add($"LineLevel sheet not found. Candidates: {lineCandidates}");
		else if (lineValidation.MissingRequiredColumns.Count > 0)
			parts.Add($"LineLevel missing columns: {string.Join(", ", lineValidation.MissingRequiredColumns)} (sheet='{lineValidation.SheetUsed}')");

		if (claimValidation.SheetUsed == null)
			parts.Add($"ClaimLevel sheet not found. Candidates: {claimCandidates}");
		else if (claimValidation.MissingRequiredColumns.Count > 0)
			parts.Add($"ClaimLevel missing columns: {string.Join(", ", claimValidation.MissingRequiredColumns)} (sheet='{claimValidation.SheetUsed}')");

		return string.Join(" | ", parts);
	}

	private void MoveToErrorFolder(string stagingPath, string msg)
	{
		try
		{
			Directory.CreateDirectory(_opt.ErrorFolder);

			var name = Path.GetFileNameWithoutExtension(stagingPath);
			var ext = Path.GetExtension(stagingPath);
			var ts = DateTime.Now.ToString("yyyyMMdd_HHmmss", CultureInfo.InvariantCulture);

			var destXlsx = Path.Combine(_opt.ErrorFolder, $"{name}_{ts}{ext}");
			if (File.Exists(destXlsx)) File.Delete(destXlsx);
			File.Move(stagingPath, destXlsx);

			var destTxt = Path.Combine(_opt.ErrorFolder, $"{name}_{ts}.error.txt");
			File.WriteAllText(destTxt, msg);

			_fileLog.Warn($"Moved file to error folder: {destXlsx}");
		}
		catch (Exception ex)
		{
			_fileLog.Error("Failed to move file to error folder.", ex);
		}
	}

	private async Task TryWriteAndUploadFileStatusLogAsync(
		LabFileMap lab,
		SharePointDownloader.SelectedFile? selected,
		string? siteDriveId,
		string status,
		string outputLocation,
		string logMessage,
		CancellationToken ct)
	{
		try
		{
			var localFolder = string.IsNullOrWhiteSpace(_opt.FileStatusLogLocalFolder)
				? Path.Combine(_opt.ReportOutputsRoot, "FileStatusLogs")
				: _opt.FileStatusLogLocalFolder;

			localFolder = ResolvePath(localFolder);

			var importedLocal = DateTime.Now;
			var fileName = selected?.Name ?? "";

			var localLogPath = FileStatusLogCsv.Write(
				folder: localFolder,
				labId: lab.LabId,
				labName: lab.LabName,
				importedLocal: importedLocal,
				fileName: fileName,
				status: status,
				outputLocation: outputLocation,
				logMessage: logMessage);

			_fileLog.Info($"Lab {lab.LabId}: file status log written: {localLogPath}");

			// FIX: Upload even if selected == null; use site driveId (resolved once)
			if (IsSharePointFileUploadEnabled() && _opt.SharePoint.Enabled && !string.IsNullOrWhiteSpace(_opt.SharePoint.FileStatusLogUploadFolderPath))
			{
				var driveId = siteDriveId;
				if (string.IsNullOrWhiteSpace(driveId))
				{
					driveId = await _sp.TryGetDriveIdAsync(ct);
				}

				if (string.IsNullOrWhiteSpace(driveId))
				{
					_fileLog.Warn("File status log upload skipped: unable to resolve SharePoint driveId.");
					return;
				}

				var spFolder = _opt.SharePoint.FileStatusLogUploadFolderPath.Trim().Trim('/');

				// If configured as ImportLogs root, expand to year/month folder path
				if (spFolder.EndsWith("ImportLogs", StringComparison.OrdinalIgnoreCase))
				{
					spFolder = FileStatusLogCsv.GetSharePointFolderPath(importedLocal);
				}

				await _sp.UploadFileToFolderPathAsync(
					driveId: driveId!,
					folderPath: spFolder,
					localFilePath: localLogPath,
					uploadFileName: Path.GetFileName(localLogPath),
					ct: ct);

				_fileLog.Info($"Lab {lab.LabId}: file status log uploaded to SharePoint folder '{spFolder}'.");
			}
		}
		catch (Exception ex)
		{
			_fileLog.Error("Failed to write/upload file status log.", ex);
		}
	}

	private async Task<OutputUploadResult> TryUploadOutputsAsync(
		LabFileMap lab,
		SharePointDownloader.SelectedFile selected,
		DateTime runLocalNow,
		string claimOutPath,
		string lineOutPath,
		string modeMedianOutPath,
		CancellationToken ct)
	{
		var result = new OutputUploadResult();

		try
		{
			var sp = _opt.SharePoint;
			if (!IsSharePointFileUploadEnabled() || !sp.Enabled || !sp.UploadOutputs)
			{
				result.Summary = "SKIPPED";
				return result;
			}

			if (string.IsNullOrWhiteSpace(sp.OutputUploadFolderPath))
			{
				result.Summary = "SKIPPED (OutputUploadFolderPath empty)";
				return result;
			}

			var year = TryParseYearFromSharePointPath(selected.SharePointPath)
				?? runLocalNow.ToString("yyyy", CultureInfo.InvariantCulture);

			var (monthFolder, weekFolder) = ParseMonthAndDateFolder(selected.SharePointPath);

			var destFolder = CombineSpPath(sp.OutputUploadFolderPath, lab.LabName, year, monthFolder, weekFolder);

			result.ClaimFile = await _sp.UploadFileToFolderPathWithLinkAsync(
				driveId: selected.DriveId,
				folderPath: destFolder,
				localFilePath: claimOutPath,
				uploadFileName: Path.GetFileName(claimOutPath),
				ct: ct);

			result.LineFile = await _sp.UploadFileToFolderPathWithLinkAsync(
				driveId: selected.DriveId,
				folderPath: destFolder,
				localFilePath: lineOutPath,
				uploadFileName: Path.GetFileName(lineOutPath),
				ct: ct);

			if (File.Exists(modeMedianOutPath))
			{
				await _sp.UploadFileToFolderPathAsync(
					driveId: selected.DriveId,
					folderPath: destFolder,
					localFilePath: modeMedianOutPath,
					uploadFileName: Path.GetFileName(modeMedianOutPath),
					ct: ct);
			}

			_fileLog.Info($"Lab {lab.LabId}: output files uploaded to SharePoint folder '{destFolder}'.");
			result.Summary = $"UPLOADED -> {destFolder}";
			return result;
		}
		catch (Exception ex)
		{
			_fileLog.Error($"Lab {lab.LabId}: failed to upload output files to SharePoint.", ex);
			result.Summary = "UPLOAD_FAILED";
			return result;
		}
	}

	private async Task TryUploadMasterProcessorLogAsync(DateTime runLocalNow, string masterLogFolder, CancellationToken ct)
	{
		try
		{
			var sp = _opt.SharePoint;
			if (!IsSharePointFileUploadEnabled() || !sp.Enabled || !sp.UploadMasterProcessorLog)
				return;

			if (string.IsNullOrWhiteSpace(sp.MasterProcessorLogUploadFolderPath))
				return;

			var logFileName = MasterProcessorLogCsv.GetDailyFileName(runLocalNow);
			var localPath = Path.Combine(masterLogFolder, logFileName);

			if (!File.Exists(localPath))
				return;

			var driveId = await _sp.TryGetDriveIdAsync(ct);
			if (string.IsNullOrWhiteSpace(driveId))
				return;

			await _sp.UploadFileToFolderPathAsync(
				driveId: driveId!,
				folderPath: sp.MasterProcessorLogUploadFolderPath,
				localFilePath: localPath,
				uploadFileName: logFileName,
				ct: ct);

			_fileLog.Info($"Master processor log uploaded to SharePoint folder '{sp.MasterProcessorLogUploadFolderPath}' as '{logFileName}'.");
		}
		catch (Exception ex)
		{
			_fileLog.Error("Failed to upload master processor log to SharePoint.", ex);
		}
	}
	private async Task NotifyNoRecentFileFoundInLatestWeekFolderAsync(
	LabFileMap lab,
	string? monthFolder,
	string? weekFolder,
	CancellationToken ct)
	{
		var title = "LRN : Master File Processor";

		var lines = new List<string>
	{
		$"⚠️ No recent file found for the {lab.LabName} lab.",
		$"📁 Latest month folder: {monthFolder ?? "Unknown"}",
		$"📂 Latest week folder: {weekFolder ?? "Unknown"}",
		"No earlier week folders were checked."
	};

		await TrySendTeamNotificationAsync(title, string.Join(Environment.NewLine + Environment.NewLine, lines), ct);
	}
	private static string CombineSpPath(params string[] parts)
	{
		var clean = parts
			.Where(p => !string.IsNullOrWhiteSpace(p))
			.Select(p => p.Trim().Trim('/').Trim('\\'))
			.Where(p => p.Length > 0);
		return string.Join("/", clean);
	}

	private static (string MonthFolder, string DateFolder) ParseMonthAndDateFolder(string sharePointPath)
	{
		var parts = sharePointPath.Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
		if (parts.Length == 0)
			return ("UnknownMonth", "UnknownDate");

		string monthFolder = "UnknownMonth";
		string weekFolder = "UnknownDate";

		for (int i = 0; i < parts.Length; i++)
		{
			var normalized = NormalizeFolderLabel(parts[i]);

			if (monthFolder == "UnknownMonth" && LooksLikeMonthFolder(normalized))
			{
				monthFolder = parts[i];
				if (i + 1 < parts.Length)
				{
					var nextNormalized = NormalizeFolderLabel(parts[i + 1]);
					if (LooksLikeWeekFolder(nextNormalized))
						weekFolder = parts[i + 1];
				}
				break;
			}
		}

		if (monthFolder == "UnknownMonth" && parts.Length >= 3)
			monthFolder = parts[^3];

		if (weekFolder == "UnknownDate" && parts.Length >= 2)
			weekFolder = parts[^2];

		return (monthFolder, weekFolder);
	}

	private static string? TryParseYearFromSharePointPath(string sharePointPath)
	{
		var parts = sharePointPath.Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
		foreach (var p in parts)
		{
			var normalized = NormalizeFolderLabel(p);
			var m = Regex.Match(normalized, @"(?<!\d)(20\d{2})(?!\d)");
			if (m.Success)
				return m.Groups[1].Value;
		}
		return null;
	}

	private static string NormalizeFolderLabel(string value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return string.Empty;

		value = value.Trim().Trim('/');
		value = Regex.Replace(value, @"^\d+\s*\.\s*", "");
		value = Regex.Replace(value, @"\s+", " ").Trim();
		return value;
	}

	private static bool LooksLikeMonthFolder(string value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return false;

		if (Regex.IsMatch(value, @"^(0?[1-9]|1[0-2])\s*\.\s*[A-Za-z]+", RegexOptions.IgnoreCase))
			return true;

		if (Regex.IsMatch(value, @"^(January|February|March|April|May|June|July|August|September|October|November|December)$", RegexOptions.IgnoreCase))
			return true;

		return false;
	}

	private static bool LooksLikeWeekFolder(string value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return false;

		return Regex.IsMatch(value, @"\d{1,2}\.\d{1,2}\.\d{4}\s*-\s*\d{1,2}\.\d{1,2}(\.\d{4})?", RegexOptions.IgnoreCase);
	}

	private string GetEffectiveLineSheetCandidates(LabFileMap lab)
	{
		return !string.IsNullOrWhiteSpace(lab.LineLevelSheetNames)
			? lab.LineLevelSheetNames
			: _opt.SheetName;
	}

	private static string ExtractSourceLabel(string sheetName)
	{
		// "Webpm Line Level" -> "Webpm", "Daq Line Level" -> "Daq"
		const string suffix = " Line Level";
		var trimmed = sheetName.Trim();
		if (trimmed.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
			return trimmed.Substring(0, trimmed.Length - suffix.Length).Trim();
		return trimmed;
	}

	private static bool ShouldCopyClaimStatusToLineLevel(LabFileMap lab)
	{
		if (lab == null) return false;

		var labName = lab.LabName ?? string.Empty;

		return lab.LabId == 19
			|| lab.LabId == 20
			|| labName.Contains("Augustus", StringComparison.OrdinalIgnoreCase)
			|| labName.Contains("Certus", StringComparison.OrdinalIgnoreCase)
			|| labName.Contains("NorthWest", StringComparison.OrdinalIgnoreCase)
			|| labName.Contains("Northwest", StringComparison.OrdinalIgnoreCase);
	}

	private static string ResolveClaimLevelCptSummaryColumnName(string? claimSchemaPath)
	{
		const string fallback = "CPT Code X Units X Modifier";
		if (string.IsNullOrWhiteSpace(claimSchemaPath) || !File.Exists(claimSchemaPath))
			return fallback;

		try
		{
			using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(claimSchemaPath));
			if (!doc.RootElement.TryGetProperty("Columns", out var columns) || columns.ValueKind != System.Text.Json.JsonValueKind.Array)
				return fallback;

			foreach (var col in columns.EnumerateArray())
			{
				if (!col.TryGetProperty("Name", out var nameProp))
					continue;
				var name = nameProp.GetString() ?? string.Empty;
				var normalized = Regex.Replace(name, @"[^A-Za-z0-9]", "").ToLowerInvariant();
				if (normalized.Contains("cpt") && normalized.Contains("units") && normalized.Contains("modifier"))
					return name;
			}
		}
		catch { }

		return fallback;
	}

	private async Task DownloadSharePointFileWithRetryAsync(
		string driveId,
		string itemId,
		string localPath,
		CancellationToken ct)
	{
		const int maxAttempts = 4;
		var tempPath = localPath + ".download";

		Directory.CreateDirectory(Path.GetDirectoryName(localPath) ?? AppContext.BaseDirectory);

		for (var attempt = 1; attempt <= maxAttempts; attempt++)
		{
			try
			{
				ct.ThrowIfCancellationRequested();

				if (File.Exists(tempPath))
					File.Delete(tempPath);

				await _sp.DownloadFileAsync(driveId, itemId, tempPath, ct);

				if (File.Exists(localPath))
					File.Delete(localPath);

				File.Move(tempPath, localPath);
				return;
			}
			catch (OperationCanceledException) when (ct.IsCancellationRequested)
			{
				throw;
			}
			catch (Exception ex) when (IsTransientDownloadException(ex) && attempt < maxAttempts)
			{
				var delay = TimeSpan.FromSeconds(Math.Min(60, attempt * attempt * 5));
				_logger.LogWarning(ex, "SharePoint download failed. Attempt {Attempt}/{MaxAttempts}. Retrying in {DelaySeconds}s. Target={LocalPath}", attempt, maxAttempts, delay.TotalSeconds, localPath);
				_fileLog.Warn($"SharePoint download failed. Attempt {attempt}/{maxAttempts}. Retrying in {delay.TotalSeconds:n0}s. Target={localPath}. Error={ex.Message}");
				await Task.Delay(delay, ct);
			}
		}
	}

	private static bool IsTransientDownloadException(Exception ex)
	{
		for (var current = ex; current != null; current = current.InnerException)
		{
			if (current is IOException || current is HttpRequestException || current is TaskCanceledException || current is TimeoutException)
				return true;
		}

		return false;
	}

	private bool IsTeamsNotificationEnabled()
	{
		return _configuration.GetValue<bool?>("MasterFileProcessor:SendTeamsNotification")
			?? _configuration.GetValue<bool?>("MasterFileProcessor:TeamsNotificationEnabled")
			?? true;
	}

	private bool IsSharePointFileUploadEnabled()
	{
		return _configuration.GetValue<bool?>("MasterFileProcessor:UploadFilesToSharePoint")
			?? _configuration.GetValue<bool?>("MasterFileProcessor:SharePoint:UploadFilesToSharePoint")
			?? true;
	}

	private async Task<bool> TryDownloadSiblingRawMasterAsync(
		LabFileMap lab,
		SharePointDownloader.SelectedFile selected,
		string rawMasterFolder,
		string? runId,
		CancellationToken ct)
	{
		var limsPattern = GetLabConfigValue(lab, "LimsMasterFilePattern");

		if (string.IsNullOrWhiteSpace(limsPattern))
			return false;

		try
		{
			var sibling = await TryFindSiblingFileByPatternAsync(selected, limsPattern!, ct);

			if (sibling == null)
			{
				_logger.LogWarning(
					"Lab {LabId}: no LIMS master file matched pattern '{Pattern}' in the same SharePoint folder.",
					lab.LabId,
					limsPattern);

				_fileLog.Warn($"Lab {lab.LabId}: no LIMS master file matched pattern '{limsPattern}' in the same SharePoint folder.");
				return false;
			}

			var limsRawMasterPath = Path.Combine(rawMasterFolder, SanitizeFileName(sibling.Name));
			await DownloadSharePointFileWithRetryAsync(sibling.DriveId, sibling.ItemId, limsRawMasterPath, ct);

			_logger.LogInformation(
				"Lab {LabId}: LIMS raw master downloaded -> {Path}",
				lab.LabId,
				limsRawMasterPath);

			_fileLog.Info($"Lab {lab.LabId}: LIMS raw master downloaded -> {limsRawMasterPath}");

			await TryImportLimsMasterAsync(lab, limsRawMasterPath, runId, ct);
			return true;
		}
		catch (Exception ex)
		{
			_logger.LogWarning(ex, "Lab {LabId}: failed to download LIMS raw master file.", lab.LabId);
			_fileLog.Error($"Lab {lab.LabId}: failed to download LIMS raw master file.", ex);
			return false;
		}
	}

	private async Task TrySyncClientPaidFileAsync(
		LabFileMap lab,
		SharePointDownloader.SelectedFile selected,
		string outputFolder,
		string runId,
		CancellationToken ct)
	{
		var clientPaidPattern = lab.ClientPaidFileNamePattern ?? GetLabConfigValue(lab, "ClientPaidFileNamePattern");

		if (string.IsNullOrWhiteSpace(clientPaidPattern))
			return;

		try
		{
			var sibling = await TryFindSiblingFileByPatternAsync(selected, clientPaidPattern!, ct);

			if (sibling == null)
			{
				_logger.LogWarning(
					"Lab {LabId}: no Client Paid file matched pattern '{Pattern}' in the same SharePoint folder.",
					lab.LabId,
					clientPaidPattern);

				_fileLog.Warn($"Lab {lab.LabId}: no Client Paid file matched pattern '{clientPaidPattern}' in the same SharePoint folder.");
				return;
			}

			Directory.CreateDirectory(outputFolder);

			var clientPaidOutPath = Path.Combine(
				outputFolder,
				BuildRunPrefixedFileName(runId, sibling.Name));

			await DownloadSharePointFileWithRetryAsync(sibling.DriveId, sibling.ItemId, clientPaidOutPath, ct);

			_logger.LogInformation(
				"Lab {LabId}: Client Paid file synchronized -> {Path}",
				lab.LabId,
				clientPaidOutPath);

			_fileLog.Info($"Lab {lab.LabId}: Client Paid file synchronized -> {clientPaidOutPath}");
		}
		catch (Exception ex)
		{
			_logger.LogWarning(ex, "Lab {LabId}: failed to synchronize Client Paid file.", lab.LabId);
			_fileLog.Error($"Lab {lab.LabId}: failed to synchronize Client Paid file.", ex);
		}
	}

	private async Task TryImportLimsMasterAsync(LabFileMap lab, string limsRawMasterPath, string? runId, CancellationToken ct)
	{
		var enabled = _configuration.GetValue<bool?>("MasterFileProcessor:LimsSqlImportEnabled") ?? true;
		if (!enabled)
		{
			_logger.LogInformation("Lab {LabId}: LIMS SQL import disabled by MasterFileProcessor:LimsSqlImportEnabled.", lab.LabId);
			return;
		}

		try
		{
			var connectionString =
				GetLabConfigValue(lab, "LabDbConnectionString")
				?? GetLabConfigValue(lab, "LimsDbConnectionString")
				?? _configuration.GetConnectionString(GetLabConfigValue(lab, "LabDbConnectionKey") ?? string.Empty)
				?? _configuration.GetConnectionString("DefaultConnection");

			if (string.IsNullOrWhiteSpace(connectionString))
				throw new InvalidOperationException($"Lab {lab.LabId}: LIMS connection string missing.");

			var schemaPath = GetLabConfigValue(lab, "LIMSSchemaJsonPath");
			if (!string.IsNullOrWhiteSpace(schemaPath))
				schemaPath = ResolvePath(schemaPath);

			var importer = new LimsMasterBulkImporter(_logger);

			var result = await importer.ImportAsync(new LimsImportRequest
			{
				ExcelPath = limsRawMasterPath,
				ConnectionString = connectionString,
				DestinationTable = _configuration["MasterFileProcessor:LimsDestinationTable"] ?? "dbo.LIMSMaster",
				SchemaJsonPath = schemaPath,
				PreferredSheetName = _configuration["MasterFileProcessor:LimsSheetName"] ?? "Masterfile",
				BatchSize = _configuration.GetValue<int?>("MasterFileProcessor:LimsBulkCopyBatchSize") ?? 50000,
				TruncateBeforeLoad = _configuration.GetValue<bool?>("MasterFileProcessor:LimsTruncateBeforeLoad") ?? true,
				DisableNonClusteredIndexesDuringLoad = _configuration.GetValue<bool?>("MasterFileProcessor:LimsDisableNonClusteredIndexesDuringLoad") ?? true,
				DisableTriggersDuringLoad = _configuration.GetValue<bool?>("MasterFileProcessor:LimsDisableTriggersDuringLoad") ?? true,
				CreatedOn = DateTime.Now,
				LabId = lab.LabId,
				LabName = lab.LabName,
				RunId = runId
			}, ct);

			_logger.LogInformation(
				"Lab {LabId}: LIMS SQL import completed. Sheet={Sheet}, RowsCopied={Rows}, CreatedOn={CreatedOn}",
				lab.LabId,
				result.SheetName,
				result.TotalRowsCopied,
				result.CreatedOn);

			_fileLog.Info($"Lab {lab.LabId}: LIMS SQL import completed. Sheet={result.SheetName}, RowsCopied={result.TotalRowsCopied}, CreatedOn={result.CreatedOn:yyyy-MM-dd HH:mm:ss.fffffff}");
		}
		catch (Exception ex)
		{
			_logger.LogError(ex, "Lab {LabId}: LIMS SQL import failed for {Path}", lab.LabId, limsRawMasterPath);
			_fileLog.Error($"Lab {lab.LabId}: LIMS SQL import failed for {limsRawMasterPath}", ex);
		}
	}

	private static int ParseInt(string? value, int defaultValue)
	{
		return int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) ? parsed : defaultValue;
	}

	private static bool ParseBool(string? value, bool defaultValue)
	{
		return bool.TryParse(value, out var parsed) ? parsed : defaultValue;
	}

	private async Task<SharePointDownloader.SelectedFile?> TryFindSiblingFileByPatternAsync(
		SharePointDownloader.SelectedFile selected,
		string filePattern,
		CancellationToken ct)
	{
		var downloaderType = _sp.GetType();
		var folderPath = GetFolderPath(selected.SharePointPath);
		if (string.IsNullOrWhiteSpace(folderPath))
			return null;

		_logger.LogInformation(
			"Lab {LabId}: finding sibling raw master. DriveId={DriveId}, FolderPath={FolderPath}, Pattern={Pattern}",
			selected.LabId,
			selected.DriveId,
			folderPath,
			filePattern);

		// 1) Preferred: direct helper on SharePointDownloader if available.
		var directMethod = downloaderType.GetMethod(
			"TryGetSiblingFileByPatternAsync",
			System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic);

		if (directMethod != null)
		{
			try
			{
				var directArgs = BuildMethodArgs(directMethod, selected, filePattern, ct);
				var directResult = await InvokeMethodAsync(_sp, directMethod, directArgs);
				var directSelected = ConvertToSelectedFile(directResult);
				if (directSelected != null)
				{
					_logger.LogInformation("Lab {LabId}: sibling file found by direct helper -> {Name}", selected.LabId, directSelected.Name);
					return directSelected;
				}
			}
			catch (Exception ex)
			{
				_logger.LogDebug(ex, "Lab {LabId}: direct sibling lookup failed; falling back to folder listing.", selected.LabId);
			}
		}

		// 2) Fallback: try several likely list methods and argument orders.
		var listMethodCandidates = new[]
		{
			"ListFolderItemsByPathAsync",
			"ListChildrenByPathAsync",
			"ListFolderChildrenByPathAsync",
			"ListItemsByFolderPathAsync",
			"GetChildrenByPathAsync",
			"GetFolderChildrenAsync"
		};

		var attempted = new List<string>();
		foreach (var methodName in listMethodCandidates)
		{
			var methods = downloaderType
				.GetMethods(System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic)
				.Where(m => string.Equals(m.Name, methodName, StringComparison.Ordinal))
				.ToArray();

			foreach (var method in methods)
			{
				var candidateArgSets = new[]
				{
					BuildMethodArgs(method, selected.DriveId, folderPath, ct),
					BuildMethodArgs(method, folderPath, selected.DriveId, ct),
					BuildMethodArgs(method, folderPath, ct),
					BuildMethodArgs(method, selected.DriveId, ct),
					BuildMethodArgs(method, selected, folderPath, ct)
				};

				for (var i = 0; i < candidateArgSets.Length; i++)
				{
					try
					{
						attempted.Add($"{method.Name}#{i + 1}");
						var invokeResult = await InvokeMethodAsync(_sp, method, candidateArgSets[i]);
						var sibling = FindBestPatternMatchFromEnumerable(invokeResult as System.Collections.IEnumerable, selected, filePattern);
						if (sibling != null)
						{
							_logger.LogInformation("Lab {LabId}: sibling file found by {Method} -> {Name}", selected.LabId, method.Name, sibling.Name);
							return sibling;
						}
					}
					catch (Exception ex)
					{
						_logger.LogDebug(ex, "Lab {LabId}: sibling lookup attempt failed. Method={Method}, Attempt={Attempt}", selected.LabId, method.Name, i + 1);
					}
				}
			}
		}

		_logger.LogWarning(
			"Lab {LabId}: sibling file not found. DriveId={DriveId}, FolderPath={FolderPath}, Pattern={Pattern}, Attempts={Attempts}",
			selected.LabId,
			selected.DriveId,
			folderPath,
			filePattern,
			string.Join(", ", attempted));

		return null;
	}

	private static object?[] BuildMethodArgs(System.Reflection.MethodInfo method, params object?[] suppliedValues)
	{
		var parameters = method.GetParameters();
		var args = new object?[parameters.Length];
		var used = new bool[suppliedValues.Length];

		for (var i = 0; i < parameters.Length; i++)
		{
			var parameter = parameters[i];
			var parameterType = parameter.ParameterType;
			var matched = false;

			for (var j = 0; j < suppliedValues.Length; j++)
			{
				if (used[j])
					continue;

				var supplied = suppliedValues[j];
				if (supplied == null)
					continue;

				if (parameterType.IsInstanceOfType(supplied))
				{
					args[i] = supplied;
					used[j] = true;
					matched = true;
					break;
				}

				if (parameterType == typeof(string) && supplied is string s)
				{
					args[i] = s;
					used[j] = true;
					matched = true;
					break;
				}
			}

			if (!matched)
				args[i] = parameter.HasDefaultValue ? parameter.DefaultValue : GetDefault(parameterType);
		}

		return args;
	}

	private static async Task<object?> InvokeMethodAsync(object target, System.Reflection.MethodInfo method, object?[] args)
	{
		var raw = method.Invoke(method.IsStatic ? null : target, args);

		if (raw is Task task)
		{
			await task.ConfigureAwait(false);
			var taskType = task.GetType();
			if (taskType.IsGenericType)
				return taskType.GetProperty("Result")?.GetValue(task);
			return null;
		}

		return raw;
	}

	private static SharePointDownloader.SelectedFile? FindBestPatternMatchFromEnumerable(
		System.Collections.IEnumerable? items,
		SharePointDownloader.SelectedFile selected,
		string filePattern)
	{
		if (items == null)
			return null;

		var regex = WildcardToRegex(filePattern);
		SharePointDownloader.SelectedFile? best = null;
		DateTimeOffset? bestModified = null;

		foreach (var item in items)
		{
			if (item == null)
				continue;

			var name = GetPropertyValue<string>(item, "Name");
			if (string.IsNullOrWhiteSpace(name))
				continue;

			var isFolder = GetPropertyValue<bool?>(item, "IsFolder") ?? false;
			if (isFolder)
				continue;

			if (string.Equals(name, selected.Name, StringComparison.OrdinalIgnoreCase))
				continue;

			if (!regex.IsMatch(name))
				continue;

			var candidate = ConvertToSelectedFile(item, selected.DriveId, CombinePath(GetFolderPath(selected.SharePointPath), name));
			if (candidate == null)
				continue;

			var modified = candidate.LastModifiedUtc;
			if (best == null || CompareNullableDateTimeOffset(modified, bestModified) > 0)
			{
				best = candidate;
				bestModified = modified;
			}
		}

		return best;
	}

	private string? ResolvePanelMasterFilePath(LabFileMap lab)
	{
		// Prefer lab-level PanelMasterFilePath from appsettings.json.
		// This is required because Augustus and NorthWest use different mapping workbooks.
		var labPanelPath = GetLabConfigValue(lab, "PanelMasterFilePath");

		if (!string.IsNullOrWhiteSpace(labPanelPath))
			return labPanelPath;

		return _opt.PanelMasterFilePath;
	}

	private string? GetLabConfigValue(LabFileMap lab, string key)
	{
		var labsSection = _configuration.GetSection("MasterFileProcessor:Labs");
		foreach (var section in labsSection.GetChildren())
		{
			var sectionLabId = section.GetValue<int?>("LabId");
			var sectionLabName = section.GetValue<string>("LabName");

			if (sectionLabId == lab.LabId ||
				string.Equals(sectionLabName, lab.LabName, StringComparison.OrdinalIgnoreCase))
			{
				return section.GetValue<string>(key);
			}
		}

		return null;
	}

	private static SharePointDownloader.SelectedFile? ConvertToSelectedFile(object? source, string? fallbackDriveId = null, string? fallbackSharePointPath = null)
	{
		if (source == null)
			return null;

		if (source is SharePointDownloader.SelectedFile selected)
			return selected;

		var name = GetPropertyValue<string>(source, "Name");
		var itemId = GetPropertyValue<string>(source, "ItemId") ?? GetPropertyValue<string>(source, "Id");
		var driveId = GetPropertyValue<string>(source, "DriveId") ?? fallbackDriveId ?? string.Empty;
		var sharePointPath = GetPropertyValue<string>(source, "SharePointPath") ?? fallbackSharePointPath ?? string.Empty;
		var etag = GetPropertyValue<string>(source, "ETagKey") ?? GetPropertyValue<string>(source, "ETag") ?? string.Empty;
		var lastModified = GetPropertyValue<DateTimeOffset?>(source, "LastModifiedUtc")
			?? GetPropertyValue<DateTimeOffset?>(source, "LastModifiedDateTime")
			?? GetPropertyValue<DateTimeOffset?>(source, "ModifiedUtc");

		if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(itemId))
			return null;

		return new SharePointDownloader.SelectedFile(
			LabId: GetPropertyValue<int?>(source, "LabId") ?? 0,
			DriveId: driveId,
			ItemId: itemId,
			Name: name,
			ETagKey: etag,
			LastModifiedUtc: lastModified,
			SharePointPath: sharePointPath);
	}

	private static T? GetPropertyValue<T>(object source, string propertyName)
	{
		var prop = source.GetType().GetProperty(propertyName, System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic);
		if (prop == null)
			return default;

		var value = prop.GetValue(source);
		if (value == null)
			return default;

		if (value is T typed)
			return typed;

		try
		{
			return (T?)Convert.ChangeType(value, Nullable.GetUnderlyingType(typeof(T)) ?? typeof(T), CultureInfo.InvariantCulture);
		}
		catch
		{
			return default;
		}
	}

	private static object? GetDefault(Type type)
	{
		if (!type.IsValueType || Nullable.GetUnderlyingType(type) != null)
			return null;

		return Activator.CreateInstance(type);
	}

	private static int CompareNullableDateTimeOffset(DateTimeOffset? left, DateTimeOffset? right)
	{
		if (left.HasValue && right.HasValue)
			return left.Value.CompareTo(right.Value);

		if (left.HasValue)
			return 1;

		if (right.HasValue)
			return -1;

		return 0;
	}

	private static string GetFolderPath(string filePath)
	{
		if (string.IsNullOrWhiteSpace(filePath))
			return string.Empty;

		var normalized = filePath.Replace("\\", "/").Trim('/');
		var idx = normalized.LastIndexOf('/');
		return idx <= 0 ? string.Empty : normalized.Substring(0, idx);
	}

	private static string CombinePath(string folder, string fileName)
	{
		folder = (folder ?? string.Empty).Trim().Trim('/');
		fileName = (fileName ?? string.Empty).Trim().Trim('/');
		return string.IsNullOrWhiteSpace(folder) ? fileName : $"{folder}/{fileName}";
	}

	private static Regex WildcardToRegex(string pattern)
	{
		var escaped = Regex.Escape(pattern).Replace("\\*", ".*").Replace("\\?", ".");
		return new Regex($"^{escaped}$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
	}

	private static string GetLabFolderName(LabFileMap lab)
	{
		if (!string.IsNullOrWhiteSpace(lab.LabName))
			return SanitizePathSegment(lab.LabName);

		return SanitizePathSegment(lab.LabId.ToString(CultureInfo.InvariantCulture));
	}

	private static string GetLabOutputPrefix(LabFileMap lab)
	{
		// Required file name style: Beech_Tree_ClaimLevel.csv / Beech_Tree_LineLevel.csv
		var name = !string.IsNullOrWhiteSpace(lab.LabName)
			? lab.LabName.Trim()
			: lab.LabId.ToString(CultureInfo.InvariantCulture);

		name = name.Replace(' ', '_');
		return SanitizeFileName(name);
	}


	private static string BuildProcessedOutputFileName(string runId, string? labName, string levelLabel, string sourceDateLabel)
	{
		var labPart = string.IsNullOrWhiteSpace(labName) ? "UnknownLab" : labName.Trim();
		var levelPart = string.IsNullOrWhiteSpace(levelLabel) ? "Output" : levelLabel.Trim();
		var datePart = string.IsNullOrWhiteSpace(sourceDateLabel) ? "UnknownDate" : sourceDateLabel.Trim();

		var fileName = $"{runId}_{labPart}_{levelPart}_{datePart}.csv";
		return SanitizeFileNameKeepSpaces(fileName);
	}

	private static string BuildModeMedianOutputFileName(string runId, string? labName, string sourceDateLabel)
	{
		var labPart = string.IsNullOrWhiteSpace(labName) ? "UnknownLab" : labName.Trim();
		var datePart = string.IsNullOrWhiteSpace(sourceDateLabel) ? "UnknownDate" : sourceDateLabel.Trim();

		var fileName = $"{runId}_{labPart}_Mode Median_{datePart}.xlsx";
		return SanitizeFileNameKeepSpaces(fileName);
	}

	private static string BuildRunPrefixedFileName(string runId, string originalFileName)
	{
		var prefix = string.IsNullOrWhiteSpace(runId) ? "UnknownRun" : runId.Trim();
		var fileName = $"{prefix}_{originalFileName}";
		return SanitizeFileNameKeepSpaces(fileName);
	}

	private static void ArchiveExistingWeekOutputFiles(string processedOutFolder, string? labName, string sourceDateLabel)
	{
		if (string.IsNullOrWhiteSpace(processedOutFolder))
			return;

		Directory.CreateDirectory(processedOutFolder);

		var obsoleteFolder = Path.Combine(processedOutFolder, "Obsolete");
		Directory.CreateDirectory(obsoleteFolder);

		var labPart = string.IsNullOrWhiteSpace(labName) ? "UnknownLab" : labName.Trim();
		var datePart = string.IsNullOrWhiteSpace(sourceDateLabel) ? "UnknownDate" : sourceDateLabel.Trim();

		var markers = new[]
		{
		$"_{labPart}_Claim Level_{datePart}",
		$"_{labPart}_Line Level_{datePart}",
		$"_{labPart}_Mode_{datePart}",
		$"_{labPart}_Median_{datePart}",
		$"_{labPart}_Mode Median_{datePart}"
	};

		foreach (var filePath in Directory.EnumerateFiles(processedOutFolder, "*.*", SearchOption.TopDirectoryOnly))
		{
			var fileName = Path.GetFileName(filePath);

			var isMatch = markers.Any(marker =>
				fileName.Contains(marker, StringComparison.OrdinalIgnoreCase));

			if (!isMatch)
				continue;

			var destName =
				$"{Path.GetFileNameWithoutExtension(fileName)}_Obsolete_{DateTime.Now:yyyyMMddHHmmss}{Path.GetExtension(fileName)}";

			var destPath = Path.Combine(obsoleteFolder, destName);

			if (File.Exists(destPath))
			{
				destPath = Path.Combine(
					obsoleteFolder,
					$"{Path.GetFileNameWithoutExtension(fileName)}_Obsolete_{DateTime.Now:yyyyMMddHHmmssfff}{Path.GetExtension(fileName)}");
			}

			File.Move(filePath, destPath);
		}
	}

	private static string NormalizeWeekFolderForFileName(string? weekFolder)
	{
		if (string.IsNullOrWhiteSpace(weekFolder)) return "UnknownDate";

		var value = weekFolder.Trim();
		value = Regex.Replace(value, @"\s*-\s*", " to ");
		return value;
	}

	private static string SanitizeFileNameKeepSpaces(string input)
	{
		foreach (var c in Path.GetInvalidFileNameChars())
			input = input.Replace(c, '_');
		return input.Trim();
	}

	private static string SanitizePathSegment(string input)
	{
		foreach (var c in Path.GetInvalidFileNameChars())
			input = input.Replace(c, '_');
		return input.Trim();
	}

	private static string SanitizeFileName(string input)
	{
		foreach (var c in Path.GetInvalidFileNameChars())
			input = input.Replace(c, '_');
		return input.Trim();
	}

	private static void TryDelete(string path)
	{
		try
		{
			if (File.Exists(path))
				File.Delete(path);
		}
		catch { }
	}

	private static string ResolvePath(string path)
	{
		if (string.IsNullOrWhiteSpace(path)) return path;
		if (Path.IsPathRooted(path)) return path;

		var normalized = path.Replace('/', Path.DirectorySeparatorChar).Replace('\\', Path.DirectorySeparatorChar);
		return Path.Combine(AppContext.BaseDirectory, normalized);
	}
}
