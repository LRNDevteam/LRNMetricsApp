using System.Data;
using Microsoft.Data.SqlClient;

namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// Writes report-run entries to the two LRNMaster stored procedures once a report
/// group has finished refreshing:
/// <list type="bullet">
///   <item><description><c>dbo.usp_ReportRunIdInfoLog_Insert</c> — the detail log.</description></item>
///   <item><description><c>dbo.usp_ReportsWorkflowTracker_Upsert</c> — the status tracker.</description></item>
/// </list>
/// <para>
/// <b>Failure policy:</b> reporting is observability, not business logic. Every call is
/// fully exception-isolated — a failure here is logged and swallowed and can never fail
/// a lab, change the exit code, or interrupt the refresh flow.
/// </para>
/// <para>
/// <b>Live troubleshooting:</b> before each call the equivalent <c>EXEC</c> statement is
/// written to the application log, so a failing call can be copied straight into SSMS
/// and replayed. This matters because these calls are only exercised in the Live
/// environment.
/// </para>
/// <para>
/// Set <c>ReportRunLogging:Enabled = false</c> in appsettings.json to switch the whole
/// feature off without a code change.
/// </para>
/// </summary>
public sealed class ReportRunLogger
{
    /// <summary>Report type names, matching the LRNMaster ReportType lookup table.</summary>
    public static class ReportTypes
    {
        public const string ProductionSummary = "Production Summary";  // ReportTypeID 12
        public const string CollectionSummary = "Collection Summary";  // ReportTypeID 4
        public const string ExecutiveSummary  = "Executive Summary";   // ReportTypeID 6
    }

    /// <summary>
    /// The tables each report type is built from. Recorded in <c>@LogMessage</c> because
    /// <c>@SourceFileName</c> can only carry one representative file — these reports are
    /// aggregates over several sources, which is also why <c>@RowCount</c> is sent as 0.
    /// </summary>
    public static string SourceTablesFor(string reportType) => reportType switch
    {
        ReportTypes.ProductionSummary => "ClaimLevel",
        ReportTypes.CollectionSummary => "ClaimLevel",
        ReportTypes.ExecutiveSummary  => "LIMSMaster, ClaimLevel, LineLevel",
        _                             => "unknown",
    };

    /// <summary>
    /// Value sent for <c>@RowCount</c>. These report types aggregate several tables, so
    /// a single row count would be misleading — 0 means "not applicable" here.
    /// </summary>
    public const int NotApplicableRowCount = 0;

    private const string LogSpName     = "dbo.usp_ReportRunIdInfoLog_Insert";
    private const string TrackerSpName = "dbo.usp_ReportsWorkflowTracker_Upsert";

    private readonly string? _masterConnectionString;
    private readonly bool    _enabled;
    private readonly string  _createdBy;
    private readonly int     _commandTimeoutSeconds;
    private readonly AppLogger _log;

    public ReportRunLogger(
        string? masterConnectionString,
        bool enabled,
        string createdBy,
        AppLogger log,
        int commandTimeoutSeconds = 60)
    {
        _masterConnectionString = masterConnectionString;
        _createdBy              = string.IsNullOrWhiteSpace(createdBy) ? "ClaimLineCSVDataCapture" : createdBy;
        _log                    = log ?? throw new ArgumentNullException(nameof(log));
        _commandTimeoutSeconds  = commandTimeoutSeconds;

        _enabled = enabled && !string.IsNullOrWhiteSpace(masterConnectionString);

        if (!enabled)
            _log.Warn($"  [ReportLog] Disabled via ReportRunLogging:Enabled=false — no LRNMaster log/tracker rows will be written.");
        else if (string.IsNullOrWhiteSpace(masterConnectionString))
            _log.Warn($"  [ReportLog] ConnectionStrings:DefaultConnection (LRNMaster) not configured — report run logging disabled.");
    }

    public bool Enabled => _enabled;

    /// <summary>
    /// Writes one detail-log row and one tracker row for a finished report group.
    /// </summary>
    /// <param name="runId">The RunId the refresh was performed for.</param>
    /// <param name="reportType">One of <see cref="ReportTypes"/>.</param>
    /// <param name="sourceSystem">
    /// The lab, using the LRNMaster-facing name (lab config
    /// <c>FetchLatestCompletedRunIDParameter</c>, e.g. "Phi Life").
    /// </param>
    /// <param name="sourceFileName">Source CSV name from <c>LineClaimFileLogs</c>, or null.</param>
    /// <param name="rowCount">
    /// Sent as <see cref="NotApplicableRowCount"/> (0) by all current callers — these
    /// report types aggregate several tables, so a single count would be misleading.
    /// Nullable so a future single-table report can pass a real count, or null.
    /// </param>
    /// <param name="success">Whether every stored procedure in the group succeeded.</param>
    /// <param name="logMessage">Detail text — SP counts, or the names of the failures.</param>
    public void Report(
        string runId,
        string reportType,
        string sourceSystem,
        string? sourceFileName,
        int? rowCount,
        bool success,
        string logMessage)
    {
        if (!_enabled) return;

        if (string.IsNullOrWhiteSpace(runId))
        {
            _log.Warn($"  [ReportLog] No RunId available for '{reportType}' / '{sourceSystem}' — skipping log and tracker.");
            return;
        }

        InsertInfoLog(runId, reportType, sourceSystem, sourceFileName,
                      success ? "Info" : "Error", logMessage);

        UpsertWorkflowTracker(runId, reportType, success ? "Success" : "Failed", rowCount);
    }

