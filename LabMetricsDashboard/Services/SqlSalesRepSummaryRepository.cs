using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Sales Rep Summary data from <c>dbo.ClaimLevelData</c> using an inline
/// GROUP BY query. No stored procedure dependency.
/// </summary>
public sealed class SqlSalesRepSummaryRepository : ISalesRepSummaryRepository
{
    private readonly ILogger<SqlSalesRepSummaryRepository> _logger;

    public SqlSalesRepSummaryRepository(ILogger<SqlSalesRepSummaryRepository> logger)
        => _logger = logger;

    public async Task<SalesRepSummaryResult> GetSalesRepSummaryAsync(
        string connectionString,
        string labName,
        List<string>? filterSalesRepNames = null,
        List<string>? filterClinicNames = null,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(labName);

        // Build WHERE clauses dynamically with IN for multi-select
        var whereClauses = new List<string> { "LabName = @LabName", "SalesRepName IS NOT NULL", "SalesRepName <> ''" };
        var parameters = new List<SqlParameter> { new("@LabName", labName) };

        AddInClause(whereClauses, parameters, "SalesRepName", "@sr", filterSalesRepNames);
        AddInClause(whereClauses, parameters, "ClinicName", "@cn", filterClinicNames);
        AddInClause(whereClauses, parameters, "PayerName", "@pn", filterPayerNames);
        AddInClause(whereClauses, parameters, "PanelName", "@pl", filterPanelNames);
        AddDateRangeClause(whereClauses, parameters, "DateOfService", "@dosFrom", "@dosTo", filterDosFrom, filterDosTo);
        AddDateRangeClause(whereClauses, parameters, "FirstBilledDate", "@fbFrom", "@fbTo", filterFirstBillFrom, filterFirstBillTo);

        var whereClause = string.Join(" AND ", whereClauses);

        var sql = $"""
            SELECT
                SalesRepName,
                COUNT(*)                                                                    AS BilledClaimCount,
                SUM(CASE WHEN ClaimStatus IN ('Fully Paid','Partially Paid',
                             'Patient Responsibility','Patient Payment') THEN 1 ELSE 0 END) AS PaidClaimCount,
                SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied')
                         THEN 1 ELSE 0 END)                                                 AS DeniedClaimCount,
                SUM(CASE WHEN ClaimStatus = 'No Response' THEN 1 ELSE 0 END)                AS OutstandingClaimCount,

                SUM(TRY_CAST(ChargeAmount       AS DECIMAL(18,2)))                          AS TotalBilledCharges,
                SUM(TRY_CAST(AllowedAmount      AS DECIMAL(18,2)))                          AS TotalAllowedAmount,
                SUM(TRY_CAST(InsurancePayment   AS DECIMAL(18,2)))                          AS TotalInsurancePaidAmount,
                SUM(TRY_CAST(PatientPayment     AS DECIMAL(18,2)))                          AS TotalPatientResponsibility,
                SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied')
                         THEN TRY_CAST(InsuranceBalance AS DECIMAL(18,2)) ELSE 0 END)       AS TotalDeniedCharges,
                SUM(CASE WHEN ClaimStatus = 'No Response'
                         THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2)) ELSE 0 END)           AS TotalOutstandingCharges,

                AVG(TRY_CAST(AllowedAmount      AS DECIMAL(18,2)))                          AS AverageAllowedAmount,
                AVG(TRY_CAST(InsurancePayment   AS DECIMAL(18,2)))                          AS AverageInsurancePaidAmount
            FROM dbo.ClaimLevelData
            WHERE {whereClause}
            GROUP BY SalesRepName
            ORDER BY BilledClaimCount DESC
            """;

        // Query for distinct filter option lists (unfiltered, lab-scoped)
        const string optionsSql = """
            SELECT DISTINCT SalesRepName FROM dbo.ClaimLevelData WHERE LabName = @LabName AND SalesRepName IS NOT NULL AND SalesRepName <> '' ORDER BY SalesRepName;
            SELECT DISTINCT ClinicName   FROM dbo.ClaimLevelData WHERE LabName = @LabName AND ClinicName   IS NOT NULL AND ClinicName   <> '' ORDER BY ClinicName;
            SELECT DISTINCT PayerName    FROM dbo.ClaimLevelData WHERE LabName = @LabName AND PayerName    IS NOT NULL AND PayerName    <> '' ORDER BY PayerName;
            SELECT DISTINCT PanelName    FROM dbo.ClaimLevelData WHERE LabName = @LabName AND PanelName    IS NOT NULL AND PanelName    <> '' ORDER BY PanelName;
            """;

        // Top collected breakdown queries (top 10 by InsurancePayment, grouped by each dimension)
        var topCollectedSql = BuildTopCollectedSql("SalesRepName", whereClause)
            + BuildTopCollectedSql("ClinicName", whereClause)
            + BuildTopCollectedSql("PayerName", whereClause)
            + BuildTopCollectedSql("PanelName", whereClause);

        // Top denied breakdown queries (top 10 by denied InsuranceBalance, grouped by each dimension)
        var topDeniedSql = BuildTopDeniedSql("SalesRepName", whereClause)
            + BuildTopDeniedSql("ClinicName", whereClause)
            + BuildTopDeniedSql("PayerName", whereClause)
            + BuildTopDeniedSql("PanelName", whereClause);

        var rows = new List<SalesRepSummaryRow>();
        var salesRepNames = new List<string>();
        var clinicNames = new List<string>();
        var payerNames = new List<string>();
        var panelNames = new List<string>();
        var topCollectedSalesReps = new List<TopCollectedItem>();
        var topCollectedClinics = new List<TopCollectedItem>();
        var topCollectedPayers = new List<TopCollectedItem>();
        var topCollectedPanels = new List<TopCollectedItem>();
        var topDeniedSalesReps = new List<TopDeniedItem>();
        var topDeniedClinics = new List<TopDeniedItem>();
        var topDeniedPayers = new List<TopDeniedItem>();
        var topDeniedPanels = new List<TopDeniedItem>();
        var drilldownCollected = new List<DrilldownCollectedGroup>();
        var drilldownDenied = new List<DrilldownDeniedGroup>();

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            // 1. Fetch filter option lists
            await using (var optCmd = new SqlCommand(optionsSql, conn) { CommandTimeout = 60 })
            {
                optCmd.Parameters.AddWithValue("@LabName", labName);
                await using var optReader = await optCmd.ExecuteReaderAsync(ct);

                while (await optReader.ReadAsync(ct))
                    salesRepNames.Add(optReader.GetString(0));

                await optReader.NextResultAsync(ct);
                while (await optReader.ReadAsync(ct))
                    clinicNames.Add(optReader.GetString(0));

                await optReader.NextResultAsync(ct);
                while (await optReader.ReadAsync(ct))
                    payerNames.Add(optReader.GetString(0));

                await optReader.NextResultAsync(ct);
                while (await optReader.ReadAsync(ct))
                    panelNames.Add(optReader.GetString(0));
            }

            // 2. Fetch aggregated rows
            await using (var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 })
            {
                cmd.Parameters.AddRange(parameters.ToArray());

                await using var reader = await cmd.ExecuteReaderAsync(ct);
                while (await reader.ReadAsync(ct))
                {
                    rows.Add(new SalesRepSummaryRow
                    {
                        SalesRepName                = reader.GetString("SalesRepName"),
                        BilledClaimCount            = reader.GetInt32("BilledClaimCount"),
                        PaidClaimCount              = reader.GetInt32("PaidClaimCount"),
                        DeniedClaimCount            = reader.GetInt32("DeniedClaimCount"),
                        OutstandingClaimCount       = reader.GetInt32("OutstandingClaimCount"),
                        TotalBilledCharges          = GetDecimalSafe(reader, "TotalBilledCharges"),
                        TotalAllowedAmount          = GetDecimalSafe(reader, "TotalAllowedAmount"),
                        TotalInsurancePaidAmount    = GetDecimalSafe(reader, "TotalInsurancePaidAmount"),
                        TotalPatientResponsibility  = GetDecimalSafe(reader, "TotalPatientResponsibility"),
                        TotalDeniedCharges          = GetDecimalSafe(reader, "TotalDeniedCharges"),
                        TotalOutstandingCharges     = GetDecimalSafe(reader, "TotalOutstandingCharges"),
                        AverageAllowedAmount        = GetDecimalSafe(reader, "AverageAllowedAmount"),
                        AverageInsurancePaidAmount  = GetDecimalSafe(reader, "AverageInsurancePaidAmount"),
                    });
                }
            }

