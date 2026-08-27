using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

/// <summary>
/// CSV writer for the 3 process-log "sheets":
///   Run_Log  (24 cols)
///   Step_Log (23 cols)
///   Error_Log(16 cols)
///
/// Output path (local):
///   {folder}\{Month}\Run_Log.{ddMMyyyy}.csv
///   {folder}\{Month}\Step_Log.{ddMMyyyy}.csv
///   {folder}\{Month}\Error_Log.{ddMMyyyy}.csv
///
/// Notes:
/// - Run_Log is UPSERT by RunID (one unique entry per run).
/// - Step_Log is UPSERT by (RunID, StepSeq) so StepStart + StepEnd becomes one row.
/// - Error_Log is APPEND (multiple errors per run).
/// - Headers match LRN_Process_Log_Template.xlsx exactly (including "Lab Name" in Step_Log).
/// </summary>
public static class ProcessLogCsv
{
    // IMPORTANT: Must match the template headers exactly.
    public const string RunHeader =
        "RunID,LabName,PipelineName,TriggerType,TriggeredBy,StartTimeIST,EndTimeIST,DurationSeconds,OverallStatus,LatestMasterFileFound,InputMasterSharePointPath,InputMasterFileName,InputMasterFileModifiedTime,InputMasterFileSizeMB,MandatoryColumnCheck,SplitOutputWrittenToSharePoint,PayerPolicyValidationStatus,CodingValidationStatus,AveragesProcessStatus,OutputsCopiedToSharePoint,MasterSyncPerformed,TotalErrors,TotalWarnings,Notes";

    public const string StepHeader =
        "RunID,Lab Name,StepSeq,StepName,StepCategory,SourceSystem,StartTimeIST,EndTimeIST,DurationSeconds,Status,RecordsIn,RecordsOut,FileNameIn,FileNameOut,PathIn,PathOut,ErrorCode,ErrorMessage,ErrorDetail,RetryCount,ExecutedBy,Host,ModuleVersion";

    public const string ErrorHeader =
        "RunID,LabName,ErrorTimeIST,Severity,StepName,ErrorCode,ErrorSummary,MissingColumns,SheetName,FileName,FilePath,RowExample,RecommendedAction,OwnerTeam,TicketID,Status";

    private static readonly ConcurrentDictionary<string, object> _fileLocks = new(StringComparer.OrdinalIgnoreCase);

    public static string GetMonthFolderName(DateTime localNow)
        => localNow.ToString("MMMM", CultureInfo.InvariantCulture);

    public static string GetDailyFileName(string sheetName, DateTime localNow)
        => $"{sheetName}.{localNow:ddMMyyyy}.csv";

    public static string GetRunCsvPath(string folder, DateTime localNow)
        => GetCsvPath(folder, localNow, "Run_Log");

    public static string GetStepCsvPath(string folder, DateTime localNow)
        => GetCsvPath(folder, localNow, "Step_Log");

    public static string GetErrorCsvPath(string folder, DateTime localNow)
        => GetCsvPath(folder, localNow, "Error_Log");

    private static string GetCsvPath(string folder, DateTime localNow, string sheetName)
    {
        var month = GetMonthFolderName(localNow);
        var monthFolder = Path.Combine(folder, month);
        Directory.CreateDirectory(monthFolder);
        return Path.Combine(monthFolder, GetDailyFileName(sheetName, localNow));
    }

    public static string UpsertRun(string folder, DateTime localNow, RunLogRow row)
    {
        var path = GetRunCsvPath(folder, localNow);
        Upsert(path, RunHeader, new[] { "RunID" }, new[] { row.RunID }, BuildRunValues(row));
        return path;
    }

    public static string UpsertStep(string folder, DateTime localNow, StepLogRow row)
    {
        var path = GetStepCsvPath(folder, localNow);
        Upsert(path, StepHeader, new[] { "RunID", "StepSeq" }, new[] { row.RunID, row.StepSeq.ToString(CultureInfo.InvariantCulture) }, BuildStepValues(row));
        return path;
    }

    public static string AppendError(string folder, DateTime localNow, ErrorLogRow row)
    {
        var path = GetErrorCsvPath(folder, localNow);
        Append(path, ErrorHeader, BuildErrorValues(row));
        return path;
    }

