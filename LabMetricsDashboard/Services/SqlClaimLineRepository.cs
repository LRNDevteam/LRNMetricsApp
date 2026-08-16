using System.Data;
using System.Globalization;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads paginated Claim Level and Line Level detail rows from
/// <c>dbo.ClaimLevelData</c> and <c>dbo.LineLevelData</c> via
/// <c>usp_GetClaimLevel*</c> / <c>usp_GetLineLevel*</c>
/// (common: Sql/ClaimLineDetails_SPs.sql; lab SELECT lists: Sql/ClaimLineDetails_SPs/{Lab}_Details.sql).
/// </summary>
public sealed class SqlClaimLineRepository : IClaimLineRepository
{
    private readonly ILogger<SqlClaimLineRepository> _logger;

    public SqlClaimLineRepository(ILogger<SqlClaimLineRepository> logger)
        => _logger = logger;

    // ?? Claim Level ??????????????????????????????????????????????????????

    public async Task<ClaimLevelResult> GetClaimLevelAsync(
        string connectionString,
        string labName,
        string? filterPayerName = null,
        List<string>? filterPayerTypes = null,
        List<string>? filterClaimStatuses = null,
        List<string>? filterClinicNames = null,
        string? filterDenialCode = null,
        bool filterDenialCodeExcludeBlank = false,
        List<string>? filterPayerNames = null,
        bool filterPayerExcludeBlank = false,
        List<string>? filterPanelNames = null,
        bool filterPanelExcludeBlank = false,
        List<string>? filterAgingBuckets = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        bool filterFirstBillNull = false,
        bool filterFirstBillExcludeBlank = false,
        DateOnly? filterChargeEnteredFrom = null,
        DateOnly? filterChargeEnteredTo = null,
        bool filterChargeEnteredNull = false,
        bool filterChargeEnteredExcludeBlank = false,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        bool filterDosNull = false,
        int page = 1,
        int pageSize = 50,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        int offset = (Math.Max(1, page) - 1) * pageSize;
        var filterParams = BuildClaimLevelSpParameters(
            filterPayerName, filterPayerTypes, filterClaimStatuses, filterClinicNames,
            filterDenialCode, filterDenialCodeExcludeBlank,
            filterPayerNames, filterPayerExcludeBlank,
            filterPanelNames, filterPanelExcludeBlank,
            filterAgingBuckets,
            filterFirstBillFrom, filterFirstBillTo, filterFirstBillNull, filterFirstBillExcludeBlank,
            filterChargeEnteredFrom, filterChargeEnteredTo, filterChargeEnteredNull, filterChargeEnteredExcludeBlank,
            filterDosFrom, filterDosTo, filterDosNull);

        var payerTypes = new List<string>();
        var claimStatuses = new List<string>();
        var clinicNames = new List<string>();
        var payerNames = new List<string>();
        var panelNames = new List<string>();
        var agingBuckets = new List<string>();
        int totalAll = 0, totalFiltered = 0;
        var records = new List<ClaimRecord>();
        IReadOnlyList<string> displayColumns = [];

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        try
        {
            await using var cmd = NewProc(conn, "dbo.usp_GetClaimLevelFilterOptions");
            await using var r = await cmd.ExecuteReaderAsync(ct);
            await ReadStringColumnAsync(r, payerTypes, ct);
            if (await r.NextResultAsync(ct)) await ReadStringColumnAsync(r, claimStatuses, ct);
            if (await r.NextResultAsync(ct)) await ReadStringColumnAsync(r, clinicNames, ct);
            if (await r.NextResultAsync(ct)) await ReadStringColumnAsync(r, payerNames, ct);
            if (await r.NextResultAsync(ct)) await ReadStringColumnAsync(r, panelNames, ct);
            if (await r.NextResultAsync(ct)) await ReadStringColumnAsync(r, agingBuckets, ct);
        }
        catch (SqlException ex)
        {
            _logger.LogWarning(ex, "Claim Level filter-options SP failed for lab {Lab}", labName);
        }

        try
        {
            await using var cmd = NewProc(conn, "dbo.usp_GetClaimLevelDetailsCounts");
            cmd.Parameters.AddRange(CloneParams(filterParams));
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
            {
                totalFiltered = Convert.ToInt32(r.GetValue(0));
                totalAll = r.FieldCount > 1 ? Convert.ToInt32(r.GetValue(1)) : totalFiltered;
            }
        }
        catch (SqlException ex)
        {
            _logger.LogWarning(ex, "Claim Level counts SP failed for lab {Lab}", labName);
        }

        await using (var cmd = NewProc(conn, "dbo.usp_GetClaimLevelDetails"))
        {
            cmd.Parameters.AddRange(CloneParams(filterParams));
            cmd.Parameters.Add(IntParam("@Offset", offset));
            cmd.Parameters.Add(IntParam("@PageSize", pageSize));

            await using var r = await cmd.ExecuteReaderAsync(ct);
            displayColumns = ReadColumnNames(r);
            while (await r.ReadAsync(ct))
                records.Add(ReadClaimRecord(r, labName));
        }

        _logger.LogInformation(
            "ClaimLevel: lab={Lab}, filtered={Filtered}/{All}, page={Page}",
            labName, totalFiltered, totalAll, page);

        return new ClaimLevelResult(payerTypes, claimStatuses, clinicNames,
            payerNames, panelNames, agingBuckets,
            records, totalFiltered, totalAll, displayColumns);
    }

