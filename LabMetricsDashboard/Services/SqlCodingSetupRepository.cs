using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// SQL Server implementation of <see cref="ICodingSetupRepository"/>
/// targeting <c>CodingSetupMasterList</c> in each lab's own database.
/// The lab-specific connection string is resolved from <see cref="LabSettings"/>.
/// </summary>
public sealed class SqlCodingSetupRepository : ICodingSetupRepository
{
    private readonly LabSettings _labSettings;
    private readonly ILogger<SqlCodingSetupRepository> _logger;
    private readonly string _masterConnectionString;

    private static readonly HashSet<string> AllowedSortColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        "PanelName", "TestName", "PathogenName", "CPTCode",
        "DefaultUnits", "DefaultICDCodes", "SortOrder", "IsActive"
    };

    public SqlCodingSetupRepository(LabSettings labSettings, IConfiguration configuration, ILogger<SqlCodingSetupRepository> logger)
    {
        ArgumentNullException.ThrowIfNull(labSettings);
        ArgumentNullException.ThrowIfNull(configuration);
        _labSettings = labSettings;
        _logger = logger;
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("Missing 'DefaultConnection' connection string for LRNMaster database.");
    }

    /// <summary>Resolves the lab-specific DB connection string.</summary>
    private string GetConnectionString(string labName)
    {
        if (_labSettings.Labs.TryGetValue(labName, out var cfg)
            && !string.IsNullOrWhiteSpace(cfg.DbConnectionString))
        {
            return cfg.DbConnectionString;
        }

        throw new InvalidOperationException(
            $"No DbConnectionString configured for lab '{labName}'. Check the lab config JSON.");
    }

    public async Task<(List<PanelPathogenCptRecord> Records, int TotalCount)> GetPagedAsync(
        string labName, string? search, string sortColumn, string sortDirection,
        string activeFilter, int page, int pageSize, CancellationToken ct = default)
    {
        if (!AllowedSortColumns.Contains(sortColumn)) sortColumn = "PanelName";
        var dir = sortDirection.Equals("desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC";

        var where = BuildWhereClause(search, activeFilter, out var parameters);
        var countSql = $"SELECT COUNT(*) FROM CodingSetupMasterList WHERE {where}";
        var dataSql = $"""
            SELECT Id, LabName, PanelName, TestName, PathogenName, CPTCode,
                   DefaultUnits, DefaultICDCodes, SortOrder, IsActive,
                   CreatedBy, CreatedDate, ModifiedBy, ModifiedDate
            FROM CodingSetupMasterList
            WHERE {where}
            ORDER BY [{sortColumn}] {dir}
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY
            """;

        await using var conn = new SqlConnection(GetConnectionString(labName));
        await conn.OpenAsync(ct);

        await using var countCmd = new SqlCommand(countSql, conn);
        countCmd.Parameters.AddRange(CloneParams(parameters));
        var totalCount = (int)(await countCmd.ExecuteScalarAsync(ct) ?? 0);

        await using var dataCmd = new SqlCommand(dataSql, conn);
        dataCmd.Parameters.AddRange(CloneParams(parameters));
        dataCmd.Parameters.Add(new SqlParameter("@Offset", (page - 1) * pageSize));
        dataCmd.Parameters.Add(new SqlParameter("@PageSize", pageSize));

        var records = new List<PanelPathogenCptRecord>();
        await using var reader = await dataCmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            records.Add(MapRecord(reader));

        return (records, totalCount);
    }

    public async Task<PanelPathogenCptRecord?> GetByIdAsync(string labName, int id, CancellationToken ct = default)
    {
        const string sql = """
            SELECT Id, LabName, PanelName, TestName, PathogenName, CPTCode,
                   DefaultUnits, DefaultICDCodes, SortOrder, IsActive,
                   CreatedBy, CreatedDate, ModifiedBy, ModifiedDate
            FROM CodingSetupMasterList WHERE Id = @Id
            """;

        await using var conn = new SqlConnection(GetConnectionString(labName));
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add(new SqlParameter("@Id", id));
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? MapRecord(reader) : null;
    }

    public async Task<bool> ExistsDuplicateAsync(string labName, string panelName, string? testName,
        string pathogenName, string cptCode, int? excludeId = null, CancellationToken ct = default)
    {
        var sql = """
            SELECT COUNT(1) FROM CodingSetupMasterList
            WHERE PanelName = @PanelName
              AND ISNULL(TestName,'') = ISNULL(@TestName,'')
              AND PathogenName = @PathogenName
              AND CPTCode = @CPTCode
            """;
        if (excludeId.HasValue) sql += " AND Id <> @ExcludeId";

        await using var conn = new SqlConnection(GetConnectionString(labName));
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add(new SqlParameter("@PanelName", panelName));
        cmd.Parameters.Add(new SqlParameter("@TestName", (object?)testName ?? DBNull.Value));
        cmd.Parameters.Add(new SqlParameter("@PathogenName", pathogenName));
        cmd.Parameters.Add(new SqlParameter("@CPTCode", cptCode));
        if (excludeId.HasValue)
            cmd.Parameters.Add(new SqlParameter("@ExcludeId", excludeId.Value));

        return (int)(await cmd.ExecuteScalarAsync(ct) ?? 0) > 0;
    }

    public async Task<int> CreateAsync(CodingSetupFormModel model, string? userName, CancellationToken ct = default)
    {
        const string sql = """
            INSERT INTO CodingSetupMasterList
                (LabName, PanelName, TestName, PathogenName, CPTCode, DefaultUnits, DefaultICDCodes,
                 SortOrder, IsActive, CreatedBy, CreatedDate)
            VALUES
                (@LabName, @PanelName, @TestName, @PathogenName, @CPTCode, @DefaultUnits, @DefaultICDCodes,
                 @SortOrder, @IsActive, @CreatedBy, GETDATE());
            SELECT SCOPE_IDENTITY();
            """;

        await using var conn = new SqlConnection(GetConnectionString(model.LabName));
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        AddFormParams(cmd, model);
        cmd.Parameters.Add(new SqlParameter("@CreatedBy", (object?)userName ?? DBNull.Value));

        var result = await cmd.ExecuteScalarAsync(ct);
        return Convert.ToInt32(result);
    }

    public async Task UpdateAsync(CodingSetupFormModel model, string? userName, CancellationToken ct = default)
    {
        // Fetch old record for audit trail
        var oldRecord = await GetByIdAsync(model.LabName, model.Id, ct);

        const string sql = """
            UPDATE CodingSetupMasterList SET
            LabName = @LabName, PanelName = @PanelName, TestName = @TestName,
                PathogenName = @PathogenName, CPTCode = @CPTCode,
                DefaultUnits = @DefaultUnits, DefaultICDCodes = @DefaultICDCodes,
                SortOrder = @SortOrder, IsActive = @IsActive,
                ModifiedBy = @ModifiedBy, ModifiedDate = GETDATE()
            WHERE Id = @Id
            """;

        await using var conn = new SqlConnection(GetConnectionString(model.LabName));
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        AddFormParams(cmd, model);
        cmd.Parameters.Add(new SqlParameter("@ModifiedBy", (object?)userName ?? DBNull.Value));
        cmd.Parameters.Add(new SqlParameter("@Id", model.Id));
        await cmd.ExecuteNonQueryAsync(ct);

        // Write audit entries for changed fields
        if (oldRecord is not null)
            await WriteAuditEntriesAsync(conn, model.Id, model.LabName, oldRecord, model, userName, ct);
    }

    public async Task DeactivateAsync(string labName, int id, string? userName, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(GetConnectionString(labName));
        await conn.OpenAsync(ct);

        // Get current record for audit
        var old = await GetByIdAsync(labName, id, ct);

        const string sql = """
            UPDATE CodingSetupMasterList
            SET IsActive = 0, ModifiedBy = @ModifiedBy, ModifiedDate = GETDATE()
            WHERE Id = @Id
            """;
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add(new SqlParameter("@Id", id));
        cmd.Parameters.Add(new SqlParameter("@ModifiedBy", (object?)userName ?? DBNull.Value));
        await cmd.ExecuteNonQueryAsync(ct);

        // Audit the deactivation
        if (old is not null)
        {
            await InsertAuditAsync(conn, id, old.LabName, "IsActive", "True", "False", userName, ct);
        }
    }

    public async Task<int> ClonePanelAsync(string labName, string sourcePanelName,
        string newPanelName, string? userName, CancellationToken ct = default)
    {
        const string sql = """
            INSERT INTO CodingSetupMasterList
                (LabName, PanelName, TestName, PathogenName, CPTCode, DefaultUnits, DefaultICDCodes,
                 SortOrder, IsActive, CreatedBy, CreatedDate)
            SELECT @LabName, @NewPanelName, TestName, PathogenName, CPTCode, DefaultUnits, DefaultICDCodes,
                   SortOrder, IsActive, @CreatedBy, GETDATE()
            FROM CodingSetupMasterList
            WHERE PanelName = @SourcePanelName AND IsActive = 1;
            SELECT @@ROWCOUNT;
            """;

        await using var conn = new SqlConnection(GetConnectionString(labName));
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add(new SqlParameter("@LabName", labName));
        cmd.Parameters.Add(new SqlParameter("@SourcePanelName", sourcePanelName));
        cmd.Parameters.Add(new SqlParameter("@NewPanelName", newPanelName));
        cmd.Parameters.Add(new SqlParameter("@CreatedBy", (object?)userName ?? DBNull.Value));

        var result = await cmd.ExecuteScalarAsync(ct);
        return Convert.ToInt32(result);
    }

    public async Task<List<string>> GetDistinctPanelNamesAsync(string labName, CancellationToken ct = default)
    {
        const string sql = """
            SELECT DISTINCT PanelName FROM CodingSetupMasterList
            ORDER BY PanelName
            """;

        await using var conn = new SqlConnection(GetConnectionString(labName));
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var result = new List<string>();
        while (await reader.ReadAsync(ct))
            result.Add(reader.GetString(0));
        return result;
    }

    public async Task<CodingSetupDropdownLookups> GetDropdownLookupsAsync(string labName, CancellationToken ct = default)
    {
        // Panels, tests, pathogens, CPT codes come from the master PanelPathogenCPTlist in LRNMaster.
        const string masterSql = """
            SELECT DISTINCT PanelName    FROM PanelPathogenCPTlist ORDER BY PanelName;
            SELECT DISTINCT TestName     FROM PanelPathogenCPTlist WHERE TestName IS NOT NULL ORDER BY TestName;
            SELECT DISTINCT PathogenName FROM PanelPathogenCPTlist ORDER BY PathogenName;
            SELECT DISTINCT CPTCode      FROM PanelPathogenCPTlist ORDER BY CPTCode;
            """;

        await using var masterConn = new SqlConnection(_masterConnectionString);
        await masterConn.OpenAsync(ct);
        await using var masterCmd = new SqlCommand(masterSql, masterConn);
        await using var reader = await masterCmd.ExecuteReaderAsync(ct);

        var panels = new List<string>();
        while (await reader.ReadAsync(ct)) panels.Add(reader.GetString(0));

        var tests = new List<string>();
        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct)) tests.Add(reader.GetString(0));

        var pathogens = new List<string>();
        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct)) pathogens.Add(reader.GetString(0));

        var cpts = new List<string>();
        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct)) cpts.Add(reader.GetString(0));

        // ICD codes come from the lab-specific CodingSetupMasterList table.
        var icds = new List<string>();
        try
        {
            const string icdSql = """
                SELECT DISTINCT value FROM CodingSetupMasterList CROSS APPLY STRING_SPLIT(DefaultICDCodes, ',')
                WHERE DefaultICDCodes IS NOT NULL ORDER BY value
                """;

            await using var labConn = new SqlConnection(GetConnectionString(labName));
            await labConn.OpenAsync(ct);
            await using var icdCmd = new SqlCommand(icdSql, labConn);
            await using var icdReader = await icdCmd.ExecuteReaderAsync(ct);
            while (await icdReader.ReadAsync(ct))
            {
                var v = icdReader.GetString(0).Trim();
                if (v.Length > 0) icds.Add(v);
            }
        }
        catch (SqlException ex) when (ex.Message.Contains("Invalid object name", StringComparison.OrdinalIgnoreCase))
        {
            _logger.LogWarning("CodingSetupMasterList not found for lab '{LabName}'; ICD lookup skipped.", labName);
        }

        return new CodingSetupDropdownLookups
        {
            PanelNames = panels,
            TestNames = tests,
            PathogenNames = pathogens,
            CptCodes = cpts,
            IcdCodes = icds.Distinct(StringComparer.OrdinalIgnoreCase).ToList()
        };
    }

    public async Task<List<PanelPathogenCptRecord>> GetAllAsync(
        string labName, string? search, string activeFilter, CancellationToken ct = default)
    {
        var where = BuildWhereClause(search, activeFilter, out var parameters);
        var sql = $"""
            SELECT Id, LabName, PanelName, TestName, PathogenName, CPTCode,
                   DefaultUnits, DefaultICDCodes, SortOrder, IsActive,
                   CreatedBy, CreatedDate, ModifiedBy, ModifiedDate
            FROM CodingSetupMasterList
            WHERE {where}
            ORDER BY PanelName, TestName, PathogenName
            """;

        await using var conn = new SqlConnection(GetConnectionString(labName));
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddRange(CloneParams(parameters));

        var records = new List<PanelPathogenCptRecord>();
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            records.Add(MapRecord(reader));
        return records;
    }

    public async Task<int> BulkImportAsync(string labName, List<CodingSetupFormModel> records,
        string? userName, CancellationToken ct = default)
    {
        if (records.Count == 0) return 0;

        await using var conn = new SqlConnection(GetConnectionString(labName));
        await conn.OpenAsync(ct);

        var inserted = 0;
        foreach (var model in records)
        {
            model.LabName = labName;
            const string sql = """
                IF NOT EXISTS (
                    SELECT 1 FROM CodingSetupMasterList
                    WHERE PanelName = @PanelName
                      AND ISNULL(TestName,'') = ISNULL(@TestName,'')
                      AND PathogenName = @PathogenName AND CPTCode = @CPTCode
                )
                BEGIN
                    INSERT INTO CodingSetupMasterList
                        (LabName, PanelName, TestName, PathogenName, CPTCode, DefaultUnits, DefaultICDCodes,
                         SortOrder, IsActive, CreatedBy, CreatedDate)
                    VALUES
                        (@LabName, @PanelName, @TestName, @PathogenName, @CPTCode, @DefaultUnits, @DefaultICDCodes,
                         @SortOrder, @IsActive, @CreatedBy, GETDATE());
                    SELECT 1;
                END
                ELSE SELECT 0;
                """;

            await using var cmd = new SqlCommand(sql, conn);
            AddFormParams(cmd, model);
            cmd.Parameters.Add(new SqlParameter("@CreatedBy", (object?)userName ?? DBNull.Value));
            var result = (int)(await cmd.ExecuteScalarAsync(ct) ?? 0);
            inserted += result;
        }

        return inserted;
    }

    public async Task<List<PanelPathogenCptRecord>> GetByPanelNameAsync(string labName, string panelName, CancellationToken ct = default)
    {
        const string sql = """
            SELECT Id, LabName, PanelName, TestName, PathogenName, CPTCode,
                   DefaultUnits, DefaultICDCodes, SortOrder, IsActive,
                   CreatedBy, CreatedDate, ModifiedBy, ModifiedDate
            FROM CodingSetupMasterList
            WHERE PanelName = @PanelName AND IsActive = 1
            ORDER BY SortOrder, PathogenName, CPTCode
            """;


        await using var conn = new SqlConnection(GetConnectionString(labName));
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add(new SqlParameter("@PanelName", panelName));
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var records = new List<PanelPathogenCptRecord>();
        while (await reader.ReadAsync(ct))
            records.Add(MapRecord(reader));
        return records;
    }

    public async Task<List<PanelPathogenCptRecord>> GetMasterPanelDetailsAsync(string panelName, CancellationToken ct = default)
    {
        const string sql = """
            SELECT PanelName, TestName, PathogenName, CPTCode
            FROM PanelPathogenCPTlist
            WHERE PanelName = @PanelName
            ORDER BY TestName, PathogenName, CPTCode
            """;

        await using var conn = new SqlConnection(_masterConnectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add(new SqlParameter("@PanelName", panelName));
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var records = new List<PanelPathogenCptRecord>();
        while (await reader.ReadAsync(ct))
        {
            records.Add(new PanelPathogenCptRecord
            {
                PanelName = reader.GetString(reader.GetOrdinal("PanelName")),
                TestName = reader.IsDBNull(reader.GetOrdinal("TestName")) ? null : reader.GetString(reader.GetOrdinal("TestName")),
                PathogenName = reader.GetString(reader.GetOrdinal("PathogenName")),
                CPTCode = reader.GetString(reader.GetOrdinal("CPTCode")),
                DefaultUnits = 1,
            });
        }
        return records;
    }

    public async Task<List<CodingSetupAuditEntry>> GetAuditHistoryAsync(string labName, int recordId, CancellationToken ct = default)
    {
        const string sql = """
            SELECT FieldName, OldValue, NewValue, ChangedBy, ChangedDate
            FROM CodingSetupMasterList_Audit
            WHERE RecordId = @RecordId
            ORDER BY ChangedDate DESC
            """;

        await using var conn = new SqlConnection(GetConnectionString(labName));
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add(new SqlParameter("@RecordId", recordId));
        await using var reader = await cmd.ExecuteReaderAsync(ct);

        var entries = new List<CodingSetupAuditEntry>();
        while (await reader.ReadAsync(ct))
        {
            entries.Add(new CodingSetupAuditEntry
            {
                FieldName = reader.GetString(0),
                OldValue = reader.IsDBNull(1) ? null : reader.GetString(1),
                NewValue = reader.IsDBNull(2) ? null : reader.GetString(2),
                ChangedBy = reader.IsDBNull(3) ? null : reader.GetString(3),
                ChangedDate = reader.GetDateTime(4)
            });
        }
        return entries;
    }

    // ?? Private helpers ????????????????????????????????????????????

    private static string BuildWhereClause(string? search, string activeFilter,
        out List<SqlParameter> parameters)
    {
        parameters = [];
        var clauses = new List<string> { "1 = 1" };

        if (!string.IsNullOrWhiteSpace(search))
        {
            clauses.Add("""
                (PanelName LIKE @Search OR TestName LIKE @Search
                 OR PathogenName LIKE @Search OR CPTCode LIKE @Search)
                """);
            parameters.Add(new SqlParameter("@Search", $"%{search.Trim()}%"));
        }

        switch (activeFilter.ToLowerInvariant())
        {
            case "active":
                clauses.Add("IsActive = 1");
                break;
            case "inactive":
                clauses.Add("IsActive = 0");
                break;
        }

        return string.Join(" AND ", clauses);
    }

    private static void AddFormParams(SqlCommand cmd, CodingSetupFormModel m)
    {
        cmd.Parameters.Add(new SqlParameter("@LabName", m.LabName));
        cmd.Parameters.Add(new SqlParameter("@PanelName", m.PanelName));
        cmd.Parameters.Add(new SqlParameter("@TestName", (object?)m.TestName ?? DBNull.Value));
        cmd.Parameters.Add(new SqlParameter("@PathogenName", m.PathogenName));
        cmd.Parameters.Add(new SqlParameter("@CPTCode", m.CPTCode));
        cmd.Parameters.Add(new SqlParameter("@DefaultUnits", m.DefaultUnits));
        cmd.Parameters.Add(new SqlParameter("@DefaultICDCodes", (object?)m.DefaultICDCodes ?? DBNull.Value));
        cmd.Parameters.Add(new SqlParameter("@SortOrder", m.SortOrder));
        cmd.Parameters.Add(new SqlParameter("@IsActive", m.IsActive));
    }

    private static PanelPathogenCptRecord MapRecord(SqlDataReader r) => new()
    {
        Id = r.GetInt32(r.GetOrdinal("Id")),
        LabName = r.IsDBNull(r.GetOrdinal("LabName")) ? "" : r.GetString(r.GetOrdinal("LabName")),
        PanelName = r.GetString(r.GetOrdinal("PanelName")),
        TestName = r.IsDBNull(r.GetOrdinal("TestName")) ? null : r.GetString(r.GetOrdinal("TestName")),
        PathogenName = r.GetString(r.GetOrdinal("PathogenName")),
        CPTCode = r.GetString(r.GetOrdinal("CPTCode")),
        DefaultUnits = r.GetDecimal(r.GetOrdinal("DefaultUnits")),
        DefaultICDCodes = r.IsDBNull(r.GetOrdinal("DefaultICDCodes")) ? null : r.GetString(r.GetOrdinal("DefaultICDCodes")),
        SortOrder = r.IsDBNull(r.GetOrdinal("SortOrder")) ? 0 : r.GetInt32(r.GetOrdinal("SortOrder")),
        IsActive = r.IsDBNull(r.GetOrdinal("IsActive")) || r.GetBoolean(r.GetOrdinal("IsActive")),
        CreatedBy = r.IsDBNull(r.GetOrdinal("CreatedBy")) ? null : r.GetString(r.GetOrdinal("CreatedBy")),
        CreatedDate = r.IsDBNull(r.GetOrdinal("CreatedDate")) ? null : r.GetDateTime(r.GetOrdinal("CreatedDate")),
        ModifiedBy = r.IsDBNull(r.GetOrdinal("ModifiedBy")) ? null : r.GetString(r.GetOrdinal("ModifiedBy")),
        ModifiedDate = r.IsDBNull(r.GetOrdinal("ModifiedDate")) ? null : r.GetDateTime(r.GetOrdinal("ModifiedDate")),
    };

    private static SqlParameter[] CloneParams(List<SqlParameter> source) =>
        source.Select(p => new SqlParameter(p.ParameterName, p.Value)).ToArray();

    private async Task WriteAuditEntriesAsync(SqlConnection conn, int recordId, string labName,
        PanelPathogenCptRecord old, CodingSetupFormModel @new, string? userName, CancellationToken ct)
    {
        var changes = new List<(string Field, string? OldVal, string? NewVal)>();

        if (old.PanelName != @new.PanelName) changes.Add(("PanelName", old.PanelName, @new.PanelName));
        if (old.TestName != @new.TestName) changes.Add(("TestName", old.TestName, @new.TestName));
        if (old.PathogenName != @new.PathogenName) changes.Add(("PathogenName", old.PathogenName, @new.PathogenName));
        if (old.CPTCode != @new.CPTCode) changes.Add(("CPTCode", old.CPTCode, @new.CPTCode));
        if (old.DefaultUnits != @new.DefaultUnits) changes.Add(("DefaultUnits", old.DefaultUnits.ToString(), @new.DefaultUnits.ToString()));
        if (old.DefaultICDCodes != @new.DefaultICDCodes) changes.Add(("DefaultICDCodes", old.DefaultICDCodes, @new.DefaultICDCodes));
        if (old.SortOrder != @new.SortOrder) changes.Add(("SortOrder", old.SortOrder.ToString(), @new.SortOrder.ToString()));
        if (old.IsActive != @new.IsActive) changes.Add(("IsActive", old.IsActive.ToString(), @new.IsActive.ToString()));

        foreach (var (field, oldVal, newVal) in changes)
        {
            await InsertAuditAsync(conn, recordId, labName, field, oldVal, newVal, userName, ct);
        }
    }

    private static async Task InsertAuditAsync(SqlConnection conn, int recordId, string labName,
        string fieldName, string? oldValue, string? newValue, string? changedBy, CancellationToken ct)
    {
        const string sql = """
            INSERT INTO CodingSetupMasterList_Audit
                (RecordId, LabName, FieldName, OldValue, NewValue, ChangedBy, ChangedDate)
            VALUES
                (@RecordId, @LabName, @FieldName, @OldValue, @NewValue, @ChangedBy, GETDATE())
            """;

        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add(new SqlParameter("@RecordId", recordId));
        cmd.Parameters.Add(new SqlParameter("@LabName", labName));
        cmd.Parameters.Add(new SqlParameter("@FieldName", fieldName));
        cmd.Parameters.Add(new SqlParameter("@OldValue", (object?)oldValue ?? DBNull.Value));
        cmd.Parameters.Add(new SqlParameter("@NewValue", (object?)newValue ?? DBNull.Value));
        cmd.Parameters.Add(new SqlParameter("@ChangedBy", (object?)changedBy ?? DBNull.Value));
        await cmd.ExecuteNonQueryAsync(ct);
    }
}
