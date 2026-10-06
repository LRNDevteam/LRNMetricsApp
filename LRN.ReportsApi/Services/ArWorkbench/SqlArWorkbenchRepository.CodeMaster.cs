using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// The central Denial Code Master (LRNMaster dbo.ARWB_DenialCodeMaster, script
/// LRNMaster_02_ARWB_DenialCodeMaster.sql) and its one link into a lab: "Apply Non-Collectible codes"
/// copies the master's flagged codes into the lab's NON_COLLECTIBLE_CODE list (which drives the
/// Non-Collectible sub-queues and auto-adjust) and recalculates the lab's claims.
/// Reads tolerate the table not being installed yet: the screen says so and claims show nothing.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private const string CodeMasterColumns = @"DenialCode, DenialDescription, ActionCategory, DenialClassification, CoverageStatus,
       ICDComplianceStatus, DenialValidity, IsNonCollectible, IsActive, CreatedOn, CreatedBy, UpdatedOn, UpdatedBy";

    public async Task<(bool Installed, IReadOnlyList<ArWorkbenchCodeMasterRow> Rows)> GetCodeMasterAsync(CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        if (!await CodeMasterInstalledAsync(master, null, ct)) return (false, []);
        await using var cmd = new SqlCommand($"SELECT {CodeMasterColumns} FROM dbo.ARWB_DenialCodeMaster;", master);
        var rows = await ReadCodeMasterRowsAsync(cmd, ct);
        return (true, rows.OrderBy(r => ArWorkbenchCodeMasterRules.SortKey(r.DenialCode), StringComparer.Ordinal).ToList());
    }

    /// <summary>The active master rows for these (normalized) codes - the claim Denial view.</summary>
    public async Task<IReadOnlyList<ArWorkbenchCodeMasterRow>> GetCodeMasterInfoAsync(IReadOnlyCollection<string> codes, CancellationToken ct)
    {
        var list = codes.Where(c => !string.IsNullOrWhiteSpace(c)).Distinct(StringComparer.OrdinalIgnoreCase).Take(200).ToList();
        if (list.Count == 0) return [];
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        if (!await CodeMasterInstalledAsync(master, null, ct)) return [];
        await using var cmd = master.CreateCommand();
        for (var i = 0; i < list.Count; i++) cmd.Parameters.Add($"@C{i}", SqlDbType.NVarChar, 50).Value = list[i];
        cmd.CommandText = $"SELECT {CodeMasterColumns} FROM dbo.ARWB_DenialCodeMaster WHERE IsActive = 1 AND DenialCode IN ({string.Join(", ", list.Select((_, i) => $"@C{i}"))});";
        return await ReadCodeMasterRowsAsync(cmd, ct);
    }

    public async Task<ArWorkbenchSaveResult> SaveCodeMasterRowAsync(ArWorkbenchCodeMasterRow row, bool isNew, string user, CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        if (!await CodeMasterInstalledAsync(master, null, ct)) return NotInstalled();
        await using var cmd = master.CreateCommand();
        cmd.CommandText = isNew
            ? @"
IF EXISTS (SELECT 1 FROM dbo.ARWB_DenialCodeMaster WITH (UPDLOCK, HOLDLOCK) WHERE DenialCode = @Code) SELECT -1;
ELSE
BEGIN
    INSERT INTO dbo.ARWB_DenialCodeMaster (DenialCode, DenialDescription, ActionCategory, DenialClassification, CoverageStatus,
        ICDComplianceStatus, DenialValidity, IsNonCollectible, IsActive, CreatedBy)
    VALUES (@Code, @Description, @Action, @Classification, @Coverage, @Icd, @Validity, @NonCollectible, @Active, @User);
    SELECT 1;
END"
            : @"
UPDATE dbo.ARWB_DenialCodeMaster
SET DenialDescription = @Description, ActionCategory = @Action, DenialClassification = @Classification, CoverageStatus = @Coverage,
    ICDComplianceStatus = @Icd, DenialValidity = @Validity, IsNonCollectible = @NonCollectible, IsActive = @Active,
    UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @User
WHERE DenialCode = @Code;
SELECT @@ROWCOUNT;";
        AddCodeMasterParameters(cmd, row, user);
        var outcome = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
        return outcome switch
        {
            -1 => ArWorkbenchSaveResult.Conflict($"Code {row.DenialCode} is already in the master. Edit that row instead."),
            0 => ArWorkbenchSaveResult.NotFound($"Code {row.DenialCode} is no longer in the master. Reload the page."),
            _ => ArWorkbenchSaveResult.Ok($"Code {row.DenialCode} {(isNew ? "added" : "saved")}.")
        };
    }

    public async Task<ArWorkbenchSaveResult> DeleteCodeMasterRowAsync(string code, CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        if (!await CodeMasterInstalledAsync(master, null, ct)) return NotInstalled();
        await using var cmd = new SqlCommand("DELETE FROM dbo.ARWB_DenialCodeMaster WHERE DenialCode = @Code;", master);
        cmd.Parameters.Add("@Code", SqlDbType.NVarChar, 50).Value = code;
        return await cmd.ExecuteNonQueryAsync(ct) > 0
            ? ArWorkbenchSaveResult.Ok($"Code {code} deleted.")
            : ArWorkbenchSaveResult.NotFound($"Code {code} is no longer in the master.");
    }

    /// <summary>Writes a merge from <see cref="ArWorkbenchCodeMasterRules.Merge"/> in one transaction.</summary>
    public async Task<ArWorkbenchSaveResult> ApplyCodeMasterImportAsync(ArWorkbenchCodeMasterMerge merge, string user, CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var tx = (SqlTransaction)await master.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        if (!await CodeMasterInstalledAsync(master, tx, ct)) { await tx.RollbackAsync(ct); return NotInstalled(); }

        foreach (var (row, isNew) in merge.Inserts.Select(r => (r, true)).Concat(merge.Updates.Select(r => (r, false))))
        {
            await using var cmd = master.CreateCommand();
            cmd.Transaction = tx;
            // An insert that meets a row added meanwhile updates it instead (and the reverse).
            cmd.CommandText = @"
UPDATE dbo.ARWB_DenialCodeMaster WITH (UPDLOCK, HOLDLOCK)
SET DenialDescription = @Description, ActionCategory = @Action, DenialClassification = @Classification, CoverageStatus = @Coverage,
    ICDComplianceStatus = @Icd, DenialValidity = @Validity, IsNonCollectible = @NonCollectible, IsActive = @Active,
    UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @User
WHERE DenialCode = @Code;
IF @@ROWCOUNT = 0
    INSERT INTO dbo.ARWB_DenialCodeMaster (DenialCode, DenialDescription, ActionCategory, DenialClassification, CoverageStatus,
        ICDComplianceStatus, DenialValidity, IsNonCollectible, IsActive, CreatedBy)
    VALUES (@Code, @Description, @Action, @Classification, @Coverage, @Icd, @Validity, @NonCollectible, @Active, @User);";
            AddCodeMasterParameters(cmd, row, user);
            await cmd.ExecuteNonQueryAsync(ct);
        }
        await tx.CommitAsync(ct);
        return ArWorkbenchSaveResult.Ok("Imported.");
    }

    /// <summary>The lab's active NON_COLLECTIBLE_CODE values.</summary>
    public async Task<IReadOnlyList<string>> GetLabNonCollectibleCodesAsync(int labId, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand("SELECT ItemValue FROM dbo.ARWB_MasterListItem WHERE ListType = 'NON_COLLECTIBLE_CODE' AND IsActive = 1;", connection);
        var codes = new List<string>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) codes.Add(r.GetString(0));
        return codes;
    }

    /// <summary>
    /// Makes the lab's NON_COLLECTIBLE_CODE list match the master: adds (or re-activates) the
    /// master's codes, deactivates the others (kept, not deleted), refreshes the line flags, then
    /// recalculates every claim so IsNonCollectible, HasNonCollectibleDenial and the queues follow.
    /// </summary>
    public async Task<(int Recalculated, int Flagged)> ApplyNonCollectibleCodesAsync(int labId, IReadOnlyList<string> toAdd, IReadOnlyList<string> toDeactivate,
        string user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using (var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct))
        {
            foreach (var code in toAdd)
            {
                await using var add = new SqlCommand(@"
UPDATE dbo.ARWB_MasterListItem WITH (UPDLOCK, HOLDLOCK)
SET IsActive = 1, UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @User
WHERE ListType = 'NON_COLLECTIBLE_CODE' AND ItemValue = @Code;
IF @@ROWCOUNT = 0
    INSERT INTO dbo.ARWB_MasterListItem (ListType, ItemValue, SortOrder, IsActive, CreatedBy)
    SELECT 'NON_COLLECTIBLE_CODE', @Code,
           ISNULL((SELECT MAX(SortOrder) FROM dbo.ARWB_MasterListItem WHERE ListType = 'NON_COLLECTIBLE_CODE'), 0) + 1, 1, @User;", connection, tx);
                add.Parameters.Add("@Code", SqlDbType.NVarChar, 400).Value = code;
                add.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user, 256);
                await add.ExecuteNonQueryAsync(ct);
            }
            foreach (var code in toDeactivate)
            {
                await using var off = new SqlCommand(@"
UPDATE dbo.ARWB_MasterListItem SET IsActive = 0, UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @User
WHERE ListType = 'NON_COLLECTIBLE_CODE' AND ItemValue = @Code AND IsActive = 1;", connection, tx);
                off.Parameters.Add("@Code", SqlDbType.NVarChar, 400).Value = code;
                off.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user, 256);
                await off.ExecuteNonQueryAsync(ct);
            }
            await using (var lines = new SqlCommand(@"
UPDATE ld
SET ld.IsNonCollectible = CASE WHEN nc.ItemValue IS NOT NULL THEN 1 ELSE 0 END
FROM dbo.ARWB_ClaimLineDenial ld
LEFT JOIN dbo.ARWB_MasterListItem nc ON nc.ListType = 'NON_COLLECTIBLE_CODE' AND nc.IsActive = 1 AND nc.ItemValue = ld.DenialCode
WHERE ld.IsNonCollectible <> CASE WHEN nc.ItemValue IS NOT NULL THEN 1 ELSE 0 END;", connection, tx) { CommandTimeout = AdjustmentTimeoutSeconds })
                await lines.ExecuteNonQueryAsync(ct);
            await tx.CommitAsync(ct);
        }

        int recalculated;
        await using (var recalc = new SqlCommand("dbo.ARWB_usp_RecalculateClaimState", connection)
                     { CommandType = CommandType.StoredProcedure, CommandTimeout = AdjustmentTimeoutSeconds })
            recalculated = Convert.ToInt32(await recalc.ExecuteScalarAsync(ct));

        await using var count = new SqlCommand(
            "SELECT COUNT(*) FROM dbo.ARWB_Claim WHERE HasNonCollectibleDenial = 1 AND IsInCurrentSource = 1;", connection);
        return (recalculated, Convert.ToInt32(await count.ExecuteScalarAsync(ct)));
    }

    private static async Task<bool> CodeMasterInstalledAsync(SqlConnection master, SqlTransaction? tx, CancellationToken ct)
    {
        await using var probe = new SqlCommand("SELECT OBJECT_ID(N'dbo.ARWB_DenialCodeMaster', N'U');", master, tx);
        return await probe.ExecuteScalarAsync(ct) is not (null or DBNull);
    }

    private static ArWorkbenchSaveResult NotInstalled() =>
        ArWorkbenchSaveResult.Invalid("The Denial Code master is not installed. Run LRN.ReportsApi/Sql/ArWorkbench/LRNMaster_02_ARWB_DenialCodeMaster.sql in LRNMaster.");

    private static void AddCodeMasterParameters(SqlCommand cmd, ArWorkbenchCodeMasterRow row, string user)
    {
        static object Db(string? v) => (object?)v ?? DBNull.Value;
        cmd.Parameters.Add("@Code", SqlDbType.NVarChar, 50).Value = row.DenialCode;
        cmd.Parameters.Add("@Description", SqlDbType.NVarChar, ArWorkbenchCodeMasterRules.DescriptionMax).Value = Db(row.DenialDescription);
        cmd.Parameters.Add("@Action", SqlDbType.NVarChar, ArWorkbenchCodeMasterRules.ActionCategoryMax).Value = Db(row.ActionCategory);
        cmd.Parameters.Add("@Classification", SqlDbType.NVarChar, 100).Value = Db(row.DenialClassification);
        cmd.Parameters.Add("@Coverage", SqlDbType.NVarChar, 100).Value = Db(row.CoverageStatus);
        cmd.Parameters.Add("@Icd", SqlDbType.NVarChar, 100).Value = Db(row.ICDComplianceStatus);
        cmd.Parameters.Add("@Validity", SqlDbType.NVarChar, 100).Value = Db(row.DenialValidity);
        cmd.Parameters.Add("@NonCollectible", SqlDbType.Bit).Value = row.IsNonCollectible;
        cmd.Parameters.Add("@Active", SqlDbType.Bit).Value = row.IsActive;
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user, 256);
    }

    private static async Task<List<ArWorkbenchCodeMasterRow>> ReadCodeMasterRowsAsync(SqlCommand cmd, CancellationToken ct)
    {
        static string? S(SqlDataReader r, int i) => r.IsDBNull(i) ? null : r.GetString(i);
        var rows = new List<ArWorkbenchCodeMasterRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new ArWorkbenchCodeMasterRow
            {
                DenialCode = r.GetString(0), DenialDescription = S(r, 1), ActionCategory = S(r, 2), DenialClassification = S(r, 3),
                CoverageStatus = S(r, 4), ICDComplianceStatus = S(r, 5), DenialValidity = S(r, 6),
                IsNonCollectible = r.GetBoolean(7), IsActive = r.GetBoolean(8),
                CreatedOn = r.IsDBNull(9) ? null : r.GetDateTime(9), CreatedBy = S(r, 10),
                UpdatedOn = r.IsDBNull(11) ? null : r.GetDateTime(11), UpdatedBy = S(r, 12)
            });
        }
        return rows;
    }
}