    /// <summary>
    /// Excel export: Select_Script columns for this lab (via
    /// <see cref="LabClaimLineColumnCatalog"/>) plus the same filter parameters
    /// as the Claim Level page. Counts still use the shared SP.
    /// </summary>
    public (string DataSql, string CountSql, List<SqlParameter> Parameters) BuildClaimLevelDetailsExportQuery(
        string labName,
        string? filterPayerName, List<string>? filterPayerTypes, List<string>? filterClaimStatuses,
        List<string>? filterClinicNames, string? filterDenialCode, bool filterDenialCodeExcludeBlank,
        List<string>? filterPayerNames, bool filterPayerExcludeBlank,
        List<string>? filterPanelNames, bool filterPanelExcludeBlank,
        List<string>? filterAgingBuckets,
        DateOnly? filterFirstBillFrom, DateOnly? filterFirstBillTo, bool filterFirstBillNull, bool filterFirstBillExcludeBlank,
        DateOnly? filterChargeEnteredFrom, DateOnly? filterChargeEnteredTo, bool filterChargeEnteredNull, bool filterChargeEnteredExcludeBlank,
        DateOnly? filterDosFrom, DateOnly? filterDosTo, bool filterDosNull)
    {
        var parameters = BuildClaimLevelSpParameters(
            filterPayerName, filterPayerTypes, filterClaimStatuses, filterClinicNames,
            filterDenialCode, filterDenialCodeExcludeBlank,
            filterPayerNames, filterPayerExcludeBlank,
            filterPanelNames, filterPanelExcludeBlank,
            filterAgingBuckets,
            filterFirstBillFrom, filterFirstBillTo, filterFirstBillNull, filterFirstBillExcludeBlank,
            filterChargeEnteredFrom, filterChargeEnteredTo, filterChargeEnteredNull, filterChargeEnteredExcludeBlank,
            filterDosFrom, filterDosTo, filterDosNull);
        parameters.Add(IntParam("@Offset", 0));
        parameters.Add(IntParam("@PageSize", null));
        var selectList = LabClaimLineColumnCatalog.GetExportSelectList(labName, isLineLevel: false);
        var dataSql = $"""
            SELECT {selectList}
            FROM dbo.ClaimLevelData
            {ClaimLevelWhereSql}
            ORDER BY ClaimID
            OFFSET ISNULL(@Offset, 0) ROWS
            FETCH NEXT ISNULL(@PageSize, 2147483647) ROWS ONLY
            """;
        return (dataSql, "dbo.usp_GetClaimLevelDetailsCounts", parameters);
    }

    /// <summary>
    /// Excel export: Select_Script columns for this lab (via
    /// <see cref="LabClaimLineColumnCatalog"/>) plus the same filter parameters
    /// as the Line Level page. Counts still use the shared SP.
    /// </summary>
    public (string DataSql, string CountSql, List<SqlParameter> Parameters) BuildLineLevelDetailsExportQuery(
        string labName,
        string? filterPayerName = null,
        List<string>? filterPayerTypes = null,
        List<string>? filterClaimStatuses = null,
        List<string>? filterPayStatuses = null,
        List<string>? filterCPTCodes = null,
        List<string>? filterClinicNames = null,
        string? filterDenialCode = null)
    {
        var parameters = BuildLineLevelSpParameters(
            filterPayerName, filterPayerTypes, filterClaimStatuses, filterPayStatuses,
            filterCPTCodes, filterClinicNames, filterDenialCode);
        parameters.Add(IntParam("@Offset", 0));
        parameters.Add(IntParam("@PageSize", null));
        var selectList = LabClaimLineColumnCatalog.GetExportSelectList(labName, isLineLevel: true);
        var dataSql = $"""
            SELECT {selectList}
            FROM dbo.LineLevelData
            {LineLevelWhereSql}
            ORDER BY ClaimID, CPTCode
            OFFSET ISNULL(@Offset, 0) ROWS
            FETCH NEXT ISNULL(@PageSize, 2147483647) ROWS ONLY
            """;
        return (dataSql, "dbo.usp_GetLineLevelDetailsCounts", parameters);
    }

