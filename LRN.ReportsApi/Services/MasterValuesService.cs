using System.Data;
using System.Globalization;
using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

public interface IMasterValuesRepository
{
    Task<PagedResult<InsurancePayerMasterDto>> GetInsurancePayersAsync(InsurancePayerMasterQuery query, CancellationToken ct);
    Task<IReadOnlyList<InsurancePayerMasterDto>> GetInsurancePayersForExportAsync(InsurancePayerMasterQuery query, CancellationToken ct);
    Task<InsurancePayerMasterDto?> GetInsurancePayerAsync(int id, CancellationToken ct);
    Task<int> CreateInsurancePayerAsync(InsurancePayerMasterDto dto, string? userName, CancellationToken ct);
    Task<bool> UpdateInsurancePayerAsync(int id, InsurancePayerMasterDto dto, string? userName, CancellationToken ct);
    Task<bool> UpdateInsurancePayerStatusAsync(int id, string? isActive, string? userName, CancellationToken ct);
    Task<ImportResultDto> ImportInsurancePayersAsync(Stream stream, string? userName, CancellationToken ct);
    Task<GlobalPayerIdConflictResolutionResult> ResolveInsuranceGlobalPayerConflictsAsync(GlobalPayerIdConflictResolutionRequest request, string? userName, CancellationToken ct);
    Task<byte[]> ExportInsurancePayersAsync(InsurancePayerMasterQuery query, CancellationToken ct);

    Task<PagedResult<PayerPolicyInsuranceMasterDto>> GetPolicyPayersAsync(PayerPolicyInsuranceMasterQuery query, CancellationToken ct);
    Task<IReadOnlyList<PayerPolicyInsuranceMasterDto>> GetPolicyPayersForExportAsync(PayerPolicyInsuranceMasterQuery query, CancellationToken ct);
    Task<PayerPolicyInsuranceMasterDto?> GetPolicyPayerAsync(int id, CancellationToken ct);
    Task<int> CreatePolicyPayerAsync(PayerPolicyInsuranceMasterDto dto, string? userName, CancellationToken ct);
    /// <summary>The next Global Payer ID a new Payer Policy record would take (MAX numeric id + 1), for pre-filling the add form.</summary>
    Task<int> GetNextPolicyGlobalPayerIdAsync(CancellationToken ct);
    /// <summary>Inserts a new Payer Policy record with the next sequential Global Payer ID (atomic) and returns it.</summary>
    Task<(int PPInsuranceMasterId, int GlobalPayerId, string GlobalPayerCode)> MintPolicyPayerAsync(
        string payerNameRaw, string? payerNameNormalized, string? state, string? userName, CancellationToken ct);
    Task<bool> UpdatePolicyPayerAsync(int id, PayerPolicyInsuranceMasterDto dto, string? userName, CancellationToken ct);
    Task<bool> UpdatePolicyPayerStatusAsync(int id, string? isActive, string? userName, CancellationToken ct);
    Task<ImportResultDto> ImportPolicyPayersAsync(Stream stream, string? userName, CancellationToken ct);
    Task<byte[]> ExportPolicyPayersAsync(PayerPolicyInsuranceMasterQuery query, CancellationToken ct);

    Task<IReadOnlyList<MasterValueLabOption>> GetLabsAsync(CancellationToken ct);
}

public sealed class SqlMasterValuesRepository : IMasterValuesRepository
{
    private readonly string _connectionString;

    public SqlMasterValuesRepository(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster.");
    }

