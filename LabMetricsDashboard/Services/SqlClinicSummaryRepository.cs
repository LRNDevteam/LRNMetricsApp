using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Clinic Summary data from <c>dbo.ClaimLevelData</c> using an inline
/// GROUP BY query. No stored procedure dependency.
/// </summary>
public sealed class SqlClinicSummaryRepository : IClinicSummaryRepository
{
    private readonly ILogger<SqlClinicSummaryRepository> _logger;

    public SqlClinicSummaryRepository(ILogger<SqlClinicSummaryRepository> logger)
        => _logger = logger;

    public async Task<ClinicSummaryResult> GetClinicSummaryAsync(
        string connectionString,
        string labName,
        List<string>? filterClinicNames = null,
        List<string>? filterSalesRepNames = null,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        // Build WHERE clauses dynamically with IN for multi-select
        var whereClauses = new List<string> { "ClinicName IS NOT NULL", "ClinicName <> ''" };
        var parameters = new List<SqlParameter>();

        AddInClause(whereClauses, parameters, "ClinicName", "@cn", filterClinicNames);
        AddInClause(whereClauses, parameters, "SalesRepName", "@sr", filterSalesRepNames);
        AddInClause(whereClauses, parameters, "PayerName", "@pn", filterPayerNames);
        AddInClause(whereClauses, parameters, "PanelName", "@pl", filterPanelNames);
        AddDateRangeClause(whereClauses, parameters, "DateOfService", "@dosFrom", "@dosTo", filterDosFrom, filterDosTo);
        AddDateRangeClause(whereClauses, parameters, "FirstBilledDate", "@fbFrom", "@fbTo", filterFirstBillFrom, filterFirstBillTo);

        var whereClause = string.Join(" AND ", whereClauses);

        var sql = $"""
            SELECT
                ClinicName,
                COUNT(*)                                                                    AS BilledClaimCount,
                SUM(CASE WHEN ClaimStatus IN ('Fully Paid','Partially Paid',
                             'Patient Responsibility','Patient Payment') THEN 1 ELSE 0 END) AS PaidClaimCount,
                SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied')
                         THEN 1 ELSE 0 END)                                                 AS DeniedClaimCount,
                SUM(CASE WHEN ClaimStatus = 'No Response' THEN 1 ELSE 0 END)                AS OutstandingClaimCount,

                SUM(TRY_CAST(ChargeAmount       AS DECIMAL(18,2)))                          AS TotalBilledCharges,
                SUM(CASE WHEN ClaimStatus IN ('Fully Paid','Partially Paid',
                             'Patient Responsibility','Patient Payment')
                         THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2)) ELSE 0 END)           AS TotalBilledChargeOnPaidClaim,
                SUM(TRY_CAST(AllowedAmount      AS DECIMAL(18,2)))                          AS TotalAllowedAmount,
                SUM(TRY_CAST(InsurancePayment   AS DECIMAL(18,2)))                          AS TotalInsurancePaidAmount,
                SUM(TRY_CAST(PatientPayment     AS DECIMAL(18,2)))                          AS TotalPatientResponsibility,
                SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied')
                         THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2)) ELSE 0 END)           AS TotalDeniedCharges,
                SUM(CASE WHEN ClaimStatus = 'No Response'
                         THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2)) ELSE 0 END)           AS TotalOutstandingCharges,

                AVG(TRY_CAST(AllowedAmount      AS DECIMAL(18,2)))                          AS AverageAllowedAmount,
                AVG(TRY_CAST(InsurancePayment   AS DECIMAL(18,2)))                          AS AverageInsurancePaidAmount
            FROM dbo.ClaimLevelData
            WHERE {whereClause}
            GROUP BY ClinicName
            ORDER BY BilledClaimCount DESC
            """;

        // Query for distinct filter option lists (unfiltered)
        const string optionsSql = """
            SELECT DISTINCT ClinicName   FROM dbo.ClaimLevelData WHERE ClinicName   IS NOT NULL AND ClinicName   <> '' ORDER BY ClinicName;
            SELECT DISTINCT SalesRepName FROM dbo.ClaimLevelData WHERE SalesRepName IS NOT NULL AND SalesRepName <> '' ORDER BY SalesRepName;
            SELECT DISTINCT PayerName    FROM dbo.ClaimLevelData WHERE PayerName    IS NOT NULL AND PayerName    <> '' ORDER BY PayerName;
            SELECT DISTINCT PanelName    FROM dbo.ClaimLevelData WHERE PanelName    IS NOT NULL AND PanelName    <> '' ORDER BY PanelName;
            """;

        // Top collected breakdown queries (top 10 by InsurancePayment, grouped by each dimension)
        var topCollectedSql = BuildTopCollectedSql("ClinicName", whereClause)
            + BuildTopCollectedSql("SalesRepName", whereClause)
            + BuildTopCollectedSql("PayerName", whereClause)
            + BuildTopCollectedSql("PanelName", whereClause);

        // Top denied breakdown queries (top 10 by denied InsuranceBalance, grouped by each dimension)
        var topDeniedSql = BuildTopDeniedSql("ClinicName", whereClause)
            + BuildTopDeniedSql("SalesRepName", whereClause)
            + BuildTopDeniedSql("PayerName", whereClause)
            + BuildTopDeniedSql("PanelName", whereClause);

        var rows = new List<ClinicSummaryRow>();
        var clinicNames = new List<string>();
        var salesRepNames = new List<string>();
        var payerNames = new List<string>();
        var panelNames = new List<string>();
        var topCollectedClinics = new List<TopCollectedItem>();
        var topCollectedSalesReps = new List<TopCollectedItem>();
        var topCollectedPayers = new List<TopCollectedItem>();
        var topCollectedPanels = new List<TopCollectedItem>();
        var topDeniedClinics = new List<TopDeniedItem>();
        var topDeniedSalesReps = new List<TopDeniedItem>();
        var topDeniedPayers = new List<TopDeniedItem>();
        var topDeniedPanels = new List<TopDeniedItem>();

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            // 1. Fetch filter option lists
            await using (var optCmd = new SqlCommand(optionsSql, conn) { CommandTimeout = 60 })
            {
                await using var optReader = await optCmd.ExecuteReaderAsync(ct);

                while (await optReader.ReadAsync(ct))
                    clinicNames.Add(optReader.GetString(0));

                await optReader.NextResultAsync(ct);
                while (await optReader.ReadAsync(ct))
                    salesRepNames.Add(optReader.GetString(0));

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
                    rows.Add(new ClinicSummaryRow
                    {
                        ClinicName                  = reader.GetString("ClinicName"),
                        BilledClaimCount            = reader.GetInt32("BilledClaimCount"),
                        PaidClaimCount              = reader.GetInt32("PaidClaimCount"),
                        DeniedClaimCount            = reader.GetInt32("DeniedClaimCount"),
                        OutstandingClaimCount       = reader.GetInt32("OutstandingClaimCount"),
                        TotalBilledCharges          = GetDecimalSafe(reader, "TotalBilledCharges"),
                        TotalBilledChargeOnPaidClaim = GetDecimalSafe(reader, "TotalBilledChargeOnPaidClaim"),
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

                ReadTopCollectedItems(topReader, topCollectedClinics);
                await topReader.NextResultAsync(ct);
                ReadTopCollectedItems(topReader, topCollectedSalesReps);
                await topReader.NextResultAsync(ct);
                ReadTopCollectedItems(topReader, topCollectedPayers);
                await topReader.NextResultAsync(ct);
                ReadTopCollectedItems(topReader, topCollectedPanels);
            }

            // 4. Fetch top denied breakdowns
            await using (var denCmd = new SqlCommand(topDeniedSql, conn) { CommandTimeout = 120 })
            {
                denCmd.Parameters.AddRange(CloneParameters(parameters));
                await using var denReader = await denCmd.ExecuteReaderAsync(ct);

                ReadTopDeniedItems(denReader, topDeniedClinics);
                await denReader.NextResultAsync(ct);
                ReadTopDeniedItems(denReader, topDeniedSalesReps);
                await denReader.NextResultAsync(ct);
                ReadTopDeniedItems(denReader, topDeniedPayers);
                await denReader.NextResultAsync(ct);
                ReadTopDeniedItems(denReader, topDeniedPanels);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to load clinic summary for lab '{LabName}'.", labName);
            throw;
        }

        return new ClinicSummaryResult(
            rows, clinicNames, salesRepNames, payerNames, panelNames,
            topCollectedClinics, topCollectedSalesReps, topCollectedPayers, topCollectedPanels,
            topDeniedClinics, topDeniedSalesReps, topDeniedPayers, topDeniedPanels);
    }

    private static decimal GetDecimalSafe(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? 0m : reader.GetDecimal(ordinal);
    }

    private static int GetInt32Safe(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? 0 : reader.GetInt32(ordinal);
    }

    private static string BuildTopCollectedSql(string groupColumn, string whereClause)
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

    private static void ReadTopCollectedItems(SqlDataReader reader, List<TopCollectedItem> list)
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

    private static void ReadTopDeniedItems(SqlDataReader reader, List<TopDeniedItem> list)
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

    /// <inheritdoc />
    public async Task<ClinicPanelStatusViewModel> GetClinicPanelStatusAsync(
        string connectionString,
        string labName,
        List<string>? filterClinicNames = null,
        List<string>? filterSalesRepNames = null,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereClauses = new List<string> { "ClinicName IS NOT NULL", "ClinicName <> ''" };
        var parameters = new List<SqlParameter>();
        AddInClause(whereClauses, parameters, "ClinicName", "@cn", filterClinicNames);
        AddInClause(whereClauses, parameters, "SalesRepName", "@sr", filterSalesRepNames);
        AddInClause(whereClauses, parameters, "PayerName", "@pn", filterPayerNames);
        AddInClause(whereClauses, parameters, "PanelName", "@pl", filterPanelNames);
        AddDateRangeClause(whereClauses, parameters, "DateOfService", "@dosFrom", "@dosTo", filterDosFrom, filterDosTo);
        AddDateRangeClause(whereClauses, parameters, "FirstBilledDate", "@fbFrom", "@fbTo", filterFirstBillFrom, filterFirstBillTo);
        var whereClause = string.Join(" AND ", whereClauses);

        var sql = $"""
            SELECT
                ISNULL(ClinicName, '(Unknown)')   AS ClinicName,
                ISNULL(PanelName, '(Unknown)')    AS PanelName,
                ISNULL(ClaimStatus, '(Unknown)')  AS ClaimStatus,
                COUNT(DISTINCT ClaimID)           AS ClaimCount
            FROM dbo.ClaimLevelData
            WHERE {whereClause}
            GROUP BY ClinicName, PanelName, ClaimStatus
            ORDER BY ClinicName, PanelName, ClaimStatus
            """;

        var rawRows = new List<(string Clinic, string Panel, string Status, int Count)>();
        var allStatuses = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
            cmd.Parameters.AddRange(parameters.ToArray());
            await using var reader = await cmd.ExecuteReaderAsync(ct);

            while (await reader.ReadAsync(ct))
            {
                var clinic = reader.GetString(0);
                var panel = reader.GetString(1);
                var status = reader.GetString(2);
                var count = reader.GetInt32(3);

                rawRows.Add((clinic, panel, status, count));
                allStatuses.Add(status);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to load clinic panel status for lab '{LabName}'.", labName);
            throw;
        }

        var statuses = allStatuses.ToList();

        // Build pivot structure
        var clinicMap = new Dictionary<string, ClinicPanelStatusClinicRow>(StringComparer.OrdinalIgnoreCase);
        var clinicPanelMap = new Dictionary<string, Dictionary<string, ClinicPanelStatusPanelRow>>(StringComparer.OrdinalIgnoreCase);

        foreach (var (clinic, panel, status, count) in rawRows)
        {
            // Clinic row
            if (!clinicMap.TryGetValue(clinic, out var clinicRow))
            {
                clinicRow = new ClinicPanelStatusClinicRow
                {
                    ClinicName = clinic,
                    StatusCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase),
                    Panels = [],
                };
                clinicMap[clinic] = clinicRow;
                clinicPanelMap[clinic] = new Dictionary<string, ClinicPanelStatusPanelRow>(StringComparer.OrdinalIgnoreCase);
            }

            // Accumulate clinic-level counts
            if (clinicRow.StatusCounts.ContainsKey(status))
                clinicRow.StatusCounts[status] += count;
            else
                clinicRow.StatusCounts[status] = count;

            // Panel row
            if (!clinicPanelMap[clinic].TryGetValue(panel, out var panelRow))
            {
                panelRow = new ClinicPanelStatusPanelRow
                {
                    PanelName = panel,
                    StatusCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase),
                };
                clinicPanelMap[clinic][panel] = panelRow;
            }

            if (panelRow.StatusCounts.ContainsKey(status))
                panelRow.StatusCounts[status] += count;
            else
                panelRow.StatusCounts[status] = count;
        }

        // Finalize: set grand totals and attach panels
        var clinics = new List<ClinicPanelStatusClinicRow>();
        var grandTotals = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var grandTotalAll = 0;

        foreach (var (clinicName, clinicRow) in clinicMap)
        {
            var clinicTotal = clinicRow.StatusCounts.Values.Sum();
            var panels = clinicPanelMap[clinicName].Values
                .Select(p => new ClinicPanelStatusPanelRow
                {
                    PanelName = p.PanelName,
                    StatusCounts = p.StatusCounts,
                    GrandTotal = p.StatusCounts.Values.Sum(),
                })
                .OrderByDescending(p => p.GrandTotal)
                .ToList();

            clinics.Add(new ClinicPanelStatusClinicRow
            {
                ClinicName = clinicRow.ClinicName,
                StatusCounts = clinicRow.StatusCounts,
                GrandTotal = clinicTotal,
                Panels = panels,
            });

            grandTotalAll += clinicTotal;
            foreach (var (status, cnt) in clinicRow.StatusCounts)
            {
                if (grandTotals.ContainsKey(status))
                    grandTotals[status] += cnt;
                else
                    grandTotals[status] = cnt;
            }
        }

        clinics = clinics.OrderByDescending(c => c.GrandTotal).ToList();

        return new ClinicPanelStatusViewModel
        {
            SelectedLab = labName,
            Statuses = statuses,
            Clinics = clinics,
            GrandTotals = grandTotals,
            GrandTotalAll = grandTotalAll,
        };
    }

