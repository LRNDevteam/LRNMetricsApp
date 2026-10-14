using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace LRN.MasterFileProcessorWorker.ArWorkbench;

/// <summary>
/// Worker switches for the AR Workbench (Denial Workbench) sync that follows the line/claim bulk copy.
/// </summary>
public sealed class ArWorkbenchSyncOptions
{
    public const string SectionName = "ArWorkbenchSync";

    /// <summary>Master switch. A lab whose database has no AR Workbench installed is skipped either way.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>Empty = every lab; otherwise only these LabIds.</summary>
    public List<int> LabIds { get; set; } = new();

    /// <summary>The sync reads the whole claim-level master; a large lab can take many minutes.</summary>
    public int CommandTimeoutSeconds { get; set; } = 3600;

    /// <summary>Recorded as ARWB_RefreshRun.RunBy.</summary>
    public string RunBy { get; set; } = "MasterFileProcessor";

    public bool AppliesTo(int labId) => LabIds.Count == 0 || LabIds.Contains(labId);
}

public enum ArWorkbenchSyncStatus { Skipped, Succeeded, Failed }

public sealed record ArWorkbenchSyncOutcome(
    ArWorkbenchSyncStatus Status,
    string Message,
    int? RefreshRunId = null,
    int ClaimRows = 0,
    int StatusVerificationClaims = 0,
    int VerificationManagers = 0);

/// <summary>
/// Runs dbo.ARWB_usp_LoadClaimsFromSource in a lab database once the worker has loaded that lab's
/// latest dbo.ClaimLevelData / dbo.LineLevelData: the workbench claims, lines and queues are
/// refreshed from the new master file, and any ASSIGNED claim that is not completed or closed whose
/// claim status changed (e.g. No Response -> Paid) moves to the Status Change Verification queue
/// under one of the lab's RCM Managers, who is notified in the AR Workbench.
/// <para>
/// The managers come from LRNMaster (role "AR Workbench - RCM Manager" + dbo.UserLabs) and are passed
/// to the procedure, which spreads the claims over them, fewest pending first. With none set up the
/// claims still move, addressed to every manager of the lab.
/// </para>
/// <para>
/// Never throws: the master file is already processed and loaded by now, so a workbench failure is
/// reported as an outcome, not allowed to fail the run.
/// </para>
/// </summary>
public sealed class ArWorkbenchSyncService
{
    private const string RcmManagerRoleName = "AR Workbench - RCM Manager";

    private readonly ArWorkbenchSyncOptions _options;
    private readonly ILogger<ArWorkbenchSyncService> _logger;
    private readonly string? _masterConnectionString;

    public ArWorkbenchSyncService(IOptions<ArWorkbenchSyncOptions> options, IConfiguration configuration, ILogger<ArWorkbenchSyncService> logger)
    {
        _options = options.Value;
        _logger = logger;
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection");
    }

    public bool IsEnabledFor(int labId) => _options.Enabled && _options.AppliesTo(labId);

