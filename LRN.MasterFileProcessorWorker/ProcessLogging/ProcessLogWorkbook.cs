using ClosedXML.Excel;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

/// <summary>
/// Excel workbook writer for the 3 process-log "sheets" in ONE file:
///   Run_Log  (24 cols)
///   Step_Log (23 cols)
///   Error_Log(16 cols)
///
/// Output path (local):
///   {folder}\{Month}\{prefix}.{ddMMyyyy}.xlsx
///
/// Notes:
/// - Run_Log  is UPSERT by RunID (one unique entry per run).
/// - Step_Log is UPSERT by (RunID, StepSeq) so StepStart + StepEnd becomes one row.
/// - Error_Log is APPEND (multiple errors per run).
/// - Headers match LRN_Process_Log_Template.xlsx exactly.
/// </summary>
public static class ProcessLogWorkbook
{
	public const string RunSheet = "Run_Log";
	public const string StepSheet = "Step_Log";
	public const string ErrorSheet = "Error_Log";

	// Must match the template headers exactly.
	public static readonly string[] RunHeader = ProcessLogCsv.RunHeader.Split(',');
	public static readonly string[] StepHeader = ProcessLogCsv.StepHeader.Split(',');
	public static readonly string[] ErrorHeader = ProcessLogCsv.ErrorHeader.Split(',');

	private static readonly ConcurrentDictionary<string, object> _fileLocks = new(StringComparer.OrdinalIgnoreCase);

	public static string GetMonthFolderName(DateTime localNow)
		=> localNow.ToString("MMMM", CultureInfo.InvariantCulture);

	public static string GetDailyWorkbookFileName(string prefix, DateTime localNow)
		=> $"{prefix}.{localNow:ddMMyyyy}.xlsx";

	public static string GetWorkbookPath(string folder, string prefix, DateTime localNow)
	{
		var month = GetMonthFolderName(localNow);
		var monthFolder = Path.Combine(folder, month);
		Directory.CreateDirectory(monthFolder);
		return Path.Combine(monthFolder, GetDailyWorkbookFileName(prefix, localNow));
	}

	public static string UpsertRun(string folder, string prefix, DateTime nowIst, RunLogRow row)
	{
		var path = GetWorkbookPath(folder, prefix, nowIst);
		lock (GetLock(path))
		{
			using var wb = OpenOrCreate(path);
			var ws = EnsureSheet(wb, RunSheet, RunHeader);
			UpsertRow(ws, keyCols: new[] { "RunID" }, keyVals: new[] { row.RunID }, values: BuildRunValues(row));
			SaveAtomically(wb, path);
		}
		return path;
	}

	public static string UpsertStep(string folder, string prefix, DateTime nowIst, StepLogRow row)
	{
		var path = GetWorkbookPath(folder, prefix, nowIst);
		lock (GetLock(path))
		{
			using var wb = OpenOrCreate(path);
			var ws = EnsureSheet(wb, StepSheet, StepHeader);
			UpsertRow(ws,
				keyCols: new[] { "RunID", "StepSeq" },
				keyVals: new[] { row.RunID, row.StepSeq.ToString(CultureInfo.InvariantCulture) },
				values: BuildStepValues(row));
			SaveAtomically(wb, path);
		}
		return path;
	}

	public static string AppendError(string folder, string prefix, DateTime nowIst, ErrorLogRow row)
	{
		var path = GetWorkbookPath(folder, prefix, nowIst);
		lock (GetLock(path))
		{
			using var wb = OpenOrCreate(path);
			var ws = EnsureSheet(wb, ErrorSheet, ErrorHeader);
			AppendRow(ws, BuildErrorValues(row));
			SaveAtomically(wb, path);
		}
		return path;
	}

	public static void IncrementRunCount(string folder, string prefix, DateTime nowIst, string runId, bool isWarning)
	{
		var path = GetWorkbookPath(folder, prefix, nowIst);
		var targetCol = isWarning ? "TotalWarnings" : "TotalErrors";

		lock (GetLock(path))
		{
			using var wb = OpenOrCreate(path);
			var ws = EnsureSheet(wb, RunSheet, RunHeader);

			var headerMap = GetHeaderMap(ws);
			if (!headerMap.TryGetValue("RunID", out var runIdCol) || !headerMap.TryGetValue(targetCol, out var tgtCol))
			{
				SaveAtomically(wb, path);
				return;
			}

			var last = GetLastDataRow(ws);
			for (int r = 2; r <= last; r++)
			{
				var cur = ws.Cell(r, runIdCol).GetString().Trim();
				if (!string.Equals(cur, runId, StringComparison.OrdinalIgnoreCase)) continue;

				var curValStr = ws.Cell(r, tgtCol).GetString();
				var curVal = 0;
				_ = int.TryParse(curValStr, NumberStyles.Integer, CultureInfo.InvariantCulture, out curVal);
				ws.Cell(r, tgtCol).Value = (curVal + 1).ToString(CultureInfo.InvariantCulture);
				SaveAtomically(wb, path);
				return;
			}

			// If run row not found, don't create a partial row; StartRun should have created it.
			SaveAtomically(wb, path);
		}
	}

