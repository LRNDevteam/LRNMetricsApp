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
        await using var cmd = new SqlCommand($@"
SELECT d.CipCaseId, d.DocumentId, d.FileName, d.ContentType, d.SizeBytes, d.CipRoundNumber, d.UploadedBy, d.UploadedOn, {await ScanStatusColumnAsync(connection, ct)}
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
                RoundNumber = r.IsDBNull(5) ? null : r.GetInt32(5), UploadedBy = r.GetString(6), UploadedOn = r.GetDateTime(7),
                ScanStatus = Str(r, 8)
            });
        }
        return result;
    }

    /// <summary>
    /// "d.ScanStatus" once lab script 11 has added the column, else a NULL placeholder - so the document
    /// lists keep working in a lab database that has not been upgraded yet.
    /// </summary>
    private static async Task<string> ScanStatusColumnAsync(SqlConnection connection, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("SELECT CASE WHEN COL_LENGTH(N'dbo.ARWB_Document', N'ScanStatus') IS NULL THEN 0 ELSE 1 END;", connection);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) == 1 ? "d.ScanStatus" : "CAST(NULL AS varchar(20))";
    }

    /// <summary>
    /// A document the caller may download (claim scope; a client only CIP responses), with the
    /// download logged. Null when not found or not allowed.
    /// </summary>
    public async Task<(ArWorkbenchDocumentInfo Info, string Container, string Path, string? Sha256)?> GetDocumentForDownloadAsync(int labId, long documentId,
        ArWorkbenchUserContext user, string? clientIp, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        var scanStatus = await ScanStatusColumnAsync(connection, ct);
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
    SELECT d.DocumentId, d.FileName, d.ContentType, d.SizeBytes, d.CipRoundNumber, d.UploadedBy, d.UploadedOn, d.BlobContainer, d.BlobPath, d.ContentSha256,
           {scanStatus}
    FROM dbo.ARWB_Document d WHERE d.DocumentId = @Id;
END;";
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        var info = new ArWorkbenchDocumentInfo
        {
            DocumentId = r.GetInt64(0), FileName = r.GetString(1), ContentType = Str(r, 2), SizeBytes = r.GetInt64(3),
            RoundNumber = r.IsDBNull(4) ? null : r.GetInt32(4), UploadedBy = r.GetString(5), UploadedOn = r.GetDateTime(6),
            ScanStatus = Str(r, 10)
        };
        return (info, r.GetString(7), r.GetString(8), Str(r, 9));
    }

    /// <summary>
    /// Appends one access-log row (Blocked, Migrate, ...). Detail is written only once script 10 has added
    /// the column, and must never hold file or patient names. A failed insert (e.g. script 10 not run, so
    /// the CHECK refuses 'Blocked') returns false for the caller to log.
    /// </summary>
    public async Task<bool> LogDocumentAccessAsync(int labId, long documentId, string accessType, string? detail, ArWorkbenchUserContext user, string? clientIp, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenLabAsync(labId, ct);
            // Detail is named only inside sp_executesql: a missing column would otherwise fail the whole batch at compile time.
            await using var cmd = new SqlCommand(@"
IF COL_LENGTH(N'dbo.ARWB_DocumentAccessLog', N'Detail') IS NULL
    INSERT INTO dbo.ARWB_DocumentAccessLog (DocumentId, AccessType, UserName, RoleCode, ClientIp) VALUES (@Id, @Access, @User, @Role, @Ip);
ELSE
    EXEC sp_executesql N'INSERT INTO dbo.ARWB_DocumentAccessLog (DocumentId, AccessType, UserName, RoleCode, ClientIp, Detail) VALUES (@Id, @Access, @User, @Role, @Ip, @Detail);',
        N'@Id bigint, @Access varchar(20), @User nvarchar(256), @Role varchar(20), @Ip varchar(64), @Detail nvarchar(200)',
        @Id, @Access, @User, @Role, @Ip, @Detail;", connection);
            cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = documentId;
            cmd.Parameters.Add("@Access", SqlDbType.VarChar, 20).Value = Truncate(accessType, 20);
            cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
            cmd.Parameters.Add("@Role", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
            cmd.Parameters.Add("@Ip", SqlDbType.VarChar, 64).Value = (object?)clientIp ?? DBNull.Value;
            cmd.Parameters.Add("@Detail", SqlDbType.NVarChar, 200).Value = string.IsNullOrWhiteSpace(detail) ? DBNull.Value : (object)Truncate(detail.Trim(), 200);
            await cmd.ExecuteNonQueryAsync(ct);
            return true;
        }
        catch (SqlException)
        {
            return false;
        }
    }

    /// <summary>The next documents still on local disk, oldest first; soft-deleted rows too (retention applies to them).</summary>
    public async Task<IReadOnlyList<(long DocumentId, string Path, string? Sha256)>> GetLocalDocumentsAsync(int labId, int batchSize, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(@"
SELECT TOP (@Batch) d.DocumentId, d.BlobPath, d.ContentSha256
FROM dbo.ARWB_Document d
WHERE d.BlobContainer = 'local'
ORDER BY d.DocumentId;", connection);
        cmd.Parameters.Add("@Batch", SqlDbType.Int).Value = Math.Clamp(batchSize, 1, 1000);
        var rows = new List<(long, string, string?)>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) rows.Add((r.GetInt64(0), r.GetString(1), Str(r, 2)));
        return rows;
    }

    /// <summary>Repoints a 'local' document at its blob and logs Migrate, in one transaction. False when the row had already moved.</summary>
    public async Task<bool> MoveDocumentToBlobAsync(int labId, long documentId, StoredDocument stored, ArWorkbenchUserContext user, string? clientIp, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(@"
SET XACT_ABORT ON;
BEGIN TRANSACTION;
UPDATE dbo.ARWB_Document SET BlobContainer = @Container, BlobPath = @Path, ContentSha256 = @Sha
WHERE DocumentId = @Id AND BlobContainer = 'local';
DECLARE @Changed int = @@ROWCOUNT;
IF @Changed = 1
    INSERT INTO dbo.ARWB_DocumentAccessLog (DocumentId, AccessType, UserName, RoleCode, ClientIp) VALUES (@Id, 'Migrate', @User, @Role, @Ip);
COMMIT TRANSACTION;
SELECT @Changed;", connection);
        cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = documentId;
        cmd.Parameters.Add("@Container", SqlDbType.NVarChar, 100).Value = stored.Container;
        cmd.Parameters.Add("@Path", SqlDbType.NVarChar, 1024).Value = stored.Path;
        cmd.Parameters.Add("@Sha", SqlDbType.VarChar, 64).Value = stored.Sha256;
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user.UserName, 256);
        cmd.Parameters.Add("@Role", SqlDbType.VarChar, 20).Value = Truncate(user.RoleCode, 20);
        cmd.Parameters.Add("@Ip", SqlDbType.VarChar, 64).Value = (object?)clientIp ?? DBNull.Value;
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) == 1;
    }

    /// <summary>The oldest documents still waiting for their malware scan verdict (script 11), soft-deleted ones too.</summary>
    public async Task<IReadOnlyList<ArWorkbenchPendingScanDocument>> GetPendingScanDocumentsAsync(int labId, int batchSize, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        if (await ScanStatusColumnAsync(connection, ct) != "d.ScanStatus") return [];
        // ScanStatus is named only inside sp_executesql, so this batch compiles even on a lab without it.
        await using var cmd = new SqlCommand(@"
EXEC sp_executesql N'SELECT TOP (@Batch) d.DocumentId, d.BlobContainer, d.BlobPath, d.UploadedOn
FROM dbo.ARWB_Document d WHERE d.ScanStatus = ''Pending'' ORDER BY d.DocumentId;', N'@Batch int', @Batch;", connection);
        cmd.Parameters.Add("@Batch", SqlDbType.Int).Value = Math.Clamp(batchSize, 1, 1000);
        var rows = new List<ArWorkbenchPendingScanDocument>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) rows.Add(new(r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetDateTime(3)));
        return rows;
    }

    public async Task<bool> RecordDocumentScanResultAsync(int labId, long documentId, string scanStatus, CancellationToken ct)
    {
        if (scanStatus is not ("Clean" or "Malicious" or "NotScanned"))
            throw new ArgumentOutOfRangeException(nameof(scanStatus), scanStatus, "Clean, Malicious or NotScanned.");
        await using var connection = await OpenLabAsync(labId, ct);
        if (await ScanStatusColumnAsync(connection, ct) != "d.ScanStatus") return false;

        // One transaction: the status, and for a virus the audit row, claim activity and notifications.
        // Messages carry the claim ID only - never the file or patient name.
        await using var cmd = new SqlCommand(@"
EXEC sp_executesql N'
SET XACT_ABORT ON;
BEGIN TRANSACTION;
DECLARE @Now datetime2(0) = SYSUTCDATETIME();
UPDATE dbo.ARWB_Document
SET ScanStatus = @Status, ScanCheckedOn = @Now, ScanDetectedOn = CASE WHEN @Status = ''Malicious'' THEN @Now END
WHERE DocumentId = @Id AND ScanStatus = ''Pending'';
DECLARE @Changed int = @@ROWCOUNT;
IF @Changed = 1 AND @Status = ''Malicious''
BEGIN
    DECLARE @ClaimKey bigint, @ClaimId nvarchar(100), @Uploader nvarchar(256);
    SELECT @ClaimKey = d.ClaimKey, @ClaimId = w.ClaimID, @Uploader = d.UploadedBy
    FROM dbo.ARWB_Document d LEFT JOIN dbo.ARWB_Claim w ON w.ClaimKey = d.ClaimKey
    WHERE d.DocumentId = @Id;

    INSERT INTO dbo.ARWB_DocumentAccessLog (DocumentId, AccessType, UserName, RoleCode, ClientIp, Detail)
    VALUES (@Id, ''Malware'', N''System / Defender for Storage'', ''Automation'', NULL, N''Virus detected by Defender for Storage - document quarantined'');

    IF @ClaimKey IS NOT NULL
        INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, UserName, RoleCode, IsSystem)
        VALUES (@ClaimKey, @Now, N''Document Quarantined'',
                CONCAT(N''Virus detected in document #'', @Id, N'' (uploaded by '', @Uploader, N''). It is quarantined and cannot be downloaded.''),
                N''System / Defender for Storage'', ''Automation'', 1);

    INSERT INTO dbo.ARWB_Notification (ClaimKey, RecipientUser, NotificationType, Message, CreatedOn, RelatedEntityType, RelatedEntityId)
    VALUES (@ClaimKey, @Uploader, ''DocumentMalware'',
            CONCAT(N''A virus was found in the document you uploaded'', N'' to claim '' + @ClaimId, N''. It has been quarantined and cannot be downloaded. Upload a clean copy if it is still needed.''),
            @Now, ''Document'', @Id);
    INSERT INTO dbo.ARWB_Notification (ClaimKey, RecipientRole, NotificationType, Message, CreatedOn, RelatedEntityType, RelatedEntityId)
    VALUES (@ClaimKey, ''admin'', ''DocumentMalware'',
            CONCAT(N''Virus detected: document #'', @Id, N'' uploaded by '', @Uploader, N'' to claim '' + @ClaimId, N'' was quarantined.''),
            @Now, ''Document'', @Id);
END;
COMMIT TRANSACTION;
SELECT @Changed;',
    N'@Id bigint, @Status varchar(20)', @Id, @Status;", connection);
        cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = documentId;
        cmd.Parameters.Add("@Status", SqlDbType.VarChar, 20).Value = scanStatus;
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) == 1;
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
        var scanStatus = await ScanStatusColumnAsync(connection, ct);
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
       d.UploadedBy, d.UploadedOn, d.Description, d.DocumentTypeName, d.DocumentTypeCode, {scanStatus}
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
                DocumentTypeCode = Str(r, 20),
                ScanStatus = Str(r, 21)
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