    // ── Line Level ───────────────────────────────────────────────────────

    public async Task<LineLevelResult> GetLineLevelAsync(
        string connectionString,
        string labName,
        string? filterPayerName = null,
        List<string>? filterPayerTypes = null,
        List<string>? filterClaimStatuses = null,
        List<string>? filterPayStatuses = null,
        List<string>? filterCPTCodes = null,
        List<string>? filterClinicNames = null,
        string? filterDenialCode = null,
        int page = 1,
        int pageSize = 50,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        int offset = (Math.Max(1, page) - 1) * pageSize;
        var filterParams = BuildLineLevelSpParameters(
            filterPayerName, filterPayerTypes, filterClaimStatuses, filterPayStatuses,
            filterCPTCodes, filterClinicNames, filterDenialCode);

        var payerTypes = new List<string>();
        var claimStatuses = new List<string>();
        var payStatuses = new List<string>();
        var clinicNames = new List<string>();
        var cptCodes = new List<string>();
        int totalAll = 0, totalFiltered = 0;
        var records = new List<LineRecord>();
        IReadOnlyList<string> displayColumns = [];

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        try
        {
            await using var cmd = NewProc(conn, "dbo.usp_GetLineLevelFilterOptions");
            await using var r = await cmd.ExecuteReaderAsync(ct);
            await ReadStringColumnAsync(r, payerTypes, ct);
            if (await r.NextResultAsync(ct)) await ReadStringColumnAsync(r, claimStatuses, ct);
            if (await r.NextResultAsync(ct)) await ReadStringColumnAsync(r, payStatuses, ct);
            if (await r.NextResultAsync(ct)) await ReadStringColumnAsync(r, clinicNames, ct);
            if (await r.NextResultAsync(ct)) await ReadStringColumnAsync(r, cptCodes, ct);
        }
        catch (SqlException ex)
        {
            _logger.LogWarning(ex, "Line Level filter-options SP failed for lab {Lab}", labName);
        }

        try
        {
            await using var cmd = NewProc(conn, "dbo.usp_GetLineLevelDetailsCounts");
            cmd.Parameters.AddRange(CloneParams(filterParams));
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
            {
                totalFiltered = Convert.ToInt32(r.GetValue(0));
                totalAll = r.FieldCount > 1 ? Convert.ToInt32(r.GetValue(1)) : totalFiltered;
            }
        }
        catch (SqlException ex)
        {
            _logger.LogWarning(ex, "Line Level counts SP failed for lab {Lab}", labName);
        }

        await using (var cmd = NewProc(conn, "dbo.usp_GetLineLevelDetails"))
        {
            cmd.Parameters.AddRange(CloneParams(filterParams));
            cmd.Parameters.Add(IntParam("@Offset", offset));
            cmd.Parameters.Add(IntParam("@PageSize", pageSize));

            await using var r = await cmd.ExecuteReaderAsync(ct);
            displayColumns = ReadColumnNames(r);
            while (await r.ReadAsync(ct))
                records.Add(ReadLineRecord(r, labName));
        }

        _logger.LogInformation(
            "LineLevel: lab={Lab}, filtered={Filtered}/{All}, page={Page}",
            labName, totalFiltered, totalAll, page);

        return new LineLevelResult(payerTypes, claimStatuses, payStatuses, clinicNames,
            cptCodes, records, totalFiltered, totalAll, displayColumns);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private static async Task ReadStringColumnAsync(
        SqlDataReader r, List<string> target, CancellationToken ct)
    {
        while (await r.ReadAsync(ct))
        {
            if (r.IsDBNull(0)) continue;
            var value = Convert.ToString(r.GetValue(0), CultureInfo.InvariantCulture)?.Trim();
            if (!string.IsNullOrEmpty(value))
                target.Add(value);
        }
    }

    private static IReadOnlyList<string> ReadColumnNames(SqlDataReader r)
    {
        var names = new List<string>(r.FieldCount);
        for (var i = 0; i < r.FieldCount; i++)
        {
            var name = r.GetName(i);
            if (name.StartsWith("__", StringComparison.Ordinal)) continue;
            names.Add(name);
        }
        return names;
    }

    private static Dictionary<string, string> ReadCells(SqlDataReader r)
    {
        var cells = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < r.FieldCount; i++)
        {
            var name = r.GetName(i);
            if (name.StartsWith("__", StringComparison.Ordinal)) continue;
            cells[name] = FormatDbValue(r.IsDBNull(i) ? null : r.GetValue(i));
        }
        return cells;
    }

