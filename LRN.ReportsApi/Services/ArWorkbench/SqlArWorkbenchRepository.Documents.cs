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
    /// <summary>
    /// The upload's Document Type dropdown: active rows of LRNMaster dbo.ARDocumentTypeMaster (script
    /// LRNMaster_04_ARDocumentTypeMaster.sql), by category then name. Empty when the table is not installed.
    /// </summary>
    public async Task<IReadOnlyList<ArWorkbenchDocumentType>> GetDocumentTypesAsync(CancellationToken ct)
    {
        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand(@"
IF OBJECT_ID(N'dbo.ARDocumentTypeMaster', N'U') IS NOT NULL
    SELECT DocumentTypeID, DocumentCategory, DocumentTypeCode, DocumentTypeName
    FROM dbo.ARDocumentTypeMaster
    WHERE IsActive = 1
    ORDER BY DocumentCategory, DocumentTypeName;", master);
        var types = new List<ArWorkbenchDocumentType>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            types.Add(new ArWorkbenchDocumentType { DocumentTypeId = r.GetInt32(0), DocumentCategory = r.GetString(1), DocumentTypeCode = r.GetString(2), DocumentTypeName = r.GetString(3) });
        return types;
    }

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

    /// <summary>
    /// Follow-up attachments (handoff §8.2, DEF-13): files an AR user attaches to a claim - optionally to
    /// one of its follow-up notes - each with its own document type (LRNMaster dbo.ARDocumentTypeMaster; its
    /// category becomes DocumentCategory) and optional notes. The claim must be in the caller's scope (an agent:
    /// their own caseload); nothing is recorded otherwise and the result is empty.
    /// </summary>
    public async Task<IReadOnlyList<long>> AddClaimDocumentsAsync(int labId, long claimKey, long? followUpId,
        IReadOnlyList<ArWorkbenchClaimUpload> files, ArWorkbenchUserContext user, string? clientIp, CancellationToken ct)
    {
        var ids = new List<long>();
        if (files.Count == 0) return ids;
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        foreach (var (fileName, contentType, stored, docType, description) in files)
        {
            await using var cmd = connection.CreateCommand();
            cmd.Transaction = tx;
            var scope = AppendScope(cmd, user);
            cmd.CommandText = $@"
INSERT INTO dbo.ARWB_Document (ClaimKey, FollowUpId, DocumentSource, DocumentCategory, DocumentTypeID, DocumentTypeCode, DocumentTypeName,
                               Description, FileName, ContentType, SizeBytes, BlobContainer, BlobPath, ContentSha256, UploadedBy, UploadedByRole)
SELECT w.ClaimKey, @FollowUp, 'FollowUp', @Category, @TypeId, @TypeCode, @TypeName,
       @Description, @Name, @Type, @Size, @Container, @Path, @Sha, @User, @Role
FROM dbo.ARWB_Claim w
WHERE w.ClaimKey = @ClaimKey {scope}
  AND (@FollowUp IS NULL OR EXISTS (SELECT 1 FROM dbo.ARWB_ClaimFollowUp f WHERE f.FollowUpId = @FollowUp AND f.ClaimKey = w.ClaimKey));
IF @@ROWCOUNT = 0 BEGIN SELECT CAST(NULL AS bigint); RETURN; END;
DECLARE @Id bigint = CAST(SCOPE_IDENTITY() AS bigint);
INSERT INTO dbo.ARWB_DocumentAccessLog (DocumentId, AccessType, UserName, RoleCode, ClientIp) VALUES (@Id, 'Upload', @User, @Role, @Ip);
INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, UserName, RoleCode, IsSystem)
VALUES (@ClaimKey, SYSUTCDATETIME(), N'Document Uploaded', CONCAT(@TypeName, N' (', @Category, N'): ', @Name, N' - ' + @Description), @User, @Role, 0);
SELECT @Id;";
            cmd.Parameters.Add("@ClaimKey", SqlDbType.BigInt).Value = claimKey;
            cmd.Parameters.Add("@FollowUp", SqlDbType.BigInt).Value = (object?)followUpId ?? DBNull.Value;
            cmd.Parameters.Add("@Category", SqlDbType.NVarChar, 100).Value = Truncate(docType.DocumentCategory, 100);
            cmd.Parameters.Add("@TypeId", SqlDbType.Int).Value = docType.DocumentTypeId;
            cmd.Parameters.Add("@TypeCode", SqlDbType.NVarChar, 100).Value = Truncate(docType.DocumentTypeCode, 100);
            cmd.Parameters.Add("@TypeName", SqlDbType.NVarChar, 200).Value = Truncate(docType.DocumentTypeName, 200);
            cmd.Parameters.Add("@Description", SqlDbType.NVarChar, 500).Value = string.IsNullOrWhiteSpace(description) ? DBNull.Value : (object)Truncate(description.Trim(), 500);
            cmd.Parameters.Add("@Name", SqlDbType.NVarChar, 260).Value = Truncate(fileName, 260);
            cmd.Parameters.Add("@Type", SqlDbType.NVarChar, 200).Value = (object?)contentType ?? DBNull.Value;
            cmd.Parameters.Add("@Size", SqlDbType.BigInt).Value = stored.SizeBytes;
            cmd.Parameters.Add("@Container", SqlDbType.NVarChar, 100).Value = stored.Container;
            cmd.Parameters.Add("@Path", SqlDbType.NVarChar, 1024).Value = stored.Path;
            cmd.Parameters.Add("@Sha", SqlDbType.VarChar, 64).Value = stored.Sha256;
            cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
            cmd.Parameters.Add("@Role", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
            cmd.Parameters.Add("@Ip", SqlDbType.VarChar, 64).Value = (object?)clientIp ?? DBNull.Value;
            if (await cmd.ExecuteScalarAsync(ct) is long id) ids.Add(id);
            else { await tx.RollbackAsync(ct); return []; }
        }
        await tx.CommitAsync(ct);
        return ids;
    }

    /// <summary>
    /// Document Vault (handoff §8.2, DEF-14) and a claim's Documents tab: documents on claims in the
    /// caller's scope, searchable by claim / visit (accession), patient and category. A client user
    /// only ever sees CIP-response documents.
    /// </summary>
    public async Task<ArWorkbenchPagedResult<ArWorkbenchDocumentRow>> SearchDocumentsAsync(ArWorkbenchDocumentFilter filter, ArWorkbenchUserContext user, CancellationToken ct)
    {
        var page = Math.Max(1, filter.Page);
        var pageSize = Math.Clamp(filter.PageSize <= 0 ? 50 : filter.PageSize, 1, 500);
        await using var connection = await OpenLabAsync(filter.LabId, ct);
        await using var cmd = connection.CreateCommand();
        cmd.CommandTimeout = 60;
        var scope = AppendScope(cmd, user);

        var where = new List<string> { "d.IsDeleted = 0" };
        if (ArWorkbenchClientVisibility.IsClientUser(user)) where.Add("d.DocumentSource = 'CipResponse'");
        if (filter.ClaimKey is long key)
        {
            where.Add("d.ClaimKey = @ClaimKey");
            cmd.Parameters.Add("@ClaimKey", SqlDbType.BigInt).Value = key;
        }
        if (!string.IsNullOrWhiteSpace(filter.Search))
        {
            where.Add("(w.ClaimID LIKE @Search OR w.AccessionNumber LIKE @Search OR w.PatientName LIKE @Search OR w.PatientID LIKE @Search OR d.FileName LIKE @Search OR d.Description LIKE @Search OR d.DocumentTypeName LIKE @Search)");
            cmd.Parameters.Add("@Search", SqlDbType.NVarChar, 210).Value = "%" + EscapeLike(filter.Search.Trim()) + "%";
        }
        if (!string.IsNullOrWhiteSpace(filter.Category))
        {
            where.Add("d.DocumentCategory = @Category");
            cmd.Parameters.Add("@Category", SqlDbType.NVarChar, 100).Value = filter.Category.Trim();
        }
        if (!string.IsNullOrWhiteSpace(filter.Source))
        {
            where.Add("d.DocumentSource = @Source");
            cmd.Parameters.Add("@Source", SqlDbType.VarChar, 20).Value = filter.Source.Trim();
        }
        if (filter.From is DateTime from)
        {
            where.Add("d.UploadedOn >= @From");
            cmd.Parameters.Add("@From", SqlDbType.DateTime2).Value = from.Date;
        }
        if (filter.To is DateTime to)
        {
            where.Add("d.UploadedOn < @To");
            cmd.Parameters.Add("@To", SqlDbType.DateTime2).Value = to.Date.AddDays(1);
        }
        cmd.Parameters.Add("@Offset", SqlDbType.Int).Value = (page - 1) * pageSize;
        cmd.Parameters.Add("@PageSize", SqlDbType.Int).Value = pageSize;

        var filterSql = string.Join(" AND ", where) + scope;
        cmd.CommandText = $@"
SELECT COUNT(*) FROM dbo.ARWB_Document d INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = d.ClaimKey WHERE {filterSql};
SELECT d.DocumentId, d.ClaimKey, w.ClaimID, w.AccessionNumber, w.PatientName, w.PatientID, w.DateOfService, w.PayerName,
       d.DocumentSource, d.DocumentCategory, d.FollowUpId, d.CipCaseId, d.CipRoundNumber, d.FileName, d.ContentType, d.SizeBytes,
       d.UploadedBy, d.UploadedOn, d.Description, d.DocumentTypeName, d.DocumentTypeCode
FROM dbo.ARWB_Document d INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = d.ClaimKey
WHERE {filterSql}
ORDER BY d.UploadedOn DESC, d.DocumentId DESC
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;";

        var result = new ArWorkbenchPagedResult<ArWorkbenchDocumentRow> { Page = page, PageSize = pageSize };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (await r.ReadAsync(ct)) result.TotalCount = r.GetInt32(0);
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct))
        {
            result.Items.Add(new ArWorkbenchDocumentRow
            {
                DocumentId = r.GetInt64(0),
                ClaimKey = r.GetInt64(1),
                ClaimID = r.GetString(2),
                AccessionNumber = Str(r, 3),
                PatientName = Str(r, 4),
                PatientID = Str(r, 5),
                DateOfService = r.IsDBNull(6) ? null : r.GetDateTime(6),
                PayerName = Str(r, 7),
                DocumentSource = r.GetString(8),
                DocumentCategory = r.GetString(9),
                FollowUpId = r.IsDBNull(10) ? null : r.GetInt64(10),
                CipCaseId = r.IsDBNull(11) ? null : r.GetInt64(11),
                RoundNumber = r.IsDBNull(12) ? null : r.GetInt32(12),
                FileName = r.GetString(13),
                ContentType = Str(r, 14),
                SizeBytes = r.GetInt64(15),
                UploadedBy = r.GetString(16),
                UploadedOn = r.GetDateTime(17),
                Description = Str(r, 18),
                DocumentTypeName = Str(r, 19),
                DocumentTypeCode = Str(r, 20)
            });
        }
        return result;
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
