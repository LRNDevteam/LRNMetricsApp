using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads paginated Claim Level and Line Level detail rows from
/// <c>dbo.ClaimLevelData</c> and <c>dbo.LineLevelData</c> using
/// parameterized inline SQL with server-side filtering and pagination.
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
        ArgumentException.ThrowIfNullOrWhiteSpace(labName);

        var where = new List<string> { "LabName = @LabName" };
        var parameters = new List<SqlParameter> { new("@LabName", labName) };

        AddLikeFilter(where, parameters, "PayerName", "@fpn", filterPayerName);
        AddInClause(where, parameters, "LTRIM(RTRIM(PayerType))", "@fpt", filterPayerTypes);
        AddInClause(where, parameters, "LTRIM(RTRIM(ClaimStatus))", "@fcs", filterClaimStatuses);
        AddInClause(where, parameters, "LTRIM(RTRIM(ClinicName))", "@fcn", filterClinicNames);
        AddLikeFilter(where, parameters, "DenialCode", "@fdc", filterDenialCode);
        if (filterDenialCodeExcludeBlank)
            where.Add("DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> ''");
        AddInClause(where, parameters, "LTRIM(RTRIM(PayerName))", "@fpnm", filterPayerNames);
        if (filterPayerExcludeBlank)
            where.Add("PayerName IS NOT NULL AND LTRIM(RTRIM(PayerName)) <> ''");
        AddInClause(where, parameters, "LTRIM(RTRIM(PanelName))", "@fplnm", filterPanelNames);
        if (filterPanelExcludeBlank)
            where.Add("PanelName IS NOT NULL AND LTRIM(RTRIM(PanelName)) <> ''");

        // Aging bucket filter (computed column)
        if (filterAgingBuckets is { Count: > 0 })
        {
            var paramNames = new List<string>(filterAgingBuckets.Count);
            for (var i = 0; i < filterAgingBuckets.Count; i++)
            {
                var name = $"@fab_{i}";
                paramNames.Add(name);
                parameters.Add(new SqlParameter(name, filterAgingBuckets[i]));
            }
            where.Add($"""
                CASE
                    WHEN TRY_CAST(DaystoDOS AS INT) IS NULL THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 30    THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 60    THEN '30+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 90    THEN '60+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 120   THEN '90+'
                    ELSE '120+'
                END IN ({string.Join(", ", paramNames)})
                """);
        }

        // Date range filters with null/blank handling
        AddDateRangeFilter(where, parameters, "FirstBilledDate", "@ffbFrom", "@ffbTo", filterFirstBillFrom, filterFirstBillTo, filterFirstBillNull, filterFirstBillExcludeBlank);
        AddDateRangeFilter(where, parameters, "ChargeEnteredDate", "@fceFrom", "@fceTo", filterChargeEnteredFrom, filterChargeEnteredTo, filterChargeEnteredNull, filterChargeEnteredExcludeBlank);
        AddDateRangeFilter(where, parameters, "DateOfService", "@fdosFrom", "@fdosTo", filterDosFrom, filterDosTo, filterDosNull);

        var whereStr = string.Join(" AND ", where);

        // Filter option lists (unfiltered, lab-scoped)
        const string optionsSql = """
            SELECT DISTINCT LTRIM(RTRIM(PayerType))   FROM dbo.ClaimLevelData WHERE LabName = @LabName AND PayerType   IS NOT NULL AND LTRIM(RTRIM(PayerType))   <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(ClaimStatus)) FROM dbo.ClaimLevelData WHERE LabName = @LabName AND ClaimStatus IS NOT NULL AND LTRIM(RTRIM(ClaimStatus)) <> ''
                AND TRY_CAST(ClaimStatus AS DATE) IS NULL ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(ClinicName))  FROM dbo.ClaimLevelData WHERE LabName = @LabName AND ClinicName  IS NOT NULL AND LTRIM(RTRIM(ClinicName))  <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(PayerName))   FROM dbo.ClaimLevelData WHERE LabName = @LabName AND PayerName   IS NOT NULL AND LTRIM(RTRIM(PayerName))   <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(PanelName))   FROM dbo.ClaimLevelData WHERE LabName = @LabName AND PanelName   IS NOT NULL AND LTRIM(RTRIM(PanelName))   <> '' ORDER BY 1;
            SELECT DISTINCT
                CASE
                    WHEN TRY_CAST(DaystoDOS AS INT) IS NULL THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 30    THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 60    THEN '30+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 90    THEN '60+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 120   THEN '90+'
                    ELSE '120+'
                END AS AgingBucket
            FROM dbo.ClaimLevelData WHERE LabName = @LabName ORDER BY 1;
            """;

        // Counts
        var countSql = $"""
            SELECT COUNT(*) FROM dbo.ClaimLevelData WHERE LabName = @LabName;
            SELECT COUNT(*) FROM dbo.ClaimLevelData WHERE {whereStr};
            """;

        // Paged data — order by a deterministic column for consistent paging
        int offset = (Math.Max(1, page) - 1) * pageSize;
        var dataSql = $"""
            SELECT
                ISNULL(ClaimID,'')              AS ClaimID,
                ISNULL(AccessionNumber,'')      AS AccessionNumber,
                ISNULL(SourceFileID,'')         AS SourceFileID,
                ISNULL(IngestedOn,'')           AS IngestedOn,
                ISNULL(RowHash,'')              AS RowHash,
                ISNULL(PayerName_Raw,'')        AS PayerName_Raw,
                ISNULL(LTRIM(RTRIM(PayerName)),'')  AS PayerName,
                ISNULL(Payer_Code,'')           AS Payer_Code,
                ISNULL(Payer_Common_Code,'')    AS Payer_Common_Code,
                ISNULL(Payer_Group_Code,'')     AS Payer_Group_Code,
                ISNULL(Global_Payer_ID,'')      AS Global_Payer_ID,
                ISNULL(LTRIM(RTRIM(PayerType)),'')  AS PayerType,
                ISNULL(BillingProvider,'')      AS BillingProvider,
                ISNULL(ReferringProvider,'')    AS ReferringProvider,
                ISNULL(LTRIM(RTRIM(ClinicName)),'') AS ClinicName,
                ISNULL(SalesRepName,'')         AS SalesRepName,
                ISNULL(PatientID,'')            AS PatientID,
                ISNULL(PatientDOB,'')           AS PatientDOB,
                ISNULL(DateOfService,'')        AS DateOfService,
                ISNULL(ChargeEnteredDate,'')    AS ChargeEnteredDate,
                ISNULL(FirstBilledDate,'')      AS FirstBilledDate,
                ISNULL(LTRIM(RTRIM(PanelName)),'')  AS PanelName,
                ISNULL(CPTCodeXUnitsXModifier,'') AS CPTCodeUnitsModifier,
                ISNULL(POS,'')                  AS POS,
                ISNULL(TOS,'')                  AS TOS,
                ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
                ISNULL(TRY_CAST(AllowedAmount        AS DECIMAL(18,2)), 0) AS AllowedAmount,
                ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
                ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
                ISNULL(TRY_CAST(TotalPayments        AS DECIMAL(18,2)), 0) AS TotalPayments,
                ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
                ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
                ISNULL(TRY_CAST(TotalAdjustments     AS DECIMAL(18,2)), 0) AS TotalAdjustments,
                ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
                ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance,
                ISNULL(TRY_CAST(TotalBalance         AS DECIMAL(18,2)), 0) AS TotalBalance,
                ISNULL(CheckDate,'')             AS CheckDate,
                ISNULL(LTRIM(RTRIM(ClaimStatus)),'') AS ClaimStatus,
                ISNULL(DenialCode,'')            AS DenialCode,
                ISNULL(ICDCode,'')               AS ICDCode,
                ISNULL(DaysToDOS,'')             AS DaysToDOS,
                ISNULL(RollingDays,'')           AS RollingDays,
                ISNULL(DaysToBill,'')            AS DaysToBill,
                ISNULL(DaysToPost,'')            AS DaysToPost,
                ISNULL(ICDPointer,'')            AS ICDPointer,
                CASE
                    WHEN TRY_CAST(DaystoDOS AS INT) IS NULL THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 30    THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 60    THEN '30+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 90    THEN '60+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 120   THEN '90+'
                    ELSE '120+'
                END                              AS AgingBucket
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            ORDER BY ClaimID
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY
            """;

        var payerTypes = new List<string>();
        var claimStatuses = new List<string>();
        var clinicNames = new List<string>();
        var payerNames = new List<string>();
        var panelNames = new List<string>();
        var agingBuckets = new List<string>();
        int totalAll = 0, totalFiltered = 0;
        var records = new List<ClaimRecord>();

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        // Options
        await using (var cmd = new SqlCommand(optionsSql, conn))
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct)) payerTypes.Add(r.GetString(0));
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) claimStatuses.Add(r.GetString(0));
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) clinicNames.Add(r.GetString(0));
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) payerNames.Add(r.GetString(0));
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) panelNames.Add(r.GetString(0));
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) agingBuckets.Add(r.GetString(0));
        }

        // Counts
        await using (var cmd = new SqlCommand(countSql, conn))
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct)) totalAll = r.GetInt32(0);
            await r.NextResultAsync(ct);
            if (await r.ReadAsync(ct)) totalFiltered = r.GetInt32(0);
        }

        // Paged data
        await using (var cmd = new SqlCommand(dataSql, conn))
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            cmd.Parameters.Add(new SqlParameter("@Offset", SqlDbType.Int) { Value = offset });
            cmd.Parameters.Add(new SqlParameter("@PageSize", SqlDbType.Int) { Value = pageSize });

            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                records.Add(new ClaimRecord
                {
                    LabID                = labName,
                    LabName              = labName,
                    ClaimID              = r.GetString(r.GetOrdinal("ClaimID")),
                    AccessionNumber      = r.GetString(r.GetOrdinal("AccessionNumber")),
                    SourceFileID         = r.GetString(r.GetOrdinal("SourceFileID")),
                    IngestedOn           = r.GetString(r.GetOrdinal("IngestedOn")),
                    RowHash              = r.GetString(r.GetOrdinal("RowHash")),
                    PayerName_Raw        = r.GetString(r.GetOrdinal("PayerName_Raw")),
                    PayerName            = r.GetString(r.GetOrdinal("PayerName")),
                    Payer_Code           = r.GetString(r.GetOrdinal("Payer_Code")),
                    Payer_Common_Code    = r.GetString(r.GetOrdinal("Payer_Common_Code")),
                    Payer_Group_Code     = r.GetString(r.GetOrdinal("Payer_Group_Code")),
                    Global_Payer_ID      = r.GetString(r.GetOrdinal("Global_Payer_ID")),
                    PayerType            = r.GetString(r.GetOrdinal("PayerType")),
                    BillingProvider      = r.GetString(r.GetOrdinal("BillingProvider")),
                    ReferringProvider    = r.GetString(r.GetOrdinal("ReferringProvider")),
                    ClinicName           = r.GetString(r.GetOrdinal("ClinicName")),
                    SalesRepName         = r.GetString(r.GetOrdinal("SalesRepName")),
                    PatientID            = r.GetString(r.GetOrdinal("PatientID")),
                    PatientDOB           = r.GetString(r.GetOrdinal("PatientDOB")),
                    DateOfService        = r.GetString(r.GetOrdinal("DateOfService")),
                    ChargeEnteredDate    = r.GetString(r.GetOrdinal("ChargeEnteredDate")),
                    FirstBilledDate      = r.GetString(r.GetOrdinal("FirstBilledDate")),
                    PanelName            = r.GetString(r.GetOrdinal("PanelName")),
                    CPTCodeUnitsModifier = r.GetString(r.GetOrdinal("CPTCodeUnitsModifier")),
                    POS                  = r.GetString(r.GetOrdinal("POS")),
                    TOS                  = r.GetString(r.GetOrdinal("TOS")),
                    ChargeAmount         = r.GetDecimal(r.GetOrdinal("ChargeAmount")),
                    AllowedAmount        = r.GetDecimal(r.GetOrdinal("AllowedAmount")),
                    InsurancePayment     = r.GetDecimal(r.GetOrdinal("InsurancePayment")),
                    PatientPayment       = r.GetDecimal(r.GetOrdinal("PatientPayment")),
                    TotalPayments        = r.GetDecimal(r.GetOrdinal("TotalPayments")),
                    InsuranceAdjustments = r.GetDecimal(r.GetOrdinal("InsuranceAdjustments")),
                    PatientAdjustments   = r.GetDecimal(r.GetOrdinal("PatientAdjustments")),
                    TotalAdjustments     = r.GetDecimal(r.GetOrdinal("TotalAdjustments")),
                    InsuranceBalance     = r.GetDecimal(r.GetOrdinal("InsuranceBalance")),
                    PatientBalance       = r.GetDecimal(r.GetOrdinal("PatientBalance")),
                    TotalBalance         = r.GetDecimal(r.GetOrdinal("TotalBalance")),
                    CheckDate            = r.GetString(r.GetOrdinal("CheckDate")),
                    ClaimStatus          = r.GetString(r.GetOrdinal("ClaimStatus")),
                    DenialCode           = r.GetString(r.GetOrdinal("DenialCode")),
                    ICDCode              = r.GetString(r.GetOrdinal("ICDCode")),
                    DaysToDOS            = r.GetString(r.GetOrdinal("DaysToDOS")),
                    RollingDays          = r.GetString(r.GetOrdinal("RollingDays")),
                    DaysToBill           = r.GetString(r.GetOrdinal("DaysToBill")),
                    DaysToPost           = r.GetString(r.GetOrdinal("DaysToPost")),
                    ICDPointer           = r.GetString(r.GetOrdinal("ICDPointer")),
                    AgingBucket          = r.GetString(r.GetOrdinal("AgingBucket")),
                });
            }
        }

        _logger.LogInformation(
            "ClaimLevel: lab={Lab}, filtered={Filtered}/{All}, page={Page}",
            labName, totalFiltered, totalAll, page);

        return new ClaimLevelResult(payerTypes, claimStatuses, clinicNames,
            payerNames, panelNames, agingBuckets,
            records, totalFiltered, totalAll);
    }

    // ?? Line Level ???????????????????????????????????????????????????????

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
        ArgumentException.ThrowIfNullOrWhiteSpace(labName);

        var where = new List<string> { "LabName = @LabName" };
        var parameters = new List<SqlParameter> { new("@LabName", labName) };

        AddLikeFilter(where, parameters, "PayerName", "@fpn", filterPayerName);
        AddInClause(where, parameters, "LTRIM(RTRIM(PayerType))", "@fpt", filterPayerTypes);
        AddInClause(where, parameters, "LTRIM(RTRIM(ClaimStatus))", "@fcs", filterClaimStatuses);
        AddInClause(where, parameters, "LTRIM(RTRIM(PayStatus))", "@fps", filterPayStatuses);
        AddInClause(where, parameters, "LTRIM(RTRIM(CPTCode))", "@fcpt", filterCPTCodes);
        AddInClause(where, parameters, "LTRIM(RTRIM(ClinicName))", "@fcn", filterClinicNames);
        AddLikeFilter(where, parameters, "DenialCode", "@fdc", filterDenialCode);

        var whereStr = string.Join(" AND ", where);

        // Filter option lists (unfiltered, lab-scoped)
        const string optionsSql = """
            SELECT DISTINCT LTRIM(RTRIM(PayerType))   FROM dbo.LineLevelData WHERE LabName = @LabName AND PayerType   IS NOT NULL AND LTRIM(RTRIM(PayerType))   <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(ClaimStatus)) FROM dbo.LineLevelData WHERE LabName = @LabName AND ClaimStatus IS NOT NULL AND LTRIM(RTRIM(ClaimStatus)) <> ''
                AND TRY_CAST(ClaimStatus AS DATE) IS NULL ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(PayStatus))   FROM dbo.LineLevelData WHERE LabName = @LabName AND PayStatus   IS NOT NULL AND LTRIM(RTRIM(PayStatus))   <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(ClinicName))  FROM dbo.LineLevelData WHERE LabName = @LabName AND ClinicName  IS NOT NULL AND LTRIM(RTRIM(ClinicName))  <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(CPTCode))     FROM dbo.LineLevelData WHERE LabName = @LabName AND CPTCode     IS NOT NULL AND LTRIM(RTRIM(CPTCode))     <> '' ORDER BY 1;
            """;

        // Counts
        var countSql = $"""
            SELECT COUNT(*) FROM dbo.LineLevelData WHERE LabName = @LabName;
            SELECT COUNT(*) FROM dbo.LineLevelData WHERE {whereStr};
            """;

        // Paged data
        int offset = (Math.Max(1, page) - 1) * pageSize;
        var dataSql = $"""
            SELECT
                ISNULL(ClaimID,'')              AS ClaimID,
                ISNULL(AccessionNumber,'')      AS AccessionNumber,
                ISNULL(SourceFileID,'')         AS SourceFileID,
                ISNULL(IngestedOn,'')           AS IngestedOn,
                ISNULL(RowHash,'')              AS RowHash,
                ISNULL(PayerName_Raw,'')        AS PayerName_Raw,
                ISNULL(LTRIM(RTRIM(PayerName)),'')  AS PayerName,
                ISNULL(Payer_Code,'')           AS Payer_Code,
                ISNULL(Payer_Common_Code,'')    AS Payer_Common_Code,
                ISNULL(Payer_Group_Code,'')     AS Payer_Group_Code,
                ISNULL(Global_Payer_ID,'')      AS Global_Payer_ID,
                ISNULL(LTRIM(RTRIM(PayerType)),'')  AS PayerType,
                ISNULL(BillingProvider,'')      AS BillingProvider,
                ISNULL(ReferringProvider,'')    AS ReferringProvider,
                ISNULL(LTRIM(RTRIM(ClinicName)),'') AS ClinicName,
                ISNULL(SalesRepName,'')         AS SalesRepName,
                ISNULL(PatientID,'')            AS PatientID,
                ISNULL(PatientDOB,'')           AS PatientDOB,
                ISNULL(DateOfService,'')        AS DateOfService,
                ISNULL(ChargeEnteredDate,'')    AS ChargeEnteredDate,
                ISNULL(FirstBilledDate,'')      AS FirstBilledDate,
                ISNULL(LTRIM(RTRIM(PanelName)),'')  AS PanelName,
                ISNULL(LTRIM(RTRIM(CPTCode)),'')    AS CPTCode,
                ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 0)                  AS Units,
                ISNULL(Modifier,'')             AS Modifier,
                ISNULL(POS,'')                  AS POS,
                ISNULL(TOS,'')                  AS TOS,
                ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
                ISNULL(TRY_CAST(ChargeAmountPerUnit  AS DECIMAL(18,2)), 0) AS ChargeAmountPerUnit,
                ISNULL(TRY_CAST(AllowedAmount        AS DECIMAL(18,2)), 0) AS AllowedAmount,
                ISNULL(TRY_CAST(AllowedAmountPerUnit AS DECIMAL(18,2)), 0) AS AllowedAmountPerUnit,
                ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
                ISNULL(TRY_CAST(InsurancePaymentPerUnit AS DECIMAL(18,2)), 0) AS InsurancePaymentPerUnit,
                ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
                ISNULL(TRY_CAST(PatientPaymentPerUnit AS DECIMAL(18,2)), 0) AS PatientPaymentPerUnit,
                ISNULL(TRY_CAST(TotalPayments        AS DECIMAL(18,2)), 0) AS TotalPayments,
                ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
                ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
                ISNULL(TRY_CAST(TotalAdjustments     AS DECIMAL(18,2)), 0) AS TotalAdjustments,
                ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
                ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance,
                ISNULL(TRY_CAST(PatientBalancePerUnit AS DECIMAL(18,2)), 0) AS PatientBalancePerUnit,
                ISNULL(TRY_CAST(TotalBalance         AS DECIMAL(18,2)), 0) AS TotalBalance,
                ISNULL(CheckDate,'')             AS CheckDate,
                ISNULL(LTRIM(RTRIM(ClaimStatus)),'') AS ClaimStatus,
                ISNULL(LTRIM(RTRIM(PayStatus)),'')   AS PayStatus,
                ISNULL(DenialCode,'')            AS DenialCode,
                ISNULL(ICDCode,'')               AS ICDCode,
                ISNULL(DaysToDOS,'')             AS DaysToDOS,
                ISNULL(RollingDays,'')           AS RollingDays,
                ISNULL(DaysToBill,'')            AS DaysToBill,
                ISNULL(DaysToPost,'')            AS DaysToPost,
                ISNULL(ICDPointer,'')            AS ICDPointer
            FROM dbo.LineLevelData
            WHERE {whereStr}
            ORDER BY ClaimID, CPTCode
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY
            """;

        var payerTypes = new List<string>();
        var claimStatuses = new List<string>();
        var payStatuses = new List<string>();
        var clinicNames = new List<string>();
        var cptCodes = new List<string>();
        int totalAll = 0, totalFiltered = 0;
        var records = new List<LineRecord>();

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        // Options
        await using (var cmd = new SqlCommand(optionsSql, conn))
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct)) payerTypes.Add(r.GetString(0));
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) claimStatuses.Add(r.GetString(0));
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) payStatuses.Add(r.GetString(0));
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) clinicNames.Add(r.GetString(0));
            await r.NextResultAsync(ct);
            while (await r.ReadAsync(ct)) cptCodes.Add(r.GetString(0));
        }

        // Counts
        await using (var cmd = new SqlCommand(countSql, conn))
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct)) totalAll = r.GetInt32(0);
            await r.NextResultAsync(ct);
            if (await r.ReadAsync(ct)) totalFiltered = r.GetInt32(0);
        }

        // Paged data
        await using (var cmd = new SqlCommand(dataSql, conn))
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            cmd.Parameters.Add(new SqlParameter("@Offset", SqlDbType.Int) { Value = offset });
            cmd.Parameters.Add(new SqlParameter("@PageSize", SqlDbType.Int) { Value = pageSize });

            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                records.Add(new LineRecord
                {
                    LabID                   = labName,
                    LabName                 = labName,
                    ClaimID                 = r.GetString(r.GetOrdinal("ClaimID")),
                    AccessionNumber         = r.GetString(r.GetOrdinal("AccessionNumber")),
                    SourceFileID            = r.GetString(r.GetOrdinal("SourceFileID")),
                    IngestedOn              = r.GetString(r.GetOrdinal("IngestedOn")),
                    RowHash                 = r.GetString(r.GetOrdinal("RowHash")),
                    PayerName_Raw           = r.GetString(r.GetOrdinal("PayerName_Raw")),
                    PayerName               = r.GetString(r.GetOrdinal("PayerName")),
                    Payer_Code              = r.GetString(r.GetOrdinal("Payer_Code")),
                    Payer_Common_Code       = r.GetString(r.GetOrdinal("Payer_Common_Code")),
                    Payer_Group_Code        = r.GetString(r.GetOrdinal("Payer_Group_Code")),
                    Global_Payer_ID         = r.GetString(r.GetOrdinal("Global_Payer_ID")),
                    PayerType               = r.GetString(r.GetOrdinal("PayerType")),
                    BillingProvider         = r.GetString(r.GetOrdinal("BillingProvider")),
                    ReferringProvider       = r.GetString(r.GetOrdinal("ReferringProvider")),
                    ClinicName              = r.GetString(r.GetOrdinal("ClinicName")),
                    SalesRepName            = r.GetString(r.GetOrdinal("SalesRepName")),
                    PatientID               = r.GetString(r.GetOrdinal("PatientID")),
                    PatientDOB              = r.GetString(r.GetOrdinal("PatientDOB")),
                    DateOfService           = r.GetString(r.GetOrdinal("DateOfService")),
                    ChargeEnteredDate       = r.GetString(r.GetOrdinal("ChargeEnteredDate")),
                    FirstBilledDate         = r.GetString(r.GetOrdinal("FirstBilledDate")),
                    PanelName               = r.GetString(r.GetOrdinal("PanelName")),
                    CPTCode                 = r.GetString(r.GetOrdinal("CPTCode")),
                    Units                   = r.GetDecimal(r.GetOrdinal("Units")),
                    Modifier                = r.GetString(r.GetOrdinal("Modifier")),
                    POS                     = r.GetString(r.GetOrdinal("POS")),
                    TOS                     = r.GetString(r.GetOrdinal("TOS")),
                    ChargeAmount            = r.GetDecimal(r.GetOrdinal("ChargeAmount")),
                    ChargeAmountPerUnit     = r.GetDecimal(r.GetOrdinal("ChargeAmountPerUnit")),
                    AllowedAmount           = r.GetDecimal(r.GetOrdinal("AllowedAmount")),
                    AllowedAmountPerUnit    = r.GetDecimal(r.GetOrdinal("AllowedAmountPerUnit")),
                    InsurancePayment        = r.GetDecimal(r.GetOrdinal("InsurancePayment")),
                    InsurancePaymentPerUnit = r.GetDecimal(r.GetOrdinal("InsurancePaymentPerUnit")),
                    PatientPayment          = r.GetDecimal(r.GetOrdinal("PatientPayment")),
                    PatientPaymentPerUnit   = r.GetDecimal(r.GetOrdinal("PatientPaymentPerUnit")),
                    TotalPayments           = r.GetDecimal(r.GetOrdinal("TotalPayments")),
                    InsuranceAdjustments    = r.GetDecimal(r.GetOrdinal("InsuranceAdjustments")),
                    PatientAdjustments      = r.GetDecimal(r.GetOrdinal("PatientAdjustments")),
                    TotalAdjustments        = r.GetDecimal(r.GetOrdinal("TotalAdjustments")),
                    InsuranceBalance        = r.GetDecimal(r.GetOrdinal("InsuranceBalance")),
                    PatientBalance          = r.GetDecimal(r.GetOrdinal("PatientBalance")),
                    PatientBalancePerUnit   = r.GetDecimal(r.GetOrdinal("PatientBalancePerUnit")),
                    TotalBalance            = r.GetDecimal(r.GetOrdinal("TotalBalance")),
                    CheckDate               = r.GetString(r.GetOrdinal("CheckDate")),
                    ClaimStatus             = r.GetString(r.GetOrdinal("ClaimStatus")),
                    PayStatus               = r.GetString(r.GetOrdinal("PayStatus")),
                    DenialCode              = r.GetString(r.GetOrdinal("DenialCode")),
                    ICDCode                 = r.GetString(r.GetOrdinal("ICDCode")),
                    DaysToDOS               = r.GetString(r.GetOrdinal("DaysToDOS")),
                    RollingDays             = r.GetString(r.GetOrdinal("RollingDays")),
                    DaysToBill              = r.GetString(r.GetOrdinal("DaysToBill")),
                    DaysToPost              = r.GetString(r.GetOrdinal("DaysToPost")),
                    ICDPointer              = r.GetString(r.GetOrdinal("ICDPointer")),
                });
            }
        }

        _logger.LogInformation(
            "LineLevel: lab={Lab}, filtered={Filtered}/{All}, page={Page}",
            labName, totalFiltered, totalAll, page);

        return new LineLevelResult(payerTypes, claimStatuses, payStatuses, clinicNames,
            cptCodes, records, totalFiltered, totalAll);
    }

    // ?? Helpers ??????????????????????????????????????????????????????????

    private static void AddInClause(List<string> where, List<SqlParameter> parms,
        string columnExpression, string paramPrefix, List<string>? values)
    {
        if (values is not { Count: > 0 }) return;

        var paramNames = new List<string>(values.Count);
        for (var i = 0; i < values.Count; i++)
        {
            var name = $"{paramPrefix}_{i}";
            paramNames.Add(name);
            parms.Add(new SqlParameter(name, values[i]));
        }

        where.Add($"{columnExpression} IN ({string.Join(", ", paramNames)})");
    }

    private static void AddLikeFilter(List<string> where, List<SqlParameter> parms,
        string column, string paramName, string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;

        var parts = value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length == 0) return;

        if (parts.Length == 1)
        {
            where.Add($"LTRIM(RTRIM({column})) LIKE '%' + {paramName} + '%'");
            parms.Add(new SqlParameter(paramName, parts[0]));
        }
        else
        {
            var clauses = new List<string>(parts.Length);
            for (var i = 0; i < parts.Length; i++)
            {
                var name = $"{paramName}_{i}";
                clauses.Add($"LTRIM(RTRIM({column})) LIKE '%' + {name} + '%'");
                parms.Add(new SqlParameter(name, parts[i]));
            }
            where.Add($"({string.Join(" OR ", clauses)})");
        }
    }

    private static SqlParameter[] CloneParams(List<SqlParameter> source)
    {
        var cloned = new SqlParameter[source.Count];
        for (var i = 0; i < source.Count; i++)
            cloned[i] = new SqlParameter(source[i].ParameterName, source[i].Value);
        return cloned;
    }

    /// <summary>
    /// Adds a date-range filter for a string-typed date column. When <paramref name="includeNull"/>
    /// is true, rows where the column is NULL or blank are included (OR-ed with the range).
    /// When <paramref name="excludeBlank"/> is true, rows where the column is NULL or blank are excluded.
    /// </summary>
    private static void AddDateRangeFilter(
        List<string> where, List<SqlParameter> parms,
        string column, string fromParam, string toParam,
        DateOnly? from, DateOnly? to, bool includeNull, bool excludeBlank = false)
    {
        var hasFrom = from.HasValue;
        var hasTo = to.HasValue;

        if (!hasFrom && !hasTo && !includeNull && !excludeBlank) return;

        // Exclude blank takes precedence — filter out NULL/blank rows
        if (excludeBlank)
            where.Add($"{column} IS NOT NULL AND LTRIM(RTRIM({column})) <> ''");

        var parts = new List<string>();

        if (hasFrom)
        {
            parts.Add($"TRY_CAST({column} AS DATE) >= {fromParam}");
            parms.Add(new SqlParameter(fromParam, SqlDbType.Date) { Value = from!.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (hasTo)
        {
            parts.Add($"TRY_CAST({column} AS DATE) <= {toParam}");
            parms.Add(new SqlParameter(toParam, SqlDbType.Date) { Value = to!.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (includeNull)
        {
            var nullClause = $"({column} IS NULL OR LTRIM(RTRIM({column})) = '')";
            if (parts.Count > 0)
            {
                // NULL/blank OR within date range
                var rangeClause = string.Join(" AND ", parts);
                where.Add($"({nullClause} OR ({rangeClause}))");
            }
            else
            {
                where.Add(nullClause);
            }
        }
        else
        {
            foreach (var p in parts)
                where.Add(p);
        }
    }
}