    public async Task<PagedResult<InsurancePayerMasterDto>> GetInsurancePayersAsync(InsurancePayerMasterQuery query, CancellationToken ct)
    {
        query.Page = Math.Max(1, query.Page);
        query.PageSize = Math.Clamp(query.PageSize <= 0 ? 25 : query.PageSize, 10, 1000);
        var where = BuildInsuranceWhere(query, out var parameters);
        var orderBy = BuildInsuranceOrderBy(query);
        var result = new PagedResult<InsurancePayerMasterDto> { Page = query.Page, PageSize = query.PageSize };
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using (var count = new SqlCommand($"SELECT COUNT(1) FROM dbo.LabInsuranceMaster WHERE {where};", conn))
        {
            count.Parameters.AddRange(Clone(parameters));
            result.TotalCount = Convert.ToInt32(await count.ExecuteScalarAsync(ct) ?? 0);
        }
        await using var cmd = new SqlCommand($"""
            SELECT LabInsuranceMasterId, PayerCode, PayerNameRaw, PayerNameNormalized, GlobalPayerID,
                   PayerGroupCode, PayerCommonCode, Parent, PlanType, MCOType, PayerState, IsActive,
                   BenefitAdminCode, BenefitAdministrator, Remarks, LabName, LabId, LabState, LabStateCode,
                   MappingStatus, MappedBy
            FROM dbo.LabInsuranceMaster
            WHERE {where}
            ORDER BY {orderBy}
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """, conn);
        cmd.Parameters.AddRange(Clone(parameters));
        cmd.Parameters.AddWithValue("@Offset", (query.Page - 1) * query.PageSize);
        cmd.Parameters.AddWithValue("@PageSize", query.PageSize);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) result.Items.Add(MapInsurance(reader));
        return result;
    }

    public async Task<IReadOnlyList<InsurancePayerMasterDto>> GetInsurancePayersForExportAsync(InsurancePayerMasterQuery query, CancellationToken ct)
    {
        query.Page = 1;
        query.PageSize = 100000;
        return (await GetInsurancePayersAsync(query, ct)).Items;
    }

    public async Task<InsurancePayerMasterDto?> GetInsurancePayerAsync(int id, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT LabInsuranceMasterId, PayerCode, PayerNameRaw, PayerNameNormalized, GlobalPayerID,
                   PayerGroupCode, PayerCommonCode, Parent, PlanType, MCOType, PayerState, IsActive,
                   BenefitAdminCode, BenefitAdministrator, Remarks, LabName, LabId, LabState, LabStateCode,
                   MappingStatus, MappedBy
            FROM dbo.LabInsuranceMaster WHERE LabInsuranceMasterId = @Id;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? MapInsurance(reader) : null;
    }

    public async Task<int> CreateInsurancePayerAsync(InsurancePayerMasterDto dto, string? userName, CancellationToken ct)
    {
        Trim(dto);
        if (string.IsNullOrWhiteSpace(dto.PayerNameRaw)) throw new ArgumentException("PayerNameRaw is required.");
        await using var conn = Open();
        await conn.OpenAsync(ct);
        if (dto.LabId.HasValue && !await LabExistsAsync(conn, dto.LabId.Value, ct)) throw new ArgumentException("LabId does not exist.");
        if (await InsuranceNormalizedGlobalExistsAsync(conn, dto.PayerNameNormalized, dto.GlobalPayerID, null, ct))
            throw new ArgumentException("Payer Name Normalized and Global Payer ID combination already exists.");
        await using var cmd = new SqlCommand("""
            INSERT INTO dbo.LabInsuranceMaster
                (PayerCode, PayerNameRaw, PayerNameNormalized, GlobalPayerID, PayerGroupCode, PayerCommonCode, Parent,
                 PlanType, MCOType, PayerState, IsActive, BenefitAdminCode, BenefitAdministrator, Remarks, LabName,
                 LabId, LabState, LabStateCode, CreatedBy, MappingStatus)
            OUTPUT INSERTED.LabInsuranceMasterId
            VALUES
                (@PayerCode, @PayerNameRaw, @PayerNameNormalized, @GlobalPayerID, @PayerGroupCode, @PayerCommonCode, @Parent,
                 @PlanType, @MCOType, @PayerState, @IsActive, @BenefitAdminCode, @BenefitAdministrator, @Remarks, @LabName,
                 @LabId, @LabState, @LabStateCode, @CreatedBy,
                 CASE WHEN @GlobalPayerID IS NOT NULL THEN 'Mapped' ELSE 'Unmapped' END);
            """, conn);
        AddInsuranceParams(cmd, dto);
        cmd.Parameters.AddWithValue("@CreatedBy", DbValue(userName));
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
    }

    public async Task<bool> UpdateInsurancePayerAsync(int id, InsurancePayerMasterDto dto, string? userName, CancellationToken ct)
    {
        Trim(dto);
        if (string.IsNullOrWhiteSpace(dto.PayerNameRaw)) throw new ArgumentException("PayerNameRaw is required.");
        await using var conn = Open();
        await conn.OpenAsync(ct);
        if (dto.LabId.HasValue && !await LabExistsAsync(conn, dto.LabId.Value, ct)) throw new ArgumentException("LabId does not exist.");
        if (await InsuranceNormalizedGlobalExistsAsync(conn, dto.PayerNameNormalized, dto.GlobalPayerID, id, ct))
            throw new ArgumentException("Payer Name Normalized and Global Payer ID combination already exists.");
        await using var cmd = new SqlCommand("""
            UPDATE dbo.LabInsuranceMaster
            SET PayerCode=@PayerCode, PayerNameRaw=@PayerNameRaw,
                PayerNameNormalized=@PayerNameNormalized, GlobalPayerID=@GlobalPayerID, PayerGroupCode=@PayerGroupCode,
                PayerCommonCode=@PayerCommonCode, Parent=@Parent, PlanType=@PlanType, MCOType=@MCOType, PayerState=@PayerState,
                IsActive=@IsActive, BenefitAdminCode=@BenefitAdminCode, BenefitAdministrator=@BenefitAdministrator, Remarks=@Remarks,
                LabName=@LabName, LabId=@LabId, LabState=@LabState, LabStateCode=@LabStateCode, ModifiedBy=@ModifiedBy,
                ModifiedOn=SYSUTCDATETIME(),
                MappingStatus = CASE WHEN @GlobalPayerID IS NOT NULL THEN 'Mapped'
                                     WHEN MappingStatus = 'Mapped' OR MappingStatus IS NULL THEN 'Unmapped'
                                     ELSE MappingStatus END
            WHERE LabInsuranceMasterId=@Id;
            """, conn);
        AddInsuranceParams(cmd, dto);
        cmd.Parameters.AddWithValue("@Id", id);
        cmd.Parameters.AddWithValue("@ModifiedBy", DbValue(userName));
        return await cmd.ExecuteNonQueryAsync(ct) > 0;
    }

    public Task<bool> UpdateInsurancePayerStatusAsync(int id, string? isActive, string? userName, CancellationToken ct)
        => UpdateStatusAsync("dbo.LabInsuranceMaster", "LabInsuranceMasterId", id, isActive, userName, ct);

    // Excel column names expected in the Lab Insurance Master import file (LabId is resolved, not a column).
    private static readonly string[] LabImportColumns =
    {
        "Payer_Code", "Global_Payer_ID", "Payer_Name_Raw", "Payer_Name_Normalized", "Payer_Group_Code",
        "Payer_Common_Code", "Parent", "Plan_Type", "MCO_Type", "Payer_State", "Is_Active",
        "Benefit Admin Code", "Benefit Administrator", "Remarks", "Lab Name", "Lab State", "Lab State Code"
    };

    public async Task<ImportResultDto> ImportInsurancePayersAsync(Stream stream, string? userName, CancellationToken ct)
    {
        using var workbook = new XLWorkbook(stream);
        if (!workbook.Worksheets.TryGetWorksheet("Lab_Ins_Master", out var ws))
            return new ImportResultDto { ErrorRows = 1, Errors = { "Sheet Lab_Ins_Master was not found." } };
        // NOT-NULL rule (Lab): only Payer_Name_Raw is required; every other column is optional.
        if (!TryBuildHeaderMap(ws, LabImportColumns, new[] { "Payer_Name_Raw" }, out var header, out var headerErrors))
            return new ImportResultDto { ErrorRows = headerErrors.Count, Errors = headerErrors };

        var result = new ImportResultDto();
        var lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
        var importRows = new List<(int RowNumber, InsurancePayerMasterDto Value)>();
        // Rows whose imported Global Payer ID conflicts with the policy master (saved NULL, resolved later).
        var pendingConflicts = new List<(InsurancePayerMasterDto Dto, int ImportGid, int PolicyGid)>();

        await using var conn = Open();
        await conn.OpenAsync(ct);
        var labs = await LabsByNameAsync(conn, ct);
        var policyGlobals = await PolicyGlobalPayerIdsByRawNameAsync(conn, ct);
        for (var row = 2; row <= lastRow; row++)
        {
            result.TotalRows++;
            var globalId = IntCellOpt(ws, row, header, "Global_Payer_ID", result, row, out var globalIdInvalid);
            var dto = new InsurancePayerMasterDto
            {
                PayerCode = CellOpt(ws, row, header, "Payer_Code"),
                PayerNameRaw = CellOpt(ws, row, header, "Payer_Name_Raw") ?? string.Empty,
                PayerNameNormalized = CellOpt(ws, row, header, "Payer_Name_Normalized"),
                GlobalPayerID = globalId,
                PayerGroupCode = CellOpt(ws, row, header, "Payer_Group_Code"),
                PayerCommonCode = CellOpt(ws, row, header, "Payer_Common_Code"),
                Parent = CellOpt(ws, row, header, "Parent"),
                PlanType = CellOpt(ws, row, header, "Plan_Type"),
                MCOType = CellOpt(ws, row, header, "MCO_Type"),
                PayerState = CellOpt(ws, row, header, "Payer_State"),
                IsActive = CellOpt(ws, row, header, "Is_Active"),
                BenefitAdminCode = CellOpt(ws, row, header, "Benefit Admin Code"),
                BenefitAdministrator = CellOpt(ws, row, header, "Benefit Administrator"),
                Remarks = CellOpt(ws, row, header, "Remarks"),
                LabName = CellOpt(ws, row, header, "Lab Name"),
                LabState = CellOpt(ws, row, header, "Lab State"),
                LabStateCode = CellOpt(ws, row, header, "Lab State Code")
            };
            Trim(dto);
            if (string.IsNullOrWhiteSpace(dto.PayerNameRaw))
            {
                result.SkippedRows++;
                result.Errors.Add($"Row {row}: Payer_Name_Raw is required.");
                continue;
            }
            if (globalIdInvalid)
            {
                result.SkippedRows++;
                result.Errors.Add($"Row {row}: Global_Payer_ID is not a valid integer.");
                continue;
            }
            if (!string.IsNullOrWhiteSpace(dto.LabName) && labs.TryGetValue(Norm(dto.LabName), out var lab)) dto.LabId = lab.LabId;
            else if (!string.IsNullOrWhiteSpace(dto.LabName)) result.Warnings.Add($"Row {row}: Lab Name '{dto.LabName}' was not found; LabId left blank.");

            // GlobalPayerID reconciliation against the Payer Policy master (matched on PayerNameRaw).
            if (policyGlobals.TryGetValue(CiKey(dto.PayerNameRaw), out var policyGid))
            {
                if (!dto.GlobalPayerID.HasValue || dto.GlobalPayerID.Value == policyGid)
                {
                    dto.GlobalPayerID = policyGid; // cases 1 & 2: adopt the policy master value
                }
                else
                {
                    // case 3: values differ - store NULL now, collect for the resolution modal
                    pendingConflicts.Add((dto, dto.GlobalPayerID.Value, policyGid));
                    dto.GlobalPayerID = null;
                }
            }
            // else: PayerNameRaw not in policy master - keep the import file's value as-is.

            importRows.Add((row, dto));
        }

        if (importRows.Count > 0)
        {
            var counts = await BulkUpsertInsurancePayersAsync(conn, importRows, userName, ct);
            result.InsertedRows = counts.Inserted;
            result.UpdatedRows = counts.Updated;
            result.UnmappedRecordIds = counts.UnmappedRecordIds;
            result.SkippedRows += counts.Duplicates.Count;
            if (counts.Duplicates.Count > 0)
            {
                result.Duplicates = counts.Duplicates;
                result.Warnings.Add($"{counts.Duplicates.Count} duplicate import row(s) were superseded by the last matching row in the workbook (see the duplicate list below).");
            }
        }

        // Resolve each conflict row's saved LabInsuranceMasterId so the modal can target it.
        foreach (var (dto, importGid, policyGid) in pendingConflicts)
        {
            var id = await FindLabRecordIdByRawNameAndLabAsync(conn, dto.PayerNameRaw, dto.LabName, ct);
            if (id.HasValue)
                result.Conflicts.Add(new GlobalPayerIdConflictDto
                {
                    LabInsuranceMasterId = id.Value,
                    PayerNameRaw = dto.PayerNameRaw,
                    LabName = dto.LabName,
                    ImportGlobalPayerId = importGid,
                    PolicyGlobalPayerId = policyGid
                });
        }

        // Conflict rows wait for the user's Import-vs-Policy choice; the pipeline must not race it.
        if (result.Conflicts.Count > 0)
        {
            var conflictIds = result.Conflicts.Select(c => c.LabInsuranceMasterId).ToHashSet();
            result.UnmappedRecordIds.RemoveAll(conflictIds.Contains);
        }

        result.ErrorRows = result.Errors.Count;
        return result;
    }

    /// <summary>Loads Payer Policy master Global Payer IDs keyed by normalized raw payer name for reconciliation.</summary>
    private static async Task<Dictionary<string, int>> PolicyGlobalPayerIdsByRawNameAsync(SqlConnection conn, CancellationToken ct)
    {
        var map = new Dictionary<string, int>();
        await using var cmd = new SqlCommand("""
            SELECT PayerNameRaw, TRY_CONVERT(INT, GlobalPayerId) AS Gid
            FROM dbo.PayerPolicyInsuranceMaster
            WHERE NULLIF(LTRIM(RTRIM(PayerNameRaw)), '') IS NOT NULL
              AND TRY_CONVERT(INT, GlobalPayerId) IS NOT NULL
            ORDER BY PPInsuranceMasterId;
            """, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var raw = reader.GetString(0);
            var key = CiKey(raw);
            // First policy row wins for a given raw name (stable, matches ORDER BY).
            if (!map.ContainsKey(key)) map[key] = reader.GetInt32(1);
        }
        return map;
    }

    private static async Task<int?> FindLabRecordIdByRawNameAndLabAsync(SqlConnection conn, string payerNameRaw, string? labName, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("""
            SELECT TOP (1) LabInsuranceMasterId
            FROM dbo.LabInsuranceMaster
            WHERE LTRIM(RTRIM(PayerNameRaw)) = @PayerNameRaw COLLATE Latin1_General_CI_AS
              AND ISNULL(LTRIM(RTRIM(LabName)), '') = @LabName COLLATE Latin1_General_CI_AS
            ORDER BY LabInsuranceMasterId DESC;
            """, conn);
        cmd.Parameters.AddWithValue("@PayerNameRaw", payerNameRaw.Trim());
        cmd.Parameters.AddWithValue("@LabName", labName?.Trim() ?? string.Empty);
        var id = await cmd.ExecuteScalarAsync(ct);
        return id == null || id == DBNull.Value ? null : Convert.ToInt32(id);
    }

    public async Task<GlobalPayerIdConflictResolutionResult> ResolveInsuranceGlobalPayerConflictsAsync(
        GlobalPayerIdConflictResolutionRequest request, string? userName, CancellationToken ct)
    {
        var result = new GlobalPayerIdConflictResolutionResult();
        if (request.Resolutions.Count == 0) return result;

        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct);
        try
        {
            foreach (var r in request.Resolutions)
            {
                var useImport = string.Equals(r.Source, "Import", StringComparison.OrdinalIgnoreCase);
                var usePolicy = string.Equals(r.Source, "Policy", StringComparison.OrdinalIgnoreCase);
                if (!useImport && !usePolicy)
                {
                    result.Failed++;
                    result.Errors.Add($"Record {r.LabInsuranceMasterId}: Source must be 'Import' or 'Policy'.");
                    continue;
                }
                var chosen = useImport ? r.ImportGlobalPayerId : r.PolicyGlobalPayerId;
                if (!chosen.HasValue)
                {
                    result.Failed++;
                    result.Errors.Add($"Record {r.LabInsuranceMasterId}: chosen Global Payer ID is blank.");
                    continue;
                }

                await using (var upd = new SqlCommand("""
                    UPDATE dbo.LabInsuranceMaster
                    SET GlobalPayerID = @Gid, ModifiedBy = @UserName, ModifiedOn = SYSUTCDATETIME(),
                        MappingStatus = 'Mapped', MappedBy = CONCAT('Manual (', ISNULL(@UserName, 'system'), ')')
                    WHERE LabInsuranceMasterId = @Id;
                    DELETE FROM dbo.PendingMatchCandidates WHERE LabInsuranceMasterId = @Id;
                    """, conn, tx))
                {
                    upd.Parameters.AddWithValue("@Gid", chosen.Value);
                    upd.Parameters.AddWithValue("@UserName", DbValue(userName));
                    upd.Parameters.AddWithValue("@Id", r.LabInsuranceMasterId);
                    if (await upd.ExecuteNonQueryAsync(ct) == 0)
                    {
                        result.Failed++;
                        result.Errors.Add($"Record {r.LabInsuranceMasterId}: not found.");
                        continue;
                    }
                }

                // Field-level audit for the resolution (OldValue = NULL per spec, NewValue = chosen value).
                await WriteImportAuditAsync(conn, tx, "Lab", r.LabInsuranceMasterId, chosen, null, "GlobalPayerID",
                    null, chosen.Value.ToString(CultureInfo.InvariantCulture), userName, ct);
                result.Resolved++;
            }
            await tx.CommitAsync(ct);
        }
        catch
        {
            await tx.RollbackAsync(CancellationToken.None);
            throw;
        }
        return result;
    }

    private static async Task<(int Inserted, int Updated, List<ImportDuplicateDto> Duplicates, List<int> UnmappedRecordIds)> BulkUpsertInsurancePayersAsync(
        SqlConnection conn,
        IReadOnlyList<(int RowNumber, InsurancePayerMasterDto Value)> rows,
        string? userName,
        CancellationToken ct)
    {
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        try
        {
            const string createStageSql = """
                CREATE TABLE #InsuranceImportStage
                (
                    RowNumber INT NOT NULL,
                    PayerCode NVARCHAR(50) NULL,
                    PayerNameRaw NVARCHAR(250) NOT NULL,
                    PayerNameNormalized NVARCHAR(250) NULL,
                    GlobalPayerID INT NULL,
                    PayerGroupCode NVARCHAR(250) NULL,
                    PayerCommonCode NVARCHAR(250) NULL,
                    Parent NVARCHAR(250) NULL,
                    PlanType NVARCHAR(250) NULL,
                    MCOType NVARCHAR(250) NULL,
                    PayerState NVARCHAR(50) NULL,
                    IsActive NVARCHAR(50) NULL,
                    BenefitAdminCode NVARCHAR(250) NULL,
                    BenefitAdministrator NVARCHAR(250) NULL,
                    Remarks NVARCHAR(500) NULL,
                    LabName NVARCHAR(50) NULL,
                    LabId INT NULL,
                    LabState NVARCHAR(50) NULL,
                    LabStateCode NVARCHAR(10) NULL,
                    ExistingId INT NULL
                );
                """;
            await using (var create = new SqlCommand(createStageSql, conn, tx) { CommandTimeout = 120 })
                await create.ExecuteNonQueryAsync(ct);

            var table = BuildInsuranceImportTable(rows);
            using (var bulk = new SqlBulkCopy(conn, SqlBulkCopyOptions.CheckConstraints, tx)
            {
                DestinationTableName = "#InsuranceImportStage",
                BatchSize = 2_000,
                BulkCopyTimeout = 300
            })
            {
                foreach (DataColumn column in table.Columns)
                    bulk.ColumnMappings.Add(column.ColumnName, column.ColumnName);
                await bulk.WriteToServerAsync(table, ct);
            }

            const string upsertSql = """
                SET NOCOUNT ON;
                SET XACT_ABORT ON;

                -- A master record's identity is the Payer_Name_Raw + Lab Name combination
                -- (one record per Payer + Lab), so both existing-record matching and the
                -- in-file duplicate detection below key on that pair and nothing else.
                UPDATE s
                SET ExistingId = matched.LabInsuranceMasterId
                FROM #InsuranceImportStage s
                OUTER APPLY
                (
                    SELECT TOP (1) m.LabInsuranceMasterId
                    FROM dbo.LabInsuranceMaster m WITH (UPDLOCK, HOLDLOCK)
                    WHERE m.PayerNameRaw = s.PayerNameRaw
                      AND ISNULL(m.LabName, '') = ISNULL(s.LabName, '')
                    ORDER BY m.LabInsuranceMasterId
                ) matched;

                -- DupKey is the identity a row is deduplicated on (Payer_Name_Raw + Lab Name);
                -- kept as a column so skipped duplicates can be reported back with the surviving row.
                SELECT s.*,
                       DupKey = CONCAT(s.PayerNameRaw, N'|', ISNULL(s.LabName, N''))
                INTO #KeyedInsuranceImport
                FROM #InsuranceImportStage s;

                SELECT k.*,
                       SourceRank = ROW_NUMBER() OVER (PARTITION BY k.DupKey ORDER BY k.RowNumber DESC)
                INTO #EffectiveInsuranceImport
                FROM #KeyedInsuranceImport k;

                -- Record-level import audit rows are captured here (set-based, in the same transaction).
                CREATE TABLE #LabImportAudit
                (
                    RecordId INT NOT NULL,
                    GlobalPayerID INT NULL,
                    PayerNameRaw NVARCHAR(250) NULL,
                    ActionKind VARCHAR(10) NOT NULL
                );

                UPDATE target
                SET PayerNameNormalized = source.PayerNameNormalized,
                    GlobalPayerID = source.GlobalPayerID,
                    PayerGroupCode = source.PayerGroupCode,
                    PayerCommonCode = source.PayerCommonCode,
                    Parent = source.Parent,
                    PlanType = source.PlanType,
                    MCOType = source.MCOType,
                    PayerState = source.PayerState,
                    IsActive = source.IsActive,
                    BenefitAdminCode = source.BenefitAdminCode,
                    BenefitAdministrator = source.BenefitAdministrator,
                    Remarks = source.Remarks,
                    LabName = source.LabName,
                    LabId = source.LabId,
                    LabState = source.LabState,
                    LabStateCode = source.LabStateCode,
                    ModifiedBy = @UserName,
                    ModifiedOn = SYSUTCDATETIME()
                OUTPUT inserted.LabInsuranceMasterId, inserted.GlobalPayerID, inserted.PayerNameRaw, 'Update'
                    INTO #LabImportAudit (RecordId, GlobalPayerID, PayerNameRaw, ActionKind)
                FROM dbo.LabInsuranceMaster target
                JOIN #EffectiveInsuranceImport source
                  ON source.ExistingId = target.LabInsuranceMasterId
                 AND source.SourceRank = 1;
                DECLARE @Updated INT = @@ROWCOUNT;

                INSERT dbo.LabInsuranceMaster
                    (PayerCode, PayerNameRaw, PayerNameNormalized, GlobalPayerID, PayerGroupCode,
                     PayerCommonCode, Parent, PlanType, MCOType, PayerState, IsActive, BenefitAdminCode,
                     BenefitAdministrator, Remarks, LabName, LabId, LabState, LabStateCode, CreatedBy)
                OUTPUT inserted.LabInsuranceMasterId, inserted.GlobalPayerID, inserted.PayerNameRaw, 'Insert'
                    INTO #LabImportAudit (RecordId, GlobalPayerID, PayerNameRaw, ActionKind)
                SELECT PayerCode, PayerNameRaw, PayerNameNormalized, GlobalPayerID, PayerGroupCode,
                       PayerCommonCode, Parent, PlanType, MCOType, PayerState, IsActive, BenefitAdminCode,
                       BenefitAdministrator, Remarks, LabName, LabId, LabState, LabStateCode, @UserName
                FROM #EffectiveInsuranceImport
                WHERE ExistingId IS NULL
                  AND SourceRank = 1;
                DECLARE @Inserted INT = @@ROWCOUNT;

                -- Payer mapper bookkeeping on every touched row: Mapped when a GlobalPayerID arrived with
                -- the import, otherwise Unmapped with a cleared LastEvaluatedOn so the pipeline/worker
                -- (re-)evaluates the row (columns come from Sql/001_payer_mapper_additions.sql).
                IF COL_LENGTH('dbo.LabInsuranceMaster', 'MappingStatus') IS NOT NULL
                    UPDATE m
                    SET MappingStatus = CASE WHEN m.GlobalPayerID IS NOT NULL THEN 'Mapped'
                                             WHEN m.MappingStatus IS NULL OR m.MappingStatus IN ('', 'Mapped') THEN 'Unmapped'
                                             ELSE m.MappingStatus END,
                        LastEvaluatedOn = CASE WHEN m.GlobalPayerID IS NULL THEN NULL ELSE m.LastEvaluatedOn END
                    FROM dbo.LabInsuranceMaster m
                    JOIN #LabImportAudit a ON a.RecordId = m.LabInsuranceMasterId;

                -- One record-level audit row per inserted/updated Lab record (ActionType = 'Import').
                IF OBJECT_ID('dbo.PayerMasterAuditTrail', 'U') IS NOT NULL
                    INSERT dbo.PayerMasterAuditTrail
                        (Master, RecordId, GlobalPayerID, PayerName, FieldName, OldValue, NewValue, ActionType, PerformedBy, ApprovalStatus)
                    SELECT 'Lab', RecordId, GlobalPayerID, PayerNameRaw, '(record)', NULL,
                           CASE WHEN ActionKind = 'Insert' THEN 'Inserted' ELSE 'Updated' END,
                           'Import', @UserName, 'Applied directly'
                    FROM #LabImportAudit;

                SELECT Inserted = @Inserted,
                       Updated = @Updated,
                       DuplicateRows = (SELECT COUNT(1) FROM #EffectiveInsuranceImport WHERE SourceRank > 1);

                -- Second result set: every skipped duplicate row (all import columns) and the row that won.
                SELECT d.RowNumber,
                       KeptRowNumber = w.RowNumber,
                       d.PayerCode, d.PayerNameRaw, d.PayerNameNormalized, d.GlobalPayerID,
                       d.PayerGroupCode, d.PayerCommonCode, d.Parent, d.PlanType, d.MCOType,
                       d.PayerState, d.IsActive, d.BenefitAdminCode, d.BenefitAdministrator,
                       d.Remarks, d.LabName, d.LabState, d.LabStateCode
                FROM #EffectiveInsuranceImport d
                JOIN #EffectiveInsuranceImport w ON w.DupKey = d.DupKey AND w.SourceRank = 1
                WHERE d.SourceRank > 1
                ORDER BY d.RowNumber;

                -- Third result set: imported rows still without a GlobalPayerID - the upload hook runs
                -- the payer matching pipeline over exactly these ids.
                SELECT DISTINCT a.RecordId
                FROM #LabImportAudit a
                JOIN dbo.LabInsuranceMaster m ON m.LabInsuranceMasterId = a.RecordId
                WHERE m.GlobalPayerID IS NULL;
                """;

            int inserted;
            int updated;
            var duplicates = new List<ImportDuplicateDto>();
            var unmappedIds = new List<int>();
            await using (var upsert = new SqlCommand(upsertSql, conn, tx) { CommandTimeout = 300 })
            {
                upsert.Parameters.Add("@UserName", SqlDbType.NVarChar, 100).Value = DbValue(userName);
                await using var reader = await upsert.ExecuteReaderAsync(ct);
                if (!await reader.ReadAsync(ct)) throw new InvalidOperationException("Insurance payer import did not return row counts.");
                inserted = reader.GetInt32(reader.GetOrdinal("Inserted"));
                updated = reader.GetInt32(reader.GetOrdinal("Updated"));

                if (await reader.NextResultAsync(ct))
                {
                    string? S(int i) => reader.IsDBNull(i) ? null : reader.GetString(i);
                    while (await reader.ReadAsync(ct))
                        duplicates.Add(new ImportDuplicateDto
                        {
                            RowNumber = reader.GetInt32(0),
                            KeptRowNumber = reader.GetInt32(1),
                            PayerCode = S(2),
                            PayerNameRaw = S(3),
                            PayerNameNormalized = S(4),
                            GlobalPayerID = reader.IsDBNull(5) ? null : reader.GetInt32(5),
                            PayerGroupCode = S(6),
                            PayerCommonCode = S(7),
                            Parent = S(8),
                            PlanType = S(9),
                            MCOType = S(10),
                            PayerState = S(11),
                            IsActive = S(12),
                            BenefitAdminCode = S(13),
                            BenefitAdministrator = S(14),
                            Remarks = S(15),
                            LabName = S(16),
                            LabState = S(17),
                            LabStateCode = S(18),
                            Basis = "Same Payer_Name_Raw + Lab Name"
                        });
                }

                if (await reader.NextResultAsync(ct))
                    while (await reader.ReadAsync(ct))
                        unmappedIds.Add(reader.GetInt32(0));
            }

            await tx.CommitAsync(ct);
            return (inserted, updated, duplicates, unmappedIds);
        }
        catch
        {
            await tx.RollbackAsync(CancellationToken.None);
            throw;
        }
    }

    private static DataTable BuildInsuranceImportTable(IReadOnlyList<(int RowNumber, InsurancePayerMasterDto Value)> rows)
    {
        var table = new DataTable();
        table.Columns.Add("RowNumber", typeof(int));
        table.Columns.Add("PayerCode", typeof(string));
        table.Columns.Add("PayerNameRaw", typeof(string));
        table.Columns.Add("PayerNameNormalized", typeof(string));
        table.Columns.Add("GlobalPayerID", typeof(int));
        table.Columns.Add("PayerGroupCode", typeof(string));
        table.Columns.Add("PayerCommonCode", typeof(string));
        table.Columns.Add("Parent", typeof(string));
        table.Columns.Add("PlanType", typeof(string));
        table.Columns.Add("MCOType", typeof(string));
        table.Columns.Add("PayerState", typeof(string));
        table.Columns.Add("IsActive", typeof(string));
        table.Columns.Add("BenefitAdminCode", typeof(string));
        table.Columns.Add("BenefitAdministrator", typeof(string));
        table.Columns.Add("Remarks", typeof(string));
        table.Columns.Add("LabName", typeof(string));
        table.Columns.Add("LabId", typeof(int));
        table.Columns.Add("LabState", typeof(string));
        table.Columns.Add("LabStateCode", typeof(string));

        foreach (var (rowNumber, value) in rows)
        {
            table.Rows.Add(
                rowNumber,
                DbValue(value.PayerCode),
                value.PayerNameRaw,
                DbValue(value.PayerNameNormalized),
                DbValue(value.GlobalPayerID),
                DbValue(value.PayerGroupCode),
                DbValue(value.PayerCommonCode),
                DbValue(value.Parent),
                DbValue(value.PlanType),
                DbValue(value.MCOType),
                DbValue(value.PayerState),
                DbValue(value.IsActive),
                DbValue(value.BenefitAdminCode),
                DbValue(value.BenefitAdministrator),
                DbValue(value.Remarks),
                DbValue(value.LabName),
                DbValue(value.LabId),
                DbValue(value.LabState),
                DbValue(value.LabStateCode));
        }

        return table;
    }

    public async Task<byte[]> ExportInsurancePayersAsync(InsurancePayerMasterQuery query, CancellationToken ct)
    {
        var rows = await GetInsurancePayersForExportAsync(query, ct);
        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add("Lab_Ins_Master");
        var headers = new[] { "S.No", "Payer_Code", "Payer_Name_Raw", "Payer_Name_Normalized", "Global_Payer_ID", "Payer_Group_Code", "Payer_Common_Code", "Parent", "Plan_Type", "MCO_Type", "Payer_State", "Is_Active", "Benefit Admin Code", "Benefit Administrator", "Remarks", "Lab Name", "Lab State", "Lab State Code" };
        WriteHeaders(ws, headers);
        for (var i = 0; i < rows.Count; i++)
        {
            var r = rows[i]; var row = i + 2;
            ws.Cell(row, 1).Value = i + 1; ws.Cell(row, 2).Value = r.PayerCode; ws.Cell(row, 3).Value = r.PayerNameRaw; ws.Cell(row, 4).Value = r.PayerNameNormalized; ws.Cell(row, 5).Value = r.GlobalPayerID; ws.Cell(row, 6).Value = r.PayerGroupCode; ws.Cell(row, 7).Value = r.PayerCommonCode; ws.Cell(row, 8).Value = r.Parent; ws.Cell(row, 9).Value = r.PlanType; ws.Cell(row, 10).Value = r.MCOType; ws.Cell(row, 11).Value = r.PayerState; ws.Cell(row, 12).Value = r.IsActive; ws.Cell(row, 13).Value = r.BenefitAdminCode; ws.Cell(row, 14).Value = r.BenefitAdministrator; ws.Cell(row, 15).Value = r.Remarks; ws.Cell(row, 16).Value = r.LabName; ws.Cell(row, 17).Value = r.LabState; ws.Cell(row, 18).Value = r.LabStateCode;
        }
        ws.Columns().AdjustToContents();
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    public async Task<PagedResult<PayerPolicyInsuranceMasterDto>> GetPolicyPayersAsync(PayerPolicyInsuranceMasterQuery query, CancellationToken ct)
    {
        query.Page = Math.Max(1, query.Page);
        query.PageSize = Math.Clamp(query.PageSize <= 0 ? 25 : query.PageSize, 10, 1000);
        var where = BuildPolicyWhere(query, out var parameters);
        var orderBy = BuildPolicyOrderBy(query);
        var result = new PagedResult<PayerPolicyInsuranceMasterDto> { Page = query.Page, PageSize = query.PageSize };
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using (var count = new SqlCommand($"SELECT COUNT(1) FROM dbo.PayerPolicyInsuranceMaster WHERE {where};", conn))
        {
            count.Parameters.AddRange(Clone(parameters));
            result.TotalCount = Convert.ToInt32(await count.ExecuteScalarAsync(ct) ?? 0);
        }
        await using var cmd = new SqlCommand($"""
            SELECT PPInsuranceMasterId, GlobalPayerId, GlobalPayerCode, PayerGroupCode, BenefitAdminCode,
                   BenefitAdministrator, PayerNameRaw, PayerNameNormalized, PayerShortCode, PlanType,
                   PayerState, IsActive, Remarks, PayerFamily, PayerFamilySource
            FROM dbo.PayerPolicyInsuranceMaster
            WHERE {where}
            ORDER BY {orderBy}
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """, conn);
        cmd.Parameters.AddRange(Clone(parameters));
        cmd.Parameters.AddWithValue("@Offset", (query.Page - 1) * query.PageSize);
        cmd.Parameters.AddWithValue("@PageSize", query.PageSize);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) result.Items.Add(MapPolicy(reader));
        return result;
    }

    public async Task<IReadOnlyList<PayerPolicyInsuranceMasterDto>> GetPolicyPayersForExportAsync(PayerPolicyInsuranceMasterQuery query, CancellationToken ct)
    {
        query.Page = 1;
        query.PageSize = 100000;
        return (await GetPolicyPayersAsync(query, ct)).Items;
    }

    public async Task<PayerPolicyInsuranceMasterDto?> GetPolicyPayerAsync(int id, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT PPInsuranceMasterId, GlobalPayerId, GlobalPayerCode, PayerGroupCode, BenefitAdminCode,
                   BenefitAdministrator, PayerNameRaw, PayerNameNormalized, PayerShortCode, PlanType,
                   PayerState, IsActive, Remarks, PayerFamily, PayerFamilySource
            FROM dbo.PayerPolicyInsuranceMaster WHERE PPInsuranceMasterId = @Id;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? MapPolicy(reader) : null;
    }

    public async Task<int> CreatePolicyPayerAsync(PayerPolicyInsuranceMasterDto dto, string? userName, CancellationToken ct)
    {
        Trim(dto);
        if (string.IsNullOrWhiteSpace(dto.PayerNameRaw)) throw new ArgumentException("Payer Name is required.");
        if (!dto.GlobalPayerId.HasValue) throw new ArgumentException("Global Payer ID is required.");
        await using var conn = Open();
        await conn.OpenAsync(ct);
        // Payer Name must be unique in the master (a new payer under an existing normalized group still
        // needs its own distinct raw name).
        await EnsurePolicyRawNameAvailableAsync(conn, dto.PayerNameRaw, null, ct);
        await EnsurePolicyUniqueAsync(conn, dto, null, ct);
        await using var cmd = new SqlCommand("""
            INSERT INTO dbo.PayerPolicyInsuranceMaster
                (GlobalPayerId, GlobalPayerCode, PayerGroupCode, BenefitAdminCode, BenefitAdministrator,
                 PayerNameRaw, PayerNameNormalized, PayerShortCode, PlanType, PayerState, IsActive, Remarks,
                 PayerFamily, PayerFamilySource, CreatedBy)
            OUTPUT INSERTED.PPInsuranceMasterId
            VALUES
                (@GlobalPayerId, @GlobalPayerCode, @PayerGroupCode, @BenefitAdminCode, @BenefitAdministrator,
                 @PayerNameRaw, @PayerNameNormalized, @PayerShortCode, @PlanType, @PayerState, @IsActive, @Remarks,
                 @PayerFamily, @PayerFamilySource, @CreatedBy);
            """, conn);
        AddPolicyParams(cmd, dto);
        cmd.Parameters.AddWithValue("@CreatedBy", DbValue(userName));
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
    }

    public async Task<int> GetNextPolicyGlobalPayerIdAsync(CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(
            "SELECT ISNULL(MAX(TRY_CONVERT(INT, GlobalPayerId)), 1000) + 1 FROM dbo.PayerPolicyInsuranceMaster;", conn);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
    }

    public async Task<(int PPInsuranceMasterId, int GlobalPayerId, string GlobalPayerCode)> MintPolicyPayerAsync(
        string payerNameRaw, string? payerNameNormalized, string? state, string? userName, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(payerNameRaw)) throw new ArgumentException("Payer Name is required.");
        await using var conn = Open();
        await conn.OpenAsync(ct);
        // Serializable + UPDLOCK/HOLDLOCK so two concurrent mints can never take the same next id.
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        try
        {
            int newId;
            await using (var idCmd = new SqlCommand(
                "SELECT ISNULL(MAX(TRY_CONVERT(INT, GlobalPayerId)), 1000) + 1 FROM dbo.PayerPolicyInsuranceMaster WITH (UPDLOCK, HOLDLOCK);", conn, tx))
                newId = Convert.ToInt32(await idCmd.ExecuteScalarAsync(ct));
            var code = newId.ToString(CultureInfo.InvariantCulture);

            int ppId;
            await using (var ins = new SqlCommand("""
                INSERT INTO dbo.PayerPolicyInsuranceMaster
                    (GlobalPayerId, GlobalPayerCode, PayerNameRaw, PayerNameNormalized, PayerState, IsActive, CreatedBy)
                OUTPUT INSERTED.PPInsuranceMasterId
                VALUES (@Gid, @Code, @Raw, @Norm, @State, 'Y', @User);
                """, conn, tx))
            {
                ins.Parameters.AddWithValue("@Gid", code);   // GlobalPayerId is nvarchar(50); store the numeric string
                ins.Parameters.AddWithValue("@Code", code);  // GlobalPayerCode is NOT NULL - seed it with the id
                ins.Parameters.AddWithValue("@Raw", payerNameRaw.Trim());
                ins.Parameters.AddWithValue("@Norm", DbValue(payerNameNormalized));
                ins.Parameters.AddWithValue("@State", DbValue(state));
                ins.Parameters.AddWithValue("@User", DbValue(userName));
                ppId = Convert.ToInt32(await ins.ExecuteScalarAsync(ct));
            }

            await using (var aud = new SqlCommand("""
                IF OBJECT_ID('dbo.PayerMasterAuditTrail', 'U') IS NOT NULL
                    INSERT dbo.PayerMasterAuditTrail
                        (Master, RecordId, GlobalPayerID, PayerName, FieldName, OldValue, NewValue, ActionType, PerformedBy, ApprovalStatus)
                    VALUES ('Policy', @Rec, @GidInt, @Raw, '(record)', NULL, 'Created via resolve API', 'ApiMint', @User, 'Applied directly');
                """, conn, tx))
            {
                aud.Parameters.AddWithValue("@Rec", ppId);
                aud.Parameters.AddWithValue("@GidInt", newId);
                aud.Parameters.AddWithValue("@Raw", payerNameRaw.Trim());
                aud.Parameters.AddWithValue("@User", DbValue(userName));
                await aud.ExecuteNonQueryAsync(ct);
            }

            await tx.CommitAsync(ct);
            return (ppId, newId, code);
        }
        catch
        {
            await tx.RollbackAsync(CancellationToken.None);
            throw;
        }
    }

    public async Task<bool> UpdatePolicyPayerAsync(int id, PayerPolicyInsuranceMasterDto dto, string? userName, CancellationToken ct)
    {
        Trim(dto);
        if (string.IsNullOrWhiteSpace(dto.PayerNameRaw)) throw new ArgumentException("Payer Name is required.");
        if (!dto.GlobalPayerId.HasValue) throw new ArgumentException("Global Payer ID is required.");
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await EnsurePolicyUniqueAsync(conn, dto, id, ct);
        await using var cmd = new SqlCommand("""
            UPDATE dbo.PayerPolicyInsuranceMaster
            SET GlobalPayerId=@GlobalPayerId, GlobalPayerCode=@GlobalPayerCode, PayerGroupCode=@PayerGroupCode,
                BenefitAdminCode=@BenefitAdminCode, BenefitAdministrator=@BenefitAdministrator, PayerNameRaw=@PayerNameRaw,
                PayerNameNormalized=@PayerNameNormalized, PayerShortCode=@PayerShortCode, PlanType=@PlanType,
                PayerState=@PayerState, IsActive=@IsActive, Remarks=@Remarks,
                PayerFamily=COALESCE(@PayerFamily, PayerFamily), PayerFamilySource=COALESCE(@PayerFamilySource, PayerFamilySource),
                ModifiedBy=@ModifiedBy, ModifiedOn=SYSUTCDATETIME()
            WHERE PPInsuranceMasterId=@Id;
            """, conn);
        AddPolicyParams(cmd, dto);
        cmd.Parameters.AddWithValue("@Id", id);
        cmd.Parameters.AddWithValue("@ModifiedBy", DbValue(userName));
        return await cmd.ExecuteNonQueryAsync(ct) > 0;
    }

    public Task<bool> UpdatePolicyPayerStatusAsync(int id, string? isActive, string? userName, CancellationToken ct)
        => UpdateStatusAsync("dbo.PayerPolicyInsuranceMaster", "PPInsuranceMasterId", id, isActive, userName, ct);

    // Excel column names expected in the Payer Policy Insurance Master import file.
    private static readonly string[] PolicyImportColumns =
    {
        "Global_Payer_ID", "Global_Payer_Code", "Payer_Group_Code", "Benefit Admin Code", "Benefit Administrator",
        "Payer Name", "Payer_Name_Normalized", "Payer", "Plan_Type", "Payer_State", "Is_Active", "Remarks",
        "Payer Family", "Payer Family Source"
    };

    public async Task<ImportResultDto> ImportPolicyPayersAsync(Stream stream, string? userName, CancellationToken ct)
    {
        using var workbook = new XLWorkbook(stream);
        if (!workbook.Worksheets.TryGetWorksheet("PP_Ins.Master", out var ws))
            return new ImportResultDto { ErrorRows = 1, Errors = { "Sheet PP_Ins.Master was not found." } };
        // NOT-NULL rule (Policy): only the natural key Payer Name + Global_Payer_ID is required;
        // every other column is optional and may be blank.
        var required = new[] { "Global_Payer_ID", "Payer Name" };
        if (!TryBuildHeaderMap(ws, PolicyImportColumns, required, out var header, out var headerErrors))
            return new ImportResultDto { ErrorRows = headerErrors.Count, Errors = headerErrors };

        var result = new ImportResultDto();
        var lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
        var rows = new List<PayerPolicyInsuranceMasterDto>();
        for (var row = 2; row <= lastRow; row++)
        {
            result.TotalRows++;
            var globalId = IntCellOpt(ws, row, header, "Global_Payer_ID", result, row, out var globalIdInvalid);
            var payerGroup = IntCellOpt(ws, row, header, "Payer_Group_Code", result, row, out var payerGroupInvalid);
            var dto = new PayerPolicyInsuranceMasterDto
            {
                GlobalPayerId = globalId,
                GlobalPayerCode = CellOpt(ws, row, header, "Global_Payer_Code") ?? string.Empty,
                PayerGroupCode = payerGroup,
                BenefitAdminCode = CellOpt(ws, row, header, "Benefit Admin Code"),
                BenefitAdministrator = CellOpt(ws, row, header, "Benefit Administrator"),
                PayerNameRaw = CellOpt(ws, row, header, "Payer Name") ?? string.Empty,
                PayerNameNormalized = CellOpt(ws, row, header, "Payer_Name_Normalized"),
                PayerShortCode = CellOpt(ws, row, header, "Payer"),
                PlanType = CellOpt(ws, row, header, "Plan_Type"),
                PayerState = CellOpt(ws, row, header, "Payer_State"),
                IsActive = CellOpt(ws, row, header, "Is_Active"),
                Remarks = CellOpt(ws, row, header, "Remarks"),
                PayerFamily = CellOpt(ws, row, header, "Payer Family"),
                PayerFamilySource = CellOpt(ws, row, header, "Payer Family Source")
            };
            Trim(dto);

            var rowErrors = new List<string>();
            if (globalIdInvalid) rowErrors.Add("Global_Payer_ID is not a valid integer");
            else if (!dto.GlobalPayerId.HasValue) rowErrors.Add("Global_Payer_ID is required");
            if (string.IsNullOrWhiteSpace(dto.PayerNameRaw)) rowErrors.Add("Payer Name is required");
            if (rowErrors.Count > 0)
            {
                result.SkippedRows++;
                result.Errors.Add($"Row {row}: {string.Join("; ", rowErrors)}.");
                continue;
            }
            if (payerGroupInvalid)
                result.Warnings.Add($"Row {row}: Payer_Group_Code is not an integer and was left blank.");

            rows.Add(dto);
        }

        if (rows.Count > 0)
        {
            await using var conn = Open();
            await conn.OpenAsync(ct);
            await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(IsolationLevel.Serializable, ct);
            try
            {
                foreach (var dto in rows)
                {
                    var existingId = await FindPolicyImportMatchAsync(conn, tx, dto, ct);
                    if (existingId.HasValue)
                    {
                        await UpsertPolicyRowAsync(conn, tx, existingId.Value, dto, userName, ct);
                        result.UpdatedRows++;
                    }
                    else
                    {
                        var newId = await UpsertPolicyRowAsync(conn, tx, null, dto, userName, ct);
                        result.InsertedRows++;
                        existingId = newId;
                    }
                }

                // Post-import sync: the policy master is the source of truth for GlobalPayerID on the
                // Lab master. Overwrite every matching Lab record (matched on PayerNameNormalized).
                var syncPairs = rows
                    .Where(r => !string.IsNullOrWhiteSpace(r.PayerNameNormalized) && r.GlobalPayerId.HasValue)
                    .GroupBy(r => CiKey(r.PayerNameNormalized!))
                    .Select(g => (Normalized: g.Last().PayerNameNormalized!.Trim(), Gid: g.Last().GlobalPayerId!.Value))
                    .ToList();
                var synced = await SyncLabGlobalPayerIdsFromPolicyAsync(conn, tx, syncPairs, userName, ct);
                if (synced > 0)
                    result.Warnings.Add($"{synced} Lab Insurance Master record(s) had their Global Payer ID synced from the policy master.");

                await tx.CommitAsync(ct);
            }
            catch
            {
                await tx.RollbackAsync(CancellationToken.None);
                throw;
            }
        }

        result.ErrorRows = result.Errors.Count;
        return result;
    }

    /// <summary>Inserts or updates one Payer Policy row inside the import transaction and writes a record-level audit entry.</summary>
    private static async Task<int> UpsertPolicyRowAsync(SqlConnection conn, SqlTransaction tx, int? existingId, PayerPolicyInsuranceMasterDto dto, string? userName, CancellationToken ct)
    {
        int recordId;
        if (existingId.HasValue)
        {
            await using var cmd = new SqlCommand("""
                UPDATE dbo.PayerPolicyInsuranceMaster
                SET GlobalPayerId=@GlobalPayerId, GlobalPayerCode=@GlobalPayerCode, PayerGroupCode=@PayerGroupCode,
                    BenefitAdminCode=@BenefitAdminCode, BenefitAdministrator=@BenefitAdministrator, PayerNameRaw=@PayerNameRaw,
                    PayerNameNormalized=@PayerNameNormalized, PayerShortCode=@PayerShortCode, PlanType=@PlanType,
                    PayerState=@PayerState, IsActive=@IsActive, Remarks=@Remarks,
                    PayerFamily=COALESCE(@PayerFamily, PayerFamily), PayerFamilySource=COALESCE(@PayerFamilySource, PayerFamilySource),
                    ModifiedBy=@ActionUser, ModifiedOn=SYSUTCDATETIME()
                WHERE PPInsuranceMasterId=@Id;
                """, conn, tx);
            AddPolicyParams(cmd, dto);
            cmd.Parameters.AddWithValue("@Id", existingId.Value);
            cmd.Parameters.AddWithValue("@ActionUser", DbValue(userName));
            await cmd.ExecuteNonQueryAsync(ct);
            recordId = existingId.Value;
        }
        else
        {
            await using var cmd = new SqlCommand("""
                INSERT INTO dbo.PayerPolicyInsuranceMaster
                    (GlobalPayerId, GlobalPayerCode, PayerGroupCode, BenefitAdminCode, BenefitAdministrator,
                     PayerNameRaw, PayerNameNormalized, PayerShortCode, PlanType, PayerState, IsActive, Remarks,
                     PayerFamily, PayerFamilySource, CreatedBy)
                OUTPUT INSERTED.PPInsuranceMasterId
                VALUES
                    (@GlobalPayerId, @GlobalPayerCode, @PayerGroupCode, @BenefitAdminCode, @BenefitAdministrator,
                     @PayerNameRaw, @PayerNameNormalized, @PayerShortCode, @PlanType, @PayerState, @IsActive, @Remarks,
                     @PayerFamily, @PayerFamilySource, @ActionUser);
                """, conn, tx);
            AddPolicyParams(cmd, dto);
            cmd.Parameters.AddWithValue("@ActionUser", DbValue(userName));
            recordId = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
        }

        await WriteImportAuditAsync(conn, tx, "Policy", recordId, dto.GlobalPayerId, dto.PayerNameRaw, "(record)", null,
            existingId.HasValue ? "Updated" : "Inserted", userName, ct);
        return recordId;
    }

    /// <summary>Overwrites Lab master GlobalPayerID from the policy master (matched on PayerNameNormalized) and audits each change.</summary>
    private static async Task<int> SyncLabGlobalPayerIdsFromPolicyAsync(SqlConnection conn, SqlTransaction tx,
        IReadOnlyList<(string Normalized, int Gid)> pairs, string? userName, CancellationToken ct)
    {
        if (pairs.Count == 0) return 0;

        await using (var create = new SqlCommand("CREATE TABLE #PolicySync (PayerNameNormalized NVARCHAR(250) NOT NULL, GlobalPayerId INT NOT NULL); CREATE TABLE #PolicySyncAudit (RecordId INT, OldGid INT, NewGid INT, PayerNameRaw NVARCHAR(250));", conn, tx))
            await create.ExecuteNonQueryAsync(ct);

        foreach (var (normalized, gid) in pairs)
        {
            await using var ins = new SqlCommand("INSERT INTO #PolicySync (PayerNameNormalized, GlobalPayerId) VALUES (@N, @G);", conn, tx);
            ins.Parameters.AddWithValue("@N", normalized);
            ins.Parameters.AddWithValue("@G", gid);
            await ins.ExecuteNonQueryAsync(ct);
        }

        int changed;
        await using (var upd = new SqlCommand("""
            UPDATE lab
            SET GlobalPayerID = s.GlobalPayerId,
                ModifiedBy = @UserName,
                ModifiedOn = SYSUTCDATETIME()
            OUTPUT inserted.LabInsuranceMasterId, deleted.GlobalPayerID, inserted.GlobalPayerID, inserted.PayerNameRaw
                INTO #PolicySyncAudit (RecordId, OldGid, NewGid, PayerNameRaw)
            FROM dbo.LabInsuranceMaster lab
            JOIN #PolicySync s
              ON LTRIM(RTRIM(lab.PayerNameNormalized)) = s.PayerNameNormalized COLLATE Latin1_General_CI_AS
            WHERE ISNULL(lab.GlobalPayerID, -2147483648) <> s.GlobalPayerId;
            DECLARE @Changed INT = @@ROWCOUNT;

            IF OBJECT_ID('dbo.PayerMasterAuditTrail', 'U') IS NOT NULL
                INSERT dbo.PayerMasterAuditTrail
                    (Master, RecordId, GlobalPayerID, PayerName, FieldName, OldValue, NewValue, ActionType, PerformedBy, ApprovalStatus)
                SELECT 'Lab', RecordId, NewGid, PayerNameRaw, 'GlobalPayerID',
                       CONVERT(NVARCHAR(50), OldGid), CONVERT(NVARCHAR(50), NewGid),
                       'Import', @UserName, 'Applied directly'
                FROM #PolicySyncAudit;

            SELECT @Changed;
            """, conn, tx))
        {
            upd.Parameters.Add("@UserName", SqlDbType.NVarChar, 100).Value = DbValue(userName);
            changed = Convert.ToInt32(await upd.ExecuteScalarAsync(ct) ?? 0);
        }
        return changed;
    }

    private static async Task WriteImportAuditAsync(SqlConnection conn, SqlTransaction? tx, string master, int recordId,
        int? globalPayerId, string? payerName, string fieldName, string? oldValue, string? newValue, string? userName, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("""
            IF OBJECT_ID('dbo.PayerMasterAuditTrail', 'U') IS NOT NULL
                INSERT dbo.PayerMasterAuditTrail
                    (Master, RecordId, GlobalPayerID, PayerName, FieldName, OldValue, NewValue, ActionType, PerformedBy, ApprovalStatus)
                VALUES (@Master, @RecordId, @GlobalPayerID, @PayerName, @FieldName, @OldValue, @NewValue, 'Import', @PerformedBy, 'Applied directly');
            """, conn, tx);
        cmd.Parameters.AddWithValue("@Master", master);
        cmd.Parameters.AddWithValue("@RecordId", recordId);
        cmd.Parameters.AddWithValue("@GlobalPayerID", (object?)globalPayerId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@PayerName", (object?)payerName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FieldName", fieldName);
        cmd.Parameters.AddWithValue("@OldValue", (object?)oldValue ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@NewValue", (object?)newValue ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@PerformedBy", DbValue(userName));
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<byte[]> ExportPolicyPayersAsync(PayerPolicyInsuranceMasterQuery query, CancellationToken ct)
    {
        var rows = await GetPolicyPayersForExportAsync(query, ct);
        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add("PP_Ins.Master");
        var headers = new[] { "S.No", "Global_Payer_ID", "Global_Payer_Code", "Payer_Group_Code", "Benefit Admin Code", "Benefit Administrator", "Payer Name", "Payer_Name_Normalized", "Payer", "Plan_Type", "Payer_State", "Is_Active", "Remarks" };
        WriteHeaders(ws, headers);
        for (var i = 0; i < rows.Count; i++)
        {
            var r = rows[i]; var row = i + 2;
            ws.Cell(row, 1).Value = i + 1; ws.Cell(row, 2).Value = r.GlobalPayerId; ws.Cell(row, 3).Value = r.GlobalPayerCode; ws.Cell(row, 4).Value = r.PayerGroupCode; ws.Cell(row, 5).Value = r.BenefitAdminCode; ws.Cell(row, 6).Value = r.BenefitAdministrator; ws.Cell(row, 7).Value = r.PayerNameRaw; ws.Cell(row, 8).Value = r.PayerNameNormalized; ws.Cell(row, 9).Value = r.PayerShortCode; ws.Cell(row, 10).Value = r.PlanType; ws.Cell(row, 11).Value = r.PayerState; ws.Cell(row, 12).Value = r.IsActive; ws.Cell(row, 13).Value = r.Remarks;
        }
        ws.Columns().AdjustToContents();
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    public async Task<IReadOnlyList<MasterValueLabOption>> GetLabsAsync(CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        var rows = new List<MasterValueLabOption>();
        await using var cmd = new SqlCommand("SELECT LabId, LabName FROM dbo.Labs WHERE IsActive = 1 ORDER BY LabName;", conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) rows.Add(new MasterValueLabOption { LabId = reader.GetInt32(0), LabName = reader.GetString(1) });
        return rows;
    }

    private async Task<bool> UpdateStatusAsync(string table, string key, int id, string? isActive, string? userName, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand($"UPDATE {table} SET IsActive=@IsActive, ModifiedBy=@ModifiedBy, ModifiedOn=SYSUTCDATETIME() WHERE {key}=@Id;", conn);
        cmd.Parameters.AddWithValue("@Id", id);
        cmd.Parameters.AddWithValue("@IsActive", DbValue(isActive));
        cmd.Parameters.AddWithValue("@ModifiedBy", DbValue(userName));
        return await cmd.ExecuteNonQueryAsync(ct) > 0;
    }

    private async Task<int?> FindInsuranceImportMatchAsync(SqlConnection conn, InsurancePayerMasterDto dto, CancellationToken ct)
    {
        var normalizedMatch = await FindInsuranceByNormalizedGlobalAsync(conn, dto.PayerNameNormalized, dto.GlobalPayerID, ct);
        if (normalizedMatch.HasValue) return normalizedMatch;

        if (!string.IsNullOrWhiteSpace(dto.PayerCode) && dto.LabId.HasValue)
        {
            await using var cmd = new SqlCommand("SELECT TOP (1) LabInsuranceMasterId FROM dbo.LabInsuranceMaster WHERE PayerCode=@PayerCode AND LabId=@LabId;", conn);
            cmd.Parameters.AddWithValue("@PayerCode", dto.PayerCode);
            cmd.Parameters.AddWithValue("@LabId", dto.LabId.Value);
            var id = await cmd.ExecuteScalarAsync(ct);
            if (id != null) return Convert.ToInt32(id);
        }
        if (!string.IsNullOrWhiteSpace(dto.PayerNameRaw) && !string.IsNullOrWhiteSpace(dto.LabName))
        {
            await using var cmd = new SqlCommand("SELECT TOP (1) LabInsuranceMasterId FROM dbo.LabInsuranceMaster WHERE PayerNameRaw=@PayerNameRaw AND LabName=@LabName;", conn);
            cmd.Parameters.AddWithValue("@PayerNameRaw", dto.PayerNameRaw);
            cmd.Parameters.AddWithValue("@LabName", dto.LabName);
            var id = await cmd.ExecuteScalarAsync(ct);
            if (id != null) return Convert.ToInt32(id);
        }
        return null;
    }

    /// <summary>
    /// Payer Policy Insurance Master upsert key is (PayerNameRaw, PayerNameNormalized, GlobalPayerId),
    /// all matched trim + case-insensitive. Returns the existing PPInsuranceMasterId when a row with
    /// the same triple already exists, otherwise null (insert).
    /// </summary>
    private static async Task<int?> FindPolicyImportMatchAsync(SqlConnection conn, SqlTransaction? tx, PayerPolicyInsuranceMasterDto dto, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("""
            SELECT TOP (1) PPInsuranceMasterId
            FROM dbo.PayerPolicyInsuranceMaster WITH (UPDLOCK, HOLDLOCK)
            WHERE LTRIM(RTRIM(PayerNameRaw)) = @PayerNameRaw COLLATE Latin1_General_CI_AS
              AND ISNULL(TRY_CONVERT(INT, GlobalPayerId), -1) = @GlobalPayerId
            ORDER BY PPInsuranceMasterId;
            """, conn, tx);
        cmd.Parameters.AddWithValue("@PayerNameRaw", dto.PayerNameRaw.Trim());
        cmd.Parameters.AddWithValue("@GlobalPayerId", dto.GlobalPayerId ?? -1);
        var id = await cmd.ExecuteScalarAsync(ct);
        return id == null || id == DBNull.Value ? null : Convert.ToInt32(id);
    }

    private static async Task<bool> InsuranceNormalizedGlobalExistsAsync(SqlConnection conn, string? payerNameNormalized, int? globalPayerId, int? excludeId, CancellationToken ct)
        => await FindInsuranceByNormalizedGlobalAsync(conn, payerNameNormalized, globalPayerId, ct) is int existingId
           && (!excludeId.HasValue || existingId != excludeId.Value);

    /// <summary>
    /// Payer Policy Insurance Master uniqueness follows the natural key
    /// (PayerNameRaw, GlobalPayerId). A second row with the same pair is rejected.
    /// </summary>
    private static async Task EnsurePolicyUniqueAsync(SqlConnection conn, PayerPolicyInsuranceMasterDto dto, int? excludeId, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("""
            SELECT TOP (1) PPInsuranceMasterId FROM dbo.PayerPolicyInsuranceMaster
            WHERE LTRIM(RTRIM(PayerNameRaw)) = @PayerNameRaw COLLATE Latin1_General_CI_AS
              AND ISNULL(TRY_CONVERT(INT, GlobalPayerId), -1) = @GlobalPayerId
              AND (@ExcludeId IS NULL OR PPInsuranceMasterId <> @ExcludeId);
            """, conn);
        cmd.Parameters.AddWithValue("@PayerNameRaw", dto.PayerNameRaw.Trim());
        cmd.Parameters.AddWithValue("@GlobalPayerId", dto.GlobalPayerId ?? -1);
        cmd.Parameters.AddWithValue("@ExcludeId", (object?)excludeId ?? DBNull.Value);
        if (await cmd.ExecuteScalarAsync(ct) != null)
            throw new ArgumentException($"A Payer Policy record for '{dto.PayerNameRaw.Trim()}' with Global Payer ID {(dto.GlobalPayerId?.ToString() ?? "(blank)")} already exists.");
    }

    private static async Task EnsurePolicyRawNameAvailableAsync(SqlConnection conn, string? payerNameRaw, int? excludeId, CancellationToken ct)
    {
        var raw = (payerNameRaw ?? string.Empty).Trim();
        if (raw.Length == 0) return;
        await using var cmd = new SqlCommand("""
            SELECT TOP (1) PPInsuranceMasterId FROM dbo.PayerPolicyInsuranceMaster
            WHERE LTRIM(RTRIM(PayerNameRaw)) = @Raw COLLATE Latin1_General_CI_AS
              AND (@ExcludeId IS NULL OR PPInsuranceMasterId <> @ExcludeId);
            """, conn);
        cmd.Parameters.AddWithValue("@Raw", raw);
        cmd.Parameters.AddWithValue("@ExcludeId", (object?)excludeId ?? DBNull.Value);
        if (await cmd.ExecuteScalarAsync(ct) != null)
            throw new ArgumentException($"A Payer Policy record with the Payer Name '{raw}' already exists. Enter a different Payer Name.");
    }

    private static async Task<int?> FindInsuranceByNormalizedGlobalAsync(SqlConnection conn, string? payerNameNormalized, int? globalPayerId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(payerNameNormalized) || !globalPayerId.HasValue) return null;
        await using var cmd = new SqlCommand("""
            SELECT TOP (1) LabInsuranceMasterId
            FROM dbo.LabInsuranceMaster
            WHERE PayerNameNormalized = @PayerNameNormalized
              AND GlobalPayerID = @GlobalPayerID;
            """, conn);
        cmd.Parameters.AddWithValue("@PayerNameNormalized", payerNameNormalized.Trim());
        cmd.Parameters.AddWithValue("@GlobalPayerID", globalPayerId.Value);
        var id = await cmd.ExecuteScalarAsync(ct);
        return id == null ? null : Convert.ToInt32(id);
    }

    /// <summary>
    /// Reconciliation lookup for the Lab import: returns the Payer Policy master's Global Payer ID for a
    /// given raw payer name (trim + case-insensitive), or null when the payer is not in the policy master.
    /// </summary>
    private static async Task<int?> FindPolicyGlobalPayerIdByRawNameAsync(SqlConnection conn, SqlTransaction? tx, string payerNameRaw, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("""
            SELECT TOP (1) TRY_CONVERT(INT, GlobalPayerId)
            FROM dbo.PayerPolicyInsuranceMaster
            WHERE LTRIM(RTRIM(PayerNameRaw)) = @PayerNameRaw COLLATE Latin1_General_CI_AS
              AND TRY_CONVERT(INT, GlobalPayerId) IS NOT NULL
            ORDER BY PPInsuranceMasterId;
            """, conn, tx);
        cmd.Parameters.AddWithValue("@PayerNameRaw", payerNameRaw.Trim());
        var value = await cmd.ExecuteScalarAsync(ct);
        return value == null || value == DBNull.Value ? null : Convert.ToInt32(value);
    }

    private static string BuildInsuranceWhere(InsurancePayerMasterQuery q, out List<SqlParameter> p)
    {
        var parts = new List<string> { "1=1" };
        p = new List<SqlParameter>();
        AddLike(parts, p, "PayerCode", q.PayerCode);
        AddLike(parts, p, "PayerNameRaw", q.PayerName);
        AddEquals(parts, p, "LabId", q.LabId);
        AddEquals(parts, p, "GlobalPayerID", q.GlobalPayerId);
        AddLike(parts, p, "IsActive", q.IsActive);
        if (!string.IsNullOrWhiteSpace(q.MappingStatus))
        {
            // Same computed expression as the bell's mapping-summary counts, so a count deep-link
            // always finds exactly that many rows (blank status falls back to the GlobalPayerID state).
            parts.Add("""
                ISNULL(NULLIF(LTRIM(RTRIM(MappingStatus)), ''),
                       CASE WHEN GlobalPayerID IS NOT NULL THEN 'Mapped' ELSE 'Unmapped' END) = @MappingStatus
                """);
            p.Add(new SqlParameter("@MappingStatus", q.MappingStatus.Trim()));
        }
        if (!string.IsNullOrWhiteSpace(q.Search))
        {
            parts.Add("(PayerCode LIKE @Search ESCAPE '\\' OR PayerNameRaw LIKE @Search ESCAPE '\\' OR PayerNameNormalized LIKE @Search ESCAPE '\\' OR LabName LIKE @Search ESCAPE '\\')");
            p.Add(new SqlParameter("@Search", LikePattern(q.Search)));
        }
        return string.Join(" AND ", parts);
    }

    private static string BuildPolicyWhere(PayerPolicyInsuranceMasterQuery q, out List<SqlParameter> p)
    {
        var parts = new List<string> { "1=1" };
        p = new List<SqlParameter>();
        AddLike(parts, p, "GlobalPayerCode", q.GlobalPayerCode);
        AddLike(parts, p, "PayerNameRaw", q.PayerName);
        AddLike(parts, p, "PayerShortCode", q.PayerShortCode);
        AddLike(parts, p, "PlanType", q.PlanType);
        AddLike(parts, p, "PayerState", q.PayerState);
        AddLike(parts, p, "IsActive", q.IsActive);
        if (q.GlobalPayerId.HasValue)
        {
            // GlobalPayerId is nvarchar(50); compare numerically via TRY_CONVERT.
            parts.Add("TRY_CONVERT(INT, GlobalPayerId) = @GlobalPayerId");
            p.Add(new SqlParameter("@GlobalPayerId", q.GlobalPayerId.Value));
        }
        if (!string.IsNullOrWhiteSpace(q.Search))
        {
            parts.Add("(GlobalPayerCode LIKE @Search ESCAPE '\\' OR PayerNameRaw LIKE @Search ESCAPE '\\' OR PayerNameNormalized LIKE @Search ESCAPE '\\' OR PayerShortCode LIKE @Search ESCAPE '\\')");
            p.Add(new SqlParameter("@Search", LikePattern(q.Search)));
        }
        return string.Join(" AND ", parts);
    }

    private static string BuildInsuranceOrderBy(InsurancePayerMasterQuery q)
    {
        var columns = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["payerCode"] = "PayerCode",
            ["payerNameRaw"] = "PayerNameRaw",
            ["payerNameNormalized"] = "PayerNameNormalized",
            ["globalPayerID"] = "GlobalPayerID",
            ["payerGroupCode"] = "PayerGroupCode",
            ["payerCommonCode"] = "PayerCommonCode",
            ["parent"] = "Parent",
            ["planType"] = "PlanType",
            ["mcoType"] = "MCOType",
            ["payerState"] = "PayerState",
            ["isActive"] = "IsActive",
            ["benefitAdminCode"] = "BenefitAdminCode",
            ["benefitAdministrator"] = "BenefitAdministrator",
            ["labName"] = "LabName",
            ["labState"] = "LabState",
            ["labStateCode"] = "LabStateCode",
            ["remarks"] = "Remarks"
        };
        return BuildOrderBy(q.SortColumn, q.SortDirection, columns, "LabInsuranceMasterId DESC");
    }

    private static string BuildPolicyOrderBy(PayerPolicyInsuranceMasterQuery q)
    {
        var columns = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["globalPayerId"] = "TRY_CONVERT(INT, GlobalPayerId)",
            ["globalPayerCode"] = "GlobalPayerCode",
            ["payerGroupCode"] = "PayerGroupCode",
            ["benefitAdminCode"] = "BenefitAdminCode",
            ["benefitAdministrator"] = "BenefitAdministrator",
            ["payerNameRaw"] = "PayerNameRaw",
            ["payerName"] = "PayerNameRaw",
            ["payerNameNormalized"] = "PayerNameNormalized",
            ["payerShortCode"] = "PayerShortCode",
            ["planType"] = "PlanType",
            ["payerState"] = "PayerState",
            ["isActive"] = "IsActive",
            ["remarks"] = "Remarks",
            ["payerFamily"] = "PayerFamily",
            ["payerFamilySource"] = "PayerFamilySource"
        };
        return BuildOrderBy(q.SortColumn, q.SortDirection, columns, "PPInsuranceMasterId DESC");
    }

    private static string BuildOrderBy(string? requestedColumn, string? requestedDirection, IReadOnlyDictionary<string, string> columns, string fallback)
    {
        if (string.IsNullOrWhiteSpace(requestedColumn) || !columns.TryGetValue(requestedColumn.Trim(), out var column))
            return fallback;

        var direction = string.Equals(requestedDirection, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC";
        return $"{column} {direction}";
    }

    private static void AddLike(List<string> parts, List<SqlParameter> p, string column, string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        var name = "@" + column;
        parts.Add($"{column} LIKE {name} ESCAPE '\\'");
        p.Add(new SqlParameter(name, LikePattern(value)));
    }

    private static void AddEquals(List<string> parts, List<SqlParameter> p, string column, int? value)
    {
        if (!value.HasValue) return;
        var name = "@" + column;
        parts.Add($"{column} = {name}");
        p.Add(new SqlParameter(name, value.Value));
    }

    private static string LikePattern(string value)
        => $"%{EscapeLike(value.Trim())}%";

    private static string EscapeLike(string value)
        => value.Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("%", "\\%", StringComparison.Ordinal)
            .Replace("_", "\\_", StringComparison.Ordinal)
            .Replace("[", "\\[", StringComparison.Ordinal);

    /// <summary>
    /// Shared file-structure validation for both master imports. Headers are trimmed and matched
    /// case-insensitively against the expected column list (data casing is not mutated). Fails with a
    /// clear error when the file contains a duplicated expected column or is missing a NOT-NULL
    /// (required) column. Missing optional columns are allowed; columns not in the expected list
    /// (e.g. S.No) are ignored so the file still imports.
    /// </summary>
    private static bool TryBuildHeaderMap(IXLWorksheet ws, IReadOnlyList<string> expected, IReadOnlyList<string> required,
        out Dictionary<string, int> map, out List<string> errors)
    {
        map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        errors = new List<string>();
        var expectedSet = new HashSet<string>(expected, StringComparer.OrdinalIgnoreCase);
        var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var duplicates = new List<string>();

        var lastColumn = ws.LastColumnUsed()?.ColumnNumber() ?? 0;
        for (var col = 1; col <= lastColumn; col++)
        {
            var name = ws.Cell(1, col).GetString().Trim();
            if (name.Length == 0) continue;
            if (!expectedSet.Contains(name)) continue;
            var canonical = expected.First(e => string.Equals(e, name, StringComparison.OrdinalIgnoreCase));
            if (counts.TryGetValue(canonical, out var c))
            {
                counts[canonical] = c + 1;
                if (c == 1) duplicates.Add(canonical);
            }
            else
            {
                counts[canonical] = 1;
                map[canonical] = col;
            }
        }

        if (duplicates.Count > 0)
            errors.Add("Duplicate column(s): " + string.Join(", ", duplicates.Distinct()));
        var builtMap = map;
        var missingRequired = required.Where(r => !builtMap.ContainsKey(r)).ToList();
        if (missingRequired.Count > 0)
            errors.Add("Missing required column(s): " + string.Join(", ", missingRequired));

        return errors.Count == 0;
    }

    private static string? Cell(IXLWorksheet ws, int row, int col)
    {
        var value = ws.Cell(row, col).GetFormattedString().Trim();
        return string.IsNullOrWhiteSpace(value) ? null : value;
    }

    /// <summary>Reads a cell for an optional column that may be absent from the file.</summary>
    private static string? CellOpt(IXLWorksheet ws, int row, IReadOnlyDictionary<string, int> header, string column)
        => header.TryGetValue(column, out var col) ? Cell(ws, row, col) : null;

    private static int? IntCellOpt(IXLWorksheet ws, int row, IReadOnlyDictionary<string, int> header, string column, ImportResultDto result, int sourceRow, out bool invalid)
    {
        invalid = false;
        if (!header.TryGetValue(column, out var col)) return null;
        var text = Cell(ws, row, col);
        if (string.IsNullOrWhiteSpace(text)) return null;
        if (int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value)) return value;
        if (decimal.TryParse(text, NumberStyles.Number, CultureInfo.InvariantCulture, out var dec)) return (int)dec;
        invalid = true;
        return null;
    }

    private static void WriteHeaders(IXLWorksheet ws, IReadOnlyList<string> headers)
    {
        for (var i = 0; i < headers.Count; i++) ws.Cell(1, i + 1).Value = headers[i];
        ws.Row(1).Style.Font.Bold = true;
    }

    private async Task<Dictionary<string, MasterValueLabOption>> LabsByNameAsync(SqlConnection conn, CancellationToken ct)
    {
        var rows = new Dictionary<string, MasterValueLabOption>(StringComparer.OrdinalIgnoreCase);
        await using var cmd = new SqlCommand("SELECT LabId, LabName FROM dbo.Labs;", conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var option = new MasterValueLabOption { LabId = reader.GetInt32(0), LabName = reader.GetString(1) };
            rows[Norm(option.LabName)] = option;
        }
        AddLabImportAliases(rows);
        return rows;
    }

    private static void AddLabImportAliases(Dictionary<string, MasterValueLabOption> labs)
    {
        var aliases = new (int LabId, string LabName, string ImportReference)[]
        {
            (1, "Prism Molecular", "Prism"),
            (2, "InHealth", "InHealth-DTR"),
            (4, "Cove", "Cove"),
            (5, "Dylo", "Dylo"),
            (6, "PCRDx - AL", "PCR AL"),
            (7, "PCRDx - CO", "PCR CO"),
            (10, "BeechTree", "Beech Tree"),
            (13, "PCR Labs of America", "PCR Labs of America"),
            (18, "Certus", "Certus"),
            (23, "Northwest", "NWL"),
            (24, "Augustus_Labs", "Augustus"),
            (16, "Elixir", "Elixir"),
            (12, "Phi Life", "Phi Life"),
            (9, "Rising Tides", "Rising Tides")
        };

        var byId = labs.Values
            .GroupBy(x => x.LabId)
            .ToDictionary(x => x.Key, x => x.First());

        foreach (var alias in aliases)
        {
            var option = byId.TryGetValue(alias.LabId, out var existing)
                ? existing
                : new MasterValueLabOption { LabId = alias.LabId, LabName = alias.LabName };

            labs[Norm(alias.ImportReference)] = option;
            labs[Norm(alias.LabName)] = option;
        }
    }

    private static async Task<bool> LabExistsAsync(SqlConnection conn, int labId, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("SELECT COUNT(1) FROM dbo.Labs WHERE LabId=@LabId;", conn);
        cmd.Parameters.AddWithValue("@LabId", labId);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct) ?? 0) > 0;
    }

    private SqlConnection Open() => new(_connectionString);
    private static SqlParameter[] Clone(IEnumerable<SqlParameter> source) => source.Select(x => new SqlParameter(x.ParameterName, x.Value)).ToArray();
    private static object DbValue(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();
    private static object DbValue(int? value) => value.HasValue ? value.Value : DBNull.Value;
    private static string Norm(string value) => new(value.Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
    // Trim + case-insensitive key for reconciliation matching (per spec: trim + case-insensitive, not alphanumeric-strip).
    private static string CiKey(string value) => value.Trim().ToUpperInvariant();
    private static string? Str(SqlDataReader r, string c) => r.IsDBNull(r.GetOrdinal(c)) ? null : r.GetString(r.GetOrdinal(c));
    private static int? Int(SqlDataReader r, string c) => r.IsDBNull(r.GetOrdinal(c)) ? null : r.GetInt32(r.GetOrdinal(c));

    private static InsurancePayerMasterDto MapInsurance(SqlDataReader r) => new()
    {
        LabInsuranceMasterId = r.GetInt32(r.GetOrdinal("LabInsuranceMasterId")),
        PayerCode = Str(r, "PayerCode"),
        PayerNameRaw = Str(r, "PayerNameRaw") ?? string.Empty,
        PayerNameNormalized = Str(r, "PayerNameNormalized"),
        GlobalPayerID = Int(r, "GlobalPayerID"),
        PayerGroupCode = Str(r, "PayerGroupCode"),
        PayerCommonCode = Str(r, "PayerCommonCode"),
        Parent = Str(r, "Parent"),
        PlanType = Str(r, "PlanType"),
        MCOType = Str(r, "MCOType"),
        PayerState = Str(r, "PayerState"),
        IsActive = Str(r, "IsActive"),
        BenefitAdminCode = Str(r, "BenefitAdminCode"),
        BenefitAdministrator = Str(r, "BenefitAdministrator"),
        Remarks = Str(r, "Remarks"),
        LabName = Str(r, "LabName"),
        LabId = Int(r, "LabId"),
        LabState = Str(r, "LabState"),
        LabStateCode = Str(r, "LabStateCode"),
        MappingStatus = Str(r, "MappingStatus"),
        MappedBy = Str(r, "MappedBy")
    };

    private static PayerPolicyInsuranceMasterDto MapPolicy(SqlDataReader r) => new()
    {
        PPInsuranceMasterId = r.GetInt32(r.GetOrdinal("PPInsuranceMasterId")),
        // GlobalPayerId is nvarchar(50) in the DB but always numeric; surface as int?.
        GlobalPayerId = ParseInt(Str(r, "GlobalPayerId")),
        GlobalPayerCode = Str(r, "GlobalPayerCode") ?? string.Empty,
        PayerGroupCode = Int(r, "PayerGroupCode"),
        BenefitAdminCode = Str(r, "BenefitAdminCode"),
        BenefitAdministrator = Str(r, "BenefitAdministrator"),
        PayerNameRaw = Str(r, "PayerNameRaw") ?? string.Empty,
        PayerNameNormalized = Str(r, "PayerNameNormalized"),
        PayerShortCode = Str(r, "PayerShortCode"),
        PlanType = Str(r, "PlanType"),
        PayerState = Str(r, "PayerState"),
        IsActive = Str(r, "IsActive"),
        Remarks = Str(r, "Remarks"),
        PayerFamily = Str(r, "PayerFamily"),
        PayerFamilySource = Str(r, "PayerFamilySource")
    };

    private static void AddInsuranceParams(SqlCommand cmd, InsurancePayerMasterDto d)
    {
        cmd.Parameters.AddWithValue("@PayerCode", DbValue(d.PayerCode));
        cmd.Parameters.AddWithValue("@PayerNameRaw", d.PayerNameRaw.Trim());
        cmd.Parameters.AddWithValue("@PayerNameNormalized", DbValue(d.PayerNameNormalized));
        cmd.Parameters.AddWithValue("@GlobalPayerID", DbValue(d.GlobalPayerID));
        cmd.Parameters.AddWithValue("@PayerGroupCode", DbValue(d.PayerGroupCode));
        cmd.Parameters.AddWithValue("@PayerCommonCode", DbValue(d.PayerCommonCode));
        cmd.Parameters.AddWithValue("@Parent", DbValue(d.Parent));
        cmd.Parameters.AddWithValue("@PlanType", DbValue(d.PlanType));
        cmd.Parameters.AddWithValue("@MCOType", DbValue(d.MCOType));
        cmd.Parameters.AddWithValue("@PayerState", DbValue(d.PayerState));
        cmd.Parameters.AddWithValue("@IsActive", DbValue(d.IsActive));
        cmd.Parameters.AddWithValue("@BenefitAdminCode", DbValue(d.BenefitAdminCode));
        cmd.Parameters.AddWithValue("@BenefitAdministrator", DbValue(d.BenefitAdministrator));
        cmd.Parameters.AddWithValue("@Remarks", DbValue(d.Remarks));
        cmd.Parameters.AddWithValue("@LabName", DbValue(d.LabName));
        cmd.Parameters.AddWithValue("@LabId", DbValue(d.LabId));
        cmd.Parameters.AddWithValue("@LabState", DbValue(d.LabState));
        cmd.Parameters.AddWithValue("@LabStateCode", DbValue(d.LabStateCode));
    }

    private static void AddPolicyParams(SqlCommand cmd, PayerPolicyInsuranceMasterDto d)
    {
        // GlobalPayerId column is nvarchar(50); store the numeric value as its string form.
        cmd.Parameters.AddWithValue("@GlobalPayerId", d.GlobalPayerId.HasValue
            ? d.GlobalPayerId.Value.ToString(CultureInfo.InvariantCulture)
            : DBNull.Value);
        cmd.Parameters.AddWithValue("@GlobalPayerCode", d.GlobalPayerCode?.Trim() ?? string.Empty);
        cmd.Parameters.AddWithValue("@PayerGroupCode", DbValue(d.PayerGroupCode));
        cmd.Parameters.AddWithValue("@BenefitAdminCode", DbValue(d.BenefitAdminCode));
        cmd.Parameters.AddWithValue("@BenefitAdministrator", DbValue(d.BenefitAdministrator));
        cmd.Parameters.AddWithValue("@PayerNameRaw", d.PayerNameRaw.Trim());
        cmd.Parameters.AddWithValue("@PayerNameNormalized", DbValue(d.PayerNameNormalized));
        cmd.Parameters.AddWithValue("@PayerShortCode", DbValue(d.PayerShortCode));
        cmd.Parameters.AddWithValue("@PlanType", DbValue(d.PlanType));
        cmd.Parameters.AddWithValue("@PayerState", DbValue(d.PayerState));
        cmd.Parameters.AddWithValue("@IsActive", DbValue(d.IsActive));
        cmd.Parameters.AddWithValue("@Remarks", DbValue(d.Remarks));
        cmd.Parameters.AddWithValue("@PayerFamily", DbValue(d.PayerFamily));
        cmd.Parameters.AddWithValue("@PayerFamilySource", DbValue(d.PayerFamilySource));
    }

    private static void Trim(InsurancePayerMasterDto d)
    {
        d.PayerCode = d.PayerCode?.Trim(); d.PayerNameRaw = d.PayerNameRaw.Trim(); d.PayerNameNormalized = d.PayerNameNormalized?.Trim(); d.PayerGroupCode = d.PayerGroupCode?.Trim(); d.PayerCommonCode = d.PayerCommonCode?.Trim(); d.Parent = d.Parent?.Trim(); d.PlanType = d.PlanType?.Trim(); d.MCOType = d.MCOType?.Trim(); d.PayerState = d.PayerState?.Trim(); d.IsActive = d.IsActive?.Trim(); d.BenefitAdminCode = d.BenefitAdminCode?.Trim(); d.BenefitAdministrator = d.BenefitAdministrator?.Trim(); d.Remarks = d.Remarks?.Trim(); d.LabName = d.LabName?.Trim(); d.LabState = d.LabState?.Trim(); d.LabStateCode = d.LabStateCode?.Trim();
    }

    private static void Trim(PayerPolicyInsuranceMasterDto d)
    {
        d.GlobalPayerCode = d.GlobalPayerCode?.Trim() ?? string.Empty; d.PayerNameRaw = d.PayerNameRaw.Trim(); d.PayerNameNormalized = d.PayerNameNormalized?.Trim(); d.PayerShortCode = d.PayerShortCode?.Trim(); d.BenefitAdminCode = d.BenefitAdminCode?.Trim(); d.BenefitAdministrator = d.BenefitAdministrator?.Trim(); d.PlanType = d.PlanType?.Trim(); d.PayerState = d.PayerState?.Trim(); d.IsActive = d.IsActive?.Trim(); d.Remarks = d.Remarks?.Trim(); d.PayerFamily = d.PayerFamily?.Trim(); d.PayerFamilySource = d.PayerFamilySource?.Trim();
    }

    private static int? ParseInt(string? value)
        => int.TryParse(value?.Trim(), out var i) ? i : null;
}
