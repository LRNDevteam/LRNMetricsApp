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
    private const int ExportDetailChunk = 5000;

    public async Task<Dictionary<long, ArWorkbenchClaimExportDetail>> GetClaimExportDetailsAsync(int labId, IReadOnlyList<long> claimKeys, CancellationToken ct)
    {
        var result = new Dictionary<long, ArWorkbenchClaimExportDetail>();
        var keys = claimKeys.Where(k => k > 0).Distinct().ToList();
        if (keys.Count == 0) return result;

        await using var connection = await OpenLabAsync(labId, ct);
        var hasVerification = await TableExistsAsync(connection, "dbo.ARWB_StatusVerification", ct);

        // The keys go into #allk once by SqlBulkCopy, and each chunk reads its Seq range. Passing them
        // as a comma list through dbo.ARWB_tvf_ParseKeyList cost ~77 s per 2,000 keys on the old XML
        // splitter, which made an 84,000-claim export run for over an hour.
        await using (var create = new SqlCommand("CREATE TABLE #allk (Seq int NOT NULL PRIMARY KEY, ClaimKey bigint NOT NULL);", connection))
            await create.ExecuteNonQueryAsync(ct);
        var table = new DataTable();
        table.Columns.Add("Seq", typeof(int));
        table.Columns.Add("ClaimKey", typeof(long));
        for (var i = 0; i < keys.Count; i++) table.Rows.Add(i, keys[i]);
        using (var bulk = new SqlBulkCopy(connection) { DestinationTableName = "#allk", BulkCopyTimeout = 300, BatchSize = 10_000 })
            await bulk.WriteToServerAsync(table, ct);

        var verificationSql = hasVerification ? @"
SELECT v.ClaimKey, v.VerificationStatus, v.PreviousSourceStatus, v.NewSourceStatus, v.ManagerUser,
       v.ResolvedAction, v.ResolvedBy, v.ResolvedOn, v.ResolutionNote
FROM #k k
CROSS APPLY (SELECT TOP (1) s.* FROM dbo.ARWB_StatusVerification s WHERE s.ClaimKey = k.ClaimKey
             ORDER BY s.RaisedOn DESC, s.StatusVerificationId DESC) v;" : "";

        var sql = $@"
SET NOCOUNT ON;
CREATE TABLE #k (ClaimKey bigint NOT NULL PRIMARY KEY);
INSERT INTO #k (ClaimKey) SELECT a.ClaimKey FROM #allk a WHERE a.Seq >= @From AND a.Seq < @To;

SELECT c.ClaimKey, c.AssignedBy, c.AssignedOn,
       (SELECT COUNT(*) FROM dbo.ARWB_ClaimFollowUp x WHERE x.ClaimKey = c.ClaimKey AND x.IsSystem = 0),
       f.ClaimType, f.FollowUpType, f.FollowUpClaimStatus, f.DenialRootCause, f.FixResolution, f.FollowUpComment, f.NextFollowUpDate,
       f.CipCategory, f.CipRequiredInfo, f.CipComment, f.CreatedBy, f.CreatedByRole, f.CreatedOn,
       q.ReviewStatus, q.ReviewedBy, q.ReviewedByRole, q.ReviewedOn, q.ErrorType, q.ReviewNote,
       c.AccessionNumber, c.PatientDOB, c.SubscriberId, c.BillingProvider, c.ChargeEnteredDate, c.FirstBilledDate, c.CptSummary,
       c.Facility,
       -- Claim-level POS / TOS when the master has them, else the distinct values on the claim's lines
       COALESCE(c.POS, STUFF((SELECT DISTINCT N', ' + l.POS FROM dbo.ARWB_ClaimLine l WHERE l.ClaimKey = c.ClaimKey AND l.POS IS NOT NULL
                              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')),
       COALESCE(c.TOS, STUFF((SELECT DISTINCT N', ' + l.TOS FROM dbo.ARWB_ClaimLine l WHERE l.ClaimKey = c.ClaimKey AND l.TOS IS NOT NULL
                              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')),
       c.ICDCode, c.AllowedAmount, c.InsurancePayment, c.PatientPayment, c.TotalPayments,
       c.InsuranceAdjustments, c.PatientAdjustments, c.TotalAdjustments, c.TotalBalance, c.CheckDate, c.BillStatus,
       -- Every follow-up note, newest first, one per line: date, who, status / fix, comment
       STUFF((SELECT NCHAR(10) + CONVERT(nvarchar(10), x.CreatedOn, 101) + N' ' + x.CreatedBy + N': '
                     + x.FollowUpClaimStatus + N' / ' + x.FixResolution + ISNULL(N' - ' + x.FollowUpComment, N'')
              FROM dbo.ARWB_ClaimFollowUp x WHERE x.ClaimKey = c.ClaimKey AND x.IsSystem = 0
              ORDER BY x.CreatedOn DESC, x.FollowUpId DESC
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'')
FROM #k k
INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = k.ClaimKey
OUTER APPLY (SELECT TOP (1) * FROM dbo.ARWB_ClaimFollowUp x WHERE x.ClaimKey = c.ClaimKey AND x.IsSystem = 0
             ORDER BY x.CreatedOn DESC, x.FollowUpId DESC) f
OUTER APPLY (SELECT TOP (1) * FROM dbo.ARWB_ClaimQaReview r WHERE r.ClaimKey = c.ClaimKey AND r.IsCurrent = 1
             ORDER BY r.QaReviewId DESC) q;
{verificationSql}
DROP TABLE #k;";

        for (var from = 0; from < keys.Count; from += ExportDetailChunk)
        {
            await using var cmd = new SqlCommand(sql, connection) { CommandTimeout = 300 };
            cmd.Parameters.Add("@From", SqlDbType.Int).Value = from;
            cmd.Parameters.Add("@To", SqlDbType.Int).Value = from + ExportDetailChunk;
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
                    QaErrorType = Str(r, 21), QaComment = Str(r, 22),
                    AccessionNumber = Str(r, 23), PatientDOB = Date(r, 24), SubscriberId = Str(r, 25), BillingProvider = Str(r, 26),
                    ChargeEnteredDate = Date(r, 27), FirstBilledDate = Date(r, 28), CptSummary = Str(r, 29), Facility = Str(r, 30),
                    POS = Str(r, 31), TOS = Str(r, 32), ICDCode = Str(r, 33),
                    AllowedAmount = r.GetDecimal(34), InsurancePayment = r.GetDecimal(35), PatientPayment = r.GetDecimal(36), TotalPayments = r.GetDecimal(37),
                    InsuranceAdjustments = r.GetDecimal(38), PatientAdjustments = r.GetDecimal(39), TotalAdjustments = r.GetDecimal(40),
                    TotalBalance = r.GetDecimal(41), CheckDate = Date(r, 42), BillStatus = Str(r, 43), Notes = Str(r, 44)
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