	private static object GetLock(string path)
		=> _fileLocks.GetOrAdd(path, _ => new object());

	private static XLWorkbook OpenOrCreate(string path)
	{
		Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
		if (File.Exists(path))
			return new XLWorkbook(path);

		var wb = new XLWorkbook();
		// Ensure all 3 sheets exist on create
		EnsureSheet(wb, RunSheet, RunHeader);
		EnsureSheet(wb, StepSheet, StepHeader);
		EnsureSheet(wb, ErrorSheet, ErrorHeader);
		return wb;
	}

	private static IXLWorksheet EnsureSheet(XLWorkbook wb, string sheetName, string[] header)
	{
		var ws = wb.Worksheets.FirstOrDefault(s => string.Equals(s.Name, sheetName, StringComparison.OrdinalIgnoreCase))
				 ?? wb.AddWorksheet(sheetName);

		// Header row
		if (ws.Row(1).Cell(1).IsEmpty())
		{
			for (int i = 0; i < header.Length; i++)
				ws.Cell(1, i + 1).Value = header[i];

			ws.Row(1).Style.Font.Bold = true;
			ws.SheetView.FreezeRows(1);
		}

		return ws;
	}

	private static Dictionary<string, int> GetHeaderMap(IXLWorksheet ws)
	{
		var map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
		var lastCol = ws.Row(1).LastCellUsed()?.Address.ColumnNumber ?? 0;
		for (int c = 1; c <= lastCol; c++)
		{
			var name = ws.Cell(1, c).GetString().Trim();
			if (name.Length == 0) continue;
			if (!map.ContainsKey(name)) map.Add(name, c);
		}
		return map;
	}

	private static int GetLastDataRow(IXLWorksheet ws)
		=> ws.LastRowUsed()?.RowNumber() ?? 1;

	private static void UpsertRow(IXLWorksheet ws, string[] keyCols, string[] keyVals, string[] values)
	{
		var headerMap = GetHeaderMap(ws);
		var keyColIdx = keyCols.Select(c => headerMap.TryGetValue(c, out var idx) ? idx : -1).ToArray();
		if (keyColIdx.Any(i => i < 0))
		{
			// Header mismatch - append, never lose logs
			AppendRow(ws, values);
			return;
		}

		var last = GetLastDataRow(ws);
		int foundRow = -1;
		for (int r = 2; r <= last; r++)
		{
			bool match = true;
			for (int k = 0; k < keyColIdx.Length; k++)
			{
				var cur = ws.Cell(r, keyColIdx[k]).GetString().Trim();
				if (!string.Equals(cur, keyVals[k] ?? "", StringComparison.OrdinalIgnoreCase))
				{
					match = false;
					break;
				}
			}
			if (match)
			{
				foundRow = r;
				break;
			}
		}

		var targetRow = foundRow >= 0 ? foundRow : (last + 1);
		for (int c = 0; c < values.Length; c++)
			ws.Cell(targetRow, c + 1).Value = values[c] ?? "";
	}

	private static void AppendRow(IXLWorksheet ws, string[] values)
	{
		var last = GetLastDataRow(ws);
		var targetRow = last < 2 ? 2 : last + 1;
		for (int c = 0; c < values.Length; c++)
			ws.Cell(targetRow, c + 1).Value = values[c] ?? "";
	}

