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
    Task<DenialCodeMasterImportResult> ReplaceFromImportAsync(int labId, IReadOnlyList<DenialCodeMasterRequest> records, int skippedCount, IReadOnlyList<string> errors, string? userName, CancellationToken ct);
}

public interface IDenialCodeMasterExcelService
{
    Task<DenialCodeMasterImportResult> ImportAsync(int labId, Stream stream, string? userName, CancellationToken ct);
    Task<string> RegenerateExportAsync(int labId, CancellationToken ct);
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

    public async Task<DenialCodeMasterImportResult> ReplaceFromImportAsync(int labId, IReadOnlyList<DenialCodeMasterRequest> records, int skippedCount, IReadOnlyList<string> errors, string? userName, CancellationToken ct)
    {
        if (errors.Count > 0) return new DenialCodeMasterImportResult { SkippedCount = skippedCount, FailedCount = errors.Count, Errors = errors };

        await using var conn = OpenLab(labId);
        await conn.OpenAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        var inserted = 0;
        var updated = 0;
        try
        {
            var uniqueRecords = DeduplicateImportRecords(records);
            skippedCount += records.Count - uniqueRecords.Count;

            if (uniqueRecords.Count > 0)
            {
                (inserted, updated) = await BulkUpsertImportAsync(conn, (SqlTransaction)tx, uniqueRecords, userName, ct);
            }

            await tx.CommitAsync(ct);
        }
        catch
        {
            await tx.RollbackAsync(CancellationToken.None);
            throw;
        }

        return new DenialCodeMasterImportResult { InsertedCount = inserted, UpdatedCount = updated, SkippedCount = skippedCount, FailedCount = 0 };
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

    private static async Task<(int InsertedCount, int UpdatedCount)> BulkUpsertImportAsync(SqlConnection conn, SqlTransaction tx, IReadOnlyList<DenialCodeMasterRequest> records, string? userName, CancellationToken ct)
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
            return (reader.GetInt32(reader.GetOrdinal("InsertedCount")), reader.GetInt32(reader.GetOrdinal("UpdatedCount")));
        }

        return (0, 0);
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
        record.DenialCode = record.DenialCode.Trim();
        record.DenialDescription = Trim(record.DenialDescription);
        record.DenialClassification = Trim(record.DenialClassification);
        record.CoverageStatus = record.CoverageStatus!.Trim();
        record.ICDComplianceStatus = record.ICDComplianceStatus!.Trim();
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

    private SqlConnection OpenLab(int labId)
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

    public async Task<DenialCodeMasterImportResult> ImportAsync(int labId, Stream stream, string? userName, CancellationToken ct)
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
            var coverageStatus = Text(sheet.Cell(row, 4));
            var icdComplianceStatus = Text(sheet.Cell(row, 5));
            if (string.IsNullOrWhiteSpace(code))
            {
                skipped++;
                continue;
            }
            if (string.IsNullOrWhiteSpace(coverageStatus))
            {
                errors.Add($"Row {row}: Coverage Status is required.");
                continue;
            }
            if (string.IsNullOrWhiteSpace(icdComplianceStatus))
            {
                errors.Add($"Row {row}: ICD Compliance Status is required.");
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

        var result = await _repo.ReplaceFromImportAsync(labId, records, skipped, errors, userName, ct);
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
}
