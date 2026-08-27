using System.Data;
using Microsoft.Data.SqlClient;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

public static class WorkflowReportNames
{
    public const string LineLevelMaster = "Line Level Master";
    public const string ClaimLevelMaster = "Claim Level Master";

    /// <summary>
    /// The LIMS master load. Spelled exactly as dbo.ReportTypeMaster holds it - the upsert procedure
    /// resolves ReportTypeId from this name and rejects anything not in that table.
    /// </summary>
    public const string LisSummary = "LIS Summary";

    // Derived from the two masters rather than run separately - see LineClaimImportService.
    public const string ClinicSummary = "Clinic Summary";
    public const string SalesRepSummary = "Sales Rep Summary";
}

public static class WorkflowStatus
{
    public const string Success = "Success";
    public const string Failed = "Failed";
    public const string Skipped = "Skipped";
    public const string InProgress = "InProgress";
}

/// <summary>
/// Upserts <c>LRNMaster.dbo.ReportsWorkflowTracker</c>.
/// <para>
/// Stored TALL (one row per RunId + Lab + ReportName) by decision, rather than mirroring the wide
/// layout of Reports_Workflow_Tracker_v1.0.xlsx. Tall means a new report type needs no ALTER TABLE,
/// and the unique key makes the write idempotent on re-run. The workbook's wide shape is reproduced
/// by the view <c>dbo.vw_ReportsWorkflowTracker_Wide</c> created alongside the table.
/// </para>
/// </summary>
public sealed class ReportsWorkflowTrackerRepository
{
    // Goes through the shared procedure so this worker uses the same contract as every other team.
    // The procedure resolves LabId / LabName / WeekFolder from dbo.LRN_Run_Log by RunId, and
    // ReportTypeId from dbo.ReportTypeMaster by ReportName.
    private const string UpsertProc = "dbo.usp_ReportsWorkflowTracker_Upsert";

    private readonly string _masterConnectionString;
    private readonly ILogger<ReportsWorkflowTrackerRepository> _logger;
    private readonly string _createdBy;

    public ReportsWorkflowTrackerRepository(IConfiguration configuration, ILogger<ReportsWorkflowTrackerRepository> logger)
    {
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("Missing DefaultConnection connection string (LRNMaster).");

        _logger = logger;
        _createdBy = $"LRN.MasterFileProcessorWorker/{Environment.UserName}@{Environment.MachineName}";
    }

    public async Task UpsertAsync(
        string runId,
        int labId,
        string labName,
        string? weekFolder,
        string reportName,
        string? reportType,
        string status,
        long? rowCount,
        DateTime? startedOn,
        DateTime? completedOn,
        string? remarks,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(runId))
            return;

        try
        {
            await using var conn = new SqlConnection(_masterConnectionString);
            await using var cmd = new SqlCommand(UpsertProc, conn)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = 60
            };

            cmd.Parameters.Add("@RunId", SqlDbType.VarChar, 30).Value = runId;
            cmd.Parameters.Add("@ReportName", SqlDbType.VarChar, 200).Value = reportName;
            cmd.Parameters.Add("@Status", SqlDbType.VarChar, 50).Value = status;
            cmd.Parameters.Add("@RowCount", SqlDbType.BigInt).Value = (object?)rowCount ?? DBNull.Value;
            cmd.Parameters.Add("@StartedOn", SqlDbType.DateTime2).Value = (object?)startedOn ?? DBNull.Value;
            cmd.Parameters.Add("@CompletedOn", SqlDbType.DateTime2).Value = (object?)completedOn ?? DBNull.Value;
            cmd.Parameters.Add("@Remarks", SqlDbType.NVarChar, -1).Value = (object?)remarks ?? DBNull.Value;
            cmd.Parameters.Add("@CreatedBy", SqlDbType.VarChar, 100).Value = _createdBy;

            // Passed as a fallback: the procedure prefers dbo.LRN_Run_Log, and uses these only when
            // the run log has no lab context yet. LabName matters more than it looks - the workflow
            // dashboard groups labs by name, so a row that ends up with a NULL one merges with every
            // other nameless row and drops out of the one-row-per-lab views.
            cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
            cmd.Parameters.Add("@WeekFolder", SqlDbType.VarChar, 200).Value = (object?)weekFolder ?? DBNull.Value;
            cmd.Parameters.Add("@LabName", SqlDbType.VarChar, 200).Value =
                string.IsNullOrWhiteSpace(labName) ? DBNull.Value : labName;

            await conn.OpenAsync(ct).ConfigureAwait(false);
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex,
                "ReportsWorkflowTracker upsert failed (RunId={RunId}, Lab={LabId}, Report={ReportName}, Status={Status}).",
                runId, labId, reportName, status);
        }
    }
}
