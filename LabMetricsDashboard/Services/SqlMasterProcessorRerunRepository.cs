using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

public interface IMasterProcessorRerunRepository
{
    Task<MasterProcessorRerunSubmitResult> RequestAsync(
        IReadOnlyList<MasterProcessorRerunLabSelection> labs,
        MasterProcessorRerunContext context,
        CancellationToken ct);

    Task<IReadOnlyList<MasterProcessorRerunRow>> GetRecentAsync(int take, CancellationToken ct);
}

/// <summary>
/// Queues master file processor re-runs into <c>LRNMaster.dbo.MasterFileProcessorRerunRequest</c>.
///
/// <para>
/// The dashboard cannot call the worker: it is a Windows Service polling on a timer in a different
/// process, often on a different machine. So a re-run is a row. The worker claims it on its next
/// poll, runs the lab with its already-processed gates bypassed, and writes the outcome back.
/// </para>
/// <para>
/// This screen writes the queue and reads the history; it never updates a claimed row. Only the
/// worker closes a request, so the screen can never report a run as finished that is still going.
/// </para>
/// </summary>
public sealed class SqlMasterProcessorRerunRepository : IMasterProcessorRerunRepository
{
    private readonly string _connectionString;
    private readonly ILogger<SqlMasterProcessorRerunRepository> _logger;

    public SqlMasterProcessorRerunRepository(
        IConfiguration configuration, ILogger<SqlMasterProcessorRerunRepository> logger)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("DefaultConnection is not configured (LRNMaster).");
        _logger = logger;
    }

    public async Task<MasterProcessorRerunSubmitResult> RequestAsync(
        IReadOnlyList<MasterProcessorRerunLabSelection> labs,
        MasterProcessorRerunContext context,
        CancellationToken ct)
    {
        var result = new MasterProcessorRerunSubmitResult { BatchId = Guid.NewGuid() };

        // One insert per lab, each in its own statement rather than one transaction for the batch.
        // A lab that is already queued must not stop the other eleven from being queued - the
        // requester ticked them independently and expects them handled independently.
        const string sql = @"
IF EXISTS (SELECT 1 FROM dbo.MasterFileProcessorRerunRequest
           WHERE LabId = @LabId AND Status IN ('Pending', 'Claimed'))
BEGIN
    SELECT CAST(0 AS BIT) AS Queued,
           (SELECT TOP (1) Status FROM dbo.MasterFileProcessorRerunRequest
            WHERE LabId = @LabId AND Status IN ('Pending','Claimed')
            ORDER BY RerunRequestId DESC) AS ExistingStatus;
END
ELSE
BEGIN
    INSERT INTO dbo.MasterFileProcessorRerunRequest
        (BatchId, LabId, LabName, Status, RequestedBy, RequestedByRole,
         RequestedFromApp, RequestedFromHost, RequestedFromIp, RequestedFromUserAgent, Notes)
    VALUES
        (@BatchId, @LabId, @LabName, 'Pending', @RequestedBy, @RequestedByRole,
         @App, @Host, @Ip, @UserAgent, @Notes);

    SELECT CAST(1 AS BIT) AS Queued, CAST(NULL AS VARCHAR(20)) AS ExistingStatus;
END";

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);

        foreach (var lab in labs)
        {
            try
            {
                await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
                cmd.Parameters.Add("@BatchId", SqlDbType.UniqueIdentifier).Value = result.BatchId;
                cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = lab.LabId;
                cmd.Parameters.Add("@LabName", SqlDbType.VarChar, 120).Value = Clip(lab.LabName, 120);
                cmd.Parameters.Add("@RequestedBy", SqlDbType.NVarChar, 200).Value = Clip(context.RequestedBy, 200);
                cmd.Parameters.Add("@RequestedByRole", SqlDbType.NVarChar, 100).Value = Clip(context.RequestedByRole, 100);
                cmd.Parameters.Add("@App", SqlDbType.VarChar, 100).Value = Clip(context.App, 100);
                cmd.Parameters.Add("@Host", SqlDbType.NVarChar, 200).Value = Clip(context.Host, 200);
                cmd.Parameters.Add("@Ip", SqlDbType.VarChar, 64).Value = Clip(context.ClientIp, 64);
                cmd.Parameters.Add("@UserAgent", SqlDbType.NVarChar, 400).Value = Clip(context.UserAgent, 400);
                cmd.Parameters.Add("@Notes", SqlDbType.NVarChar, 1000).Value = Clip(context.Notes, 1000);

                await using var rd = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

                var queued = await rd.ReadAsync(ct).ConfigureAwait(false) && rd.GetBoolean(0);
                var existing = queued || rd.IsDBNull(1) ? null : rd.GetString(1);

                if (queued) result.Queued.Add(lab.LabName);
                else result.AlreadyQueued.Add($"{lab.LabName} ({existing ?? "in progress"})");
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Could not queue a master processor re-run for lab {LabId}.", lab.LabId);
                result.Failed.Add(lab.LabName);
            }
        }

        return result;
    }

    public async Task<IReadOnlyList<MasterProcessorRerunRow>> GetRecentAsync(int take, CancellationToken ct)
    {
        // TOP is parameterised rather than interpolated, and clamped before it gets there.
        const string sql = @"
SELECT TOP (@Take)
       RerunRequestId, BatchId, LabId, LabName, Status, RequestedBy, RequestedByRole, RequestedOn,
       RequestedFromApp, RequestedFromHost, RequestedFromIp, Notes,
       ClaimedOn, ClaimedByHost, CompletedOn, RunId, ResultStatus, ResultMessage
FROM   dbo.MasterFileProcessorRerunRequest
ORDER  BY RequestedOn DESC, RerunRequestId DESC;";

        var rows = new List<MasterProcessorRerunRow>();

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
        cmd.Parameters.Add("@Take", SqlDbType.Int).Value = Math.Clamp(take, 1, 500);

        await using var rd = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        while (await rd.ReadAsync(ct).ConfigureAwait(false))
        {
            rows.Add(new MasterProcessorRerunRow
            {
                RerunRequestId = rd.GetInt64(0),
                BatchId = rd.GetGuid(1),
                LabId = rd.GetInt32(2),
                LabName = Str(rd, 3),
                Status = Str(rd, 4),
                RequestedBy = Str(rd, 5),
                RequestedByRole = Str(rd, 6),
                RequestedOn = rd.GetDateTime(7),
                RequestedFromApp = Str(rd, 8),
                RequestedFromHost = Str(rd, 9),
                RequestedFromIp = Str(rd, 10),
                Notes = Str(rd, 11),
                ClaimedOn = rd.IsDBNull(12) ? null : rd.GetDateTime(12),
                ClaimedByHost = Str(rd, 13),
                CompletedOn = rd.IsDBNull(14) ? null : rd.GetDateTime(14),
                RunId = Str(rd, 15),
                ResultStatus = Str(rd, 16),
                ResultMessage = Str(rd, 17)
            });
        }

        return rows;
    }

    private static string? Str(SqlDataReader rd, int i) => rd.IsDBNull(i) ? null : rd.GetString(i);

    private static object Clip(string? value, int max)
    {
        if (string.IsNullOrWhiteSpace(value)) return DBNull.Value;
        var trimmed = value.Trim();
        return trimmed.Length <= max ? trimmed : trimmed[..max];
    }
}