    /// <inheritdoc />
    public async Task<ClinicDollarAnalysisViewModel> GetClinicDollarAnalysisAsync(
        string connectionString,
        string labName,
        List<string>? filterClinicNames = null,
        List<string>? filterSalesRepNames = null,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereClauses = new List<string> { "ClinicName IS NOT NULL", "ClinicName <> ''" };
        var parameters = new List<SqlParameter>();
        AddInClause(whereClauses, parameters, "ClinicName", "@cn", filterClinicNames);
        AddInClause(whereClauses, parameters, "SalesRepName", "@sr", filterSalesRepNames);
        AddInClause(whereClauses, parameters, "PayerName", "@pn", filterPayerNames);
        AddInClause(whereClauses, parameters, "PanelName", "@pl", filterPanelNames);
        AddDateRangeClause(whereClauses, parameters, "DateOfService", "@dosFrom", "@dosTo", filterDosFrom, filterDosTo);
        AddDateRangeClause(whereClauses, parameters, "FirstBilledDate", "@fbFrom", "@fbTo", filterFirstBillFrom, filterFirstBillTo);
        var whereClause = string.Join(" AND ", whereClauses);

        var sql = $"""
            SELECT
                ISNULL(ClinicName, '(Unknown)')   AS ClinicName,
                ISNULL(ClaimStatus, '(Unknown)')  AS ClaimStatus,
                COUNT(DISTINCT ClaimID)            AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))), 0) AS TotalCharge,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
            FROM dbo.ClaimLevelData
            WHERE {whereClause}
            GROUP BY ClinicName, ClaimStatus
            ORDER BY ClinicName, ClaimStatus
            """;

        var rawRows = new List<(string Clinic, string Status, int Count, decimal Charge, decimal Payment)>();

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
            cmd.Parameters.AddRange(parameters.ToArray());
            await using var reader = await cmd.ExecuteReaderAsync(ct);

            while (await reader.ReadAsync(ct))
            {
                rawRows.Add((
                    reader.GetString(0),
                    reader.GetString(1),
                    reader.GetInt32(2),
                    GetDecimalSafe(reader, "TotalCharge"),
                    GetDecimalSafe(reader, "InsurancePayment")
                ));
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to load clinic dollar analysis for lab '{LabName}'.", labName);
            throw;
        }

        // Build pivot structure grouped by ClinicName
        var clinicMap = new Dictionary<string, (int Count, decimal Charge, decimal Payment, List<ClinicDollarAnalysisStatusRow> Statuses)>(StringComparer.OrdinalIgnoreCase);

        foreach (var (clinic, status, count, charge, payment) in rawRows)
        {
            if (!clinicMap.TryGetValue(clinic, out var entry))
            {
                entry = (0, 0m, 0m, []);
                clinicMap[clinic] = entry;
            }

            entry.Statuses.Add(new ClinicDollarAnalysisStatusRow
            {
                ClaimStatus = status,
                ClaimCount = count,
                TotalCharge = charge,
                InsurancePayment = payment,
            });

            clinicMap[clinic] = (entry.Count + count, entry.Charge + charge, entry.Payment + payment, entry.Statuses);
        }

        var clinics = clinicMap
            .Select(kvp => new ClinicDollarAnalysisClinicRow
            {
                ClinicName = kvp.Key,
                ClaimCount = kvp.Value.Count,
                TotalCharge = kvp.Value.Charge,
                InsurancePayment = kvp.Value.Payment,
                Statuses = kvp.Value.Statuses
                    .OrderByDescending(s => s.ClaimCount)
                    .ToList(),
            })
            .OrderByDescending(c => c.ClaimCount)
            .ToList();

        return new ClinicDollarAnalysisViewModel
        {
            SelectedLab = labName,
            Clinics = clinics,
            GrandTotalClaims = clinics.Sum(c => c.ClaimCount),
            GrandTotalCharge = clinics.Sum(c => c.TotalCharge),
            GrandTotalInsurancePayment = clinics.Sum(c => c.InsurancePayment),
        };
    }

