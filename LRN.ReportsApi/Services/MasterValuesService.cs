using System.Data;
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
    Task<byte[]> ExportInsurancePayersAsync(InsurancePayerMasterQuery query, CancellationToken ct);

    Task<PagedResult<PayerPolicyInsuranceMasterDto>> GetPolicyPayersAsync(PayerPolicyInsuranceMasterQuery query, CancellationToken ct);
    Task<IReadOnlyList<PayerPolicyInsuranceMasterDto>> GetPolicyPayersForExportAsync(PayerPolicyInsuranceMasterQuery query, CancellationToken ct);
    Task<PayerPolicyInsuranceMasterDto?> GetPolicyPayerAsync(int id, CancellationToken ct);
    Task<int> CreatePolicyPayerAsync(PayerPolicyInsuranceMasterDto dto, string? userName, CancellationToken ct);
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
        query.PageSize = Math.Clamp(query.PageSize <= 0 ? 25 : query.PageSize, 10, 200);
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
                   BenefitAdminCode, BenefitAdministrator, Remarks, LabName, LabId, LabState, LabStateCode
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
                   BenefitAdminCode, BenefitAdministrator, Remarks, LabName, LabId, LabState, LabStateCode
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
                 LabId, LabState, LabStateCode, CreatedBy)
            OUTPUT INSERTED.LabInsuranceMasterId
            VALUES
                (@PayerCode, @PayerNameRaw, @PayerNameNormalized, @GlobalPayerID, @PayerGroupCode, @PayerCommonCode, @Parent,
                 @PlanType, @MCOType, @PayerState, @IsActive, @BenefitAdminCode, @BenefitAdministrator, @Remarks, @LabName,
                 @LabId, @LabState, @LabStateCode, @CreatedBy);
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
            SET PayerNameNormalized=@PayerNameNormalized, GlobalPayerID=@GlobalPayerID, PayerGroupCode=@PayerGroupCode,
                PayerCommonCode=@PayerCommonCode, Parent=@Parent, PlanType=@PlanType, MCOType=@MCOType, PayerState=@PayerState,
                IsActive=@IsActive, BenefitAdminCode=@BenefitAdminCode, BenefitAdministrator=@BenefitAdministrator, Remarks=@Remarks,
                LabName=@LabName, LabId=@LabId, LabState=@LabState, LabStateCode=@LabStateCode, ModifiedBy=@ModifiedBy,
                ModifiedOn=SYSUTCDATETIME()
            WHERE LabInsuranceMasterId=@Id;
            """, conn);
        AddInsuranceParams(cmd, dto);
        cmd.Parameters.AddWithValue("@Id", id);
        cmd.Parameters.AddWithValue("@ModifiedBy", DbValue(userName));
        return await cmd.ExecuteNonQueryAsync(ct) > 0;
    }

    public Task<bool> UpdateInsurancePayerStatusAsync(int id, string? isActive, string? userName, CancellationToken ct)
        => UpdateStatusAsync("dbo.LabInsuranceMaster", "LabInsuranceMasterId", id, isActive, userName, ct);

    public async Task<ImportResultDto> ImportInsurancePayersAsync(Stream stream, string? userName, CancellationToken ct)
    {
        using var workbook = new XLWorkbook(stream);
        if (!workbook.Worksheets.TryGetWorksheet("Lab_Ins_Master", out var ws))
            return new ImportResultDto { ErrorRows = 1, Errors = { "Sheet Lab_Ins_Master was not found." } };
        var header = HeaderMap(ws, allowDuplicateNames: false);
        var required = new[] { "Payer_Code", "Payer_Name_Raw", "Payer_Name_Normalized", "Global_Payer_ID", "Payer_Group_Code", "Payer_Common_Code", "Parent", "Plan_Type", "MCO_Type", "Payer_State", "Is_Active", "Benefit Admin Code", "Benefit Administrator", "Remarks", "Lab Name", "Lab State", "Lab State Code" };
        var missing = required.Where(x => !header.ContainsKey(x)).ToList();
        if (missing.Count > 0) return new ImportResultDto { ErrorRows = missing.Count, Errors = { "Missing required columns: " + string.Join(", ", missing) } };

        var result = new ImportResultDto();
        var lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
        await using var conn = Open();
        await conn.OpenAsync(ct);
        var labs = await LabsByNameAsync(conn, ct);
        for (var row = 2; row <= lastRow; row++)
        {
            result.TotalRows++;
            var dto = new InsurancePayerMasterDto
            {
                PayerCode = Cell(ws, row, header["Payer_Code"]),
                PayerNameRaw = Cell(ws, row, header["Payer_Name_Raw"]) ?? string.Empty,
                PayerNameNormalized = Cell(ws, row, header["Payer_Name_Normalized"]),
                GlobalPayerID = IntCell(ws, row, header["Global_Payer_ID"], result, row),
                PayerGroupCode = Cell(ws, row, header["Payer_Group_Code"]),
                PayerCommonCode = Cell(ws, row, header["Payer_Common_Code"]),
                Parent = Cell(ws, row, header["Parent"]),
                PlanType = Cell(ws, row, header["Plan_Type"]),
                MCOType = Cell(ws, row, header["MCO_Type"]),
                PayerState = Cell(ws, row, header["Payer_State"]),
                IsActive = Cell(ws, row, header["Is_Active"]),
                BenefitAdminCode = Cell(ws, row, header["Benefit Admin Code"]),
                BenefitAdministrator = Cell(ws, row, header["Benefit Administrator"]),
                Remarks = Cell(ws, row, header["Remarks"]),
                LabName = Cell(ws, row, header["Lab Name"]),
                LabState = Cell(ws, row, header["Lab State"]),
                LabStateCode = Cell(ws, row, header["Lab State Code"])
            };
            if (string.IsNullOrWhiteSpace(dto.PayerNameRaw))
            {
                result.SkippedRows++;
                result.Errors.Add($"Row {row}: Payer_Name_Raw is required.");
                continue;
            }
            if (!string.IsNullOrWhiteSpace(dto.LabName) && labs.TryGetValue(Norm(dto.LabName), out var lab)) dto.LabId = lab.LabId;
            else if (!string.IsNullOrWhiteSpace(dto.LabName)) result.Warnings.Add($"Row {row}: Lab Name '{dto.LabName}' was not found; LabId left blank.");

            var existingId = await FindInsuranceImportMatchAsync(conn, dto, ct);
            if (existingId.HasValue)
            {
                await UpdateInsurancePayerAsync(existingId.Value, dto, userName, ct);
                result.UpdatedRows++;
            }
            else
            {
                await CreateInsurancePayerAsync(dto, userName, ct);
                result.InsertedRows++;
            }
        }
        result.ErrorRows = result.Errors.Count;
        return result;
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
        query.PageSize = Math.Clamp(query.PageSize <= 0 ? 25 : query.PageSize, 10, 200);
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
            SELECT PayerPolicyInsuranceMasterId, PayerCode, PayerName, PayerNameNormalized, GlobalPayerID,
                   PayerGroupCode, PayerCommonCode, PlanType, PayerState, IsActive, BenefitAdminCode,
                   BenefitAdministrator, Remarks, IsMCO
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
            SELECT PayerPolicyInsuranceMasterId, PayerCode, PayerName, PayerNameNormalized, GlobalPayerID,
                   PayerGroupCode, PayerCommonCode, PlanType, PayerState, IsActive, BenefitAdminCode,
                   BenefitAdministrator, Remarks, IsMCO
            FROM dbo.PayerPolicyInsuranceMaster WHERE PayerPolicyInsuranceMasterId = @Id;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? MapPolicy(reader) : null;
    }

    public async Task<int> CreatePolicyPayerAsync(PayerPolicyInsuranceMasterDto dto, string? userName, CancellationToken ct)
    {
        Trim(dto);
        if (string.IsNullOrWhiteSpace(dto.PayerName)) throw new ArgumentException("PayerName is required.");
        await using var conn = Open();
        await conn.OpenAsync(ct);
        if (await PolicyNormalizedGlobalExistsAsync(conn, dto.PayerNameNormalized, dto.GlobalPayerID, null, ct))
            throw new ArgumentException("Payer Name Normalized and Global Payer ID combination already exists.");
        await using var cmd = new SqlCommand("""
            INSERT INTO dbo.PayerPolicyInsuranceMaster
                (PayerCode, PayerName, PayerNameNormalized, GlobalPayerID, PayerGroupCode, PayerCommonCode,
                 PlanType, PayerState, IsActive, BenefitAdminCode, BenefitAdministrator, Remarks, IsMCO, CreatedBy)
            OUTPUT INSERTED.PayerPolicyInsuranceMasterId
            VALUES
                (@PayerCode, @PayerName, @PayerNameNormalized, @GlobalPayerID, @PayerGroupCode, @PayerCommonCode,
                 @PlanType, @PayerState, @IsActive, @BenefitAdminCode, @BenefitAdministrator, @Remarks, @IsMCO, @CreatedBy);
            """, conn);
        AddPolicyParams(cmd, dto);
        cmd.Parameters.AddWithValue("@CreatedBy", DbValue(userName));
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
    }

    public async Task<bool> UpdatePolicyPayerAsync(int id, PayerPolicyInsuranceMasterDto dto, string? userName, CancellationToken ct)
    {
        Trim(dto);
        if (string.IsNullOrWhiteSpace(dto.PayerName)) throw new ArgumentException("PayerName is required.");
        await using var conn = Open();
        await conn.OpenAsync(ct);
        if (await PolicyNormalizedGlobalExistsAsync(conn, dto.PayerNameNormalized, dto.GlobalPayerID, id, ct))
            throw new ArgumentException("Payer Name Normalized and Global Payer ID combination already exists.");
        await using var cmd = new SqlCommand("""
            UPDATE dbo.PayerPolicyInsuranceMaster
            SET PayerCode=@PayerCode, PayerName=@PayerName, PayerNameNormalized=@PayerNameNormalized, GlobalPayerID=@GlobalPayerID,
                PayerGroupCode=@PayerGroupCode, PayerCommonCode=@PayerCommonCode, PlanType=@PlanType, PayerState=@PayerState,
                IsActive=@IsActive, BenefitAdminCode=@BenefitAdminCode, BenefitAdministrator=@BenefitAdministrator, Remarks=@Remarks,
                IsMCO=@IsMCO, ModifiedBy=@ModifiedBy, ModifiedOn=SYSUTCDATETIME()
            WHERE PayerPolicyInsuranceMasterId=@Id;
            """, conn);
        AddPolicyParams(cmd, dto);
        cmd.Parameters.AddWithValue("@Id", id);
        cmd.Parameters.AddWithValue("@ModifiedBy", DbValue(userName));
        return await cmd.ExecuteNonQueryAsync(ct) > 0;
    }

    public Task<bool> UpdatePolicyPayerStatusAsync(int id, string? isActive, string? userName, CancellationToken ct)
        => UpdateStatusAsync("dbo.PayerPolicyInsuranceMaster", "PayerPolicyInsuranceMasterId", id, isActive, userName, ct);

    public async Task<ImportResultDto> ImportPolicyPayersAsync(Stream stream, string? userName, CancellationToken ct)
    {
        using var workbook = new XLWorkbook(stream);
        if (!workbook.Worksheets.TryGetWorksheet("PP_Ins.Master", out var ws))
            return new ImportResultDto { ErrorRows = 1, Errors = { "Sheet PP_Ins.Master was not found." } };
        var header = HeaderMap(ws, allowDuplicateNames: true);
        var required = new[] { "Payer_Code", "Payer Name", "Payer_Name_Normalized", "Global_Payer_ID", "Payer_Group_Code", "Payer_Common_Code", "Plan_Type", "Payer_State", "Is_Active", "Benefit Admin Code", "Benefit Administrator", "Remarks", "Is_MCO" };
        var missing = required.Where(x => !header.ContainsKey(x)).ToList();
        if (missing.Count > 0) return new ImportResultDto { ErrorRows = missing.Count, Errors = { "Missing required columns: " + string.Join(", ", missing) } };
        var result = new ImportResultDto();
        var lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
        for (var row = 2; row <= lastRow; row++)
        {
            result.TotalRows++;
            var dto = new PayerPolicyInsuranceMasterDto
            {
                PayerCode = Cell(ws, row, header["Payer_Code"]),
                PayerName = Cell(ws, row, header["Payer Name"]) ?? string.Empty,
                PayerNameNormalized = Cell(ws, row, header["Payer_Name_Normalized"]),
                GlobalPayerID = IntCell(ws, row, header["Global_Payer_ID"], result, row),
                PayerGroupCode = Cell(ws, row, header["Payer_Group_Code"]),
                PayerCommonCode = Cell(ws, row, header["Payer_Common_Code"]),
                PlanType = Cell(ws, row, header["Plan_Type"]),
                PayerState = Cell(ws, row, header["Payer_State"]),
                IsActive = Cell(ws, row, header["Is_Active"]),
                BenefitAdminCode = Cell(ws, row, header["Benefit Admin Code"]),
                BenefitAdministrator = Cell(ws, row, header["Benefit Administrator"]),
                Remarks = Cell(ws, row, header["Remarks"]),
                IsMCO = Cell(ws, row, header["Is_MCO"])
            };
            if (string.IsNullOrWhiteSpace(dto.PayerName))
            {
                result.SkippedRows++;
                result.Errors.Add($"Row {row}: Payer Name is required.");
                continue;
            }
            await using var conn = Open();
            await conn.OpenAsync(ct);
            var existingId = await FindPolicyImportMatchAsync(conn, dto, ct);
            if (existingId.HasValue)
            {
                await UpdatePolicyPayerAsync(existingId.Value, dto, userName, ct);
                result.UpdatedRows++;
            }
            else
            {
                await CreatePolicyPayerAsync(dto, userName, ct);
                result.InsertedRows++;
            }
        }
        result.ErrorRows = result.Errors.Count;
        return result;
    }

    public async Task<byte[]> ExportPolicyPayersAsync(PayerPolicyInsuranceMasterQuery query, CancellationToken ct)
    {
        var rows = await GetPolicyPayersForExportAsync(query, ct);
        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add("PP_Ins.Master");
        var headers = new[] { "S.No", "Payer_Code", "Payer Name", "Payer_Name_Normalized", "Global_Payer_ID", "Payer_Group_Code", "Payer_Common_Code", "Plan_Type", "Payer_State", "Is_Active", "Benefit Admin Code", "Benefit Administrator", "Remarks", "Is_MCO" };
        WriteHeaders(ws, headers);
        for (var i = 0; i < rows.Count; i++)
        {
            var r = rows[i]; var row = i + 2;
            ws.Cell(row, 1).Value = i + 1; ws.Cell(row, 2).Value = r.PayerCode; ws.Cell(row, 3).Value = r.PayerName; ws.Cell(row, 4).Value = r.PayerNameNormalized; ws.Cell(row, 5).Value = r.GlobalPayerID; ws.Cell(row, 6).Value = r.PayerGroupCode; ws.Cell(row, 7).Value = r.PayerCommonCode; ws.Cell(row, 8).Value = r.PlanType; ws.Cell(row, 9).Value = r.PayerState; ws.Cell(row, 10).Value = r.IsActive; ws.Cell(row, 11).Value = r.BenefitAdminCode; ws.Cell(row, 12).Value = r.BenefitAdministrator; ws.Cell(row, 13).Value = r.Remarks; ws.Cell(row, 14).Value = r.IsMCO;
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

    private async Task<int?> FindPolicyImportMatchAsync(SqlConnection conn, PayerPolicyInsuranceMasterDto dto, CancellationToken ct)
    {
        var normalizedMatch = await FindPolicyByNormalizedGlobalAsync(conn, dto.PayerNameNormalized, dto.GlobalPayerID, ct);
        if (normalizedMatch.HasValue) return normalizedMatch;

        if (!string.IsNullOrWhiteSpace(dto.PayerCode))
        {
            await using var cmd = new SqlCommand("SELECT TOP (1) PayerPolicyInsuranceMasterId FROM dbo.PayerPolicyInsuranceMaster WHERE PayerCode=@PayerCode;", conn);
            cmd.Parameters.AddWithValue("@PayerCode", dto.PayerCode);
            var id = await cmd.ExecuteScalarAsync(ct);
            if (id != null) return Convert.ToInt32(id);
        }
        if (!string.IsNullOrWhiteSpace(dto.PayerName) && dto.GlobalPayerID.HasValue)
        {
            await using var cmd = new SqlCommand("SELECT TOP (1) PayerPolicyInsuranceMasterId FROM dbo.PayerPolicyInsuranceMaster WHERE PayerName=@PayerName AND GlobalPayerID=@GlobalPayerID;", conn);
            cmd.Parameters.AddWithValue("@PayerName", dto.PayerName);
            cmd.Parameters.AddWithValue("@GlobalPayerID", dto.GlobalPayerID.Value);
            var id = await cmd.ExecuteScalarAsync(ct);
            if (id != null) return Convert.ToInt32(id);
        }
        return null;
    }

    private static async Task<bool> InsuranceNormalizedGlobalExistsAsync(SqlConnection conn, string? payerNameNormalized, int? globalPayerId, int? excludeId, CancellationToken ct)
        => await FindInsuranceByNormalizedGlobalAsync(conn, payerNameNormalized, globalPayerId, ct) is int existingId
           && (!excludeId.HasValue || existingId != excludeId.Value);

    private static async Task<bool> PolicyNormalizedGlobalExistsAsync(SqlConnection conn, string? payerNameNormalized, int? globalPayerId, int? excludeId, CancellationToken ct)
        => await FindPolicyByNormalizedGlobalAsync(conn, payerNameNormalized, globalPayerId, ct) is int existingId
           && (!excludeId.HasValue || existingId != excludeId.Value);

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

    private static async Task<int?> FindPolicyByNormalizedGlobalAsync(SqlConnection conn, string? payerNameNormalized, int? globalPayerId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(payerNameNormalized) || !globalPayerId.HasValue) return null;
        await using var cmd = new SqlCommand("""
            SELECT TOP (1) PayerPolicyInsuranceMasterId
            FROM dbo.PayerPolicyInsuranceMaster
            WHERE PayerNameNormalized = @PayerNameNormalized
              AND GlobalPayerID = @GlobalPayerID;
            """, conn);
        cmd.Parameters.AddWithValue("@PayerNameNormalized", payerNameNormalized.Trim());
        cmd.Parameters.AddWithValue("@GlobalPayerID", globalPayerId.Value);
        var id = await cmd.ExecuteScalarAsync(ct);
        return id == null ? null : Convert.ToInt32(id);
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
        AddLike(parts, p, "PayerCode", q.PayerCode);
        AddLike(parts, p, "PayerName", q.PayerName);
        AddEquals(parts, p, "GlobalPayerID", q.GlobalPayerId);
        AddLike(parts, p, "PlanType", q.PlanType);
        AddLike(parts, p, "PayerState", q.PayerState);
        AddLike(parts, p, "IsActive", q.IsActive);
        AddLike(parts, p, "IsMCO", q.IsMCO);
        if (!string.IsNullOrWhiteSpace(q.Search))
        {
            parts.Add("(PayerCode LIKE @Search ESCAPE '\\' OR PayerName LIKE @Search ESCAPE '\\' OR PayerNameNormalized LIKE @Search ESCAPE '\\')");
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
            ["payerCode"] = "PayerCode",
            ["payerName"] = "PayerName",
            ["payerNameNormalized"] = "PayerNameNormalized",
            ["globalPayerID"] = "GlobalPayerID",
            ["payerGroupCode"] = "PayerGroupCode",
            ["payerCommonCode"] = "PayerCommonCode",
            ["planType"] = "PlanType",
            ["payerState"] = "PayerState",
            ["isActive"] = "IsActive",
            ["benefitAdminCode"] = "BenefitAdminCode",
            ["benefitAdministrator"] = "BenefitAdministrator",
            ["isMCO"] = "IsMCO",
            ["remarks"] = "Remarks"
        };
        return BuildOrderBy(q.SortColumn, q.SortDirection, columns, "PayerPolicyInsuranceMasterId DESC");
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

    private static Dictionary<string, int> HeaderMap(IXLWorksheet ws, bool allowDuplicateNames)
    {
        var map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var lastColumn = ws.LastColumnUsed()?.ColumnNumber() ?? 0;
        for (var col = 1; col <= lastColumn; col++)
        {
            var name = ws.Cell(1, col).GetString().Trim();
            if (name.Length == 0) continue;
            if (allowDuplicateNames && map.ContainsKey(name)) continue;
            map[name] = col;
        }
        return map;
    }

    private static string? Cell(IXLWorksheet ws, int row, int col)
    {
        var value = ws.Cell(row, col).GetFormattedString().Trim();
        return string.IsNullOrWhiteSpace(value) ? null : value;
    }

    private static int? IntCell(IXLWorksheet ws, int row, int col, ImportResultDto result, int sourceRow)
    {
        var text = Cell(ws, row, col);
        if (string.IsNullOrWhiteSpace(text)) return null;
        if (int.TryParse(text, out var value)) return value;
        if (decimal.TryParse(text, out var dec)) return (int)dec;
        result.Warnings.Add($"Row {sourceRow}: Global_Payer_ID '{text}' is not an integer and was left blank.");
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
        LabStateCode = Str(r, "LabStateCode")
    };

    private static PayerPolicyInsuranceMasterDto MapPolicy(SqlDataReader r) => new()
    {
        PayerPolicyInsuranceMasterId = r.GetInt32(r.GetOrdinal("PayerPolicyInsuranceMasterId")),
        PayerCode = Str(r, "PayerCode"),
        PayerName = Str(r, "PayerName") ?? string.Empty,
        PayerNameNormalized = Str(r, "PayerNameNormalized"),
        GlobalPayerID = Int(r, "GlobalPayerID"),
        PayerGroupCode = Str(r, "PayerGroupCode"),
        PayerCommonCode = Str(r, "PayerCommonCode"),
        PlanType = Str(r, "PlanType"),
        PayerState = Str(r, "PayerState"),
        IsActive = Str(r, "IsActive"),
        BenefitAdminCode = Str(r, "BenefitAdminCode"),
        BenefitAdministrator = Str(r, "BenefitAdministrator"),
        Remarks = Str(r, "Remarks"),
        IsMCO = Str(r, "IsMCO")
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
        cmd.Parameters.AddWithValue("@PayerCode", DbValue(d.PayerCode));
        cmd.Parameters.AddWithValue("@PayerName", d.PayerName.Trim());
        cmd.Parameters.AddWithValue("@PayerNameNormalized", DbValue(d.PayerNameNormalized));
        cmd.Parameters.AddWithValue("@GlobalPayerID", DbValue(d.GlobalPayerID));
        cmd.Parameters.AddWithValue("@PayerGroupCode", DbValue(d.PayerGroupCode));
        cmd.Parameters.AddWithValue("@PayerCommonCode", DbValue(d.PayerCommonCode));
        cmd.Parameters.AddWithValue("@PlanType", DbValue(d.PlanType));
        cmd.Parameters.AddWithValue("@PayerState", DbValue(d.PayerState));
        cmd.Parameters.AddWithValue("@IsActive", DbValue(d.IsActive));
        cmd.Parameters.AddWithValue("@BenefitAdminCode", DbValue(d.BenefitAdminCode));
        cmd.Parameters.AddWithValue("@BenefitAdministrator", DbValue(d.BenefitAdministrator));
        cmd.Parameters.AddWithValue("@Remarks", DbValue(d.Remarks));
        cmd.Parameters.AddWithValue("@IsMCO", DbValue(d.IsMCO));
    }

    private static void Trim(InsurancePayerMasterDto d)
    {
        d.PayerCode = d.PayerCode?.Trim(); d.PayerNameRaw = d.PayerNameRaw.Trim(); d.PayerNameNormalized = d.PayerNameNormalized?.Trim(); d.PayerGroupCode = d.PayerGroupCode?.Trim(); d.PayerCommonCode = d.PayerCommonCode?.Trim(); d.Parent = d.Parent?.Trim(); d.PlanType = d.PlanType?.Trim(); d.MCOType = d.MCOType?.Trim(); d.PayerState = d.PayerState?.Trim(); d.IsActive = d.IsActive?.Trim(); d.BenefitAdminCode = d.BenefitAdminCode?.Trim(); d.BenefitAdministrator = d.BenefitAdministrator?.Trim(); d.Remarks = d.Remarks?.Trim(); d.LabName = d.LabName?.Trim(); d.LabState = d.LabState?.Trim(); d.LabStateCode = d.LabStateCode?.Trim();
    }

    private static void Trim(PayerPolicyInsuranceMasterDto d)
    {
        d.PayerCode = d.PayerCode?.Trim(); d.PayerName = d.PayerName.Trim(); d.PayerNameNormalized = d.PayerNameNormalized?.Trim(); d.PayerGroupCode = d.PayerGroupCode?.Trim(); d.PayerCommonCode = d.PayerCommonCode?.Trim(); d.PlanType = d.PlanType?.Trim(); d.PayerState = d.PayerState?.Trim(); d.IsActive = d.IsActive?.Trim(); d.BenefitAdminCode = d.BenefitAdminCode?.Trim(); d.BenefitAdministrator = d.BenefitAdministrator?.Trim(); d.Remarks = d.Remarks?.Trim(); d.IsMCO = d.IsMCO?.Trim();
    }
}