    public static void IncrementRunCount(string folder, DateTime localNow, string runId, bool isWarning)
    {
        var path = GetRunCsvPath(folder, localNow);
        var col = isWarning ? "TotalWarnings" : "TotalErrors";
        UpdateNumericCell(path, RunHeader, keyCols: new[] { "RunID" }, keyVals: new[] { runId }, targetCol: col, delta: 1);
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
            s.LabName ?? "",
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

    private static void EnsureHeader(string path, string header)
    {
        if (File.Exists(path)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
        File.WriteAllText(path, header + Environment.NewLine, Encoding.UTF8);
    }

    private static object GetLock(string path)
        => _fileLocks.GetOrAdd(path, _ => new object());

    private static void Append(string path, string header, string[] values)
    {
        lock (GetLock(path))
        {
            EnsureHeader(path, header);
            File.AppendAllText(path, ToCsvLine(values) + Environment.NewLine, Encoding.UTF8);
        }
    }

    private static void Upsert(string path, string header, string[] keyCols, string[] keyVals, string[] allValues)
    {
        lock (GetLock(path))
        {
            EnsureHeader(path, header);

            var lines = File.ReadAllLines(path, Encoding.UTF8).ToList();
            if (lines.Count == 0)
            {
                lines.Add(header);
            }

            var headers = ParseCsvLine(lines[0]).Select(h => h.Trim()).ToList();
            var keyIdx = keyCols.Select(c => headers.FindIndex(h => string.Equals(h, c, StringComparison.OrdinalIgnoreCase))).ToArray();
            if (keyIdx.Any(i => i < 0))
            {
                // header mismatch - fall back to append (never lose logs)
                lines.Add(ToCsvLine(allValues));
                File.WriteAllLines(path, lines, Encoding.UTF8);
                return;
            }

            int foundAt = -1;
            for (int i = 1; i < lines.Count; i++)
            {
                if (string.IsNullOrWhiteSpace(lines[i])) continue;
                var fields = ParseCsvLine(lines[i]);
                bool match = true;
                for (int k = 0; k < keyIdx.Length; k++)
                {
                    var idx = keyIdx[k];
                    var cur = idx < fields.Count ? fields[idx] : "";
                    if (!string.Equals(cur, keyVals[k] ?? "", StringComparison.OrdinalIgnoreCase))
                    {
                        match = false;
                        break;
                    }
                }
                if (match)
                {
                    foundAt = i;
                    break;
                }
            }

            var newLine = ToCsvLine(allValues);
            if (foundAt >= 0) lines[foundAt] = newLine;
            else lines.Add(newLine);

            // Write atomically
            var tmp = path + ".tmp";
            File.WriteAllLines(tmp, lines, Encoding.UTF8);
            File.Copy(tmp, path, overwrite: true);
            File.Delete(tmp);
        }
    }

    private static void UpdateNumericCell(
        string path,
        string header,
        string[] keyCols,
        string[] keyVals,
        string targetCol,
        int delta)
    {
        lock (GetLock(path))
        {
            EnsureHeader(path, header);
            var lines = File.ReadAllLines(path, Encoding.UTF8).ToList();
            if (lines.Count == 0) lines.Add(header);

            var headers = ParseCsvLine(lines[0]).Select(h => h.Trim()).ToList();
            var keyIdx = keyCols.Select(c => headers.FindIndex(h => string.Equals(h, c, StringComparison.OrdinalIgnoreCase))).ToArray();
            var targetIdx = headers.FindIndex(h => string.Equals(h, targetCol, StringComparison.OrdinalIgnoreCase));
            if (keyIdx.Any(i => i < 0) || targetIdx < 0) return;

            for (int i = 1; i < lines.Count; i++)
            {
                if (string.IsNullOrWhiteSpace(lines[i])) continue;
                var fields = ParseCsvLine(lines[i]);

                bool match = true;
                for (int k = 0; k < keyIdx.Length; k++)
                {
                    var idx = keyIdx[k];
                    var cur = idx < fields.Count ? fields[idx] : "";
                    if (!string.Equals(cur, keyVals[k] ?? "", StringComparison.OrdinalIgnoreCase))
                    {
                        match = false;
                        break;
                    }
                }
                if (!match) continue;

                while (fields.Count <= targetIdx) fields.Add("");
                _ = int.TryParse(fields[targetIdx], NumberStyles.Integer, CultureInfo.InvariantCulture, out var curVal);
                fields[targetIdx] = (curVal + delta).ToString(CultureInfo.InvariantCulture);
                lines[i] = ToCsvLine(fields);

                var tmp = path + ".tmp";
                File.WriteAllLines(tmp, lines, Encoding.UTF8);
                File.Copy(tmp, path, overwrite: true);
                File.Delete(tmp);
                return;
            }
        }
    }

    private static string ToCsvLine(IEnumerable<string> values)
        => string.Join(",", values.Select(Escape));

    private static string Escape(string? value)
    {
        value ??= "";
        if (value.Contains('"')) value = value.Replace("\"", "\"\"");
        if (value.IndexOfAny(new[] { ',', '\n', '\r', '"' }) >= 0)
            return "\"" + value + "\"";
        return value;
    }

    private static List<string> ParseCsvLine(string line)
    {
        var result = new List<string>();
        if (line == null) return result;

        var sb = new StringBuilder();
        bool inQuotes = false;

        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];
            if (inQuotes)
            {
                if (c == '"')
                {
                    // escaped quote
                    if (i + 1 < line.Length && line[i + 1] == '"')
                    {
                        sb.Append('"');
                        i++;
                    }
                    else
                    {
                        inQuotes = false;
                    }
                }
                else
                {
                    sb.Append(c);
                }
            }
            else
            {
                if (c == ',')
                {
                    result.Add(sb.ToString());
                    sb.Clear();
                }
                else if (c == '"')
                {
                    inQuotes = true;
                }
                else
                {
                    sb.Append(c);
                }
            }
        }
        result.Add(sb.ToString());
        return result;
    }
}
