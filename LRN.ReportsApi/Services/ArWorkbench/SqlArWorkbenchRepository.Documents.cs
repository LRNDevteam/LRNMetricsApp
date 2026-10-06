using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Attachments (dbo.ARWB_Document): metadata here, bytes in <see cref="IArWorkbenchDocumentStore"/>.
/// Every upload and download is written to dbo.ARWB_DocumentAccessLog (HIPAA). Downloads go through
/// the claim's scope; a client (viewer) user only reaches CIP-response documents.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    /// <summary>Records the files a client attached to a CIP response (round = the case's current round).</summary>
    public async Task<IReadOnlyList<long>> AddCipResponseDocumentsAsync(int labId, long cipCaseId, IReadOnlyList<(string FileName, string? ContentType, StoredDocument Stored)> files,
        ArWorkbenchUserContext user, string? clientIp, CancellationToken ct)
    {
        var ids = new List<long>();
        if (files.Count == 0) return ids;
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        foreach (var (fileName, contentType, stored) in files)
        {
            await using var cmd = new SqlCommand(@"
INSERT INTO dbo.ARWB_Document (ClaimKey, CipCaseId, CipRoundNumber, DocumentSource, DocumentCategory, FileName, ContentType, SizeBytes,
                               BlobContainer, BlobPath, ContentSha256, UploadedBy, UploadedByRole)
SELECT c.ClaimKey, c.CipCaseId, c.RoundNumber, 'CipResponse', N'CIP Response', @Name, @Type, @Size, @Container, @Path, @Sha, @User, @Role
FROM dbo.ARWB_CipCase c WHERE c.CipCaseId = @Case;
DECLARE @Id bigint = CAST(SCOPE_IDENTITY() AS bigint);
INSERT INTO dbo.ARWB_DocumentAccessLog (DocumentId, AccessType, UserName, RoleCode, ClientIp) VALUES (@Id, 'Upload', @User, @Role, @Ip);
SELECT @Id;", connection, tx);
            cmd.Parameters.Add("@Case", SqlDbType.BigInt).Value = cipCaseId;
            cmd.Parameters.Add("@Name", SqlDbType.NVarChar, 260).Value = Truncate(fileName, 260);
            cmd.Parameters.Add("@Type", SqlDbType.NVarChar, 200).Value = (object?)contentType ?? DBNull.Value;
            cmd.Parameters.Add("@Size", SqlDbType.BigInt).Value = stored.SizeBytes;
            cmd.Parameters.Add("@Container", SqlDbType.NVarChar, 100).Value = stored.Container;
            cmd.Parameters.Add("@Path", SqlDbType.NVarChar, 1024).Value = stored.Path;
            cmd.Parameters.Add("@Sha", SqlDbType.VarChar, 64).Value = stored.Sha256;
            cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
            cmd.Parameters.Add("@Role", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
            cmd.Parameters.Add("@Ip", SqlDbType.VarChar, 64).Value = (object?)clientIp ?? DBNull.Value;
            ids.Add(Convert.ToInt64(await cmd.ExecuteScalarAsync(ct)));
        }
        await tx.CommitAsync(ct);
        return ids;
    }

    /// <summary>The CIP-response attachments of these cases.</summary>
    public async Task<Dictionary<long, List<ArWorkbenchDocumentInfo>>> GetCipDocumentsAsync(int labId, IReadOnlyCollection<long> caseIds, CancellationToken ct)
    {
        var result = new Dictionary<long, List<ArWorkbenchDocumentInfo>>();
        if (caseIds.Count == 0) return result;
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(@"
SELECT d.CipCaseId, d.DocumentId, d.FileName, d.ContentType, d.SizeBytes, d.CipRoundNumber, d.UploadedBy, d.UploadedOn
FROM dbo.ARWB_Document d
WHERE d.IsDeleted = 0 AND d.DocumentSource = 'CipResponse'
  AND d.CipCaseId IN (SELECT k.ClaimKey FROM dbo.ARWB_tvf_ParseKeyList(@Ids) k)
ORDER BY d.UploadedOn, d.DocumentId;", connection);
        cmd.Parameters.Add("@Ids", SqlDbType.NVarChar, -1).Value = string.Join(",", caseIds);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            var caseId = r.GetInt64(0);
            if (!result.TryGetValue(caseId, out var list)) result[caseId] = list = new();
            list.Add(new ArWorkbenchDocumentInfo
            {
                DocumentId = r.GetInt64(1), FileName = r.GetString(2), ContentType = Str(r, 3), SizeBytes = r.GetInt64(4),
                RoundNumber = r.IsDBNull(5) ? null : r.GetInt32(5), UploadedBy = r.GetString(6), UploadedOn = r.GetDateTime(7)
            });
        }
        return result;
    }

    /// <summary>
    /// A document the caller may download (claim scope; a client only CIP responses), with the
    /// download logged. Null when not found or not allowed.
    /// </summary>
    public async Task<(ArWorkbenchDocumentInfo Info, string Container, string Path)?> GetDocumentForDownloadAsync(int labId, long documentId,
        ArWorkbenchUserContext user, string? clientIp, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var scope = AppendScope(cmd, user);
        cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = documentId;
        cmd.Parameters.Add("@ClientOnly", SqlDbType.Bit).Value = user.RoleCode == "viewer";
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
        cmd.Parameters.Add("@Role", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
        cmd.Parameters.Add("@Ip", SqlDbType.VarChar, 64).Value = (object?)clientIp ?? DBNull.Value;
        // Log first (only when allowed), then return the row: the log never depends on the reader draining.
        cmd.CommandText = $@"
SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM dbo.ARWB_Document d INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = d.ClaimKey
           WHERE d.DocumentId = @Id AND d.IsDeleted = 0 AND (@ClientOnly = 0 OR d.DocumentSource = 'CipResponse') {scope})
BEGIN
    INSERT INTO dbo.ARWB_DocumentAccessLog (DocumentId, AccessType, UserName, RoleCode, ClientIp) VALUES (@Id, 'Download', @User, @Role, @Ip);
    SELECT d.DocumentId, d.FileName, d.ContentType, d.SizeBytes, d.CipRoundNumber, d.UploadedBy, d.UploadedOn, d.BlobContainer, d.BlobPath
    FROM dbo.ARWB_Document d WHERE d.DocumentId = @Id;
END;";
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        var info = new ArWorkbenchDocumentInfo
        {
            DocumentId = r.GetInt64(0), FileName = r.GetString(1), ContentType = Str(r, 2), SizeBytes = r.GetInt64(3),
            RoundNumber = r.IsDBNull(4) ? null : r.GetInt32(4), UploadedBy = r.GetString(5), UploadedOn = r.GetDateTime(6)
        };
        return (info, r.GetString(7), r.GetString(8));
    }

    /// <summary>The client-visible CIP cases in scope, by case number (bulk CSV response).</summary>
    public async Task<Dictionary<string, (long CipCaseId, string Status)>> GetClientCipIndexAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var scope = AppendScope(cmd, user);
        cmd.CommandText = $@"
SELECT c.CaseNumber, c.CipCaseId, c.CaseStatus
FROM dbo.ARWB_CipCase c INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = c.ClaimKey
WHERE c.CaseStatus IN ('Sent to Client', 'Client Responded', 'Returned to Agent') {scope};";
        var map = new Dictionary<string, (long, string)>(StringComparer.OrdinalIgnoreCase);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) map[r.GetString(0)] = (r.GetInt64(1), r.GetString(2));
        return map;
    }
}
