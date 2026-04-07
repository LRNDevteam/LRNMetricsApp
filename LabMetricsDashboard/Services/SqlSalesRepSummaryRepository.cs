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

        var rows = new List<SalesRepSummaryRow>();
        var salesRepNames = new List<string>();
        var clinicNames = new List<string>();
        var payerNames = new List<string>();
        var panelNames = new List<string>();

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
            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
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
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to load sales rep summary for lab '{LabName}'.", labName);
            throw;
        }

        return new SalesRepSummaryResult(rows, salesRepNames, clinicNames, payerNames, panelNames);
    }

    private static decimal GetDecimalSafe(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? 0m : reader.GetDecimal(ordinal);
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
}