    public async Task<ArWorkbenchSyncOutcome> SyncLabAsync(int labId, string labConnectionString, string workerRunId, CancellationToken ct)
    {
        if (!_options.Enabled)
            return new(ArWorkbenchSyncStatus.Skipped, "ArWorkbenchSync:Enabled is false.");
        if (!_options.AppliesTo(labId))
            return new(ArWorkbenchSyncStatus.Skipped, "Lab is not in ArWorkbenchSync:LabIds.");

        try
        {
            await using var connection = new SqlConnection(labConnectionString);
            await connection.OpenAsync(ct);

            bool installed, takesManagers;
            await using (var probe = new SqlCommand(@"
SELECT CASE WHEN OBJECT_ID(N'dbo.ARWB_usp_LoadClaimsFromSource', N'P') IS NULL THEN 0 ELSE 1 END,
       (SELECT COUNT(*) FROM sys.parameters
        WHERE object_id = OBJECT_ID(N'dbo.ARWB_usp_LoadClaimsFromSource') AND name = N'@VerificationManagers');", connection))
            {
                await using var r = await probe.ExecuteReaderAsync(ct);
                await r.ReadAsync(ct);
                installed = r.GetInt32(0) == 1;
                takesManagers = r.GetInt32(1) > 0;
            }

            if (!installed)
                return new(ArWorkbenchSyncStatus.Skipped, $"AR Workbench is not installed in database '{connection.Database}'.");

            if (!takesManagers)
            {
                _logger.LogWarning(
                    "Lab {LabId}: dbo.ARWB_usp_LoadClaimsFromSource has no @VerificationManagers parameter; run the updated " +
                    "Database/LRN.ReportsApi/ArWorkbench scripts in '{Database}' to enable status change verification.", labId, connection.Database);
            }

            var managers = takesManagers ? await GetRcmManagersAsync(labId, ct) : Array.Empty<string>();

            await using var cmd = new SqlCommand("dbo.ARWB_usp_LoadClaimsFromSource", connection)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = Math.Max(60, _options.CommandTimeoutSeconds)
            };
            cmd.Parameters.Add("@RunBy", SqlDbType.NVarChar, 256).Value = _options.RunBy;
            cmd.Parameters.Add("@Note", SqlDbType.NVarChar, 1000).Value = $"Master File Processor run {workerRunId}";
            if (takesManagers)
                cmd.Parameters.Add("@VerificationManagers", SqlDbType.NVarChar, -1).Value = managers.Count == 0 ? DBNull.Value : string.Join(",", managers);

            // The procedure ends with SELECT * FROM dbo.ARWB_RefreshRun for this run.
            int? refreshRunId = null;
            int claimRows = 0, verification = 0;
            await using (var r = await cmd.ExecuteReaderAsync(ct))
            {
                do
                {
                    if (HasColumn(r, "RefreshRunId") && await r.ReadAsync(ct))
                    {
                        refreshRunId = IntOrNull(r, "RefreshRunId");
                        claimRows = IntOrNull(r, "SourceClaimRows") ?? 0;
                        verification = HasColumn(r, "ClaimsStatusVerification") ? IntOrNull(r, "ClaimsStatusVerification") ?? 0 : 0;
                    }
                } while (await r.NextResultAsync(ct));
            }

            var message = $"AR Workbench refresh #{refreshRunId}: {claimRows:N0} claims synced; " +
                          $"{verification:N0} moved to Status Change Verification" +
                          (verification > 0
                              ? managers.Count > 0 ? $" ({managers.Count} RCM Manager(s))." : " (no RCM Manager on file - sent to every manager of the lab)."
                              : ".");

            _logger.LogInformation("Lab {LabId}: {Message}", labId, message);
            return new(ArWorkbenchSyncStatus.Succeeded, message, refreshRunId, claimRows, verification, managers.Count);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (SqlException ex) when (ex.Number is 51003 or 51004)
        {
            // 51003 another sync is running for this lab; 51004 the claim-level table is empty.
            _logger.LogWarning("Lab {LabId}: AR Workbench sync skipped - {Message}", labId, ex.Message);
            return new(ArWorkbenchSyncStatus.Skipped, ex.Message);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Lab {LabId}: AR Workbench sync failed.", labId);
            return new(ArWorkbenchSyncStatus.Failed, ex.Message);
        }
    }

    /// <summary>Active users holding the RCM Manager role with access to the lab. Empty on any failure.</summary>
    private async Task<IReadOnlyList<string>> GetRcmManagersAsync(int labId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_masterConnectionString)) return Array.Empty<string>();

        const string sql = @"
IF OBJECT_ID(N'dbo.UserLabs', N'U') IS NOT NULL AND OBJECT_ID(N'dbo.UserRoles', N'U') IS NOT NULL
    SELECT DISTINCT u.UserName
    FROM dbo.LabUsers u
    INNER JOIN dbo.UserLabs ul  ON ul.LabUserID = u.LabUserID AND ul.LabId = @LabId
    INNER JOIN dbo.UserRoles ur ON ur.LabUserID = u.LabUserID
    INNER JOIN dbo.Roles r      ON r.RoleID     = ur.RoleID
    WHERE ISNULL(u.IsActive, 0) = 1
      AND ISNULL(r.IsActive, 0) = 1
      AND r.RoleName = @RoleName
    ORDER BY u.UserName;";

        try
        {
            var list = new List<string>();
            await using var master = new SqlConnection(_masterConnectionString);
            await master.OpenAsync(ct);
            await using var cmd = new SqlCommand(sql, master) { CommandTimeout = 60 };
            cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
            cmd.Parameters.Add("@RoleName", SqlDbType.NVarChar, 200).Value = RcmManagerRoleName;
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                // A comma would split one name in two inside the procedure's list.
                var name = r.IsDBNull(0) ? "" : r.GetString(0).Trim();
                if (name.Length > 0 && !name.Contains(',')) list.Add(name);
            }
            return list;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex, "Lab {LabId}: could not read the RCM Managers from LRNMaster; verifications go to every manager of the lab.", labId);
            return Array.Empty<string>();
        }
    }

    private static bool HasColumn(SqlDataReader r, string name)
    {
        for (var i = 0; i < r.FieldCount; i++)
            if (string.Equals(r.GetName(i), name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static int? IntOrNull(SqlDataReader r, string name)
    {
        var i = r.GetOrdinal(name);
        return r.IsDBNull(i) ? null : Convert.ToInt32(r.GetValue(i));
    }
}