            // 3. Fetch top collected breakdowns
            await using (var topCmd = new SqlCommand(topCollectedSql, conn) { CommandTimeout = 120 })
            {
                topCmd.Parameters.AddRange(CloneParameters(parameters));
                await using var topReader = await topCmd.ExecuteReaderAsync(ct);

                ReadTopCollectedItems(topReader, topCollectedSalesReps, ct);
                await topReader.NextResultAsync(ct);
                ReadTopCollectedItems(topReader, topCollectedClinics, ct);
                await topReader.NextResultAsync(ct);
                ReadTopCollectedItems(topReader, topCollectedPayers, ct);
                await topReader.NextResultAsync(ct);
                ReadTopCollectedItems(topReader, topCollectedPanels, ct);
            }

            // 4. Fetch top denied breakdowns
            await using (var denCmd = new SqlCommand(topDeniedSql, conn) { CommandTimeout = 120 })
            {
                denCmd.Parameters.AddRange(CloneParameters(parameters));
                await using var denReader = await denCmd.ExecuteReaderAsync(ct);

                ReadTopDeniedItems(denReader, topDeniedSalesReps, ct);
                await denReader.NextResultAsync(ct);
                ReadTopDeniedItems(denReader, topDeniedClinics, ct);
                await denReader.NextResultAsync(ct);
                ReadTopDeniedItems(denReader, topDeniedPayers, ct);
                await denReader.NextResultAsync(ct);
                ReadTopDeniedItems(denReader, topDeniedPanels, ct);
            }

