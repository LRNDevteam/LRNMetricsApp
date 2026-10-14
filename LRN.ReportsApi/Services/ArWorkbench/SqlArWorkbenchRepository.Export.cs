using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Claims export (Work Queue / My Work "Export"): the workflow columns read beside each claim row -
/// who assigned it, the latest follow-up note exactly as logged in the Log Follow-Up Note pop-up, the
/// QA reviewer / manager decision on it, and the latest status change verification.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private const int ExportDetailChunk = 2000;

    public async Task<Dictionary<long, ArWorkbenchClaimExportDetail>> GetClaimExportDetailsAsync(int labId, IReadOnlyList<long> claimKeys, CancellationToken ct)
    {
        var result = new Dictionary<long, ArWorkbenchClaimExportDetail>();
        var keys = claimKeys.Where(k => k > 0).Distinct().ToList();
        if (keys.Count == 0) return result;

        await using var connection = await OpenLabAsync(labId, ct);
        var hasVerification = await TableExistsAsync(connection, "dbo.ARWB_StatusVerification", ct);

        var verificationSql = hasVerification ? @"
SELECT v.ClaimKey, v.VerificationStatus, v.PreviousSourceStatus, v.NewSourceStatus, v.ManagerUser,
       v.ResolvedAction, v.ResolvedBy, v.ResolvedOn, v.ResolutionNote
FROM #k k
CROSS APPLY (SELECT TOP (1) s.* FROM dbo.ARWB_StatusVerification s WHERE s.ClaimKey = k.ClaimKey
             ORDER BY s.RaisedOn DESC, s.StatusVerificationId DESC) v;" : "";

        var sql = $@"
SET NOCOUNT ON;
CREATE TABLE #k (ClaimKey bigint NOT NULL PRIMARY KEY);
INSERT INTO #k (ClaimKey) SELECT DISTINCT k.ClaimKey FROM dbo.ARWB_tvf_ParseKeyList(@Keys) k;

SELECT c.ClaimKey, c.AssignedBy, c.AssignedOn,
       (SELECT COUNT(*) FROM dbo.ARWB_ClaimFollowUp x WHERE x.ClaimKey = c.ClaimKey AND x.IsSystem = 0),
       f.ClaimType, f.FollowUpType, f.FollowUpClaimStatus, f.DenialRootCause, f.FixResolution, f.FollowUpComment, f.NextFollowUpDate,
       f.CipCategory, f.CipRequiredInfo, f.CipComment, f.CreatedBy, f.CreatedByRole, f.CreatedOn,
       q.ReviewStatus, q.ReviewedBy, q.ReviewedByRole, q.ReviewedOn, q.ErrorType, q.ReviewNote
FROM #k k
INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = k.ClaimKey
OUTER APPLY (SELECT TOP (1) * FROM dbo.ARWB_ClaimFollowUp x WHERE x.ClaimKey = c.ClaimKey AND x.IsSystem = 0
             ORDER BY x.CreatedOn DESC, x.FollowUpId DESC) f
OUTER APPLY (SELECT TOP (1) * FROM dbo.ARWB_ClaimQaReview r WHERE r.ClaimKey = c.ClaimKey AND r.IsCurrent = 1
             ORDER BY r.QaReviewId DESC) q;
{verificationSql}
DROP TABLE #k;";

        foreach (var chunk in keys.Chunk(ExportDetailChunk))
        {
            await using var cmd = new SqlCommand(sql, connection) { CommandTimeout = 300 };
            cmd.Parameters.Add("@Keys", SqlDbType.NVarChar, -1).Value = string.Join(",", chunk);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                result[r.GetInt64(0)] = new ArWorkbenchClaimExportDetail
                {
                    AssignedBy = Str(r, 1), AssignedOn = Date(r, 2), FollowUpCount = r.GetInt32(3),
                    ClaimType = Str(r, 4), FollowUpType = Str(r, 5), FollowUpClaimStatus = Str(r, 6), DenialRootCause = Str(r, 7),
                    FixResolution = Str(r, 8), FollowUpComment = Str(r, 9), NextFollowUpDate = Date(r, 10),
                    CipCategory = Str(r, 11), CipRequiredInfo = Str(r, 12), CipComment = Str(r, 13),
                    FollowUpBy = Str(r, 14), FollowUpByRole = Str(r, 15), FollowUpOn = Date(r, 16),
                    QaStatus = Str(r, 17), QaReviewedBy = Str(r, 18), QaReviewedByRole = Str(r, 19), QaReviewedOn = Date(r, 20),
                    QaErrorType = Str(r, 21), QaComment = Str(r, 22)
                };
            }

            if (!hasVerification || !await r.NextResultAsync(ct)) continue;
            while (await r.ReadAsync(ct))
            {
                if (!result.TryGetValue(r.GetInt64(0), out var d)) continue;
                d.VerificationStatus = Str(r, 1);
                d.VerificationChange = $"{Str(r, 2) ?? "(blank)"} -> {Str(r, 3) ?? "(blank)"}";
                d.VerificationManager = Str(r, 4);
                d.VerificationAction = Str(r, 5);
                d.VerificationBy = Str(r, 6);
                d.VerificationOn = Date(r, 7);
                d.VerificationComment = Str(r, 8);
            }
        }

        // User names -> "First Last", as on screen.
        var names = await GetDisplayNamesAsync(result.Values.SelectMany(d => new[] { d.AssignedBy, d.FollowUpBy, d.QaReviewedBy, d.VerificationManager, d.VerificationBy }), ct);
        string? Name(string? u) => u is not null && names.TryGetValue(u, out var n) ? n : u;
        foreach (var d in result.Values)
        {
            d.AssignedBy = Name(d.AssignedBy);
            d.FollowUpBy = Name(d.FollowUpBy);
            d.QaReviewedBy = Name(d.QaReviewedBy);
            d.VerificationManager = Name(d.VerificationManager);
            d.VerificationBy = Name(d.VerificationBy);
        }
        return result;
    }
}
