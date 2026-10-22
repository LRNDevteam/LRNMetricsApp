using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// T068 Client Management: per-client (lab) cards and activation. Activation lives in LRNMaster
/// dbo.ARWB_ClientSetting (script LRNMaster_03); no row, or no table yet, means active. The
/// inactive set is cached briefly because every AR Workbench request checks it.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private static readonly object InactiveCacheLock = new();
    private static (DateTime At, HashSet<int> Labs)? _inactiveCache;
    private static readonly TimeSpan InactiveCacheTtl = TimeSpan.FromSeconds(60);

    public async Task<IReadOnlySet<int>> GetInactiveClientLabIdsAsync(CancellationToken ct)
    {
        lock (InactiveCacheLock)
        {
            if (_inactiveCache is { } c && DateTime.UtcNow - c.At < InactiveCacheTtl) return c.Labs;
        }
        var labs = new HashSet<int>();
        await using (var master = new SqlConnection(_masterConnectionString))
        {
            await master.OpenAsync(ct);
            await using var cmd = new SqlCommand(@"
IF OBJECT_ID(N'dbo.ARWB_ClientSetting', N'U') IS NOT NULL
    SELECT LabId FROM dbo.ARWB_ClientSetting WHERE IsActive = 0;", master);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct)) labs.Add(r.GetInt32(0));
        }
        lock (InactiveCacheLock) _inactiveCache = (DateTime.UtcNow, labs);
        return labs;
    }

    public async Task<Dictionary<int, ArWorkbenchClientStatus>> GetClientStatusesAsync(CancellationToken ct)
    {
        var map = new Dictionary<int, ArWorkbenchClientStatus>();
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        // The configuration columns (FR-CM-03) come with the re-run of LRNMaster_03; until then they read as blank.
        await using var cmd = new SqlCommand(@"
IF OBJECT_ID(N'dbo.ARWB_ClientSetting', N'U') IS NULL RETURN;
IF COL_LENGTH(N'dbo.ARWB_ClientSetting', N'ConfigUpdatedOn') IS NOT NULL
    EXEC (N'SELECT LabId, IsActive, StatusNote, ChangedBy, ChangedOn, SharePointFolder, OnboardingStatus, AccountManager, ConfigUpdatedBy, ConfigUpdatedOn FROM dbo.ARWB_ClientSetting;');
ELSE
    SELECT LabId, IsActive, StatusNote, ChangedBy, ChangedOn, CAST(NULL AS nvarchar(1000)), CAST(NULL AS varchar(30)), CAST(NULL AS nvarchar(256)),
           CAST(NULL AS nvarchar(256)), CAST(NULL AS datetime2(0))
    FROM dbo.ARWB_ClientSetting;", master);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            map[r.GetInt32(0)] = new ArWorkbenchClientStatus
            {
                IsActive = r.GetBoolean(1), StatusNote = Str(r, 2), ChangedBy = r.GetString(3), ChangedOn = r.GetDateTime(4),
                Config = new ArWorkbenchClientConfig
                {
                    SharePointFolder = Str(r, 5), OnboardingStatus = Str(r, 6), AccountManager = Str(r, 7),
                    UpdatedBy = Str(r, 8), UpdatedOn = r.IsDBNull(9) ? null : r.GetDateTime(9)
                }
            };
        return map;
    }

    /// <summary>FR-CM-03: saves one client's configuration; a lab with no row yet gets one (active). History keeps every change.</summary>
    public async Task<ArWorkbenchSaveResult> SetClientConfigAsync(int labId, ArWorkbenchClientConfig config, string user, CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand(@"
IF OBJECT_ID(N'dbo.ARWB_ClientSetting', N'U') IS NULL OR COL_LENGTH(N'dbo.ARWB_ClientSetting', N'ConfigUpdatedOn') IS NULL BEGIN SELECT 0; RETURN; END;
EXEC sp_executesql N'
MERGE dbo.ARWB_ClientSetting WITH (HOLDLOCK) AS t
USING (SELECT @Lab AS LabId) AS s ON t.LabId = s.LabId
WHEN MATCHED THEN UPDATE SET SharePointFolder = @Folder, OnboardingStatus = @Status, AccountManager = @Manager,
                             ConfigUpdatedBy = @User, ConfigUpdatedOn = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (LabId, IsActive, ChangedBy, SharePointFolder, OnboardingStatus, AccountManager, ConfigUpdatedBy, ConfigUpdatedOn)
                      VALUES (@Lab, 1, @User, @Folder, @Status, @Manager, @User, SYSUTCDATETIME());
INSERT INTO dbo.ARWB_ClientSettingHistory (LabId, IsActive, StatusNote, ChangedBy, SharePointFolder, OnboardingStatus, AccountManager)
SELECT LabId, IsActive, N''Configuration updated'', @User, SharePointFolder, OnboardingStatus, AccountManager FROM dbo.ARWB_ClientSetting WHERE LabId = @Lab;',
    N'@Lab int, @Folder nvarchar(1000), @Status varchar(30), @Manager nvarchar(256), @User nvarchar(256)',
    @Lab, @Folder, @Status, @Manager, @User;
SELECT 1;", master);
        cmd.Parameters.Add("@Lab", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@Folder", SqlDbType.NVarChar, 1000).Value = (object?)config.SharePointFolder ?? DBNull.Value;
        cmd.Parameters.Add("@Status", SqlDbType.VarChar, 30).Value = (object?)config.OnboardingStatus ?? DBNull.Value;
        cmd.Parameters.Add("@Manager", SqlDbType.NVarChar, 256).Value = (object?)config.AccountManager ?? DBNull.Value;
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user, 256);
        if (Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) != 1)
            return ArWorkbenchSaveResult.Invalid("Client configuration is not installed. Re-run Database/LRN.ReportsApi/ArWorkbench/LRNMaster/LRNMaster_03_ARWB_ClientSetting.sql in LRNMaster.");
        return ArWorkbenchSaveResult.Ok("Client configuration saved.");
    }

    public async Task<ArWorkbenchSaveResult> SetClientActiveAsync(int labId, bool isActive, string? note, string user, CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand(@"
IF OBJECT_ID(N'dbo.ARWB_ClientSetting', N'U') IS NULL BEGIN SELECT 0; RETURN; END;
MERGE dbo.ARWB_ClientSetting WITH (HOLDLOCK) AS t
USING (SELECT @Lab AS LabId) AS s ON t.LabId = s.LabId
WHEN MATCHED THEN UPDATE SET IsActive = @Active, StatusNote = @Note, ChangedBy = @User, ChangedOn = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (LabId, IsActive, StatusNote, ChangedBy) VALUES (@Lab, @Active, @Note, @User);
INSERT INTO dbo.ARWB_ClientSettingHistory (LabId, IsActive, StatusNote, ChangedBy) VALUES (@Lab, @Active, @Note, @User);
SELECT 1;", master);
        cmd.Parameters.Add("@Lab", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@Active", SqlDbType.Bit).Value = isActive;
        cmd.Parameters.Add("@Note", SqlDbType.NVarChar, 500).Value = (object?)note ?? DBNull.Value;
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user, 256);
        if (Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) != 1)
            return ArWorkbenchSaveResult.Invalid("Client activation is not installed. Run Database/LRN.ReportsApi/ArWorkbench/LRNMaster/LRNMaster_03_ARWB_ClientSetting.sql in LRNMaster.");
        lock (InactiveCacheLock) _inactiveCache = null;
        return ArWorkbenchSaveResult.Ok(isActive ? "Client reactivated." : "Client deactivated.");
    }

    /// <summary>One client's card figures from its lab database; null when the AR Workbench is not set up there.</summary>
    public async Task<ArWorkbenchClientStats?> GetClientStatsAsync(int labId, CancellationToken ct)
    {
        SqlConnection connection;
        try { connection = await OpenLabAsync(labId, ct); }
        catch (InvalidOperationException) { return null; }
        catch (SqlException) { return null; }
        await using (connection)
        {
            await using var cmd = new SqlCommand(@"
SELECT
    EligibleClaims   = SUM(CASE WHEN c.IsOpenInsuranceAR = 1 THEN 1 ELSE 0 END),
    ClaimsInSource   = COUNT(*),
    OutstandingAR    = ISNULL(SUM(c.RemainingAR), 0),
    Recovered        = ISNULL(SUM(c.RecoveredAmount), 0),
    Assigned         = SUM(CASE WHEN c.AssignedAgentUser IS NOT NULL AND c.IsOpenInsuranceAR = 1 THEN 1 ELSE 0 END),
    AwaitingQa       = SUM(CASE WHEN c.WorkflowStatus = 'Submitted for QA' THEN 1 ELSE 0 END)
FROM dbo.ARWB_Claim c
WHERE c.IsInCurrentSource = 1;

SELECT TOP (1) CompletedOn FROM dbo.ARWB_RefreshRun WHERE RunStatus = 'Succeeded' ORDER BY RefreshRunId DESC;", connection) { CommandTimeout = 120 };
            await using var r = await cmd.ExecuteReaderAsync(ct);
            var stats = new ArWorkbenchClientStats();
            if (await r.ReadAsync(ct))
            {
                static int I(SqlDataReader x, int i) => x.IsDBNull(i) ? 0 : x.GetInt32(i);
                stats.EligibleClaims = I(r, 0); stats.ClaimsInSource = I(r, 1);
                stats.OutstandingAR = r.GetDecimal(2); stats.Recovered = r.GetDecimal(3);
                stats.AssignedClaims = I(r, 4); stats.AwaitingQa = I(r, 5);
            }
            await r.NextResultAsync(ct);
            if (await r.ReadAsync(ct) && !r.IsDBNull(0)) stats.LastRefreshOn = r.GetDateTime(0);
            return stats;
        }
    }
}