	private static void SaveAtomically(XLWorkbook wb, string finalPath)
	{
		var dir = Path.GetDirectoryName(finalPath);
		if (string.IsNullOrWhiteSpace(dir))
			throw new ArgumentException("Invalid path (no directory).", nameof(finalPath));

		Directory.CreateDirectory(dir);

		var ext = Path.GetExtension(finalPath);
		if (string.IsNullOrWhiteSpace(ext))
			ext = ".xlsx"; // default, but ideally finalPath already ends with .xlsx

		var baseName = Path.GetFileNameWithoutExtension(finalPath);

		// IMPORTANT: temp must still be an excel extension (e.g. .tmp.xlsx)
		var tempPath = Path.Combine(dir, $"{baseName}.{Guid.NewGuid():N}.tmp{ext}");

		wb.SaveAs(tempPath); // now ClosedXML is happy

		// Atomic replace when possible
		if (File.Exists(finalPath))
		{
			var backupPath = finalPath + ".bak";
			try
			{
				File.Replace(tempPath, finalPath, backupPath, ignoreMetadataErrors: true);
				try { File.Delete(backupPath); } catch { /* ignore */ }
			}
			catch
			{
				// fallback if Replace fails for any reason
				File.Delete(finalPath);
				File.Move(tempPath, finalPath);
			}
		}
		else
		{
			File.Move(tempPath, finalPath);
		}
	}

	private static string? FmtDate(DateTime? dt)
		=> dt.HasValue ? dt.Value.ToString("MM/dd/yyyy HH:mm:ss", CultureInfo.InvariantCulture) : null;

	private static string FmtDateReq(DateTime dt)
		=> dt.ToString("MM/dd/yyyy HH:mm:ss", CultureInfo.InvariantCulture);

	private static string? FmtDecimal(decimal? v)
		=> v.HasValue ? v.Value.ToString(CultureInfo.InvariantCulture) : null;

	private static string? FmtInt(int? v)
		=> v.HasValue ? v.Value.ToString(CultureInfo.InvariantCulture) : null;

	private static string[] BuildRunValues(RunLogRow r)
		=> new[]
		{
			r.RunID,
			r.LabName,
			r.PipelineName ?? "",
			r.TriggerType ?? "",
			r.TriggeredBy ?? "",
			FmtDate(r.StartTimeIST) ?? "",
			FmtDate(r.EndTimeIST) ?? "",
			FmtInt(r.DurationSeconds) ?? "",
			r.OverallStatus ?? "",
			r.LatestMasterFileFound ?? "",
			r.InputMasterSharePointPath ?? "",
			r.InputMasterFileName ?? "",
			FmtDate(r.InputMasterFileModifiedTime) ?? "",
			FmtDecimal(r.InputMasterFileSizeMB) ?? "",
			r.MandatoryColumnCheck ?? "",
			r.SplitOutputWrittenToSharePoint ?? "",
			r.PayerPolicyValidationStatus ?? "",
			r.CodingValidationStatus ?? "",
			r.AveragesProcessStatus ?? "",
			r.OutputsCopiedToSharePoint ?? "",
			r.MasterSyncPerformed ?? "",
			r.TotalErrors.ToString(CultureInfo.InvariantCulture),
			r.TotalWarnings.ToString(CultureInfo.InvariantCulture),
			r.Notes ?? ""
		};

	private static string[] BuildStepValues(StepLogRow s)
		=> new[]
		{
			s.RunID,
			s.LabName ?? "", // Header is "Lab Name"
            s.StepSeq.ToString(CultureInfo.InvariantCulture),
			s.StepName,
			s.StepCategory ?? "",
			s.SourceSystem ?? "",
			FmtDate(s.StartTimeIST) ?? "",
			FmtDate(s.EndTimeIST) ?? "",
			FmtInt(s.DurationSeconds) ?? "",
			s.Status ?? "",
			FmtInt(s.RecordsIn) ?? "",
			FmtInt(s.RecordsOut) ?? "",
			s.FileNameIn ?? "",
			s.FileNameOut ?? "",
			s.PathIn ?? "",
			s.PathOut ?? "",
			s.ErrorCode ?? "",
			s.ErrorMessage ?? "",
			s.ErrorDetail ?? "",
			FmtInt(s.RetryCount) ?? "",
			s.ExecutedBy ?? "",
			s.Host ?? "",
			s.ModuleVersion ?? ""
		};

	private static string[] BuildErrorValues(ErrorLogRow e)
		=> new[]
		{
			e.RunID,
			e.LabName ?? "",
			FmtDateReq(e.ErrorTimeIST),
			e.Severity,
			e.StepName ?? "",
			e.ErrorCode ?? "",
			e.ErrorSummary,
			e.MissingColumns ?? "",
			e.SheetName ?? "",
			e.FileName ?? "",
			e.FilePath ?? "",
			e.RowExample ?? "",
			e.RecommendedAction ?? "",
			e.OwnerTeam ?? "",
			e.TicketID ?? "",
			e.Status ?? ""
		};
}
