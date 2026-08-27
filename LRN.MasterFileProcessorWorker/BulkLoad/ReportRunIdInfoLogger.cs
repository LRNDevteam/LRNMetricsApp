using System.Data;
using Microsoft.Data.SqlClient;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

public static class RunInfoLogType
{
    public const string Start = "Start";
    public const string Info = "Info";
    public const string Warning = "Warning";
    public const string Error = "Error";
    public const string End = "End";
}

/// <summary>
/// Cross-lab log in <c>LRNMaster.dbo.ReportRunIdInfoLog</c>.
/// <para>
/// Strictly ADDITIVE: the existing LRN_Run_Log / LRN_Step_Log / LRN_Error_Log writes are untouched
/// and still fire. This table is a second, denormalized trail keyed by RunId.
/// </para>
/// <para>
/// Every method swallows its own failures and falls back to <see cref="ILogger"/>. A logging outage
/// must never abort a data load.
/// </para>
/// </summary>
public sealed class ReportRunIdInfoLogger
{
    // Goes through the shared procedure so this worker uses the same contract as every other team.
    private const string InsertProc = "dbo.usp_ReportRunIdInfoLog_Insert";

    private readonly string _masterConnectionString;
    private readonly ILogger<ReportRunIdInfoLogger> _logger;
    private readonly string _createdBy;

    public ReportRunIdInfoLogger(IConfiguration configuration, ILogger<ReportRunIdInfoLogger> logger)
    {
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("Missing DefaultConnection connection string (LRNMaster).");

        _logger = logger;

        // CreatedBy is a NAME, not an id - the service/process identity.
        _createdBy = $"LRN.MasterFileProcessorWorker/{Environment.UserName}@{Environment.MachineName}";
    }

    public Task StartAsync(string runId, string reportType, string sourceSystem, string message, CancellationToken ct, string? sourceFileName = null) =>
        WriteAsync(runId, reportType, sourceSystem, RunInfoLogType.Start, message, ct, sourceFileName);

    public Task InfoAsync(string runId, string reportType, string sourceSystem, string message, CancellationToken ct, string? sourceFileName = null) =>
        WriteAsync(runId, reportType, sourceSystem, RunInfoLogType.Info, message, ct, sourceFileName);

    public Task WarningAsync(string runId, string reportType, string sourceSystem, string message, CancellationToken ct, string? sourceFileName = null) =>
        WriteAsync(runId, reportType, sourceSystem, RunInfoLogType.Warning, message, ct, sourceFileName);

    public Task EndAsync(string runId, string reportType, string sourceSystem, string message, CancellationToken ct, string? sourceFileName = null) =>
        WriteAsync(runId, reportType, sourceSystem, RunInfoLogType.End, message, ct, sourceFileName);

    public Task ErrorAsync(string runId, string reportType, string sourceSystem, Exception ex, CancellationToken ct, string? sourceFileName = null) =>
        WriteAsync(runId, reportType, sourceSystem, RunInfoLogType.Error, ex.ToString(), ct, sourceFileName);

    public async Task WriteAsync(
        string runId,
        string reportType,
        string sourceSystem,
        string logType,
        string? message,
        CancellationToken ct,
        string? sourceFileName = null)
    {
        if (string.IsNullOrWhiteSpace(runId))
            return;

        try
        {
            await using var conn = new SqlConnection(_masterConnectionString);
            await using var cmd = new SqlCommand(InsertProc, conn)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = 30
            };

            cmd.Parameters.Add("@RunId", SqlDbType.VarChar, 30).Value = runId;
            cmd.Parameters.Add("@ReportType", SqlDbType.VarChar, 100).Value = reportType;
            cmd.Parameters.Add("@SourceSystem", SqlDbType.VarChar, 100).Value = sourceSystem;
            cmd.Parameters.Add("@SourceFileName", SqlDbType.NVarChar, 400).Value = (object?)sourceFileName ?? DBNull.Value;
            cmd.Parameters.Add("@LogType", SqlDbType.VarChar, 50).Value = logType;
            cmd.Parameters.Add("@LogMessage", SqlDbType.NVarChar, -1).Value = (object?)message ?? DBNull.Value;
            cmd.Parameters.Add("@CreatedBy", SqlDbType.VarChar, 100).Value = _createdBy;

            await conn.OpenAsync(ct).ConfigureAwait(false);
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex,
                "ReportRunIdInfoLog write failed (RunId={RunId}, {ReportType}, {LogType}). Falling back to file/console log. Message was: {Message}",
                runId, reportType, logType, message);
        }
    }

    internal static DateTime IstNow()
    {
        try
        {
            var tz = TimeZoneInfo.FindSystemTimeZoneById(
                OperatingSystem.IsWindows() ? "India Standard Time" : "Asia/Kolkata");

            return TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, tz);
        }
        catch
        {
            return DateTime.Now;
        }
    }
}