    /// <inheritdoc />
    public async Task<ClinicDosCountViewModel> GetClinicDosCountAsync(
        string connectionString,
        string labName,
        List<string>? filterClinicNames = null,
        List<string>? filterSalesRepNames = null,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereClauses = new List<string>
        {
            "ClinicName IS NOT NULL", "ClinicName <> ''",
            "TRY_CAST(DateOfService AS DATE) IS NOT NULL"
        };
        var parameters = new List<SqlParameter>();
        AddInClause(whereClauses, parameters, "ClinicName", "@cn", filterClinicNames);
        AddInClause(whereClauses, parameters, "SalesRepName", "@sr", filterSalesRepNames);
        AddInClause(whereClauses, parameters, "PayerName", "@pn", filterPayerNames);
        AddInClause(whereClauses, parameters, "PanelName", "@pl", filterPanelNames);
        AddDateRangeClause(whereClauses, parameters, "DateOfService", "@dosFrom", "@dosTo", filterDosFrom, filterDosTo);
        AddDateRangeClause(whereClauses, parameters, "FirstBilledDate", "@fbFrom", "@fbTo", filterFirstBillFrom, filterFirstBillTo);
        var whereClause = string.Join(" AND ", whereClauses);

        var sql = $"""
            SELECT
                ISNULL(ClinicName, '(Unknown)')       AS ClinicName,
                YEAR(TRY_CAST(DateOfService AS DATE)) AS DosYear,
                MONTH(TRY_CAST(DateOfService AS DATE)) AS DosMonth,
                COUNT(DISTINCT ClaimID)                AS ClaimCount
            FROM dbo.ClaimLevelData
            WHERE {whereClause}
            GROUP BY ClinicName,
                     YEAR(TRY_CAST(DateOfService AS DATE)),
                     MONTH(TRY_CAST(DateOfService AS DATE))
            ORDER BY ClinicName, DosYear, DosMonth
            """;

        var rawRows = new List<(string Clinic, int Year, int Month, int Count)>();

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
            cmd.Parameters.AddRange(parameters.ToArray());
            await using var reader = await cmd.ExecuteReaderAsync(ct);

            while (await reader.ReadAsync(ct))
            {
                rawRows.Add((
                    reader.GetString(0),
                    reader.GetInt32(1),
                    reader.GetInt32(2),
                    reader.GetInt32(3)
                ));
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to load clinic DOS count for lab '{LabName}'.", labName);
            throw;
        }

        // Collect distinct (Year, Month) columns sorted chronologically
        var columnSet = rawRows
            .Select(r => (r.Year, r.Month))
            .Distinct()
            .OrderBy(c => c.Year).ThenBy(c => c.Month)
            .ToList();

        var years = columnSet.Select(c => c.Year).Distinct().OrderBy(y => y).ToList();

        // Build clinic rows
        var clinicMap = new Dictionary<string, Dictionary<string, int>>(StringComparer.OrdinalIgnoreCase);

        foreach (var (clinic, year, month, count) in rawRows)
        {
            if (!clinicMap.TryGetValue(clinic, out var months))
            {
                months = new Dictionary<string, int>();
                clinicMap[clinic] = months;
            }

            var key = ClinicDosCountViewModel.ColKey(year, month);
            months.TryGetValue(key, out var existing);
            months[key] = existing + count;
        }

        var clinics = clinicMap
            .Select(kvp =>
            {
                var yearCounts = new Dictionary<int, int>();
                foreach (var y in years)
                {
                    yearCounts[y] = columnSet
                        .Where(c => c.Year == y)
                        .Sum(c => kvp.Value.GetValueOrDefault(ClinicDosCountViewModel.ColKey(c.Year, c.Month)));
                }

                return new ClinicDosCountRow
                {
                    ClinicName = kvp.Key,
                    MonthCounts = kvp.Value,
                    YearCounts = yearCounts,
                    GrandTotal = kvp.Value.Values.Sum(),
                };
            })
            .OrderByDescending(c => c.GrandTotal)
            .ToList();

        // Column totals
        var columnTotals = new Dictionary<string, int>();
        foreach (var col in columnSet)
        {
            var key = ClinicDosCountViewModel.ColKey(col.Year, col.Month);
            columnTotals[key] = clinics.Sum(c => c.MonthCounts.GetValueOrDefault(key));
        }

        var yearTotals = new Dictionary<int, int>();
        foreach (var y in years)
        {
            yearTotals[y] = clinics.Sum(c => c.YearCounts.GetValueOrDefault(y));
        }

        return new ClinicDosCountViewModel
        {
            SelectedLab = labName,
            Years = years,
            Columns = columnSet,
            Clinics = clinics,
            ColumnTotals = columnTotals,
            YearTotals = yearTotals,
            GrandTotal = clinics.Sum(c => c.GrandTotal),
        };
    }
}
