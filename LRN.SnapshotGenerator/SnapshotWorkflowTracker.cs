using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace LRN.SnapshotGenerator;

/// <summary>
/// One <c>LRNMaster.dbo.ReportsWorkflowTracker</c> row per lab + RunId for this service -
/// ReportName <c>ReportSnapshot:TrackerReportName</c> ("Report Snapshot") - so the snapshot of a run
/// shows beside its other reports: Success / Failed, the files written, and which reports it holds.
/// Written through dbo.usp_ReportsWorkflowTracker_Upsert like every other worker; the name must be an
/// active row of dbo.ReportTypeMaster (Database/LRN.MasterFileProcessorWorker/ReportTypeMaster_ReportSnapshot.sql).
/// A tracker failure is logged, never fails the snapshot.
/// </summary>
public sealed class SnapshotWorkflowTracker
{
    private readonly string _masterConnectionString;
    private readonly string _reportName;
    private readonly string _createdBy = $"LRN.SnapshotGenerator/{Environment.UserName}@{Environment.MachineName}";
    private readonly ILogger<SnapshotWorkflowTracker> _logger;

    public SnapshotWorkflowTracker(IConfiguration configuration, IOptions<ReportSnapshotOptions> options, ILogger<SnapshotWorkflowTracker> logger)
    {
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection") ?? "";
        _reportName = options.Value.TrackerReportName?.Trim() ?? "";
        _logger = logger;
    }

    /// <param name="reportCodes">The report snapshots the run now holds (from the index).</param>
    /// <param name="lastEvent">What just happened, e.g. "LISSUMMARY captured: 12 file(s)" or the failure.</param>
    public async Task WriteAsync(string runId, int labId, string labName, string? weekFolder, bool failed,
        int files, IReadOnlyList<string> reportCodes, string lastEvent, CancellationToken ct)
    {
        // Disabled (TrackerReportName empty), or the run log has no RunId to attach to.
        if (_reportName.Length == 0 || string.IsNullOrWhiteSpace(_masterConnectionString) || string.IsNullOrWhiteSpace(runId)) return;

        var remarks = (reportCodes.Count > 0 ? $"Snapshots: {string.Join(", ", reportCodes)}. " : "No report snapshot yet. ")
                      + $"Last: {lastEvent}";
        try
        {
            await using var conn = new SqlConnection(_masterConnectionString);
            await using var cmd = new SqlCommand("dbo.usp_ReportsWorkflowTracker_Upsert", conn)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = 60
            };
            cmd.Parameters.Add("@RunId", SqlDbType.VarChar, 30).Value = runId;
            cmd.Parameters.Add("@ReportName", SqlDbType.VarChar, 200).Value = _reportName;
            cmd.Parameters.Add("@Status", SqlDbType.VarChar, 50).Value = failed ? "Failed" : "Success";
            cmd.Parameters.Add("@RowCount", SqlDbType.BigInt).Value = files;
            cmd.Parameters.Add("@StartedOn", SqlDbType.DateTime2).Value = DBNull.Value;
            cmd.Parameters.Add("@CompletedOn", SqlDbType.DateTime2).Value = DateTime.Now;
            cmd.Parameters.Add("@Remarks", SqlDbType.NVarChar, -1).Value = remarks;
            cmd.Parameters.Add("@CreatedBy", SqlDbType.VarChar, 100).Value = _createdBy.Length > 100 ? _createdBy[..100] : _createdBy;
            cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
            cmd.Parameters.Add("@WeekFolder", SqlDbType.VarChar, 200).Value = (object?)weekFolder ?? DBNull.Value;
            cmd.Parameters.Add("@LabName", SqlDbType.VarChar, 200).Value = string.IsNullOrWhiteSpace(labName) ? DBNull.Value : labName;
            await conn.OpenAsync(ct);
            await cmd.ExecuteNonQueryAsync(ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            _logger.LogWarning(ex, "ReportsWorkflowTracker '{Report}' row could not be written for run {RunId} (lab {LabId}). " +
                "Is '{Report}' an active row of dbo.ReportTypeMaster?", _reportName, runId, labId, _reportName);
        }
    }
}
