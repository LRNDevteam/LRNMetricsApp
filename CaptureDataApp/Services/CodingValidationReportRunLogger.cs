using System.Data;
using Microsoft.Data.SqlClient;

namespace CaptureDataApp.Services;

/// <summary>
/// Writes Coding Validation Capture progress to LRNMaster:
/// <list type="bullet">
///   <item><description><c>dbo.usp_ReportRunIdInfoLog_Insert</c> — step trail</description></item>
///   <item><description><c>dbo.usp_ReportsWorkflowTracker_Upsert</c> — Control Board status</description></item>
/// </list>
/// Success is written only after aggregates refresh completes.
/// Never throws: logging outages must not abort capture.
/// </summary>
public sealed class CodingValidationReportRunLogger
{
    public const string ReportName = "Coding Validation";

    private const string LogSpName = "dbo.usp_ReportRunIdInfoLog_Insert";
    private const string TrackerSpName = "dbo.usp_ReportsWorkflowTracker_Upsert";
    private const int MaxRemarksLength = 400;
    private const int MaxLogMessageLength = 4000;

    private readonly string? _connectionString;
    private readonly bool _enabled;
    private readonly string _createdBy;
    private readonly int _commandTimeoutSeconds;
    private readonly AppLogger _log;
    private readonly DateTime _startedOn;

    public CodingValidationReportRunLogger(
        string? masterConnectionString,
        bool enabled,
        string createdBy,
        AppLogger log,
        int commandTimeoutSeconds = 60)
    {
        _connectionString = masterConnectionString;
        _createdBy = string.IsNullOrWhiteSpace(createdBy) ? "CaptureDataApp" : createdBy;
        _commandTimeoutSeconds = commandTimeoutSeconds;
        _log = log ?? throw new ArgumentNullException(nameof(log));
        _startedOn = DateTime.Now;

        _enabled = enabled && !string.IsNullOrWhiteSpace(masterConnectionString);

        if (!enabled)
            _log.Warn("  [ReportLog] Disabled via ReportRunLogging:Enabled=false.");
        else if (string.IsNullOrWhiteSpace(masterConnectionString))
            _log.Warn("  [ReportLog] ConnectionStrings:LRNMaster / DefaultConnection missing — report run logging disabled.");
    }

    public bool Enabled => _enabled;

    public void Begin(string? runId, string labName, string? sourceFileName = null)
    {
        if (!CanWrite(runId)) return;

        InsertInfoLog(runId!, labName, sourceFileName, "Start",
            $"CaptureDataApp started Coding Validation load for {labName}.");

        UpsertTracker(runId!, "InProgress",
            remarks: $"Capture started ({labName})",
            startedOn: _startedOn,
            completedOn: null);
    }

    public void StepInfo(string? runId, string labName, string stepName, string message, string? sourceFileName = null)
    {
        if (!CanWrite(runId)) return;

        InsertInfoLog(runId!, labName, sourceFileName, "Info",
            $"[{stepName}] {message}");
    }

    public void CompleteSuccess(
        string? runId,
        string labName,
        string message,
        long? rowCount = null,
        string? sourceFileName = null)
    {
        if (!CanWrite(runId)) return;

        InsertInfoLog(runId!, labName, sourceFileName, "Info", message);
        InsertInfoLog(runId!, labName, sourceFileName, "End",
            $"Coding Validation capture completed for {labName}.");

        UpsertTracker(runId!, "Success",
            remarks: Truncate(message, MaxRemarksLength),
            startedOn: _startedOn,
            completedOn: DateTime.Now,
            rowCount: rowCount);
    }

    public void Fail(string? runId, string labName, string failedStep, string errorMessage, string? sourceFileName = null)
    {
        if (!CanWrite(runId)) return;

        InsertInfoLog(runId!, labName, sourceFileName, "Error",
            Truncate($"[{failedStep}] {errorMessage}", MaxLogMessageLength));
        InsertInfoLog(runId!, labName, sourceFileName, "End",
            $"Coding Validation capture failed at {failedStep}.");

        UpsertTracker(runId!, "Failed",
            remarks: Truncate($"{failedStep}: {FirstLine(errorMessage)}", MaxRemarksLength),
            startedOn: _startedOn,
            completedOn: DateTime.Now);
    }