            // 5. Fetch drilldown data for top collected sales reps
            drilldownCollected = await FetchCollectedDrilldownAsync(
                conn, whereClause, parameters,
                topCollectedSalesReps.Select(x => x.Name).ToList(), ct);

            // 6. Fetch drilldown data for top denied sales reps
            drilldownDenied = await FetchDeniedDrilldownAsync(
                conn, whereClause, parameters,
                topDeniedSalesReps.Select(x => x.Name).ToList(), ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to load sales rep summary for lab '{LabName}'.", labName);
            throw;
        }

        return new SalesRepSummaryResult(
            rows, salesRepNames, clinicNames, payerNames, panelNames,
            topCollectedSalesReps, topCollectedClinics, topCollectedPayers, topCollectedPanels,
            topDeniedSalesReps, topDeniedClinics, topDeniedPayers, topDeniedPanels,
            drilldownCollected, drilldownDenied);
    }

    /// <summary>
    /// Fetches per-sales-rep drilldown data for the "Highly Collected" section.
    /// For each given sales rep name, queries breakdowns by Clinic, Payer, and Panel.
    /// </summary>
    private static async Task<List<DrilldownCollectedGroup>> FetchCollectedDrilldownAsync(
        SqlConnection conn,
        string whereClause,
        List<SqlParameter> baseParameters,
        List<string> salesRepNames,
        CancellationToken ct)
    {
        if (salesRepNames.Count == 0)
            return [];

        var results = new List<DrilldownCollectedGroup>(salesRepNames.Count);

        foreach (var repName in salesRepNames)
        {
            var repWhere = $"{whereClause} AND SalesRepName = @DrillRep";

            var sql = BuildDrilldownCollectedSql("ClinicName", repWhere)
                    + BuildDrilldownCollectedSql("PayerName", repWhere)
                    + BuildDrilldownCollectedSql("PanelName", repWhere);

            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
            cmd.Parameters.AddRange(CloneParameters(baseParameters));
            cmd.Parameters.AddWithValue("@DrillRep", repName);

            var clinics = new List<TopCollectedItem>();
            var payers = new List<TopCollectedItem>();
            var panels = new List<TopCollectedItem>();

            await using var reader = await cmd.ExecuteReaderAsync(ct);
            ReadTopCollectedItems(reader, clinics, ct);
            await reader.NextResultAsync(ct);
            ReadTopCollectedItems(reader, payers, ct);
            await reader.NextResultAsync(ct);
            ReadTopCollectedItems(reader, panels, ct);

            results.Add(new DrilldownCollectedGroup
            {
                Parent = new TopCollectedItem { Name = repName },
                Clinics = clinics,
                Payers = payers,
                Panels = panels,
            });
        }

        return results;
    }

    /// <summary>
    /// Fetches per-sales-rep drilldown data for the "Highly Denied" section.
    /// For each given sales rep name, queries breakdowns by Clinic, Payer, and Panel.
    /// </summary>
    private static async Task<List<DrilldownDeniedGroup>> FetchDeniedDrilldownAsync(
        SqlConnection conn,
        string whereClause,
        List<SqlParameter> baseParameters,
        List<string> salesRepNames,
        CancellationToken ct)
    {
        if (salesRepNames.Count == 0)
            return [];

        var results = new List<DrilldownDeniedGroup>(salesRepNames.Count);

        foreach (var repName in salesRepNames)
        {
            var repWhere = $"{whereClause} AND SalesRepName = @DrillRep";

            var sql = BuildDrilldownDeniedSql("ClinicName", repWhere)
                    + BuildDrilldownDeniedSql("PayerName", repWhere)
                    + BuildDrilldownDeniedSql("PanelName", repWhere);

            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
            cmd.Parameters.AddRange(CloneParameters(baseParameters));
            cmd.Parameters.AddWithValue("@DrillRep", repName);

            var clinics = new List<TopDeniedItem>();
            var payers = new List<TopDeniedItem>();
            var panels = new List<TopDeniedItem>();

            await using var reader = await cmd.ExecuteReaderAsync(ct);
            ReadTopDeniedItems(reader, clinics, ct);
            await reader.NextResultAsync(ct);
            ReadTopDeniedItems(reader, payers, ct);
            await reader.NextResultAsync(ct);
            ReadTopDeniedItems(reader, panels, ct);

            results.Add(new DrilldownDeniedGroup
            {
                Parent = new TopDeniedItem { Name = repName },
                Clinics = clinics,
                Payers = payers,
                Panels = panels,
            });
        }

        return results;
    }

    private static string BuildDrilldownCollectedSql(string groupColumn, string whereClause)
    {
        return $"""

            SELECT TOP 10
                {groupColumn}                                                              AS Name,
                COUNT(*)                                                                   AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))), 0)                AS TotalBilledCharges,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)                AS TotalInsurancePaid
            FROM dbo.ClaimLevelData
            WHERE {whereClause} AND {groupColumn} IS NOT NULL AND {groupColumn} <> ''
            GROUP BY {groupColumn}
            ORDER BY TotalInsurancePaid DESC;
            """;
    }

    private static string BuildDrilldownDeniedSql(string groupColumn, string whereClause)
    {
        return $"""

            SELECT TOP 10
                {groupColumn}                                                              AS Name,
                SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied')
                         THEN 1 ELSE 0 END)                                                AS DeniedClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                    AS TotalBilledCharges,
                ISNULL(SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied')
                         THEN TRY_CAST(InsuranceBalance AS DECIMAL(18,2)) ELSE 0 END), 0)  AS TotalDeniedCharges
            FROM dbo.ClaimLevelData
            WHERE {whereClause} AND {groupColumn} IS NOT NULL AND {groupColumn} <> ''
            GROUP BY {groupColumn}
            HAVING SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied') THEN 1 ELSE 0 END) > 0
            ORDER BY TotalDeniedCharges DESC;
            """;
    }

    private static decimal GetDecimalSafe(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? 0m : reader.GetDecimal(ordinal);
    }

    private static string BuildTopCollectedSql(string groupColumn, string whereClause)
    {
        // Reuse the same WHERE clause but add a non-blank guard on the group column
        return $"""

            SELECT TOP 10
                {groupColumn}                                                              AS Name,
                COUNT(*)                                                                   AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))), 0)                AS TotalBilledCharges,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)                AS TotalInsurancePaid
            FROM dbo.ClaimLevelData
            WHERE {whereClause} AND {groupColumn} IS NOT NULL AND {groupColumn} <> ''
            GROUP BY {groupColumn}
            ORDER BY TotalInsurancePaid DESC;
            """;
    }

    private static string BuildTopDeniedSql(string groupColumn, string whereClause)
    {
        return $"""

            SELECT TOP 10
                {groupColumn}                                                              AS Name,
                SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied')
                         THEN 1 ELSE 0 END)                                                AS DeniedClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                    AS TotalBilledCharges,
                ISNULL(SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied')
                         THEN TRY_CAST(InsuranceBalance AS DECIMAL(18,2)) ELSE 0 END), 0)  AS TotalDeniedCharges
            FROM dbo.ClaimLevelData
            WHERE {whereClause} AND {groupColumn} IS NOT NULL AND {groupColumn} <> ''
            GROUP BY {groupColumn}
            HAVING SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied') THEN 1 ELSE 0 END) > 0
            ORDER BY TotalDeniedCharges DESC;
            """;
    }

    private static void ReadTopCollectedItems(SqlDataReader reader, List<TopCollectedItem> list, CancellationToken ct)
    {
        while (reader.Read())
        {
            var billed = GetDecimalSafe(reader, "TotalBilledCharges");
            var paid = GetDecimalSafe(reader, "TotalInsurancePaid");

            list.Add(new TopCollectedItem
            {
                Name = reader.GetString("Name"),
                ClaimCount = reader.GetInt32("ClaimCount"),
                TotalBilledCharges = billed,
                TotalInsurancePaid = paid,
                CollectionPct = billed == 0 ? 0 : Math.Round(paid / billed * 100, 1),
            });
        }
    }

    private static void ReadTopDeniedItems(SqlDataReader reader, List<TopDeniedItem> list, CancellationToken ct)
    {
        while (reader.Read())
        {
            var billed = GetDecimalSafe(reader, "TotalBilledCharges");
            var denied = GetDecimalSafe(reader, "TotalDeniedCharges");

            list.Add(new TopDeniedItem
            {
                Name = reader.GetString("Name"),
                DeniedClaimCount = reader.GetInt32("DeniedClaimCount"),
                TotalBilledCharges = billed,
                TotalDeniedCharges = denied,
                DenialPct = billed == 0 ? 0 : Math.Round(denied / billed * 100, 1),
            });
        }
    }

    private static SqlParameter[] CloneParameters(List<SqlParameter> source)
    {
        var cloned = new SqlParameter[source.Count];
        for (var i = 0; i < source.Count; i++)
            cloned[i] = new SqlParameter(source[i].ParameterName, source[i].Value);
        return cloned;
    }

    /// <summary>
    /// Adds a parameterized IN clause for multi-select filters.
    /// </summary>
    private static void AddInClause(
        List<string> whereClauses,
        List<SqlParameter> parameters,
        string columnName,
        string paramPrefix,
        List<string>? values)
    {
        if (values is not { Count: > 0 })
            return;

        var paramNames = new List<string>(values.Count);
        for (var i = 0; i < values.Count; i++)
        {
            var name = $"{paramPrefix}{i}";
            paramNames.Add(name);
            parameters.Add(new SqlParameter(name, values[i]));
        }

        whereClauses.Add($"{columnName} IN ({string.Join(", ", paramNames)})");
    }

    /// <summary>
    /// Adds parameterized date range clauses (>= from, <= to) using TRY_CAST to DATE.
    /// </summary>
    private static void AddDateRangeClause(
        List<string> whereClauses,
        List<SqlParameter> parameters,
        string columnName,
        string fromParamName,
        string toParamName,
        DateOnly? from,
        DateOnly? to)
    {
        if (from.HasValue)
        {
            whereClauses.Add($"TRY_CAST({columnName} AS DATE) >= {fromParamName}");
            parameters.Add(new SqlParameter(fromParamName, System.Data.SqlDbType.Date) { Value = from.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (to.HasValue)
        {
            whereClauses.Add($"TRY_CAST({columnName} AS DATE) <= {toParamName}");
            parameters.Add(new SqlParameter(toParamName, System.Data.SqlDbType.Date) { Value = to.Value.ToDateTime(TimeOnly.MinValue) });
        }
    }
}