    /// <summary>EXEC dbo.usp_ReportRunIdInfoLog_Insert — never throws.</summary>
    private void InsertInfoLog(
        string runId, string reportType, string sourceSystem,
        string? sourceFileName, string logType, string logMessage)
    {
        _log.Info($"  [ReportLog] EXEC {LogSpName} " +
                  $"@RunId='{runId}', @ReportType='{reportType}', @SourceSystem='{sourceSystem}', " +
                  $"@SourceFileName={Quote(sourceFileName)}, @LogType='{logType}', " +
                  $"@LogMessage='{Escape(logMessage)}', @CreatedBy='{_createdBy}';");

        try
        {
            using var conn = new SqlConnection(_masterConnectionString);
            conn.Open();

            using var cmd = new SqlCommand(LogSpName, conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = _commandTimeoutSeconds
            };

            cmd.Parameters.AddWithValue("@RunId",          runId);
            cmd.Parameters.AddWithValue("@ReportType",     reportType);
            cmd.Parameters.AddWithValue("@SourceSystem",   sourceSystem);
            cmd.Parameters.AddWithValue("@SourceFileName", (object?)sourceFileName ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@LogType",        logType);
            cmd.Parameters.AddWithValue("@LogMessage",     Truncate(logMessage, 4000));
            cmd.Parameters.AddWithValue("@CreatedBy",      _createdBy);

            cmd.ExecuteNonQuery();
            _log.Info($"  [ReportLog] {LogSpName} — OK ({reportType} / {sourceSystem}).");
        }
        catch (Exception ex)
        {
            // Never rethrow: report logging must not affect the refresh outcome.
            _log.Error($"  [ReportLog] {LogSpName} — FAILED ({reportType} / {sourceSystem}): {ex.Message}");
        }
    }

    /// <summary>EXEC dbo.usp_ReportsWorkflowTracker_Upsert — never throws.</summary>
    private void UpsertWorkflowTracker(string runId, string reportName, string status, int? rowCount)
    {
        _log.Info($"  [ReportLog] EXEC {TrackerSpName} " +
                  $"@RunId='{runId}', @ReportName='{reportName}', @Status='{status}', " +
                  $"@RowCount={(rowCount?.ToString() ?? "NULL")}, @CreatedBy='{_createdBy}';");

        try
        {
            using var conn = new SqlConnection(_masterConnectionString);
            conn.Open();

            using var cmd = new SqlCommand(TrackerSpName, conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = _commandTimeoutSeconds
            };

            cmd.Parameters.AddWithValue("@RunId",      runId);
            cmd.Parameters.AddWithValue("@ReportName", reportName);
            cmd.Parameters.AddWithValue("@Status",     status);
            cmd.Parameters.AddWithValue("@RowCount",   (object?)rowCount ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@CreatedBy",  _createdBy);

            cmd.ExecuteNonQuery();
            _log.Info($"  [ReportLog] {TrackerSpName} — OK ({reportName} = {status}).");
        }
        catch (Exception ex)
        {
            _log.Error($"  [ReportLog] {TrackerSpName} — FAILED ({reportName}): {ex.Message}");
        }
    }

    /// <summary>
    /// Builds the @LogMessage for a group of stored procedures: the source tables the
    /// report is built from, an SP pass/fail tally, and the names of any failures.
    /// </summary>
    public static string BuildGroupMessage(
        string reportType,
        IReadOnlyCollection<(string SpName, long ElapsedMs, string? Error)> results)
    {
        var failed = results.Where(r => r.Error is not null).Select(r => r.SpName).ToList();
        var passed = results.Count - failed.Count;

        var message = $"{reportType} refreshed from {SourceTablesFor(reportType)}: " +
                      $"{passed}/{results.Count} SP(s) succeeded";

        if (failed.Count > 0)
            message += $". Failed: {string.Join(", ", failed)}";
        else
            message += ".";

        return message;
    }

    private static string Quote(string? value) => value is null ? "NULL" : $"'{Escape(value)}'";
    private static string Escape(string value) => value.Replace("'", "''");

    private static string Truncate(string value, int max)
        => string.IsNullOrEmpty(value) || value.Length <= max ? value : value[..max];
}