    private bool CanWrite(string? runId)
    {
        if (!_enabled) return false;
        if (string.IsNullOrWhiteSpace(runId))
        {
            _log.Warn("  [ReportLog] RunId blank — skipping LRNMaster log/tracker.");
            return false;
        }
        return true;
    }

    private void InsertInfoLog(
        string runId,
        string sourceSystem,
        string? sourceFileName,
        string logType,
        string logMessage)
    {
        _log.Info(
            $"  [ReportLog] EXEC {LogSpName} @RunId='{runId}', @ReportType='{ReportName}', " +
            $"@SourceSystem='{sourceSystem}', @LogType='{logType}'");

        try
        {
            using var conn = new SqlConnection(_connectionString);
            conn.Open();

            using var cmd = new SqlCommand(LogSpName, conn)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = _commandTimeoutSeconds
            };

            cmd.Parameters.Add("@RunId", SqlDbType.VarChar, 30).Value = runId.Trim();
            cmd.Parameters.Add("@ReportType", SqlDbType.VarChar, 100).Value = ReportName;
            cmd.Parameters.Add("@SourceSystem", SqlDbType.VarChar, 100).Value = Text(sourceSystem) ?? (object)DBNull.Value;
            cmd.Parameters.Add("@SourceFileName", SqlDbType.NVarChar, 400).Value = Text(sourceFileName) ?? (object)DBNull.Value;
            cmd.Parameters.Add("@LogType", SqlDbType.VarChar, 50).Value = logType;
            cmd.Parameters.Add("@LogMessage", SqlDbType.NVarChar, -1).Value = Truncate(logMessage, MaxLogMessageLength);
            cmd.Parameters.Add("@CreatedBy", SqlDbType.VarChar, 100).Value = _createdBy;

            cmd.ExecuteNonQuery();
            _log.Info($"  [ReportLog] {LogSpName} — OK ({logType}).");
        }
        catch (Exception ex)
        {
            _log.Error($"  [ReportLog] {LogSpName} — FAILED ({logType}): {ex.Message}");
        }
    }

    private void UpsertTracker(
        string runId,
        string status,
        string? remarks,
        DateTime? startedOn,
        DateTime? completedOn,
        long? rowCount = null)
    {
        _log.Info(
            $"  [ReportLog] EXEC {TrackerSpName} @RunId='{runId}', @ReportName='{ReportName}', @Status='{status}'");

        try
        {
            using var conn = new SqlConnection(_connectionString);
            conn.Open();

            using var cmd = new SqlCommand(TrackerSpName, conn)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = _commandTimeoutSeconds
            };

            cmd.Parameters.Add("@RunId", SqlDbType.VarChar, 30).Value = runId.Trim();
            cmd.Parameters.Add("@ReportName", SqlDbType.VarChar, 200).Value = ReportName;
            cmd.Parameters.Add("@Status", SqlDbType.VarChar, 50).Value = status;
            cmd.Parameters.Add("@RowCount", SqlDbType.BigInt).Value = rowCount ?? (object)DBNull.Value;
            cmd.Parameters.Add("@StartedOn", SqlDbType.DateTime2).Value = startedOn ?? (object)DBNull.Value;
            cmd.Parameters.Add("@CompletedOn", SqlDbType.DateTime2).Value = completedOn ?? (object)DBNull.Value;
            cmd.Parameters.Add("@Remarks", SqlDbType.NVarChar, -1).Value = Text(remarks) ?? (object)DBNull.Value;
            cmd.Parameters.Add("@CreatedBy", SqlDbType.VarChar, 100).Value = _createdBy;

            cmd.ExecuteNonQuery();
            _log.Info($"  [ReportLog] {TrackerSpName} — OK ({status}).");
        }
        catch (Exception ex)
        {
            _log.Error($"  [ReportLog] {TrackerSpName} — FAILED ({status}): {ex.Message}");
        }
    }

    private static string? Text(string? value)
        => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static string FirstLine(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return string.Empty;
        return value.Replace("\r", " ").Replace("\n", " ").Trim();
    }

    private static string Truncate(string value, int max)
        => string.IsNullOrEmpty(value) || value.Length <= max ? value : value[..max];
}
