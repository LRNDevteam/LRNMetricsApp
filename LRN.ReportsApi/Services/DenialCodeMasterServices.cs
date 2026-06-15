using System.Data;
using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services;

public interface IDenialCodeMasterRepository
{
    Task<PagedResult<DenialCodeMasterRecord>> GetPagedAsync(int labId, string? search, int page, int pageSize, CancellationToken ct);
    Task<IReadOnlyList<DenialCodeMasterRecord>> GetAllAsync(int labId, CancellationToken ct);
    Task<DenialCodeMasterRecord?> GetByKeyAsync(int labId, string denialCode, string coverageStatus, string icdComplianceStatus, CancellationToken ct);
    Task<bool> ExistsAsync(int labId, string denialCode, string coverageStatus, string icdComplianceStatus, CancellationToken ct);
    Task CreateAsync(int labId, DenialCodeMasterRequest request, string? userName, CancellationToken ct);
    Task UpdateAsync(int labId, string originalDenialCode, string originalCoverageStatus, string originalIcdComplianceStatus, DenialCodeMasterRequest request, string? userName, CancellationToken ct);
    Task DeleteAsync(int labId, string denialCode, string coverageStatus, string icdComplianceStatus, CancellationToken ct);
    Task<DenialCodeMasterLookups> GetLookupsAsync(int labId, CancellationToken ct);
    Task<DenialCodeMasterImportResult> ReplaceFromImportAsync(int labId, IReadOnlyList<DenialCodeMasterRequest> records, int skippedCount, IReadOnlyList<string> errors, string? sourceFileName, string? userName, CancellationToken ct);
}

public interface IDenialCodeMasterExcelService
{
    Task<DenialCodeMasterImportResult> ImportAsync(int labId, Stream stream, string? sourceFileName, string? userName, CancellationToken ct);
    Task<string> RegenerateExportAsync(int labId, CancellationToken ct);
}

public interface IDenialActionChangeVerificationRepository
{
    Task<PagedResult<DenialActionChangeVerification>> GetVerificationItemsAsync(DenialActionChangeQuery query, CancellationToken ct);
    Task<DenialActionChangeBatch?> GetBatchAsync(int labId, long batchId, CancellationToken ct);
    Task<DenialActionChangeLookups> GetLookupsAsync(int labId, CancellationToken ct);
    Task<DenialActionChangeResult> ConfirmAsync(int labId, long verificationId, string? userName, CancellationToken ct);
    Task<DenialActionChangeResult> ConfirmSelectedAsync(int labId, IReadOnlyList<long> verificationIds, string? userName, CancellationToken ct);
    Task<DenialActionChangeResult> ConfirmAllAsync(int labId, long batchId, string? userName, CancellationToken ct);
    Task<DenialActionChangeResult> IgnoreAsync(int labId, long verificationId, string? userName, CancellationToken ct);
    Task<byte[]> ExportAsync(DenialActionChangeQuery query, CancellationToken ct);
}

public sealed class SqlDenialCodeMasterRepository : IDenialCodeMasterRepository
{
    private readonly IConfiguration _configuration;
    private readonly IReadOnlyDictionary<int, string> _labNamesById;
    private readonly IReadOnlyDictionary<int, string> _labConnectionsById;

    public SqlDenialCodeMasterRepository(IConfiguration configuration)
    {
        _configuration = configuration;
        var labItems = configuration.GetSection("LabConfig:LabsID").Get<List<LabConfigItem>>() ?? [];
        if (labItems.Count == 0) labItems = DefaultActiveLabs();

        _labNamesById = labItems
            .Where(x => x.Id > 0 && x.IsActive && !string.IsNullOrWhiteSpace(x.Name))
            .GroupBy(x => x.Id)
            .ToDictionary(g => g.Key, g => g.First().Name.Trim());

        _labConnectionsById = labItems
            .Where(x => x.Id > 0 && x.IsActive)
            .GroupBy(x => x.Id)
            .ToDictionary(g => g.Key, g => ResolveLabConnectionString(configuration, g.First().Id, g.First().Name, g.First().ConnectionKey));
    }

    public async Task<PagedResult<DenialCodeMasterRecord>> GetPagedAsync(int labId, string? search, int page, int pageSize, CancellationToken ct)
    {
        page = page <= 0 ? 1 : page;
        pageSize = pageSize <= 0 ? 25 : Math.Clamp(pageSize, 10, 200);
        var where = SearchWhere(search, out var parameters);

        var result = new PagedResult<DenialCodeMasterRecord> { Page = page, PageSize = pageSize };
        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);

        await using (var countCmd = new SqlCommand($"SELECT COUNT(1) FROM dbo.DenialCodeMaster WHERE {where}", conn))
        {
            countCmd.Parameters.AddRange(CloneParams(parameters));
            result.TotalCount = Convert.ToInt32(await countCmd.ExecuteScalarAsync(ct) ?? 0);
        }