    private static string FormatDbValue(object? value)
    {
        if (value is null or DBNull) return string.Empty;
        return value switch
        {
            DateTime dt => dt.TimeOfDay == TimeSpan.Zero
                ? dt.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)
                : dt.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture),
            DateTimeOffset dto => dto.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            decimal d => d.ToString(CultureInfo.InvariantCulture),
            double dbl => dbl.ToString(CultureInfo.InvariantCulture),
            float f => f.ToString(CultureInfo.InvariantCulture),
            bool b => b ? "1" : "0",
            byte[] => string.Empty,
            _ => Convert.ToString(value, CultureInfo.InvariantCulture)?.Trim() ?? string.Empty,
        };
    }

    private static string Cell(Dictionary<string, string> cells, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (cells.TryGetValue(key, out var value))
                return value;
        }
        return string.Empty;
    }

    private static decimal CellDec(Dictionary<string, string> cells, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (cells.TryGetValue(key, out var value)
                && decimal.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var d))
                return d;
        }
        return 0;
    }

    private static ClaimRecord ReadClaimRecord(SqlDataReader r, string labName)
    {
        var cells = ReadCells(r);
        return new ClaimRecord
        {
            LabID = labName,
            LabName = labName,
            Cells = cells,
            ClaimID = Cell(cells, "ClaimID"),
            AccessionNumber = Cell(cells, "AccessionNumber"),
            SourceFileID = Cell(cells, "SourceFileID"),
            IngestedOn = Cell(cells, "IngestedOn"),
            RowHash = Cell(cells, "RowHash"),
            PayerName_Raw = Cell(cells, "PayerName_Raw"),
            PayerName = Cell(cells, "PayerName"),
            Payer_Code = Cell(cells, "Payer_Code"),
            Payer_Common_Code = Cell(cells, "Payer_Common_Code"),
            Payer_Group_Code = Cell(cells, "Payer_Group_Code"),
            Global_Payer_ID = Cell(cells, "Global_Payer_ID"),
            PayerType = Cell(cells, "PayerType"),
            BillingProvider = Cell(cells, "BillingProvider"),
            ReferringProvider = Cell(cells, "ReferringProvider"),
            ClinicName = Cell(cells, "ClinicName"),
            SalesRepName = Cell(cells, "SalesRepName", "SalesRepname"),
            PatientID = Cell(cells, "PatientID"),
            PatientDOB = Cell(cells, "PatientDOB"),
            DateOfService = Cell(cells, "DateOfService", "DateofService"),
            ChargeEnteredDate = Cell(cells, "ChargeEnteredDate"),
            FirstBilledDate = Cell(cells, "FirstBilledDate"),
            PanelName = Cell(cells, "PanelName", "Panelname"),
            CPTCodeUnitsModifier = Cell(cells, "CPTCodeUnitsModifier", "CPTCodeXUnitsXModifier"),
            POS = Cell(cells, "POS"),
            TOS = Cell(cells, "TOS"),
            ChargeAmount = CellDec(cells, "ChargeAmount"),
            AllowedAmount = CellDec(cells, "AllowedAmount"),
            InsurancePayment = CellDec(cells, "InsurancePayment"),
            PatientPayment = CellDec(cells, "PatientPayment"),
            TotalPayments = CellDec(cells, "TotalPayments"),
            InsuranceAdjustments = CellDec(cells, "InsuranceAdjustments"),
            PatientAdjustments = CellDec(cells, "PatientAdjustments"),
            TotalAdjustments = CellDec(cells, "TotalAdjustments"),
            InsuranceBalance = CellDec(cells, "InsuranceBalance"),
            PatientBalance = CellDec(cells, "PatientBalance"),
            TotalBalance = CellDec(cells, "TotalBalance"),
            CheckDate = Cell(cells, "CheckDate"),
            ClaimStatus = Cell(cells, "ClaimStatus"),
            DenialCode = Cell(cells, "DenialCode"),
            ICDCode = Cell(cells, "ICDCode"),
            DaysToDOS = Cell(cells, "DaysToDOS", "DaystoDOS"),
            RollingDays = Cell(cells, "RollingDays"),
            DaysToBill = Cell(cells, "DaysToBill", "DaystoBill"),
            DaysToPost = Cell(cells, "DaysToPost", "DaystoPost"),
            ICDPointer = Cell(cells, "ICDPointer"),
            AgingBucket = Cell(cells, "AgingBucket"),
        };
    }

    private static LineRecord ReadLineRecord(SqlDataReader r, string labName)
    {
        var cells = ReadCells(r);
        return new LineRecord
        {
            LabID = labName,
            LabName = labName,
            Cells = cells,
            ClaimID = Cell(cells, "ClaimID"),
            AccessionNumber = Cell(cells, "AccessionNumber"),
            SourceFileID = Cell(cells, "SourceFileID"),
            IngestedOn = Cell(cells, "IngestedOn"),
            RowHash = Cell(cells, "RowHash"),
            PayerName_Raw = Cell(cells, "PayerName_Raw"),
            PayerName = Cell(cells, "PayerName"),
            Payer_Code = Cell(cells, "Payer_Code"),
            Payer_Common_Code = Cell(cells, "Payer_Common_Code"),
            Payer_Group_Code = Cell(cells, "Payer_Group_Code"),
            Global_Payer_ID = Cell(cells, "Global_Payer_ID"),
            PayerType = Cell(cells, "PayerType"),
            BillingProvider = Cell(cells, "BillingProvider"),
            ReferringProvider = Cell(cells, "ReferringProvider"),
            ClinicName = Cell(cells, "ClinicName"),
            SalesRepName = Cell(cells, "SalesRepName", "SalesRepname"),
            PatientID = Cell(cells, "PatientID"),
            PatientDOB = Cell(cells, "PatientDOB"),
            DateOfService = Cell(cells, "DateOfService", "DateofService"),
            ChargeEnteredDate = Cell(cells, "ChargeEnteredDate"),
            FirstBilledDate = Cell(cells, "FirstBilledDate"),
            PanelName = Cell(cells, "PanelName", "Panelname"),
            CPTCode = Cell(cells, "CPTCode"),
            Units = CellDec(cells, "Units"),
            Modifier = Cell(cells, "Modifier"),
            POS = Cell(cells, "POS"),
            TOS = Cell(cells, "TOS"),
            ChargeAmount = CellDec(cells, "ChargeAmount"),
            ChargeAmountPerUnit = CellDec(cells, "ChargeAmountPerUnit"),
            AllowedAmount = CellDec(cells, "AllowedAmount"),
            AllowedAmountPerUnit = CellDec(cells, "AllowedAmountPerUnit"),
            InsurancePayment = CellDec(cells, "InsurancePayment"),
            InsurancePaymentPerUnit = CellDec(cells, "InsurancePaymentPerUnit"),
            PatientPayment = CellDec(cells, "PatientPayment"),
            PatientPaymentPerUnit = CellDec(cells, "PatientPaymentPerUnit"),
            TotalPayments = CellDec(cells, "TotalPayments"),
            InsuranceAdjustments = CellDec(cells, "InsuranceAdjustments"),
            PatientAdjustments = CellDec(cells, "PatientAdjustments"),
            TotalAdjustments = CellDec(cells, "TotalAdjustments"),
            InsuranceBalance = CellDec(cells, "InsuranceBalance"),
            PatientBalance = CellDec(cells, "PatientBalance"),
            PatientBalancePerUnit = CellDec(cells, "PatientBalancePerUnit"),
            TotalBalance = CellDec(cells, "TotalBalance"),
            CheckDate = Cell(cells, "CheckDate"),
            ClaimStatus = Cell(cells, "ClaimStatus"),
            PayStatus = Cell(cells, "PayStatus"),
            DenialCode = Cell(cells, "DenialCode"),
            ICDCode = Cell(cells, "ICDCode"),
            DaysToDOS = Cell(cells, "DaysToDOS", "DaystoDOS"),
            RollingDays = Cell(cells, "RollingDays"),
            DaysToBill = Cell(cells, "DaysToBill", "DaystoBill"),
            DaysToPost = Cell(cells, "DaysToPost", "DaystoPost"),
            ICDPointer = Cell(cells, "ICDPointer"),
        };
    }

    private static SqlCommand NewProc(SqlConnection conn, string procName)
        => new(procName, conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180,
        };

    private static string? PipeJoin(List<string>? values)
        => values is { Count: > 0 } ? string.Join("|", values.Where(v => !string.IsNullOrWhiteSpace(v))) : null;

    private static SqlParameter NvarcharParam(string name, string? value, int length = -1)
        => new(name, length <= 0 ? SqlDbType.NVarChar : SqlDbType.NVarChar, length <= 0 ? -1 : length)
        {
            Value = string.IsNullOrWhiteSpace(value) ? DBNull.Value : value,
        };

    private static SqlParameter BitParam(string name, bool value)
        => new(name, SqlDbType.Bit) { Value = value };

    private static SqlParameter DateParam(string name, DateOnly? value)
        => new(name, SqlDbType.Date)
        {
            Value = value.HasValue ? value.Value.ToDateTime(TimeOnly.MinValue) : DBNull.Value,
        };

    private static SqlParameter IntParam(string name, int? value)
        => new(name, SqlDbType.Int) { Value = value.HasValue ? value.Value : DBNull.Value };

    /// <summary>Same predicates as dbo.usp_GetClaimLevelDetails, using the export @params directly.</summary>
    private const string ClaimLevelWhereSql = """
        WHERE (@PayerName IS NULL OR LTRIM(RTRIM(@PayerName)) = N''
               OR EXISTS (SELECT 1 FROM STRING_SPLIT(@PayerName, ',') p
                          WHERE NULLIF(LTRIM(RTRIM(p.value)), '') IS NOT NULL
                            AND LTRIM(RTRIM(ClaimLevelData.PayerName)) LIKE N'%' + LTRIM(RTRIM(p.value)) + N'%'))
          AND (@PayerTypes IS NULL OR LTRIM(RTRIM(@PayerTypes)) = N''
               OR LTRIM(RTRIM(PayerType)) IN (SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500) FROM STRING_SPLIT(@PayerTypes, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL))
          AND (@ClaimStatuses IS NULL OR LTRIM(RTRIM(@ClaimStatuses)) = N''
               OR LTRIM(RTRIM(ClaimStatus)) IN (SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500) FROM STRING_SPLIT(@ClaimStatuses, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL))
          AND (@ClinicNames IS NULL OR LTRIM(RTRIM(@ClinicNames)) = N''
               OR LTRIM(RTRIM(ClinicName)) IN (SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500) FROM STRING_SPLIT(@ClinicNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL))
          AND (@DenialCode IS NULL OR LTRIM(RTRIM(@DenialCode)) = N''
               OR EXISTS (SELECT 1 FROM STRING_SPLIT(@DenialCode, ',') d
                          WHERE NULLIF(LTRIM(RTRIM(d.value)), '') IS NOT NULL
                            AND LTRIM(RTRIM(ClaimLevelData.DenialCode)) LIKE N'%' + LTRIM(RTRIM(d.value)) + N'%'))
          AND (@DenialCodeExcludeBlank = 0 OR (DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> N''))
          AND (@PayerNames IS NULL OR LTRIM(RTRIM(@PayerNames)) = N''
               OR LTRIM(RTRIM(PayerName)) IN (SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500) FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL))
          AND (@PayerExcludeBlank = 0 OR (PayerName IS NOT NULL AND LTRIM(RTRIM(PayerName)) <> N''))
          AND (@PanelNames IS NULL OR LTRIM(RTRIM(@PanelNames)) = N''
               OR LTRIM(RTRIM(PanelName)) IN (SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL))
          AND (@PanelExcludeBlank = 0 OR (PanelName IS NOT NULL AND LTRIM(RTRIM(PanelName)) <> N''))
          AND (@AgingBuckets IS NULL OR LTRIM(RTRIM(@AgingBuckets)) = N''
               OR CASE
                    WHEN TRY_CAST(DaystoDOS AS INT) IS NULL THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 30    THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 60    THEN '30+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 90    THEN '60+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 120   THEN '90+'
                    ELSE '120+'
                  END IN (SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 100) FROM STRING_SPLIT(@AgingBuckets, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL))
          AND (@FirstBillExcludeBlank = 0 OR (FirstBilledDate IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) <> N''))
          AND (
                (@FirstBillFrom IS NULL AND @FirstBillTo IS NULL AND @FirstBillNull = 0)
             OR (@FirstBillNull = 1 AND (@FirstBillFrom IS NULL AND @FirstBillTo IS NULL)
                 AND (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = N''))
             OR (@FirstBillNull = 1 AND (@FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL)
                 AND ((FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = N'')
                   OR ((@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
                   AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo))))
             OR (@FirstBillNull = 0 AND (
                    (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
                AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)))
              )
          AND (@ChargeEnteredExcludeBlank = 0 OR (ChargeEnteredDate IS NOT NULL AND LTRIM(RTRIM(ChargeEnteredDate)) <> N''))
          AND (
                (@ChargeEnteredFrom IS NULL AND @ChargeEnteredTo IS NULL AND @ChargeEnteredNull = 0)
             OR (@ChargeEnteredNull = 1 AND (@ChargeEnteredFrom IS NULL AND @ChargeEnteredTo IS NULL)
                 AND (ChargeEnteredDate IS NULL OR LTRIM(RTRIM(ChargeEnteredDate)) = N''))
             OR (@ChargeEnteredNull = 1 AND (@ChargeEnteredFrom IS NOT NULL OR @ChargeEnteredTo IS NOT NULL)
                 AND ((ChargeEnteredDate IS NULL OR LTRIM(RTRIM(ChargeEnteredDate)) = N'')
                   OR ((@ChargeEnteredFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @ChargeEnteredFrom)
                   AND (@ChargeEnteredTo   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @ChargeEnteredTo))))
             OR (@ChargeEnteredNull = 0 AND (
                    (@ChargeEnteredFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @ChargeEnteredFrom)
                AND (@ChargeEnteredTo   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @ChargeEnteredTo)))
              )
          AND (
                (@DosFrom IS NULL AND @DosTo IS NULL AND @DosNull = 0)
             OR (@DosNull = 1 AND (@DosFrom IS NULL AND @DosTo IS NULL)
                 AND (DateOfService IS NULL OR LTRIM(RTRIM(DateOfService)) = N''))
             OR (@DosNull = 1 AND (@DosFrom IS NOT NULL OR @DosTo IS NOT NULL)
                 AND ((DateOfService IS NULL OR LTRIM(RTRIM(DateOfService)) = N'')
                   OR ((@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
                   AND (@DosTo   IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo))))
             OR (@DosNull = 0 AND (
                    (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
                AND (@DosTo   IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)))
              )
        """;

    /// <summary>Same predicates as dbo.usp_GetLineLevelDetails, using the export @params directly.</summary>
    private const string LineLevelWhereSql = """
        WHERE (@PayerName IS NULL OR LTRIM(RTRIM(@PayerName)) = N''
               OR EXISTS (SELECT 1 FROM STRING_SPLIT(@PayerName, ',') p
                          WHERE NULLIF(LTRIM(RTRIM(p.value)), '') IS NOT NULL
                            AND LTRIM(RTRIM(LineLevelData.PayerName)) LIKE N'%' + LTRIM(RTRIM(p.value)) + N'%'))
          AND (@PayerTypes IS NULL OR LTRIM(RTRIM(@PayerTypes)) = N''
               OR LTRIM(RTRIM(PayerType)) IN (SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500) FROM STRING_SPLIT(@PayerTypes, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL))
          AND (@ClaimStatuses IS NULL OR LTRIM(RTRIM(@ClaimStatuses)) = N''
               OR LTRIM(RTRIM(ClaimStatus)) IN (SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500) FROM STRING_SPLIT(@ClaimStatuses, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL))
          AND (@PayStatuses IS NULL OR LTRIM(RTRIM(@PayStatuses)) = N''
               OR LTRIM(RTRIM(PayStatus)) IN (SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500) FROM STRING_SPLIT(@PayStatuses, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL))
          AND (@CPTCodes IS NULL OR LTRIM(RTRIM(@CPTCodes)) = N''
               OR LTRIM(RTRIM(CPTCode)) IN (SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 100) FROM STRING_SPLIT(@CPTCodes, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL))
          AND (@ClinicNames IS NULL OR LTRIM(RTRIM(@ClinicNames)) = N''
               OR LTRIM(RTRIM(ClinicName)) IN (SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500) FROM STRING_SPLIT(@ClinicNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL))
          AND (@DenialCode IS NULL OR LTRIM(RTRIM(@DenialCode)) = N''
               OR EXISTS (SELECT 1 FROM STRING_SPLIT(@DenialCode, ',') d
                          WHERE NULLIF(LTRIM(RTRIM(d.value)), '') IS NOT NULL
                            AND LTRIM(RTRIM(LineLevelData.DenialCode)) LIKE N'%' + LTRIM(RTRIM(d.value)) + N'%'))
        """;

    private static List<SqlParameter> BuildClaimLevelSpParameters(
        string? filterPayerName, List<string>? filterPayerTypes, List<string>? filterClaimStatuses,
        List<string>? filterClinicNames, string? filterDenialCode, bool filterDenialCodeExcludeBlank,
        List<string>? filterPayerNames, bool filterPayerExcludeBlank,
        List<string>? filterPanelNames, bool filterPanelExcludeBlank,
        List<string>? filterAgingBuckets,
        DateOnly? filterFirstBillFrom, DateOnly? filterFirstBillTo, bool filterFirstBillNull, bool filterFirstBillExcludeBlank,
        DateOnly? filterChargeEnteredFrom, DateOnly? filterChargeEnteredTo, bool filterChargeEnteredNull, bool filterChargeEnteredExcludeBlank,
        DateOnly? filterDosFrom, DateOnly? filterDosTo, bool filterDosNull)
        =>
        [
            NvarcharParam("@PayerName", filterPayerName, 500),
            NvarcharParam("@PayerTypes", PipeJoin(filterPayerTypes)),
            NvarcharParam("@ClaimStatuses", PipeJoin(filterClaimStatuses)),
            NvarcharParam("@ClinicNames", PipeJoin(filterClinicNames)),
            NvarcharParam("@DenialCode", filterDenialCode, 500),
            BitParam("@DenialCodeExcludeBlank", filterDenialCodeExcludeBlank),
            NvarcharParam("@PayerNames", PipeJoin(filterPayerNames)),
            BitParam("@PayerExcludeBlank", filterPayerExcludeBlank),
            NvarcharParam("@PanelNames", PipeJoin(filterPanelNames)),
            BitParam("@PanelExcludeBlank", filterPanelExcludeBlank),
            NvarcharParam("@AgingBuckets", PipeJoin(filterAgingBuckets)),
            DateParam("@FirstBillFrom", filterFirstBillFrom),
            DateParam("@FirstBillTo", filterFirstBillTo),
            BitParam("@FirstBillNull", filterFirstBillNull),
            BitParam("@FirstBillExcludeBlank", filterFirstBillExcludeBlank),
            DateParam("@ChargeEnteredFrom", filterChargeEnteredFrom),
            DateParam("@ChargeEnteredTo", filterChargeEnteredTo),
            BitParam("@ChargeEnteredNull", filterChargeEnteredNull),
            BitParam("@ChargeEnteredExcludeBlank", filterChargeEnteredExcludeBlank),
            DateParam("@DosFrom", filterDosFrom),
            DateParam("@DosTo", filterDosTo),
            BitParam("@DosNull", filterDosNull),
        ];

    private static List<SqlParameter> BuildLineLevelSpParameters(
        string? filterPayerName, List<string>? filterPayerTypes, List<string>? filterClaimStatuses,
        List<string>? filterPayStatuses, List<string>? filterCPTCodes, List<string>? filterClinicNames,
        string? filterDenialCode)
        =>
        [
            NvarcharParam("@PayerName", filterPayerName, 500),
            NvarcharParam("@PayerTypes", PipeJoin(filterPayerTypes)),
            NvarcharParam("@ClaimStatuses", PipeJoin(filterClaimStatuses)),
            NvarcharParam("@PayStatuses", PipeJoin(filterPayStatuses)),
            NvarcharParam("@CPTCodes", PipeJoin(filterCPTCodes)),
            NvarcharParam("@ClinicNames", PipeJoin(filterClinicNames)),
            NvarcharParam("@DenialCode", filterDenialCode, 500),
        ];

    private static SqlParameter[] CloneParams(List<SqlParameter> source)
    {
        var cloned = new SqlParameter[source.Count];
        for (var i = 0; i < source.Count; i++)
            cloned[i] = new SqlParameter(source[i].ParameterName, source[i].Value ?? DBNull.Value)
            {
                SqlDbType = source[i].SqlDbType,
                Size = source[i].Size,
            };
        return cloned;
    }
}
