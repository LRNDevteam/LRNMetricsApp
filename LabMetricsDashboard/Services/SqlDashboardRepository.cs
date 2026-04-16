using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Dashboard Index data from <c>dbo.ClaimLevelData</c> and <c>dbo.LineLevelData</c>
/// using parameterized inline SQL. Produces all KPIs, breakdowns, insights, and
/// trend data needed by the Dashboard Index page.
/// </summary>
public sealed class SqlDashboardRepository : IDashboardRepository
{
    private readonly ILogger<SqlDashboardRepository> _logger;

    public SqlDashboardRepository(ILogger<SqlDashboardRepository> logger)
        => _logger = logger;

    public async Task<DashboardResult> GetDashboardAsync(
        string connectionString,
        string labName,
        string? filterPayerName = null,
        string? filterPayerType = null,
        string? filterPanelName = null,
        string? filterClinicName = null,
        string? filterReferringProvider = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        // Build WHERE for ClaimLevelData
        var claimWhere = new List<string>();
        var parameters = new List<SqlParameter>();

        AddFilterClause(claimWhere, parameters, "PayerName", "@fp", filterPayerName);
        AddFilterClause(claimWhere, parameters, "PayerType", "@fpt", filterPayerType);
        AddFilterClause(claimWhere, parameters, "PanelName", "@fpl", filterPanelName);
        AddFilterClause(claimWhere, parameters, "ClinicName", "@fcn", filterClinicName);
        AddFilterClause(claimWhere, parameters, "ReferringProvider", "@frp", filterReferringProvider);
        AddDateRangeClause(claimWhere, parameters, "DateOfService", "@dosFrom", "@dosTo", filterDosFrom, filterDosTo);
        AddDateRangeClause(claimWhere, parameters, "FirstBilledDate", "@fbFrom", "@fbTo", filterFirstBillFrom, filterFirstBillTo);

        var claimWhereStr = claimWhere.Count > 0 ? string.Join(" AND ", claimWhere) : "1=1";

        // Line-level reuses the same parameter names so the same SqlParameter set works
        var lineWhere = new List<string>();
        if (!string.IsNullOrWhiteSpace(filterPayerName))          lineWhere.Add("LTRIM(RTRIM(PayerName)) = @fp");
        if (!string.IsNullOrWhiteSpace(filterPayerType))          lineWhere.Add("LTRIM(RTRIM(PayerType)) = @fpt");
        if (!string.IsNullOrWhiteSpace(filterPanelName))          lineWhere.Add("LTRIM(RTRIM(PanelName)) = @fpl");
        if (!string.IsNullOrWhiteSpace(filterClinicName))         lineWhere.Add("LTRIM(RTRIM(ClinicName)) = @fcn");
        if (!string.IsNullOrWhiteSpace(filterReferringProvider))  lineWhere.Add("LTRIM(RTRIM(ReferringProvider)) = @frp");
        if (filterDosFrom.HasValue)       lineWhere.Add("TRY_CAST(DateOfService AS DATE) >= @dosFrom");
        if (filterDosTo.HasValue)         lineWhere.Add("TRY_CAST(DateOfService AS DATE) <= @dosTo");
        if (filterFirstBillFrom.HasValue) lineWhere.Add("TRY_CAST(FirstBilledDate AS DATE) >= @fbFrom");
        if (filterFirstBillTo.HasValue)   lineWhere.Add("TRY_CAST(FirstBilledDate AS DATE) <= @fbTo");
        var lineWhereStr = lineWhere.Count > 0 ? string.Join(" AND ", lineWhere) : "1=1";

        // Filter option lists (unfiltered)
        const string optionsSql = """
            SELECT DISTINCT LTRIM(RTRIM(PayerName))          FROM dbo.ClaimLevelData WHERE PayerName          IS NOT NULL AND PayerName          <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(PayerType))          FROM dbo.ClaimLevelData WHERE PayerType          IS NOT NULL AND PayerType          <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(PanelName))          FROM dbo.ClaimLevelData WHERE PanelName          IS NOT NULL AND PanelName          <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(ClinicName))         FROM dbo.ClaimLevelData WHERE ClinicName         IS NOT NULL AND ClinicName         <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(ReferringProvider))  FROM dbo.ClaimLevelData WHERE ReferringProvider  IS NOT NULL AND ReferringProvider  <> '' ORDER BY 1;
            """;

        // ?? Claim-level KPIs ????????????????????????????????????????????
        var kpiSql = $"""
            SELECT
                COUNT(*)                                                                         AS TotalClaims,
                ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))), 0)                      AS TotalCharges,
                ISNULL(SUM(TRY_CAST(TotalPayments    AS DECIMAL(18,2))), 0)                      AS TotalPayments,
                ISNULL(SUM(TRY_CAST(TotalBalance      AS DECIMAL(18,2))), 0)                     AS TotalBalance,

                ISNULL(SUM(CASE WHEN ClaimStatus IN ('Fully Paid','Partially Paid','Patient Responsibility','Patient Payment')
                     THEN TRY_CAST(AllowedAmount AS DECIMAL(18,2)) ELSE 0 END), 0)              AS CollectionNumerator,
                ISNULL(SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied')
                     THEN TRY_CAST(ChargeAmount  AS DECIMAL(18,2)) ELSE 0 END), 0)              AS DenialNumerator,
                ISNULL(SUM(CASE WHEN ClaimStatus IN ('Complete W/O','Partially Adjusted')
                     THEN TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)) ELSE 0 END), 0)       AS AdjustmentNumerator,
                ISNULL(SUM(CASE WHEN ClaimStatus = 'No Response'
                     THEN TRY_CAST(ChargeAmount  AS DECIMAL(18,2)) ELSE 0 END), 0)              AS OutstandingNumerator
            FROM dbo.ClaimLevelData
            WHERE {claimWhereStr}
            """;

        // ?? Claim status breakdown ??????????????????????????????????????
        var statusSql = $"""
            SELECT
                ISNULL(NULLIF(LTRIM(RTRIM(ClaimStatus)),''), 'Unknown')   AS Status,
                COUNT(*)                                                  AS Claims,
                ISNULL(SUM(TRY_CAST(ChargeAmount  AS DECIMAL(18,2))), 0)  AS Charges,
                ISNULL(SUM(TRY_CAST(TotalPayments AS DECIMAL(18,2))), 0)  AS Payments,
                ISNULL(SUM(TRY_CAST(TotalBalance   AS DECIMAL(18,2))), 0) AS Balance
            FROM dbo.ClaimLevelData
            WHERE {claimWhereStr}
            GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(ClaimStatus)),''), 'Unknown')
            ORDER BY Claims DESC
            """;

        // ?? Payer type payments ?????????????????????????????????????????
        var payerTypeSql = $"""
            SELECT
                LTRIM(RTRIM(PayerType))                                    AS PayerType,
                ISNULL(SUM(TRY_CAST(TotalPayments AS DECIMAL(18,2))), 0)   AS TotalPayments
            FROM dbo.ClaimLevelData
            WHERE {claimWhereStr} AND PayerType IS NOT NULL AND PayerType <> ''
            GROUP BY LTRIM(RTRIM(PayerType))
            ORDER BY TotalPayments DESC
            """;

        // ?? Insight breakdowns (top 15 by charges per dimension) ????????
        static string insightSql(string col, string where) => $"""
            SELECT TOP 15
                ISNULL(NULLIF(LTRIM(RTRIM({col})),''), 'Unknown') AS Label,
                COUNT(*)                                                  AS Claims,
                ISNULL(SUM(TRY_CAST(ChargeAmount  AS DECIMAL(18,2))), 0)  AS Charges,
                ISNULL(SUM(TRY_CAST(TotalPayments AS DECIMAL(18,2))), 0)  AS Payments,
                ISNULL(SUM(TRY_CAST(TotalBalance   AS DECIMAL(18,2))), 0) AS Balance
            FROM dbo.ClaimLevelData
            WHERE {where}
            GROUP BY ISNULL(NULLIF(LTRIM(RTRIM({col})),''), 'Unknown')
            ORDER BY Charges DESC;
            """;

        var insightsSql = insightSql("PayerName", claimWhereStr)
            + insightSql("PanelName", claimWhereStr)
            + insightSql("ClinicName", claimWhereStr)
            + insightSql("ReferringProvider", claimWhereStr);

        // ?? Monthly trends ??????????????????????????????????????????????
        var monthlySql = $"""
            SELECT FORMAT(TRY_CAST(DateOfService AS DATE), 'yyyy-MM') AS Mth, COUNT(*) AS Cnt
            FROM dbo.ClaimLevelData
            WHERE {claimWhereStr} AND TRY_CAST(DateOfService AS DATE) IS NOT NULL
            GROUP BY FORMAT(TRY_CAST(DateOfService AS DATE), 'yyyy-MM')
            ORDER BY Mth;

            SELECT FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM') AS Mth, COUNT(*) AS Cnt
            FROM dbo.ClaimLevelData
            WHERE {claimWhereStr} AND TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
            GROUP BY FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM')
            ORDER BY Mth;
            """;

        // ?? Average Allowed by Panel x Month ????????????????????????????
        var panelMonthSql = $"""
            SELECT
                LTRIM(RTRIM(PanelName))                                          AS PanelName,
                FORMAT(TRY_CAST(DateOfService AS DATE), 'yyyy-MM')               AS Mth,
                AVG(TRY_CAST(AllowedAmount AS DECIMAL(18,2)))                    AS AvgAllowed
            FROM dbo.ClaimLevelData
            WHERE {claimWhereStr}
              AND PanelName IS NOT NULL AND PanelName <> ''
              AND TRY_CAST(DateOfService AS DATE) IS NOT NULL
            GROUP BY LTRIM(RTRIM(PanelName)), FORMAT(TRY_CAST(DateOfService AS DATE), 'yyyy-MM')
            ORDER BY PanelName, Mth
            """;

        // ?? Line-level KPIs ?????????????????????????????????????????????
        var lineKpiSql = $"""
            SELECT
                COUNT(*)                                                         AS TotalLines,
                ISNULL(SUM(TRY_CAST(ChargeAmount  AS DECIMAL(18,2))), 0)         AS LineTotalCharges,
                ISNULL(SUM(TRY_CAST(TotalPayments AS DECIMAL(18,2))), 0)         AS LineTotalPayments,
                ISNULL(SUM(TRY_CAST(TotalBalance   AS DECIMAL(18,2))), 0)        AS LineTotalBalance
            FROM dbo.LineLevelData
            WHERE {lineWhereStr}
            """;

        // ?? Top CPT by charges ??????????????????????????????????????????
        var topCptSql = $"""
            SELECT TOP 10
                LTRIM(RTRIM(CPTCode))                                             AS CPTCode,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)           AS Charges
            FROM dbo.LineLevelData
            WHERE {lineWhereStr} AND CPTCode IS NOT NULL AND CPTCode <> ''
            GROUP BY LTRIM(RTRIM(CPTCode))
            ORDER BY Charges DESC
            """;

        // ?? Pay status breakdown (line-level) ???????????????????????????
        var payStatusSql = $"""
            SELECT
                ISNULL(NULLIF(LTRIM(RTRIM(PayStatus)),''), 'Unknown') AS PayStatus,
                COUNT(*) AS Cnt
            FROM dbo.LineLevelData
            WHERE {lineWhereStr}
            GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(PayStatus)),''), 'Unknown')
            ORDER BY Cnt DESC
            """;

        // ?? Top CPT detail rows ?????????????????????????????????????????
        var cptDetailSql = $"""
            SELECT TOP 20
                LTRIM(RTRIM(CPTCode))                                             AS CPTCode,
                ISNULL(SUM(TRY_CAST(ChargeAmount      AS DECIMAL(18,2))), 0)      AS Charges,
                ISNULL(SUM(TRY_CAST(AllowedAmount     AS DECIMAL(18,2))), 0)      AS AllowedAmount,
                ISNULL(SUM(TRY_CAST(InsuranceBalance  AS DECIMAL(18,2))), 0)      AS InsuranceBalance,
                ISNULL(SUM(CASE WHEN PayStatus IN ('Paid','Patient Responsibility')
                     THEN TRY_CAST(AllowedAmount AS DECIMAL(18,2)) ELSE 0 END), 0)   AS CollectionAllowed,
                ISNULL(SUM(CASE WHEN PayStatus = 'Denied'
                     THEN TRY_CAST(ChargeAmount  AS DECIMAL(18,2)) ELSE 0 END), 0)   AS DenialCharges,
                ISNULL(SUM(CASE WHEN PayStatus = 'No Response'
                     THEN TRY_CAST(ChargeAmount  AS DECIMAL(18,2)) ELSE 0 END), 0)   AS NoRespCharges
            FROM dbo.LineLevelData
            WHERE {lineWhereStr} AND CPTCode IS NOT NULL AND CPTCode <> ''
            GROUP BY LTRIM(RTRIM(CPTCode))
            ORDER BY Charges DESC
            """;

        // ?? Execute all queries ?????????????????????????????????????????
        var payerNames = new List<string>();
        var payerTypes = new List<string>();
        var panelNames = new List<string>();
        var clinicNames = new List<string>();
        var referringProviders = new List<string>();

        int totalClaims = 0;
        decimal totalCharges = 0, totalPayments = 0, totalBalance = 0;
        decimal collNumerator = 0, denNumerator = 0, adjNumerator = 0, outNumerator = 0;

        var claimStatusRows = new List<ClaimStatusRow>();
        var payerTypePayments = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
        var payerInsights = new List<InsightRow>();
        var panelInsights = new List<InsightRow>();
        var clinicInsights = new List<InsightRow>();
        var refPhysInsights = new List<InsightRow>();
        var dosMonthly = new List<(string, int)>();
        var fbMonthly = new List<(string, int)>();

        // Panel x Month pivot
        var panelMonthRaw = new List<(string Panel, string Month, decimal Avg)>();

        int totalLines = 0;
        decimal lineTotalCharges = 0, lineTotalPayments = 0, lineTotalBalance = 0;
        var topCptCharges = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
        var payStatusBreakdown = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var topCptDetail = new List<CptDetailRow>();

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            // 1. Filter options
            await using (var cmd = new SqlCommand(optionsSql, conn) { CommandTimeout = 60 })
            {
                await using var r = await cmd.ExecuteReaderAsync(ct);
                while (await r.ReadAsync(ct)) payerNames.Add(r.GetString(0));
                await r.NextResultAsync(ct);
                while (await r.ReadAsync(ct)) payerTypes.Add(r.GetString(0));
                await r.NextResultAsync(ct);
                while (await r.ReadAsync(ct)) panelNames.Add(r.GetString(0));
                await r.NextResultAsync(ct);
                while (await r.ReadAsync(ct)) clinicNames.Add(r.GetString(0));
                await r.NextResultAsync(ct);
                while (await r.ReadAsync(ct)) referringProviders.Add(r.GetString(0));
            }

            // 2. Claim KPIs
            await using (var cmd = new SqlCommand(kpiSql, conn) { CommandTimeout = 120 })
            {
                cmd.Parameters.AddRange(CloneParams(parameters));
                await using var r = await cmd.ExecuteReaderAsync(ct);
                if (await r.ReadAsync(ct))
                {
                    totalClaims    = r.GetInt32(r.GetOrdinal("TotalClaims"));
                    totalCharges   = GetDec(r, "TotalCharges");
                    totalPayments  = GetDec(r, "TotalPayments");
                    totalBalance   = GetDec(r, "TotalBalance");
                    collNumerator  = GetDec(r, "CollectionNumerator");
                    denNumerator   = GetDec(r, "DenialNumerator");
                    adjNumerator   = GetDec(r, "AdjustmentNumerator");
                    outNumerator   = GetDec(r, "OutstandingNumerator");
                }
            }

            // 3. Claim status breakdown
            await using (var cmd = new SqlCommand(statusSql, conn) { CommandTimeout = 120 })
            {
                cmd.Parameters.AddRange(CloneParams(parameters));
                await using var r = await cmd.ExecuteReaderAsync(ct);
                while (await r.ReadAsync(ct))
                {
                    claimStatusRows.Add(new ClaimStatusRow(
                        r.GetString(r.GetOrdinal("Status")),
                        r.GetInt32(r.GetOrdinal("Claims")),
                        GetDec(r, "Charges"),
                        GetDec(r, "Payments"),
                        GetDec(r, "Balance")));
                }
            }

            // 4. Payer type payments
            await using (var cmd = new SqlCommand(payerTypeSql, conn) { CommandTimeout = 60 })
            {
                cmd.Parameters.AddRange(CloneParams(parameters));
                await using var r = await cmd.ExecuteReaderAsync(ct);
                while (await r.ReadAsync(ct))
                    payerTypePayments[r.GetString(r.GetOrdinal("PayerType"))] = GetDec(r, "TotalPayments");
            }

            // 5. Insight breakdowns (4 result sets)
            await using (var cmd = new SqlCommand(insightsSql, conn) { CommandTimeout = 120 })
            {
                cmd.Parameters.AddRange(CloneParams(parameters));
                await using var r = await cmd.ExecuteReaderAsync(ct);
                ReadInsightRows(r, payerInsights);
                await r.NextResultAsync(ct);
                ReadInsightRows(r, panelInsights);
                await r.NextResultAsync(ct);
                ReadInsightRows(r, clinicInsights);
                await r.NextResultAsync(ct);
                ReadInsightRows(r, refPhysInsights);
            }

            // 6. Monthly trends (2 result sets)
            await using (var cmd = new SqlCommand(monthlySql, conn) { CommandTimeout = 60 })
            {
                cmd.Parameters.AddRange(CloneParams(parameters));
                await using var r = await cmd.ExecuteReaderAsync(ct);
                while (await r.ReadAsync(ct))
                {
                    var mth = r.IsDBNull(0) ? null : r.GetString(0);
                    if (!string.IsNullOrWhiteSpace(mth))
                        dosMonthly.Add((mth, r.GetInt32(1)));
                }
                await r.NextResultAsync(ct);
                while (await r.ReadAsync(ct))
                {
                    var mth = r.IsDBNull(0) ? null : r.GetString(0);
                    if (!string.IsNullOrWhiteSpace(mth))
                        fbMonthly.Add((mth, r.GetInt32(1)));
                }
            }

            // 7. Panel x Month pivot
            await using (var cmd = new SqlCommand(panelMonthSql, conn) { CommandTimeout = 120 })
            {
                cmd.Parameters.AddRange(CloneParams(parameters));
                await using var r = await cmd.ExecuteReaderAsync(ct);
                while (await r.ReadAsync(ct))
                {
                    var panel = r.GetString(r.GetOrdinal("PanelName"));
                    var mth = r.IsDBNull(r.GetOrdinal("Mth")) ? null : r.GetString(r.GetOrdinal("Mth"));
                    var avg = GetDec(r, "AvgAllowed");
                    if (!string.IsNullOrWhiteSpace(mth))
                        panelMonthRaw.Add((panel, mth, Math.Round(avg, 0)));
                }
            }

            // 8. Line-level KPIs
            await using (var cmd = new SqlCommand(lineKpiSql, conn) { CommandTimeout = 120 })
            {
                cmd.Parameters.AddRange(CloneParams(parameters));
                await using var r = await cmd.ExecuteReaderAsync(ct);
                if (await r.ReadAsync(ct))
                {
                    totalLines        = r.GetInt32(r.GetOrdinal("TotalLines"));
                    lineTotalCharges  = GetDec(r, "LineTotalCharges");
                    lineTotalPayments = GetDec(r, "LineTotalPayments");
                    lineTotalBalance  = GetDec(r, "LineTotalBalance");
                }
            }

            // 9. Top CPT by charges
            await using (var cmd = new SqlCommand(topCptSql, conn) { CommandTimeout = 60 })
            {
                cmd.Parameters.AddRange(CloneParams(parameters));
                await using var r = await cmd.ExecuteReaderAsync(ct);
                while (await r.ReadAsync(ct))
                    topCptCharges[r.GetString(r.GetOrdinal("CPTCode"))] = GetDec(r, "Charges");
            }

            // 10. Pay status breakdown
            await using (var cmd = new SqlCommand(payStatusSql, conn) { CommandTimeout = 60 })
            {
                cmd.Parameters.AddRange(CloneParams(parameters));
                await using var r = await cmd.ExecuteReaderAsync(ct);
                while (await r.ReadAsync(ct))
                    payStatusBreakdown[r.GetString(r.GetOrdinal("PayStatus"))] = r.GetInt32(r.GetOrdinal("Cnt"));
            }

            // 11. CPT detail rows
            await using (var cmd = new SqlCommand(cptDetailSql, conn) { CommandTimeout = 120 })
            {
                cmd.Parameters.AddRange(CloneParams(parameters));
                await using var r = await cmd.ExecuteReaderAsync(ct);
                while (await r.ReadAsync(ct))
                {
                    var charges = GetDec(r, "Charges");
                    var collAllowed = GetDec(r, "CollectionAllowed");
                    var denCharges = GetDec(r, "DenialCharges");
                    var noResp = GetDec(r, "NoRespCharges");

                    topCptDetail.Add(new CptDetailRow(
                        CPTCode: r.GetString(r.GetOrdinal("CPTCode")),
                        Charges: charges,
                        AllowedAmount: GetDec(r, "AllowedAmount"),
                        InsuranceBalance: GetDec(r, "InsuranceBalance"),
                        CollectionRate: charges == 0 ? 0 : Math.Round(collAllowed / charges * 100, 1),
                        DenialRate: charges == 0 ? 0 : Math.Round(denCharges / charges * 100, 1),
                        NoResponseRate: charges == 0 ? 0 : Math.Round(noResp / charges * 100, 1)));
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Dashboard query failed for lab '{LabName}'.", labName);
            throw;
        }

        // ?? Build Panel x Month pivot ???????????????????????????????????
        var avgMonths = panelMonthRaw
            .Select(x => x.Month).Distinct().OrderBy(m => m).ToList();

        var avgAllowedByPanelMonth = panelMonthRaw
            .GroupBy(x => x.Panel, StringComparer.OrdinalIgnoreCase)
            .Select(g => new
            {
                PanelName = g.First().Panel,
                TotalAvg = g.Sum(x => x.Avg),
                AvgByMonth = g.GroupBy(x => x.Month)
                    .ToDictionary(mg => mg.Key, mg => Math.Round(mg.Average(x => x.Avg), 0)),
            })
            .OrderByDescending(x => x.TotalAvg)
            .Take(10)
            .OrderBy(x => x.PanelName, StringComparer.OrdinalIgnoreCase)
            .Select(x => new PanelMonthRow
            {
                PanelName = x.PanelName,
                AvgByMonth = x.AvgByMonth,
            })
            .ToList();

        return new DashboardResult(
            payerNames, payerTypes, panelNames, clinicNames, referringProviders,
            totalClaims, totalCharges, totalPayments, totalBalance,
            collNumerator, denNumerator, adjNumerator, outNumerator,
            claimStatusRows, payerTypePayments,
            payerInsights, panelInsights, clinicInsights, refPhysInsights,
            dosMonthly, fbMonthly,
            avgMonths, avgAllowedByPanelMonth,
            totalLines, lineTotalCharges, lineTotalPayments, lineTotalBalance,
            topCptCharges, payStatusBreakdown, topCptDetail);
    }

    // ?? Helpers ??????????????????????????????????????????????????????????

    private static decimal GetDec(SqlDataReader r, string col)
    {
        var ord = r.GetOrdinal(col);
        return r.IsDBNull(ord) ? 0m : r.GetDecimal(ord);
    }

    private static void ReadInsightRows(SqlDataReader r, List<InsightRow> list)
    {
        while (r.Read())
        {
            list.Add(new InsightRow(
                r.GetString(r.GetOrdinal("Label")),
                r.GetInt32(r.GetOrdinal("Claims")),
                GetDec(r, "Charges"),
                GetDec(r, "Payments"),
                GetDec(r, "Balance")));
        }
    }

    private static void AddFilterClause(List<string> where, List<SqlParameter> parms,
        string column, string paramName, string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        where.Add($"LTRIM(RTRIM({column})) = {paramName}");
        parms.Add(new SqlParameter(paramName, value.Trim()));
    }

    private static void AddDateRangeClause(List<string> where, List<SqlParameter> parms,
        string column, string fromParam, string toParam, DateOnly? from, DateOnly? to)
    {
        if (from.HasValue)
        {
            where.Add($"TRY_CAST({column} AS DATE) >= {fromParam}");
            parms.Add(new SqlParameter(fromParam, SqlDbType.Date)
                { Value = from.Value.ToDateTime(TimeOnly.MinValue) });
        }
        if (to.HasValue)
        {
            where.Add($"TRY_CAST({column} AS DATE) <= {toParam}");
            parms.Add(new SqlParameter(toParam, SqlDbType.Date)
                { Value = to.Value.ToDateTime(TimeOnly.MinValue) });
        }
    }

    private static SqlParameter[] CloneParams(List<SqlParameter> source)
    {
        var cloned = new SqlParameter[source.Count];
        for (var i = 0; i < source.Count; i++)
            cloned[i] = new SqlParameter(source[i].ParameterName, source[i].Value);
        return cloned;
    }
}
