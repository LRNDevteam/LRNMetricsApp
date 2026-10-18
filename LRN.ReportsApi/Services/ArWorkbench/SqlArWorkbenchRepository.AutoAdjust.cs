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

    /// <summary>
    /// Of <paramref name="claimKeys"/>, the approved write-offs assigned to <paramref name="agentUser"/>
    /// that still wait for posting. Handoff §8.3: after QA approves a write-off the agent performs it in
    /// the PMS and marks the claim complete themselves (DEF-17). System auto-adjustments stay with the
    /// Team Lead / RCM Manager / Administrator.
    /// </summary>
    public async Task<IReadOnlyList<long>> GetAgentPostableWriteOffsAsync(int labId, IReadOnlyList<long> claimKeys, string agentUser, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(@"
SELECT c.ClaimKey
FROM dbo.ARWB_Claim c
WHERE c.ClaimKey IN (SELECT k.ClaimKey FROM dbo.ARWB_tvf_ParseKeyList(@ClaimKeyList) k)
  AND c.IsWriteOffApproved = 1
  AND (c.IsPmsPostedConfirmed = 0 OR c.IsAdjustmentNotPosted = 1)
  AND c.AssignedAgentUser = @Agent;", connection) { CommandTimeout = AdjustmentTimeoutSeconds };
        cmd.Parameters.Add("@ClaimKeyList", SqlDbType.NVarChar, -1).Value = string.Join(",", claimKeys);
        cmd.Parameters.Add("@Agent", SqlDbType.NVarChar, 256).Value = agentUser;

        var keys = new List<long>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) keys.Add(r.GetInt64(0));
        return keys;
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