        var sql = $"""
            SELECT DenialCode, DenialDescription, DenialClassification, CoverageStatus, ICDComplianceStatus,
                   DenialValidity, ActionCode, RecommendedAction, ActionCategory, Task, ShortCategory,
                   Priority, SLADays, NotesComments, CreatedOn, CreatedBy, UpdatedOn, UpdatedBy
            FROM dbo.DenialCodeMaster
            WHERE {where}
            ORDER BY DenialCode, CoverageStatus, ICDComplianceStatus
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """;
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddRange(CloneParams(parameters));
        cmd.Parameters.Add(new SqlParameter("@Offset", (page - 1) * pageSize));
        cmd.Parameters.Add(new SqlParameter("@PageSize", pageSize));
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) result.Items.Add(Map(reader));
        return result;
    }

    public async Task<IReadOnlyList<DenialCodeMasterRecord>> GetAllAsync(int labId, CancellationToken ct)
    {
        const string sql = """
            SELECT DenialCode, DenialDescription, DenialClassification, CoverageStatus, ICDComplianceStatus,
                   DenialValidity, ActionCode, RecommendedAction, ActionCategory, Task, ShortCategory,
                   Priority, SLADays, NotesComments, CreatedOn, CreatedBy, UpdatedOn, UpdatedBy
            FROM dbo.DenialCodeMaster
            ORDER BY DenialCode, CoverageStatus, ICDComplianceStatus;
            """;
        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var rows = new List<DenialCodeMasterRecord>();
        while (await reader.ReadAsync(ct)) rows.Add(Map(reader));
        return rows;
    }

    public async Task<DenialCodeMasterRecord?> GetByKeyAsync(int labId, string denialCode, string coverageStatus, string icdComplianceStatus, CancellationToken ct)
    {
        const string sql = """
            SELECT DenialCode, DenialDescription, DenialClassification, CoverageStatus, ICDComplianceStatus,
                   DenialValidity, ActionCode, RecommendedAction, ActionCategory, Task, ShortCategory,
                   Priority, SLADays, NotesComments, CreatedOn, CreatedBy, UpdatedOn, UpdatedBy
            FROM dbo.DenialCodeMaster
            WHERE DenialCode = @DenialCode
              AND CoverageStatus = @CoverageStatus
              AND ICDComplianceStatus = @ICDComplianceStatus;
            """;
        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        AddKeyParams(cmd, denialCode, coverageStatus, icdComplianceStatus);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? Map(reader) : null;
    }

    public async Task<bool> ExistsAsync(int labId, string denialCode, string coverageStatus, string icdComplianceStatus, CancellationToken ct)
    {
        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);
        return await ExistsAsync(conn, null, denialCode, coverageStatus, icdComplianceStatus, ct);
    }

    public async Task CreateAsync(int labId, DenialCodeMasterRequest request, string? userName, CancellationToken ct)
    {
        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);
        await InsertAsync(conn, null, request, userName, ct);
    }

    public async Task UpdateAsync(int labId, string originalDenialCode, string originalCoverageStatus, string originalIcdComplianceStatus, DenialCodeMasterRequest request, string? userName, CancellationToken ct)
    {
        const string sql = """
            UPDATE dbo.DenialCodeMaster
            SET DenialCode = @DenialCode,
                DenialDescription = @DenialDescription,
                DenialClassification = @DenialClassification,
                CoverageStatus = @CoverageStatus,
                ICDComplianceStatus = @ICDComplianceStatus,
                DenialValidity = @DenialValidity,
                ActionCode = @ActionCode,
                RecommendedAction = @RecommendedAction,
                ActionCategory = @ActionCategory,
                Task = @Task,
                ShortCategory = @ShortCategory,
                Priority = @Priority,
                SLADays = @SLADays,
                NotesComments = @NotesComments,
                UpdatedOn = SYSUTCDATETIME(),
                UpdatedBy = @UpdatedBy
            WHERE DenialCode = @OriginalDenialCode
              AND CoverageStatus = @OriginalCoverageStatus
              AND ICDComplianceStatus = @OriginalICDComplianceStatus;
            """;
        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        AddParams(cmd, request);
        AddOriginalKeyParams(cmd, originalDenialCode, originalCoverageStatus, originalIcdComplianceStatus);
        cmd.Parameters.Add(new SqlParameter("@UpdatedBy", DbValue(userName)));
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task DeleteAsync(int labId, string denialCode, string coverageStatus, string icdComplianceStatus, CancellationToken ct)
    {
        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);
        await DeleteAsync(conn, null, denialCode, coverageStatus, icdComplianceStatus, ct);
    }

    public async Task<DenialCodeMasterLookups> GetLookupsAsync(int labId, CancellationToken ct)
    {
        const string sql = """
            SELECT DISTINCT DenialClassification FROM dbo.DenialCodeMaster WHERE NULLIF(LTRIM(RTRIM(DenialClassification)), '') IS NOT NULL ORDER BY DenialClassification;
            SELECT DISTINCT CoverageStatus FROM dbo.DenialCodeMaster WHERE NULLIF(LTRIM(RTRIM(CoverageStatus)), '') IS NOT NULL ORDER BY CoverageStatus;
            SELECT DISTINCT ICDComplianceStatus FROM dbo.DenialCodeMaster WHERE NULLIF(LTRIM(RTRIM(ICDComplianceStatus)), '') IS NOT NULL ORDER BY ICDComplianceStatus;
            SELECT DISTINCT DenialValidity FROM dbo.DenialCodeMaster WHERE NULLIF(LTRIM(RTRIM(DenialValidity)), '') IS NOT NULL ORDER BY DenialValidity;
            SELECT DISTINCT ActionCode FROM dbo.DenialCodeMaster WHERE NULLIF(LTRIM(RTRIM(ActionCode)), '') IS NOT NULL ORDER BY ActionCode;
            SELECT DISTINCT ActionCategory FROM dbo.DenialCodeMaster WHERE NULLIF(LTRIM(RTRIM(ActionCategory)), '') IS NOT NULL ORDER BY ActionCategory;
            SELECT DISTINCT Task FROM dbo.DenialCodeMaster WHERE NULLIF(LTRIM(RTRIM(Task)), '') IS NOT NULL ORDER BY Task;
            """;
        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);

        var result = new DenialCodeMasterLookups();
        result.DenialClassifications = await ReadStringsAsync(reader, ct);
        await reader.NextResultAsync(ct);
        result.CoverageStatuses = await ReadStringsAsync(reader, ct);
        await reader.NextResultAsync(ct);
        result.ICDComplianceStatuses = await ReadStringsAsync(reader, ct);
        await reader.NextResultAsync(ct);
        result.DenialValidities = await ReadStringsAsync(reader, ct);
        await reader.NextResultAsync(ct);
        result.ActionCodes = await ReadStringsAsync(reader, ct);
        await reader.NextResultAsync(ct);
        result.ActionCategories = await ReadStringsAsync(reader, ct);
        await reader.NextResultAsync(ct);
        result.Tasks = await ReadStringsAsync(reader, ct);
        return result;
    }

    public async Task<DenialCodeMasterImportResult> ReplaceFromImportAsync(int labId, IReadOnlyList<DenialCodeMasterRequest> records, int skippedCount, IReadOnlyList<string> errors, string? sourceFileName, string? userName, CancellationToken ct)
    {
        if (errors.Count > 0) return new DenialCodeMasterImportResult { SkippedCount = skippedCount, FailedCount = errors.Count, Errors = errors };

        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        var inserted = 0;
        var updated = 0;
        DenialCodeActionChangeSummary? actionChangeSummary = null;
        try
        {
            var uniqueRecords = DeduplicateImportRecords(records);
            skippedCount += records.Count - uniqueRecords.Count;

            if (uniqueRecords.Count > 0)
            {
                (inserted, updated, actionChangeSummary) = await BulkUpsertImportAsync(conn, (SqlTransaction)tx, uniqueRecords, sourceFileName, userName, ct);
            }

            await tx.CommitAsync(ct);
        }
        catch
        {
            await tx.RollbackAsync(CancellationToken.None);
            throw;
        }

        return new DenialCodeMasterImportResult
        {
            InsertedCount = inserted,
            UpdatedCount = updated,
            SkippedCount = skippedCount,
            FailedCount = 0,
            HasActionChangeWarnings = actionChangeSummary?.BatchId > 0,
            BatchId = actionChangeSummary?.BatchId,
            AffectedClaims = actionChangeSummary?.AffectedClaims ?? 0,
            AffectedTasks = actionChangeSummary?.AffectedTasks ?? 0,
            Message = actionChangeSummary?.BatchId > 0 ? "Assigned open claims/tasks require verification before action details are applied." : null
        };
    }

    private static IReadOnlyList<DenialCodeMasterRequest> DeduplicateImportRecords(IReadOnlyList<DenialCodeMasterRequest> records)
    {
        var byKey = new Dictionary<string, DenialCodeMasterRequest>(StringComparer.OrdinalIgnoreCase);
        foreach (var record in records)
        {
            TrimImportRecord(record);
            byKey[ImportKey(record)] = record;
        }
        return byKey.Values.ToList();
    }

    private static async Task<(int InsertedCount, int UpdatedCount, DenialCodeActionChangeSummary? ActionChangeSummary)> BulkUpsertImportAsync(SqlConnection conn, SqlTransaction tx, IReadOnlyList<DenialCodeMasterRequest> records, string? sourceFileName, string? userName, CancellationToken ct)
    {
        const string setupSql = """
            CREATE TABLE #DenialCodeMasterImport
            (
                DenialCode nvarchar(100) NOT NULL,
                DenialDescription nvarchar(1000) NULL,
                DenialClassification nvarchar(255) NULL,
                CoverageStatus nvarchar(255) NOT NULL,
                ICDComplianceStatus nvarchar(255) NOT NULL,
                DenialValidity nvarchar(255) NULL,
                ActionCode nvarchar(100) NULL,
                RecommendedAction nvarchar(1000) NULL,
                ActionCategory nvarchar(255) NULL,
                Task nvarchar(500) NULL,
                ShortCategory nvarchar(255) NULL,
                Priority nvarchar(100) NULL,
                SLADays nvarchar(100) NULL,
                NotesComments nvarchar(2000) NULL,
                CreatedBy nvarchar(100) NULL
            );
            """;
        await using (var setupCmd = new SqlCommand(setupSql, conn, tx))
        {
            setupCmd.CommandTimeout = 180;
            await setupCmd.ExecuteNonQueryAsync(ct);
        }

        using var table = BuildImportTable(records, userName);
        using (var bulkCopy = new SqlBulkCopy(conn, SqlBulkCopyOptions.CheckConstraints, tx))
        {
            bulkCopy.DestinationTableName = "#DenialCodeMasterImport";
            bulkCopy.BulkCopyTimeout = 180;
            foreach (DataColumn column in table.Columns)
                bulkCopy.ColumnMappings.Add(column.ColumnName, column.ColumnName);
            await bulkCopy.WriteToServerAsync(table, ct);
        }

        await EnsureActionChangeSchemaAsync(conn, tx, ct);
        var actionChangeSummary = await CreateActionChangeBatchAsync(conn, tx, sourceFileName, userName, ct);

        const string upsertSql = """
            DECLARE @UpdatedCount int;
            DECLARE @InsertedCount int;

            SELECT @UpdatedCount = COUNT(1)
            FROM dbo.DenialCodeMaster target
            INNER JOIN #DenialCodeMasterImport source
                ON target.DenialCode = source.DenialCode
               AND target.CoverageStatus = source.CoverageStatus
               AND target.ICDComplianceStatus = source.ICDComplianceStatus;

            UPDATE target
            SET target.DenialDescription = source.DenialDescription,
                target.DenialClassification = source.DenialClassification,
                target.DenialValidity = source.DenialValidity,
                target.ActionCode = source.ActionCode,
                target.RecommendedAction = source.RecommendedAction,
                target.ActionCategory = source.ActionCategory,
                target.Task = source.Task,
                target.ShortCategory = source.ShortCategory,
                target.Priority = source.Priority,
                target.SLADays = source.SLADays,
                target.NotesComments = source.NotesComments,
                target.UpdatedOn = SYSUTCDATETIME(),
                target.UpdatedBy = source.CreatedBy
            FROM dbo.DenialCodeMaster target
            INNER JOIN #DenialCodeMasterImport source
                ON target.DenialCode = source.DenialCode
               AND target.CoverageStatus = source.CoverageStatus
               AND target.ICDComplianceStatus = source.ICDComplianceStatus;

            SELECT @InsertedCount = COUNT(1)
            FROM #DenialCodeMasterImport source
            WHERE NOT EXISTS
            (
                SELECT 1
                FROM dbo.DenialCodeMaster target
                WHERE target.DenialCode = source.DenialCode
                  AND target.CoverageStatus = source.CoverageStatus
                  AND target.ICDComplianceStatus = source.ICDComplianceStatus
            );

            INSERT INTO dbo.DenialCodeMaster
                (DenialCode, DenialDescription, DenialClassification, CoverageStatus, ICDComplianceStatus,
                 DenialValidity, ActionCode, RecommendedAction, ActionCategory, Task, ShortCategory,
                 Priority, SLADays, NotesComments, CreatedBy)
            SELECT source.DenialCode, source.DenialDescription, source.DenialClassification, source.CoverageStatus, source.ICDComplianceStatus,
                   source.DenialValidity, source.ActionCode, source.RecommendedAction, source.ActionCategory, source.Task, source.ShortCategory,
                   source.Priority, source.SLADays, source.NotesComments, source.CreatedBy
            FROM #DenialCodeMasterImport source
            WHERE NOT EXISTS
            (
                SELECT 1
                FROM dbo.DenialCodeMaster target
                WHERE target.DenialCode = source.DenialCode
                  AND target.CoverageStatus = source.CoverageStatus
                  AND target.ICDComplianceStatus = source.ICDComplianceStatus
            );

            SELECT @InsertedCount AS InsertedCount, @UpdatedCount AS UpdatedCount;
            """;
        await using var upsertCmd = new SqlCommand(upsertSql, conn, tx) { CommandTimeout = 180 };
        await using var reader = await upsertCmd.ExecuteReaderAsync(ct);
        if (await reader.ReadAsync(ct))
        {
            return (reader.GetInt32(reader.GetOrdinal("InsertedCount")), reader.GetInt32(reader.GetOrdinal("UpdatedCount")), actionChangeSummary);
        }

        return (0, 0, actionChangeSummary);
    }

    private static async Task<DenialCodeActionChangeSummary?> CreateActionChangeBatchAsync(SqlConnection conn, SqlTransaction tx, string? sourceFileName, string? userName, CancellationToken ct)
    {
        const string sql = """
            DECLARE @BatchId bigint;

            DECLARE @Affected table
            (
                ClaimID nvarchar(100) NOT NULL,
                TaskID nvarchar(100) NULL,
                PatientId nvarchar(100) NULL,
                PayerName nvarchar(255) NULL,
                AssignedTo nvarchar(100) NULL,
                ClaimStatus nvarchar(100) NULL,
                DenialCode nvarchar(100) NOT NULL,
                ICDComplianceStatus nvarchar(255) NULL,
                CoverageStatus nvarchar(255) NULL,
                OldActionCode nvarchar(100) NULL,
                NewActionCode nvarchar(100) NULL,
                OldActionCategory nvarchar(500) NULL,
                NewActionCategory nvarchar(500) NULL,
                OldTask nvarchar(500) NULL,
                NewTask nvarchar(500) NULL,
                OldShortCategory nvarchar(255) NULL,
                NewShortCategory nvarchar(255) NULL
            );

            INSERT INTO @Affected
            SELECT CONVERT(nvarchar(100), t.ClaimID), CONVERT(nvarchar(100), t.TaskID), CONVERT(nvarchar(100), t.PatientId),
                   CONVERT(nvarchar(255), t.PayerName), CONVERT(nvarchar(100), t.AssignedTo),
                   CONVERT(nvarchar(100), ISNULL(NULLIF(LTRIM(RTRIM(t.WorkFlowStatus)), ''), t.Status)),
                   source.DenialCode, source.ICDComplianceStatus, source.CoverageStatus,
                   t.ActionCode, source.ActionCode, t.ActionCategory, source.ActionCategory,
                   t.Task, source.Task, t.ShortCategory, source.ShortCategory
            FROM dbo.DenialTaskBoard t WITH (NOLOCK)
            INNER JOIN #DenialCodeMasterImport source
                ON UPPER(LTRIM(RTRIM(ISNULL(t.DenialCode, '')))) = UPPER(source.DenialCode)
               AND UPPER(LTRIM(RTRIM(ISNULL(t.CoverageStatus, 'N/A')))) = UPPER(source.CoverageStatus)
               AND UPPER(LTRIM(RTRIM(ISNULL(t.ICDComplianceStatus, 'N/A')))) = UPPER(source.ICDComplianceStatus)
            WHERE NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo, ''))), '') IS NOT NULL
              AND LOWER(LTRIM(RTRIM(ISNULL(t.Status, '')))) NOT IN ('close', 'closed')
              AND LOWER(LTRIM(RTRIM(ISNULL(t.WorkFlowStatus, '')))) NOT IN ('close', 'closed', 'closed claim')
              AND (
                    ISNULL(LTRIM(RTRIM(t.ActionCode)), '') <> ISNULL(source.ActionCode, '')
                 OR ISNULL(LTRIM(RTRIM(t.ActionCategory)), '') <> ISNULL(source.ActionCategory, '')
                 OR ISNULL(LTRIM(RTRIM(t.Task)), '') <> ISNULL(source.Task, '')
                 OR ISNULL(LTRIM(RTRIM(t.ShortCategory)), '') <> ISNULL(source.ShortCategory, '')
              );

            IF EXISTS (SELECT 1 FROM @Affected)
            BEGIN
                INSERT INTO dbo.DenialCodeActionChangeBatch
                    (SourceFileName, UploadedBy, TotalAffectedClaims, TotalAffectedTasks, PendingCount, Status)
                SELECT @SourceFileName, @UploadedBy, COUNT(DISTINCT ClaimID), COUNT(1), COUNT(1), 'Pending'
                FROM @Affected;

                SET @BatchId = SCOPE_IDENTITY();

                INSERT INTO dbo.DenialCodeActionChangeVerification
                    (BatchId, ClaimID, TaskID, PatientId, PayerName, AssignedTo, ClaimStatus,
                     DenialCode, ICDComplianceStatus, CoverageStatus,
                     OldActionCode, NewActionCode, OldActionCategory, NewActionCategory,
                     OldTask, NewTask, OldShortCategory, NewShortCategory)
                SELECT @BatchId, ClaimID, TaskID, PatientId, PayerName, AssignedTo, ClaimStatus,
                       DenialCode, ICDComplianceStatus, CoverageStatus,
                       OldActionCode, NewActionCode, OldActionCategory, NewActionCategory,
                       OldTask, NewTask, OldShortCategory, NewShortCategory
                FROM @Affected;
            END

            SELECT ISNULL(@BatchId, 0) AS BatchId,
                   COUNT(DISTINCT ClaimID) AS AffectedClaims,
                   COUNT(1) AS AffectedTasks
            FROM @Affected;
            """;

        await using var cmd = new SqlCommand(sql, conn, tx) { CommandTimeout = 180 };
        cmd.Parameters.Add(new SqlParameter("@SourceFileName", DbValue(Path.GetFileName(sourceFileName ?? "DenialCodeMaster.xlsx"))));
        cmd.Parameters.Add(new SqlParameter("@UploadedBy", DbValue(userName ?? "ReactWorkflow")));
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;
        return new DenialCodeActionChangeSummary(
            reader.GetInt64(reader.GetOrdinal("BatchId")),
            reader.GetInt32(reader.GetOrdinal("AffectedClaims")),
            reader.GetInt32(reader.GetOrdinal("AffectedTasks")));
    }

    internal static async Task EnsureActionChangeSchemaAsync(SqlConnection conn, SqlTransaction? tx, CancellationToken ct)
    {
        const string sql = """
            IF OBJECT_ID('dbo.DenialCodeActionChangeBatch','U') IS NULL
            BEGIN
                CREATE TABLE dbo.DenialCodeActionChangeBatch
                (
                    BatchId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialCodeActionChangeBatch PRIMARY KEY,
                    SourceFileName nvarchar(500) NOT NULL,
                    UploadedBy nvarchar(100) NOT NULL,
                    UploadedOn datetime2(0) NOT NULL CONSTRAINT DF_DCACB_UploadedOn DEFAULT SYSUTCDATETIME(),
                    TotalAffectedClaims int NOT NULL CONSTRAINT DF_DCACB_TotalAffectedClaims DEFAULT 0,
                    TotalAffectedTasks int NOT NULL CONSTRAINT DF_DCACB_TotalAffectedTasks DEFAULT 0,
                    PendingCount int NOT NULL CONSTRAINT DF_DCACB_PendingCount DEFAULT 0,
                    ConfirmedCount int NOT NULL CONSTRAINT DF_DCACB_ConfirmedCount DEFAULT 0,
                    IgnoredCount int NOT NULL CONSTRAINT DF_DCACB_IgnoredCount DEFAULT 0,
                    Status nvarchar(50) NOT NULL CONSTRAINT DF_DCACB_Status DEFAULT 'Pending'
                );
            END;

            IF OBJECT_ID('dbo.DenialCodeActionChangeVerification','U') IS NULL
            BEGIN
                CREATE TABLE dbo.DenialCodeActionChangeVerification
                (
                    VerificationId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialCodeActionChangeVerification PRIMARY KEY,
                    BatchId bigint NOT NULL,
                    ClaimID nvarchar(100) NOT NULL,
                    TaskID nvarchar(100) NULL,
                    PatientId nvarchar(100) NULL,
                    PayerName nvarchar(255) NULL,
                    AssignedTo nvarchar(100) NULL,
                    ClaimStatus nvarchar(100) NULL,
                    DenialCode nvarchar(100) NOT NULL,
                    ICDComplianceStatus nvarchar(255) NULL,
                    CoverageStatus nvarchar(255) NULL,
                    OldActionCode nvarchar(100) NULL,
                    NewActionCode nvarchar(100) NULL,
                    OldActionCategory nvarchar(500) NULL,
                    NewActionCategory nvarchar(500) NULL,
                    OldTask nvarchar(500) NULL,
                    NewTask nvarchar(500) NULL,
                    OldShortCategory nvarchar(255) NULL,
                    NewShortCategory nvarchar(255) NULL,
                    VerificationStatus nvarchar(50) NOT NULL CONSTRAINT DF_DCACV_VerificationStatus DEFAULT 'Pending',
                    VerifiedBy nvarchar(100) NULL,
                    VerifiedOn datetime2(0) NULL,
                    CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DCACV_CreatedOn DEFAULT SYSUTCDATETIME(),
                    CONSTRAINT FK_DCACV_Batch FOREIGN KEY (BatchId) REFERENCES dbo.DenialCodeActionChangeBatch(BatchId)
                );
            END;

            IF COL_LENGTH('dbo.DenialTaskBoard','ShortCategory') IS NULL
                ALTER TABLE dbo.DenialTaskBoard ADD ShortCategory nvarchar(255) NULL;

            IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DCACV_Batch_Status' AND object_id=OBJECT_ID('dbo.DenialCodeActionChangeVerification'))
                CREATE INDEX IX_DCACV_Batch_Status ON dbo.DenialCodeActionChangeVerification(BatchId, VerificationStatus);
            IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DCACV_Denial_Key' AND object_id=OBJECT_ID('dbo.DenialCodeActionChangeVerification'))
                CREATE INDEX IX_DCACV_Denial_Key ON dbo.DenialCodeActionChangeVerification(DenialCode, ICDComplianceStatus, CoverageStatus);
            IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DCACV_Claim_Task' AND object_id=OBJECT_ID('dbo.DenialCodeActionChangeVerification'))
                CREATE INDEX IX_DCACV_Claim_Task ON dbo.DenialCodeActionChangeVerification(ClaimID, TaskID);
            """;

        await using var cmd = new SqlCommand(sql, conn, tx) { CommandTimeout = 180 };
        await cmd.ExecuteNonQueryAsync(ct);

        await using var procCmd = new SqlCommand("""
            CREATE OR ALTER PROCEDURE dbo.usp_DenialActionChange_RecountBatch
                @BatchId bigint
            AS
            BEGIN
                SET NOCOUNT ON;
                IF @BatchId IS NULL RETURN;

                UPDATE b
                SET PendingCount = counts.PendingCount,
                    ConfirmedCount = counts.ConfirmedCount,
                    IgnoredCount = counts.IgnoredCount,
                    Status = CASE WHEN counts.PendingCount = 0 THEN 'Completed' ELSE 'Pending' END
                FROM dbo.DenialCodeActionChangeBatch b
                CROSS APPLY
                (
                    SELECT
                        SUM(CASE WHEN v.VerificationStatus = 'Pending' THEN 1 ELSE 0 END) AS PendingCount,
                        SUM(CASE WHEN v.VerificationStatus = 'Confirmed' THEN 1 ELSE 0 END) AS ConfirmedCount,
                        SUM(CASE WHEN v.VerificationStatus IN ('Ignored', 'Skipped') THEN 1 ELSE 0 END) AS IgnoredCount
                    FROM dbo.DenialCodeActionChangeVerification v
                    WHERE v.BatchId = b.BatchId
                ) counts
                WHERE b.BatchId = @BatchId;
            END
            """, conn, tx) { CommandTimeout = 180 };
        await procCmd.ExecuteNonQueryAsync(ct);
    }

    private static DataTable BuildImportTable(IReadOnlyList<DenialCodeMasterRequest> records, string? userName)
    {
        var table = new DataTable();
        table.Columns.Add("DenialCode", typeof(string));
        table.Columns.Add("DenialDescription", typeof(string));
        table.Columns.Add("DenialClassification", typeof(string));
        table.Columns.Add("CoverageStatus", typeof(string));
        table.Columns.Add("ICDComplianceStatus", typeof(string));
        table.Columns.Add("DenialValidity", typeof(string));
        table.Columns.Add("ActionCode", typeof(string));
        table.Columns.Add("RecommendedAction", typeof(string));
        table.Columns.Add("ActionCategory", typeof(string));
        table.Columns.Add("Task", typeof(string));
        table.Columns.Add("ShortCategory", typeof(string));
        table.Columns.Add("Priority", typeof(string));
        table.Columns.Add("SLADays", typeof(string));
        table.Columns.Add("NotesComments", typeof(string));
        table.Columns.Add("CreatedBy", typeof(string));

        foreach (var record in records)
        {
            table.Rows.Add(
                record.DenialCode,
                DbImportValue(record.DenialDescription),
                DbImportValue(record.DenialClassification),
                record.CoverageStatus,
                record.ICDComplianceStatus,
                DbImportValue(record.DenialValidity),
                DbImportValue(record.ActionCode),
                DbImportValue(record.RecommendedAction),
                DbImportValue(record.ActionCategory),
                DbImportValue(record.Task),
                DbImportValue(record.ShortCategory),
                DbImportValue(record.Priority),
                DbImportValue(record.SLADays),
                DbImportValue(record.NotesComments),
                DbImportValue(userName));
        }

        return table;
    }

    private static object DbImportValue(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

    private static string ImportKey(DenialCodeMasterRequest record)
        => $"{record.DenialCode}\u001f{record.CoverageStatus}\u001f{record.ICDComplianceStatus}";

    private static void TrimImportRecord(DenialCodeMasterRequest record)
    {
        static string? Trim(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
        static string StatusOrDefault(string? value) => string.IsNullOrWhiteSpace(value) ? "N/A" : value.Trim();
        record.DenialCode = record.DenialCode.Trim();
        record.DenialDescription = Trim(record.DenialDescription);
        record.DenialClassification = Trim(record.DenialClassification);
        record.CoverageStatus = StatusOrDefault(record.CoverageStatus);
        record.ICDComplianceStatus = StatusOrDefault(record.ICDComplianceStatus);
        record.DenialValidity = Trim(record.DenialValidity);
        record.ActionCode = Trim(record.ActionCode);
        record.RecommendedAction = Trim(record.RecommendedAction);
        record.ActionCategory = Trim(record.ActionCategory);
        record.Task = Trim(record.Task);
        record.ShortCategory = Trim(record.ShortCategory);
        record.Priority = Trim(record.Priority);
        record.SLADays = Trim(record.SLADays);
        record.NotesComments = Trim(record.NotesComments);
    }

    private static async Task InsertAsync(SqlConnection conn, SqlTransaction? tx, DenialCodeMasterRequest request, string? userName, CancellationToken ct)
    {
        const string sql = """
            INSERT INTO dbo.DenialCodeMaster
                (DenialCode, DenialDescription, DenialClassification, CoverageStatus, ICDComplianceStatus,
                 DenialValidity, ActionCode, RecommendedAction, ActionCategory, Task, ShortCategory,
                 Priority, SLADays, NotesComments, CreatedBy)
            VALUES
                (@DenialCode, @DenialDescription, @DenialClassification, @CoverageStatus, @ICDComplianceStatus,
                 @DenialValidity, @ActionCode, @RecommendedAction, @ActionCategory, @Task, @ShortCategory,
                 @Priority, @SLADays, @NotesComments, @CreatedBy);
            """;
        await using var cmd = new SqlCommand(sql, conn, tx);
        AddParams(cmd, request);
        cmd.Parameters.Add(new SqlParameter("@CreatedBy", DbValue(userName)));
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task DeleteAsync(SqlConnection conn, SqlTransaction? tx, string denialCode, string coverageStatus, string icdComplianceStatus, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("""
            DELETE FROM dbo.DenialCodeMaster
            WHERE DenialCode = @DenialCode
              AND CoverageStatus = @CoverageStatus
              AND ICDComplianceStatus = @ICDComplianceStatus;
            """, conn, tx);
        AddKeyParams(cmd, denialCode, coverageStatus, icdComplianceStatus);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task<bool> ExistsAsync(SqlConnection conn, SqlTransaction? tx, string denialCode, string coverageStatus, string icdComplianceStatus, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("""
            SELECT COUNT(1)
            FROM dbo.DenialCodeMaster
            WHERE DenialCode = @DenialCode
              AND CoverageStatus = @CoverageStatus
              AND ICDComplianceStatus = @ICDComplianceStatus;
            """, conn, tx);
        AddKeyParams(cmd, denialCode, coverageStatus, icdComplianceStatus);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct) ?? 0) > 0;
    }

    private static string SearchWhere(string? search, out List<SqlParameter> parameters)
    {
        parameters = [];
        if (string.IsNullOrWhiteSpace(search)) return "1 = 1";
        parameters.Add(new SqlParameter("@Search", $"%{search.Trim()}%"));
        return """
            (DenialCode LIKE @Search OR DenialDescription LIKE @Search OR DenialClassification LIKE @Search
             OR CoverageStatus LIKE @Search OR ICDComplianceStatus LIKE @Search OR ActionCode LIKE @Search OR ActionCategory LIKE @Search)
            """;
    }

    private static void AddParams(SqlCommand cmd, DenialCodeMasterRequest r)
    {
        cmd.Parameters.Add(new SqlParameter("@DenialCode", r.DenialCode.Trim()));
        cmd.Parameters.Add(new SqlParameter("@DenialDescription", DbValue(r.DenialDescription)));
        cmd.Parameters.Add(new SqlParameter("@DenialClassification", DbValue(r.DenialClassification)));
        cmd.Parameters.Add(new SqlParameter("@CoverageStatus", r.CoverageStatus!.Trim()));
        cmd.Parameters.Add(new SqlParameter("@ICDComplianceStatus", r.ICDComplianceStatus!.Trim()));
        cmd.Parameters.Add(new SqlParameter("@DenialValidity", DbValue(r.DenialValidity)));
        cmd.Parameters.Add(new SqlParameter("@ActionCode", DbValue(r.ActionCode)));
        cmd.Parameters.Add(new SqlParameter("@RecommendedAction", DbValue(r.RecommendedAction)));
        cmd.Parameters.Add(new SqlParameter("@ActionCategory", DbValue(r.ActionCategory)));
        cmd.Parameters.Add(new SqlParameter("@Task", DbValue(r.Task)));
        cmd.Parameters.Add(new SqlParameter("@ShortCategory", DbValue(r.ShortCategory)));
        cmd.Parameters.Add(new SqlParameter("@Priority", DbValue(r.Priority)));
        cmd.Parameters.Add(new SqlParameter("@SLADays", DbValue(r.SLADays)));
        cmd.Parameters.Add(new SqlParameter("@NotesComments", DbValue(r.NotesComments)));
    }

    private static void AddKeyParams(SqlCommand cmd, string denialCode, string coverageStatus, string icdComplianceStatus)
    {
        cmd.Parameters.Add(new SqlParameter("@DenialCode", denialCode.Trim()));
        cmd.Parameters.Add(new SqlParameter("@CoverageStatus", coverageStatus.Trim()));
        cmd.Parameters.Add(new SqlParameter("@ICDComplianceStatus", icdComplianceStatus.Trim()));
    }

    private static void AddOriginalKeyParams(SqlCommand cmd, string denialCode, string coverageStatus, string icdComplianceStatus)
    {
        cmd.Parameters.Add(new SqlParameter("@OriginalDenialCode", denialCode.Trim()));
        cmd.Parameters.Add(new SqlParameter("@OriginalCoverageStatus", coverageStatus.Trim()));
        cmd.Parameters.Add(new SqlParameter("@OriginalICDComplianceStatus", icdComplianceStatus.Trim()));
    }

    private static object DbValue(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();
    private static SqlParameter[] CloneParams(List<SqlParameter> source) => source.Select(p => new SqlParameter(p.ParameterName, p.Value)).ToArray();

    private static async Task<IReadOnlyList<string>> ReadStringsAsync(SqlDataReader reader, CancellationToken ct)
    {
        var values = new List<string>();
        while (await reader.ReadAsync(ct))
        {
            if (!reader.IsDBNull(0))
            {
                var value = reader.GetString(0).Trim();
                if (value.Length > 0) values.Add(value);
            }
        }
        return values;
    }

    private static DenialCodeMasterRecord Map(SqlDataReader r) => new()
    {
        DenialCode = r.GetString(r.GetOrdinal("DenialCode")),
        DenialDescription = GetString(r, "DenialDescription"),
        DenialClassification = GetString(r, "DenialClassification"),
        CoverageStatus = GetString(r, "CoverageStatus"),
        ICDComplianceStatus = GetString(r, "ICDComplianceStatus"),
        DenialValidity = GetString(r, "DenialValidity"),
        ActionCode = GetString(r, "ActionCode"),
        RecommendedAction = GetString(r, "RecommendedAction"),
        ActionCategory = GetString(r, "ActionCategory"),
        Task = GetString(r, "Task"),
        ShortCategory = GetString(r, "ShortCategory"),
        Priority = GetString(r, "Priority"),
        SLADays = GetString(r, "SLADays"),
        NotesComments = GetString(r, "NotesComments"),
        CreatedOn = r.GetDateTime(r.GetOrdinal("CreatedOn")),
        CreatedBy = GetString(r, "CreatedBy"),
        UpdatedOn = r.IsDBNull(r.GetOrdinal("UpdatedOn")) ? null : r.GetDateTime(r.GetOrdinal("UpdatedOn")),
        UpdatedBy = GetString(r, "UpdatedBy")
    };

    private static string? GetString(SqlDataReader r, string column) => r.IsDBNull(r.GetOrdinal(column)) ? null : r.GetString(r.GetOrdinal(column));

    internal SqlConnection OpenLab(int labId)
    {
        if (labId <= 0) throw new InvalidOperationException("LabId is required.");
        if (_labConnectionsById.TryGetValue(labId, out var conn) && !string.IsNullOrWhiteSpace(conn))
            return new SqlConnection(conn);

        throw new InvalidOperationException($"No lab database connection string is configured for LabId {labId}. Add LabConfig:LabsID and a matching ConnectionStrings entry.");
    }

    private static string ResolveLabConnectionString(IConfiguration configuration, int labId, string labName, string? connectionKey = null)
    {
        var byId = configuration.GetConnectionString($"Lab_{labId}");
        if (!string.IsNullOrWhiteSpace(byId)) return byId;

        if (!string.IsNullOrWhiteSpace(connectionKey))
        {
            var byConnectionKey = configuration.GetConnectionString(connectionKey.Trim());
            if (!string.IsNullOrWhiteSpace(byConnectionKey)) return byConnectionKey;
        }

        var normalized = NormalizeKey(labName);
        var knownKey = normalized switch
        {
            "PCRLABSOFAMERICA" or "PCRLOA" => "PCRLOAConnStr",
            "COVE" => "CoveConnection",
            "INHEALTHDTR" or "INHEALTH" => "InHealthConn",
            "ELIXIR" => "ElixirConnection",
            "CERTUS" or "CERTUSLABORATORIES" => "CertusConnection",
            "BEECHTREE" => "BeechTreeConnStr",
            "AUGUSTUSLABS" or "AUGUSTUS" => "AugustusConnStr",
            "NORTHWEST" or "NWL" => "NWLConnection",
            "PCRDXAL" => "PCRALConnection",
            "PCRDXCO" => "PCRDxConnection",
            "PHILIFE" => "PhiLifeConnStr",
            "RISINGTIDES" => "RisingTidesConnStr",
            _ => string.Empty
        };

        if (!string.IsNullOrWhiteSpace(knownKey))
        {
            var conn = configuration.GetConnectionString(knownKey);
            if (!string.IsNullOrWhiteSpace(conn)) return conn;
        }

        foreach (var section in configuration.GetSection("ConnectionStrings").GetChildren())
        {
            var key = NormalizeKey(section.Key);
            if (key.Contains(normalized, StringComparison.OrdinalIgnoreCase) || normalized.Contains(key.Replace("CONNECTION", "").Replace("CONNSTR", ""), StringComparison.OrdinalIgnoreCase))
                return section.Value ?? string.Empty;
        }

        return string.Empty;
    }

    private static string NormalizeKey(string value)
        => new string((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

    private sealed class LabConfigItem
    {
        public int Id { get; set; }
        public string Name { get; set; } = string.Empty;
        public string ConnectionKey { get; set; } = string.Empty;
        public bool IsActive { get; set; } = true;
    }

    private static List<LabConfigItem> DefaultActiveLabs() =>
    [
        new() { Id = 2, Name = "InHealth", ConnectionKey = "InHealthConn" },
        new() { Id = 4, Name = "Cove", ConnectionKey = "CoveConnection" },
        new() { Id = 7, Name = "PCRDx - AL", ConnectionKey = "PCRALConnection" },
        new() { Id = 8, Name = "PCRDx - CO", ConnectionKey = "PCRDxConnection" },
        new() { Id = 9, Name = "Rising Tides", ConnectionKey = "RisingTidesConnStr" },
        new() { Id = 10, Name = "BeechTree", ConnectionKey = "BeechTreeConnStr" },
        new() { Id = 12, Name = "Phi Life", ConnectionKey = "PhiLifeConnStr" },
        new() { Id = 13, Name = "PCR Labs of America", ConnectionKey = "PCRLOAConnStr" },
        new() { Id = 16, Name = "Elixir", ConnectionKey = "ElixirConnection" },
        new() { Id = 18, Name = "Certus", ConnectionKey = "CertusConnection" },
        new() { Id = 19, Name = "Augustus Labs", ConnectionKey = "AugustusConnStr" },
        new() { Id = 23, Name = "NorthWest", ConnectionKey = "NWLConnection" }
    ];
}

public sealed class DenialCodeMasterExcelService : IDenialCodeMasterExcelService
{
    private const string SheetName = "Denial Classifier";
    private readonly IDenialCodeMasterRepository _repo;
    private readonly DenialCodeMasterExportOptions _options;

    public DenialCodeMasterExcelService(IDenialCodeMasterRepository repo, IOptions<DenialCodeMasterExportOptions> options)
    {
        _repo = repo;
        _options = options.Value;
    }

    public async Task<DenialCodeMasterImportResult> ImportAsync(int labId, Stream stream, string? sourceFileName, string? userName, CancellationToken ct)
    {
        using var workbook = new XLWorkbook(stream);
        if (!workbook.TryGetWorksheet(SheetName, out var sheet))
            return new DenialCodeMasterImportResult { FailedCount = 1, Errors = [$"Worksheet '{SheetName}' was not found."] };

        var records = new List<DenialCodeMasterRequest>();
        var errors = new List<string>();
        var skipped = 0;
        var lastRow = sheet.LastRowUsed()?.RowNumber() ?? 0;

        for (var row = 3; row <= lastRow; row++)
        {
            var code = Text(sheet.Cell(row, 1));
            var coverageStatus = StatusOrDefault(Text(sheet.Cell(row, 4)));
            var icdComplianceStatus = StatusOrDefault(Text(sheet.Cell(row, 5)));
            if (string.IsNullOrWhiteSpace(code))
            {
                skipped++;
                continue;
            }

            records.Add(new DenialCodeMasterRequest
            {
                DenialCode = code,
                DenialDescription = Text(sheet.Cell(row, 2)),
                DenialClassification = Text(sheet.Cell(row, 3)),
                CoverageStatus = coverageStatus,
                ICDComplianceStatus = icdComplianceStatus,
                DenialValidity = Text(sheet.Cell(row, 6)),
                ActionCode = Text(sheet.Cell(row, 7)),
                RecommendedAction = Text(sheet.Cell(row, 8)),
                ActionCategory = Text(sheet.Cell(row, 9)),
                Task = Text(sheet.Cell(row, 10)),
                ShortCategory = Text(sheet.Cell(row, 11)),
                Priority = Text(sheet.Cell(row, 12)),
                SLADays = Text(sheet.Cell(row, 13)),
                NotesComments = Text(sheet.Cell(row, 14))
            });
        }

        var result = await _repo.ReplaceFromImportAsync(labId, records, skipped, errors, sourceFileName, userName, ct);
        if (result.FailedCount == 0) await RegenerateExportAsync(labId, ct);
        return result;
    }

    public async Task<string> RegenerateExportAsync(int labId, CancellationToken ct)
    {
        var records = await _repo.GetAllAsync(labId, ct);
        Directory.CreateDirectory(_options.ExportFolderPath);
        var path = Path.Combine(_options.ExportFolderPath, _options.ExportFileName);

        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add(SheetName);
        sheet.Cell(1, 1).Value = "INDEPENDENT LABORATORY - DENIAL ACTION CLASSIFIER";
        sheet.Range(1, 1, 1, 14).Merge().Style.Font.SetBold();

        string[] headers = ["Denial Code", "Denial Description", "Denial Classification", "Coverage Status", "ICD Compliance Status", "Denial Validity", "Action Code", "Recommended Action", "Action Category", "Task", "Short Category", "Priority", "SLA (Days)", "Notes / Comments"];
        for (var i = 0; i < headers.Length; i++)
        {
            var cell = sheet.Cell(2, i + 1);
            cell.Value = headers[i];
            cell.Style.Font.Bold = true;
        }

        var row = 3;
        foreach (var record in records)
        {
            sheet.Cell(row, 1).Value = record.DenialCode;
            sheet.Cell(row, 2).Value = record.DenialDescription;
            sheet.Cell(row, 3).Value = record.DenialClassification;
            sheet.Cell(row, 4).Value = record.CoverageStatus;
            sheet.Cell(row, 5).Value = record.ICDComplianceStatus;
            sheet.Cell(row, 6).Value = record.DenialValidity;
            sheet.Cell(row, 7).Value = record.ActionCode;
            sheet.Cell(row, 8).Value = record.RecommendedAction;
            sheet.Cell(row, 9).Value = record.ActionCategory;
            sheet.Cell(row, 10).Value = record.Task;
            sheet.Cell(row, 11).Value = record.ShortCategory;
            sheet.Cell(row, 12).Value = record.Priority;
            sheet.Cell(row, 13).Value = record.SLADays;
            sheet.Cell(row, 14).Value = record.NotesComments;
            row++;
        }

        sheet.SheetView.FreezeRows(2);
        sheet.Columns().AdjustToContents();
        workbook.SaveAs(path);
        return path;
    }

    private static string? Text(IXLCell cell)
    {
        var value = cell.GetFormattedString().Trim();
        return string.IsNullOrWhiteSpace(value) ? null : value;
    }

    private static string StatusOrDefault(string? value) => string.IsNullOrWhiteSpace(value) ? "N/A" : value.Trim();
}

internal sealed record DenialCodeActionChangeSummary(long BatchId, int AffectedClaims, int AffectedTasks);

public sealed class SqlDenialActionChangeVerificationRepository : IDenialActionChangeVerificationRepository
{
    private readonly SqlDenialCodeMasterRepository _masterRepository;

    public SqlDenialActionChangeVerificationRepository(IConfiguration configuration)
    {
        _masterRepository = new SqlDenialCodeMasterRepository(configuration);
    }

    public async Task<PagedResult<DenialActionChangeVerification>> GetVerificationItemsAsync(DenialActionChangeQuery query, CancellationToken ct)
    {
        query.Page = query.Page <= 0 ? 1 : query.Page;
        query.PageSize = query.PageSize <= 0 ? 50 : Math.Clamp(query.PageSize, 10, 200);
        var result = new PagedResult<DenialActionChangeVerification> { Page = query.Page, PageSize = query.PageSize };
        await using var conn = OpenLab(query.LabId);
        await conn.OpenAsync(ct);
        await SqlDenialCodeMasterRepository.EnsureActionChangeSchemaAsync(conn, null, ct);
        var where = BuildWhere(query, out var parameters);

        await using (var countCmd = new SqlCommand($"SELECT COUNT(1) FROM dbo.DenialCodeActionChangeVerification v WHERE {where}", conn))
        {
            countCmd.Parameters.AddRange(CloneParams(parameters));
            result.TotalCount = Convert.ToInt32(await countCmd.ExecuteScalarAsync(ct) ?? 0);
        }

        var sql = $"""
            SELECT VerificationId, BatchId, ClaimID, TaskID, PatientId, PayerName, AssignedTo, ClaimStatus,
                   DenialCode, ICDComplianceStatus, CoverageStatus,
                   OldActionCode, NewActionCode, OldActionCategory, NewActionCategory,
                   OldTask, NewTask, OldShortCategory, NewShortCategory,
                   VerificationStatus, VerifiedBy, VerifiedOn, CreatedOn
            FROM dbo.DenialCodeActionChangeVerification v
            WHERE {where}
            ORDER BY CASE WHEN VerificationStatus = 'Pending' THEN 0 ELSE 1 END, CreatedOn DESC, VerificationId DESC
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """;
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddRange(CloneParams(parameters));
        cmd.Parameters.Add(new SqlParameter("@Offset", (query.Page - 1) * query.PageSize));
        cmd.Parameters.Add(new SqlParameter("@PageSize", query.PageSize));
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) result.Items.Add(MapVerification(reader));
        return result;
    }

    public async Task<DenialActionChangeBatch?> GetBatchAsync(int labId, long batchId, CancellationToken ct)
    {
        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);
        await SqlDenialCodeMasterRepository.EnsureActionChangeSchemaAsync(conn, null, ct);
        await using var cmd = new SqlCommand("""
            SELECT BatchId, SourceFileName, UploadedBy, UploadedOn, TotalAffectedClaims, TotalAffectedTasks,
                   PendingCount, ConfirmedCount, IgnoredCount, Status
            FROM dbo.DenialCodeActionChangeBatch
            WHERE BatchId = @BatchId;
            """, conn);
        cmd.Parameters.Add(new SqlParameter("@BatchId", batchId));
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? MapBatch(reader) : null;
    }

    public async Task<DenialActionChangeLookups> GetLookupsAsync(int labId, CancellationToken ct)
    {
        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);
        await SqlDenialCodeMasterRepository.EnsureActionChangeSchemaAsync(conn, null, ct);
        await using var cmd = new SqlCommand("""
            SELECT TOP (50) BatchId, SourceFileName, UploadedBy, UploadedOn, TotalAffectedClaims, TotalAffectedTasks, PendingCount, ConfirmedCount, IgnoredCount, Status
            FROM dbo.DenialCodeActionChangeBatch
            ORDER BY UploadedOn DESC, BatchId DESC;
            SELECT DISTINCT DenialCode FROM dbo.DenialCodeActionChangeVerification WHERE NULLIF(LTRIM(RTRIM(DenialCode)), '') IS NOT NULL ORDER BY DenialCode;
            SELECT DISTINCT ICDComplianceStatus FROM dbo.DenialCodeActionChangeVerification WHERE NULLIF(LTRIM(RTRIM(ICDComplianceStatus)), '') IS NOT NULL ORDER BY ICDComplianceStatus;
            SELECT DISTINCT CoverageStatus FROM dbo.DenialCodeActionChangeVerification WHERE NULLIF(LTRIM(RTRIM(CoverageStatus)), '') IS NOT NULL ORDER BY CoverageStatus;
            SELECT DISTINCT AssignedTo FROM dbo.DenialCodeActionChangeVerification WHERE NULLIF(LTRIM(RTRIM(AssignedTo)), '') IS NOT NULL ORDER BY AssignedTo;
            """, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var batches = new List<DenialActionChangeBatch>();
        while (await reader.ReadAsync(ct)) batches.Add(MapBatch(reader));
        await reader.NextResultAsync(ct);
        var denialCodes = await ReadStringsAsync(reader, ct);
        await reader.NextResultAsync(ct);
        var icd = await ReadStringsAsync(reader, ct);
        await reader.NextResultAsync(ct);
        var coverage = await ReadStringsAsync(reader, ct);
        await reader.NextResultAsync(ct);
        var assigned = await ReadStringsAsync(reader, ct);
        return new DenialActionChangeLookups { Batches = batches, DenialCodes = denialCodes, ICDComplianceStatuses = icd, CoverageStatuses = coverage, AssignedUsers = assigned };
    }

    public Task<DenialActionChangeResult> ConfirmAsync(int labId, long verificationId, string? userName, CancellationToken ct)
        => ApplyAsync(labId, "ConfirmOne", verificationId, null, userName, ct);

    public async Task<DenialActionChangeResult> ConfirmSelectedAsync(int labId, IReadOnlyList<long> verificationIds, string? userName, CancellationToken ct)
    {
        var done = 0;
        foreach (var id in verificationIds.Distinct())
        {
            var result = await ConfirmAsync(labId, id, userName, ct);
            if (result.Success) done++;
        }
        return new DenialActionChangeResult { Success = done > 0, Message = $"Confirmed {done} selected action change(s)." };
    }

    public Task<DenialActionChangeResult> ConfirmAllAsync(int labId, long batchId, string? userName, CancellationToken ct)
        => ApplyAsync(labId, "ConfirmAll", null, batchId, userName, ct);

    public Task<DenialActionChangeResult> IgnoreAsync(int labId, long verificationId, string? userName, CancellationToken ct)
        => ApplyAsync(labId, "IgnoreOne", verificationId, null, userName, ct);

    public async Task<byte[]> ExportAsync(DenialActionChangeQuery query, CancellationToken ct)
    {
        query.Page = 1;
        query.PageSize = 200000;
        var rows = await GetVerificationItemsAsync(query, ct);
        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add("Action Verification");
        string[] headers = ["VerificationId", "BatchId", "ClaimID", "TaskID", "PatientId", "PayerName", "AssignedTo", "ClaimStatus", "DenialCode", "ICDComplianceStatus", "CoverageStatus", "OldActionCode", "NewActionCode", "OldActionCategory", "NewActionCategory", "OldTask", "NewTask", "OldShortCategory", "NewShortCategory", "VerificationStatus", "VerifiedBy", "VerifiedOn", "CreatedOn"];
        for (var i = 0; i < headers.Length; i++) sheet.Cell(1, i + 1).Value = headers[i];
        var r = 2;
        foreach (var x in rows.Items)
        {
            sheet.Cell(r, 1).Value = x.VerificationId;
            sheet.Cell(r, 2).Value = x.BatchId;
            sheet.Cell(r, 3).Value = x.ClaimID;
            sheet.Cell(r, 4).Value = x.TaskID;
            sheet.Cell(r, 5).Value = x.PatientId;
            sheet.Cell(r, 6).Value = x.PayerName;
            sheet.Cell(r, 7).Value = x.AssignedTo;
            sheet.Cell(r, 8).Value = x.ClaimStatus;
            sheet.Cell(r, 9).Value = x.DenialCode;
            sheet.Cell(r, 10).Value = x.ICDComplianceStatus;
            sheet.Cell(r, 11).Value = x.CoverageStatus;
            sheet.Cell(r, 12).Value = x.OldActionCode;
            sheet.Cell(r, 13).Value = x.NewActionCode;
            sheet.Cell(r, 14).Value = x.OldActionCategory;
            sheet.Cell(r, 15).Value = x.NewActionCategory;
            sheet.Cell(r, 16).Value = x.OldTask;
            sheet.Cell(r, 17).Value = x.NewTask;
            sheet.Cell(r, 18).Value = x.OldShortCategory;
            sheet.Cell(r, 19).Value = x.NewShortCategory;
            sheet.Cell(r, 20).Value = x.VerificationStatus;
            sheet.Cell(r, 21).Value = x.VerifiedBy;
            sheet.Cell(r, 22).Value = x.VerifiedOn;
            sheet.Cell(r, 23).Value = x.CreatedOn;
            r++;
        }
        sheet.Range(1, 1, 1, headers.Length).Style.Font.SetBold();
        sheet.Columns().AdjustToContents();
        using var ms = new MemoryStream();
        workbook.SaveAs(ms);
        return ms.ToArray();
    }

    private async Task<DenialActionChangeResult> ApplyAsync(int labId, string mode, long? verificationId, long? batchId, string? userName, CancellationToken ct)
    {
        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);
        await SqlDenialCodeMasterRepository.EnsureActionChangeSchemaAsync(conn, null, ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        try
        {
            var sql = mode switch
            {
                "IgnoreOne" => IgnoreSql,
                "ConfirmAll" => ConfirmSql.Replace("v.VerificationId = @VerificationId", "v.BatchId = @BatchId"),
                _ => ConfirmSql
            };
            await using var cmd = new SqlCommand(sql, conn, (SqlTransaction)tx) { CommandTimeout = 180 };
            cmd.Parameters.Add(new SqlParameter("@VerificationId", (object?)verificationId ?? DBNull.Value));
            cmd.Parameters.Add(new SqlParameter("@BatchId", (object?)batchId ?? DBNull.Value));
            cmd.Parameters.Add(new SqlParameter("@UserName", DbValue(userName ?? "ReactWorkflow")));
            var message = Convert.ToString(await cmd.ExecuteScalarAsync(ct)) ?? "Action change verification updated.";
            await tx.CommitAsync(ct);
            return new DenialActionChangeResult { Success = true, Message = message };
        }
        catch
        {
            await tx.RollbackAsync(CancellationToken.None);
            throw;
        }
    }

    private const string ConfirmSql = """
        DECLARE @Updated int = 0, @Skipped int = 0, @TouchedBatch bigint;
        SELECT TOP (1) @TouchedBatch = v.BatchId
        FROM dbo.DenialCodeActionChangeVerification v
        WHERE v.VerificationId = @VerificationId AND v.VerificationStatus = 'Pending';

        UPDATE t
        SET t.ActionCode = v.NewActionCode,
            t.ActionCategory = v.NewActionCategory,
            t.Task = v.NewTask,
            t.ShortCategory = v.NewShortCategory
        FROM dbo.DenialTaskBoard t
        INNER JOIN dbo.DenialCodeActionChangeVerification v ON v.TaskID = t.TaskID AND v.ClaimID = t.ClaimID
        WHERE v.VerificationId = @VerificationId
          AND v.VerificationStatus = 'Pending'
          AND NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo, ''))), '') IS NOT NULL
          AND LOWER(LTRIM(RTRIM(ISNULL(t.Status, '')))) NOT IN ('close', 'closed')
          AND LOWER(LTRIM(RTRIM(ISNULL(t.WorkFlowStatus, '')))) NOT IN ('close', 'closed', 'closed claim');
        SET @Updated = @@ROWCOUNT;

        UPDATE v
        SET VerificationStatus = CASE WHEN EXISTS (
                SELECT 1 FROM dbo.DenialTaskBoard t
                WHERE t.TaskID = v.TaskID AND t.ClaimID = v.ClaimID
                  AND NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo, ''))), '') IS NOT NULL
                  AND LOWER(LTRIM(RTRIM(ISNULL(t.Status, '')))) NOT IN ('close', 'closed')
                  AND LOWER(LTRIM(RTRIM(ISNULL(t.WorkFlowStatus, '')))) NOT IN ('close', 'closed', 'closed claim')
            ) THEN 'Confirmed' ELSE 'Ignored' END,
            VerifiedBy = @UserName,
            VerifiedOn = SYSUTCDATETIME()
        FROM dbo.DenialCodeActionChangeVerification v
        WHERE v.VerificationId = @VerificationId AND v.VerificationStatus = 'Pending';
        SET @Skipped = @@ROWCOUNT - @Updated;

        EXEC dbo.usp_DenialActionChange_RecountBatch @TouchedBatch;
        SELECT CASE WHEN @Updated > 0 THEN CONCAT('Applied action changes to ', @Updated, ' open task(s).')
                    ELSE 'This claim/task is already closed and was not updated.' END;
        """;

    private const string IgnoreSql = """
        DECLARE @TouchedBatch bigint;
        SELECT TOP (1) @TouchedBatch = BatchId
        FROM dbo.DenialCodeActionChangeVerification
        WHERE VerificationId = @VerificationId AND VerificationStatus = 'Pending';

        UPDATE dbo.DenialCodeActionChangeVerification
        SET VerificationStatus = 'Ignored',
            VerifiedBy = @UserName,
            VerifiedOn = SYSUTCDATETIME()
        WHERE VerificationId = @VerificationId AND VerificationStatus = 'Pending';
        EXEC dbo.usp_DenialActionChange_RecountBatch @TouchedBatch;
        SELECT 'Action change ignored. Assigned task was not updated.';
        """;

    private static string BuildWhere(DenialActionChangeQuery q, out List<SqlParameter> p)
    {
        var parts = new List<string> { "1 = 1" };
        p = [];
        if (q.BatchId is > 0) { parts.Add("v.BatchId = @BatchId"); p.Add(new SqlParameter("@BatchId", q.BatchId.Value)); }
        if (!string.IsNullOrWhiteSpace(q.Status)) { parts.Add("v.VerificationStatus = @Status"); p.Add(new SqlParameter("@Status", q.Status.Trim())); }
        if (!string.IsNullOrWhiteSpace(q.DenialCode)) { parts.Add("v.DenialCode = @DenialCode"); p.Add(new SqlParameter("@DenialCode", q.DenialCode.Trim())); }
        if (!string.IsNullOrWhiteSpace(q.ICDComplianceStatus)) { parts.Add("v.ICDComplianceStatus = @ICDComplianceStatus"); p.Add(new SqlParameter("@ICDComplianceStatus", q.ICDComplianceStatus.Trim())); }
        if (!string.IsNullOrWhiteSpace(q.CoverageStatus)) { parts.Add("v.CoverageStatus = @CoverageStatus"); p.Add(new SqlParameter("@CoverageStatus", q.CoverageStatus.Trim())); }
        if (!string.IsNullOrWhiteSpace(q.AssignedTo)) { parts.Add("v.AssignedTo = @AssignedTo"); p.Add(new SqlParameter("@AssignedTo", q.AssignedTo.Trim())); }
        if (!string.IsNullOrWhiteSpace(q.Search))
        {
            parts.Add("(v.ClaimID LIKE @Search OR v.TaskID LIKE @Search OR v.PatientId LIKE @Search OR v.PayerName LIKE @Search OR v.DenialCode LIKE @Search)");
            p.Add(new SqlParameter("@Search", $"%{q.Search.Trim()}%"));
        }
        return string.Join(" AND ", parts);
    }

    private SqlConnection OpenLab(int labId)
    {
        return _masterRepository.OpenLab(labId);
    }

    private static SqlParameter[] CloneParams(List<SqlParameter> source) => source.Select(x => new SqlParameter(x.ParameterName, x.Value)).ToArray();
    private static object DbValue(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();
    private static string? GetString(SqlDataReader r, string column) => r.IsDBNull(r.GetOrdinal(column)) ? null : r.GetString(r.GetOrdinal(column));
    private static DateTime? GetDate(SqlDataReader r, string column) => r.IsDBNull(r.GetOrdinal(column)) ? null : r.GetDateTime(r.GetOrdinal(column));

    private static async Task<IReadOnlyList<string>> ReadStringsAsync(SqlDataReader reader, CancellationToken ct)
    {
        var values = new List<string>();
        while (await reader.ReadAsync(ct))
        {
            if (!reader.IsDBNull(0))
            {
                var value = reader.GetString(0).Trim();
                if (value.Length > 0) values.Add(value);
            }
        }
        return values;
    }

    private static DenialActionChangeBatch MapBatch(SqlDataReader r) => new()
    {
        BatchId = r.GetInt64(r.GetOrdinal("BatchId")),
        SourceFileName = GetString(r, "SourceFileName") ?? string.Empty,
        UploadedBy = GetString(r, "UploadedBy") ?? string.Empty,
        UploadedOn = r.GetDateTime(r.GetOrdinal("UploadedOn")),
        TotalAffectedClaims = r.GetInt32(r.GetOrdinal("TotalAffectedClaims")),
        TotalAffectedTasks = r.GetInt32(r.GetOrdinal("TotalAffectedTasks")),
        PendingCount = r.GetInt32(r.GetOrdinal("PendingCount")),
        ConfirmedCount = r.GetInt32(r.GetOrdinal("ConfirmedCount")),
        IgnoredCount = r.GetInt32(r.GetOrdinal("IgnoredCount")),
        Status = GetString(r, "Status") ?? "Pending"
    };

    private static DenialActionChangeVerification MapVerification(SqlDataReader r) => new()
    {
        VerificationId = r.GetInt64(r.GetOrdinal("VerificationId")),
        BatchId = r.GetInt64(r.GetOrdinal("BatchId")),
        ClaimID = GetString(r, "ClaimID") ?? string.Empty,
        TaskID = GetString(r, "TaskID"),
        PatientId = GetString(r, "PatientId"),
        PayerName = GetString(r, "PayerName"),
        AssignedTo = GetString(r, "AssignedTo"),
        ClaimStatus = GetString(r, "ClaimStatus"),
        DenialCode = GetString(r, "DenialCode") ?? string.Empty,
        ICDComplianceStatus = GetString(r, "ICDComplianceStatus"),
        CoverageStatus = GetString(r, "CoverageStatus"),
        OldActionCode = GetString(r, "OldActionCode"),
        NewActionCode = GetString(r, "NewActionCode"),
        OldActionCategory = GetString(r, "OldActionCategory"),
        NewActionCategory = GetString(r, "NewActionCategory"),
        OldTask = GetString(r, "OldTask"),
        NewTask = GetString(r, "NewTask"),
        OldShortCategory = GetString(r, "OldShortCategory"),
        NewShortCategory = GetString(r, "NewShortCategory"),
        VerificationStatus = GetString(r, "VerificationStatus") ?? "Pending",
        VerifiedBy = GetString(r, "VerifiedBy"),
        VerifiedOn = GetDate(r, "VerifiedOn"),
        CreatedOn = r.GetDateTime(r.GetOrdinal("CreatedOn"))
    };
}
