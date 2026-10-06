using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Automatic Adjustment (handoff 6, FR-ADJ-02..04) over the lab procedures:
///   dbo.ARWB_usp_ProcessAutoAdjustments  nullifies the insurance balance in the workbench for
///       eligible claims (IsAutoAdjustEligible: primary denial on AUTO_ADJUST_CODE, or Non-Collectible
///       when AutoAdjustIncludesNonCollectible = 1), writes the "System / Automation" activity and
///       moves them to the Auto Adjustments queue until posted in the PMS.
///   dbo.ARWB_usp_MarkAdjustmentsPosted   "Mark as Posted" once the adjustment is in the PMS.
/// Eligibility and every write live in the procedures; this only passes the claim keys.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private const int AdjustmentTimeoutSeconds = 600;

    /// <param name="claimKeys">null = every eligible claim in the lab; otherwise only these (ineligible ones are skipped).</param>
    public async Task<ArWorkbenchAdjustmentResult> ProcessAutoAdjustmentsAsync(int labId, IReadOnlyList<long>? claimKeys, bool previewOnly,
        ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand("dbo.ARWB_usp_ProcessAutoAdjustments", connection)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = AdjustmentTimeoutSeconds
        };
        cmd.Parameters.Add("@RunBy", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
        cmd.Parameters.Add("@RunByRole", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
        cmd.Parameters.Add("@ClaimKeyList", SqlDbType.NVarChar, -1).Value = claimKeys is null ? DBNull.Value : string.Join(",", claimKeys);
        cmd.Parameters.Add("@PreviewOnly", SqlDbType.Bit).Value = previewOnly;

        await using var r = await cmd.ExecuteReaderAsync(ct);
        var result = new ArWorkbenchAdjustmentResult();
        if (await r.ReadAsync(ct))
        {
            result.ClaimCount = Convert.ToInt32(r.GetValue(0));
            result.TotalAmount = Convert.ToDecimal(r.GetValue(1));
        }
        return result;
    }

    public async Task<int> MarkAdjustmentsPostedAsync(int labId, IReadOnlyList<long> claimKeys, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand("dbo.ARWB_usp_MarkAdjustmentsPosted", connection)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = AdjustmentTimeoutSeconds
        };
        cmd.Parameters.Add("@ClaimKeyList", SqlDbType.NVarChar, -1).Value = string.Join(",", claimKeys);
        cmd.Parameters.Add("@RunBy", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
        cmd.Parameters.Add("@RunByRole", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
    }
}
