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

            // The reporting team's denial category / Non-Collectible masters drive this sync's categories.
            await CopyReportingDenialMastersAsync(connection, labId, ct);

            // The fee schedule (Fees Schedule Import) prices the denied lines -> Revenue Expectation.
            var feeScheduleNote = await CopyFeeScheduleAsync(connection, labId, ct);

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
                              : ".") +
                          (feeScheduleNote is null ? "" : " " + feeScheduleNote);

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

    /// <summary>
    /// LRNMaster.dbo.DenialCategoryMaster and dbo.NonCollectibleDenialMaster (the reporting team's
    /// masters, maintained on the LRN Metrics Denial Category Master screen) -> the lab's
    /// dbo.ARWB_ReportingDenialMaster, which the sync applies to every claim. Same copy as the API's
    /// Data Processing > Run. A failure is logged and the sync continues with the previous copy.
    /// </summary>
    private async Task CopyReportingDenialMastersAsync(SqlConnection lab, int labId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_masterConnectionString)) return;

        try
        {
            await using (var probe = new SqlCommand("SELECT OBJECT_ID(N'dbo.ARWB_ReportingDenialMaster', N'U');", lab))
                if (await probe.ExecuteScalarAsync(ct) is null or DBNull) return;   // lab scripts not updated yet

            var rows = new DataTable();
            rows.Columns.Add("MasterKind", typeof(string));
            rows.Columns.Add("DenialCode", typeof(string));
            rows.Columns.Add("Description", typeof(string));
            rows.Columns.Add("ActionCategory", typeof(string));

            const string sql = @"
IF OBJECT_ID(N'dbo.DenialCategoryMaster', N'U') IS NOT NULL
    SELECT 'Category', DenialCode, Description, ActionCategory FROM dbo.DenialCategoryMaster
    WHERE NULLIF(LTRIM(RTRIM(DenialCode)), N'') IS NOT NULL;
ELSE
    SELECT CAST(NULL AS varchar(20)), CAST(NULL AS nvarchar(50)), CAST(NULL AS nvarchar(1000)), CAST(NULL AS nvarchar(300)) WHERE 1 = 0;
IF OBJECT_ID(N'dbo.NonCollectibleDenialMaster', N'U') IS NOT NULL
    SELECT 'NonCollectible', DenialCode, Description, CAST(NULL AS nvarchar(300)) FROM dbo.NonCollectibleDenialMaster
    WHERE NULLIF(LTRIM(RTRIM(DenialCode)), N'') IS NOT NULL;";

            await using (var master = new SqlConnection(_masterConnectionString))
            {
                await master.OpenAsync(ct);
                await using var cmd = new SqlCommand(sql, master) { CommandTimeout = 120 };
                await using var r = await cmd.ExecuteReaderAsync(ct);
                do
                {
                    while (await r.ReadAsync(ct))
                        rows.Rows.Add(r.GetString(0), r.GetString(1).Trim(), r.IsDBNull(2) ? null : r.GetString(2), r.IsDBNull(3) ? null : r.GetString(3));
                } while (await r.NextResultAsync(ct));
            }

            await using var tx = (SqlTransaction)await lab.BeginTransactionAsync(ct);
            await using (var clear = new SqlCommand("DELETE FROM dbo.ARWB_ReportingDenialMaster;", lab, tx))
                await clear.ExecuteNonQueryAsync(ct);
            if (rows.Rows.Count > 0)
            {
                using var bulk = new SqlBulkCopy(lab, SqlBulkCopyOptions.Default, tx) { DestinationTableName = "dbo.ARWB_ReportingDenialMaster", BulkCopyTimeout = 120 };
                foreach (DataColumn c in rows.Columns) bulk.ColumnMappings.Add(c.ColumnName, c.ColumnName);
                await bulk.WriteToServerAsync(rows, ct);
            }
            await tx.CommitAsync(ct);
            _logger.LogInformation("Lab {LabId}: {Rows} reporting denial master row(s) copied for the AR Workbench sync.", labId, rows.Rows.Count);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex, "Lab {LabId}: could not copy the reporting denial masters; the sync uses the previous copy.", labId);
        }
    }

    /// <summary>
    /// LRNMaster.dbo.FeeSchedule (LRN Metrics > Master Values > Fees Schedule Import) -> the lab's
    /// dbo.ARWB_CptFeeSchedule, the rates dbo.ARWB_usp_PriceClaimLines prices claim lines with. When the
    /// rates changed, EVERY line is re-priced now, because the sync only prices the lines it reloads;
    /// the sync's claim-state recalculation then rolls the new line values into each claim's Revenue
    /// Expectation and Recovery Status. Returns a note for the run log, or null when nothing changed.
    /// A failure is logged and the sync continues with the previous rates. Same copy as the API's
    /// Data Processing > Run.
    /// </summary>
    private async Task<string?> CopyFeeScheduleAsync(SqlConnection lab, int labId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_masterConnectionString)) return null;

        try
        {
            await using (var probe = new SqlCommand("SELECT OBJECT_ID(N'dbo.ARWB_CptFeeSchedule', N'U');", lab))
                if (await probe.ExecuteScalarAsync(ct) is null or DBNull) return null;

            var master = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
            string? source = null;
            await using (var conn = new SqlConnection(_masterConnectionString))
            {
                await conn.OpenAsync(ct);
                await using var cmd = new SqlCommand(@"
IF OBJECT_ID(N'dbo.FeeSchedule', N'U') IS NOT NULL
    SELECT HCPCS, Rate, SourceFile FROM dbo.FeeSchedule WHERE NULLIF(LTRIM(RTRIM(HCPCS)), N'') IS NOT NULL;", conn) { CommandTimeout = 120 };
                await using var r = await cmd.ExecuteReaderAsync(ct);
                while (await r.ReadAsync(ct))
                {
                    master[r.GetString(0).Trim()] = r.GetDecimal(1);
                    source ??= r.IsDBNull(2) ? null : r.GetString(2);
                }
            }

            // No schedule imported yet: leave whatever the lab has.
            if (master.Count == 0) return null;

            var current = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
            await using (var cmd = new SqlCommand("SELECT CPTCode, Rate FROM dbo.ARWB_CptFeeSchedule WHERE Modifier IS NULL;", lab) { CommandTimeout = 120 })
            await using (var r = await cmd.ExecuteReaderAsync(ct))
                while (await r.ReadAsync(ct)) current[r.GetString(0).Trim()] = r.GetDecimal(1);

            if (current.Count == master.Count && master.All(kv => current.TryGetValue(kv.Key, out var rate) && rate == kv.Value))
                return null;

            var rows = new DataTable();
            rows.Columns.Add("CPTCode", typeof(string));
            rows.Columns.Add("Rate", typeof(decimal));
            rows.Columns.Add("EffectiveFrom", typeof(DateTime));
            rows.Columns.Add("RateSource", typeof(string));
            rows.Columns.Add("UpdatedOn", typeof(DateTime));
            rows.Columns.Add("UpdatedBy", typeof(string));
            var now = DateTime.UtcNow;
            var rateSource = "Fees Schedule Import" + (string.IsNullOrWhiteSpace(source) ? "" : ": " + source);
            if (rateSource.Length > 100) rateSource = rateSource[..100];
            // Effective from 1900: the schedule prices every date of service (a 2025 claim still needs a rate).
            foreach (var kv in master)
                rows.Rows.Add(kv.Key, kv.Value, new DateTime(1900, 1, 1), rateSource, now, _options.RunBy);

            await using (var tx = (SqlTransaction)await lab.BeginTransactionAsync(ct))
            {
                await using (var clear = new SqlCommand("DELETE FROM dbo.ARWB_CptFeeSchedule;", lab, tx) { CommandTimeout = 120 })
                    await clear.ExecuteNonQueryAsync(ct);
                using (var bulk = new SqlBulkCopy(lab, SqlBulkCopyOptions.Default, tx) { DestinationTableName = "dbo.ARWB_CptFeeSchedule", BulkCopyTimeout = 120 })
                {
                    foreach (DataColumn c in rows.Columns) bulk.ColumnMappings.Add(c.ColumnName, c.ColumnName);
                    await bulk.WriteToServerAsync(rows, ct);
                }
                await tx.CommitAsync(ct);
            }

            int priced = 0;
            await using (var price = new SqlCommand("dbo.ARWB_usp_PriceClaimLines", lab)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = Math.Max(60, _options.CommandTimeoutSeconds)
            })
            {
                if (await price.ExecuteScalarAsync(ct) is { } value and not DBNull) priced = Convert.ToInt32(value);
            }

            var note = $"Fee schedule updated: {master.Count:N0} rate(s), {priced:N0} claim line(s) re-priced.";
            _logger.LogInformation("Lab {LabId}: {Note}", labId, note);
            return note;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex, "Lab {LabId}: could not copy the fee schedule; the sync uses the previous rates.", labId);
            return "Fee schedule NOT updated (see the worker log); previous rates kept.";
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
