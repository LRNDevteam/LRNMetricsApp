using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Coding Validation summary data directly from the CodingValidation table
/// using inline aggregation queries (no stored procedure dependency).
/// </summary>
public sealed class SqlCodingValidationRepository : ICodingValidationRepository
{
    private readonly ILogger<SqlCodingValidationRepository> _logger;

    public SqlCodingValidationRepository(ILogger<SqlCodingValidationRepository> logger)
        => _logger = logger;

    /// <summary>
    /// Returns the YTD Coding Insights rows, grouped by Year / PanelName plus
    /// the four CPT combination columns so each distinct combination appears
    /// as its own row (matches the per-combination breakdown image).
    /// </summary>
    public async Task<List<CodingInsightRow>> GetYtdInsightsAsync(
        string connectionString, string labName, CancellationToken ct = default)
    {
        // BillableCptCombo = ExpectedCPTCode (the panel master / what should have been billed,
        // typically clean codes like "87481*5, 87529*2, ...")
        // BilledCptCombo   = ActualCPTCode   (what was actually billed, often with modifier
        // markers such as "87481*5(59), 87529*2(59), ...")
        // The four CPT columns already contain the full comma-separated combo per claim row,
        // so we select them as-is and add them to the GROUP BY to keep distinct combinations
        // as separate rows (no STUFF / FOR XML aggregation needed).
        const string sql = """
            SELECT
                YEAR(TRY_CAST(DateofService AS DATE))                        AS ServiceYear,
                PanelName,
                ISNULL(ExpectedCPTCode,    '')                               AS BillableCptCombo,
                ISNULL(ActualCPTCode,      '')                               AS BilledCptCombo,
                ISNULL(MissingCPTCodes,    '')                               AS MissingCpts,
                ISNULL(AdditionalCPTCodes, '')                               AS AdditionalCpts,
                COUNT(*)                                                     AS TotalClaims,
                AVG(TRY_CAST(TotalCharge              AS DECIMAL(18,2)))     AS BilledChargesPerClaim,
                SUM(TRY_CAST(MissingCPT_Charges       AS DECIMAL(18,2)))     AS TotalBilledChargesForMissingCpts,
                SUM(TRY_CAST(MissingCPT_AvgPaidAmount AS DECIMAL(18,2)))     AS LostRevenue,
                SUM(TRY_CAST(AdditionalCPT_Charges    AS DECIMAL(18,2)))     AS TotalBilledChargesForAdditionalCpts,
                SUM(TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2)))  AS RevenueAtRisk
            FROM dbo.CodingValidation
            WHERE PanelName IS NOT NULL AND PanelName <> ''
              AND YEAR(TRY_CAST(DateofService AS DATE)) IS NOT NULL
            GROUP BY
                YEAR(TRY_CAST(DateofService AS DATE)),
                PanelName,
                ISNULL(ExpectedCPTCode,    ''),
                ISNULL(ActualCPTCode,      ''),
                ISNULL(MissingCPTCodes,    ''),
                ISNULL(AdditionalCPTCodes, ''),
                TRY_CAST(TotalCharge                 AS DECIMAL(18,2)),
                TRY_CAST(MissingCPT_Charges          AS DECIMAL(18,2)),
                TRY_CAST(MissingCPT_AvgPaidAmount    AS DECIMAL(18,2)),
                TRY_CAST(AdditionalCPT_Charges       AS DECIMAL(18,2)),
                TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2))
            ORDER BY
                ServiceYear DESC,
                PanelName,
                BillableCptCombo,
                BilledCptCombo;
            """;

        return await QueryAsync(connectionString, sql, labName,
            r => new CodingInsightRow
            {
                Year                               = r.GetInt32(r.GetOrdinal("ServiceYear")),
                PanelName                          = Str(r, "PanelName"),
                BillableCptCombo                   = Str(r, "BillableCptCombo"),
                TotalClaims                        = r.GetInt32(r.GetOrdinal("TotalClaims")),
                BilledChargesPerClaim              = Dec(r, "BilledChargesPerClaim"),
                BilledCptCombo                     = Str(r, "BilledCptCombo"),
                MissingCpts                        = Str(r, "MissingCpts"),
                TotalBilledChargesForMissingCpts   = Dec(r, "TotalBilledChargesForMissingCpts"),
                LostRevenue                        = Dec(r, "LostRevenue"),
                AdditionalCpts                     = Str(r, "AdditionalCpts"),
                TotalBilledChargesForAdditionalCpts = Dec(r, "TotalBilledChargesForAdditionalCpts"),
                RevenueAtRisk                      = Dec(r, "RevenueAtRisk"),
                NetImpact                          = Dec(r, "LostRevenue") - Dec(r, "RevenueAtRisk"),
            }, ct);
    }

    /// <summary>
    /// Returns the YTD Summary rows (panel-level totals) grouped by Year / PanelName,
    /// matching the summary table shown in the dashboard image.
    /// </summary>
    public async Task<List<CodingSummaryRow>> GetYtdSummaryAsync(
        string connectionString, string labName, CancellationToken ct = default)
    {
        const string sql = """
            SELECT
                g.ServiceYear,
                g.PanelName,
                -- BillableCptCombo = ExpectedCPTCode (panel master / what should be billed)
                STUFF((
                    SELECT DISTINCT '*' + d1.ExpectedCPTCode
                    FROM dbo.CodingValidation d1
                    WHERE YEAR(TRY_CAST(d1.DateofService AS DATE)) = g.ServiceYear
                      AND d1.PanelName = g.PanelName
                      AND d1.ExpectedCPTCode IS NOT NULL AND d1.ExpectedCPTCode <> ''
                    ORDER BY '*' + d1.ExpectedCPTCode
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BillableCptCombo,
                -- BilledCptCombo = ActualCPTCode (what was actually billed)
                STUFF((
                    SELECT DISTINCT '*' + d2.ActualCPTCode
                    FROM dbo.CodingValidation d2
                    WHERE YEAR(TRY_CAST(d2.DateofService AS DATE)) = g.ServiceYear
                      AND d2.PanelName = g.PanelName
                      AND d2.ActualCPTCode IS NOT NULL AND d2.ActualCPTCode <> ''
                    ORDER BY '*' + d2.ActualCPTCode
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BilledCptCombo,
                -- Distinct MissingCPTCodes values
                STUFF((
                    SELECT DISTINCT '*' + d3.MissingCPTCodes
                    FROM dbo.CodingValidation d3
                    WHERE YEAR(TRY_CAST(d3.DateofService AS DATE)) = g.ServiceYear
                      AND d3.PanelName = g.PanelName
                      AND d3.MissingCPTCodes IS NOT NULL AND d3.MissingCPTCodes <> ''
                    ORDER BY '*' + d3.MissingCPTCodes
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS MissingCpts,
                -- Distinct AdditionalCPTCodes values
                STUFF((
                    SELECT DISTINCT '*' + d4.AdditionalCPTCodes
                    FROM dbo.CodingValidation d4
                    WHERE YEAR(TRY_CAST(d4.DateofService AS DATE)) = g.ServiceYear
                      AND d4.PanelName = g.PanelName
                      AND d4.AdditionalCPTCodes IS NOT NULL AND d4.AdditionalCPTCodes <> ''
                    ORDER BY '*' + d4.AdditionalCPTCodes
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS AdditionalCpts,
                g.TotalClaims,
                g.TotalBilledCharges,
                g.DistinctClaimsWithMissingCpts,
                g.TotalBilledChargesForMissingCpts,
                g.DistinctClaimsWithAdditionalCpts,
                g.TotalBilledChargesForAdditionalCpts,
                g.LostRevenue,
                g.RevenueAtRisk
            FROM (
                SELECT
                    YEAR(TRY_CAST(DateofService AS DATE))                           AS ServiceYear,
                    PanelName,
                    COUNT(*)                                                         AS TotalClaims,
                    SUM(TRY_CAST(TotalCharge AS DECIMAL(18,2)))                     AS TotalBilledCharges,
                    COUNT(DISTINCT CASE WHEN MissingCPTCodes  IS NOT NULL
                                         AND MissingCPTCodes  <> ''
                                        THEN AccessionNo END)                        AS DistinctClaimsWithMissingCpts,
                    SUM(TRY_CAST(MissingCPT_Charges AS DECIMAL(18,2)))              AS TotalBilledChargesForMissingCpts,
                    COUNT(DISTINCT CASE WHEN AdditionalCPTCodes IS NOT NULL
                                         AND AdditionalCPTCodes  <> ''
                                        THEN AccessionNo END)                        AS DistinctClaimsWithAdditionalCpts,
                    SUM(TRY_CAST(AdditionalCPT_Charges AS DECIMAL(18,2)))           AS TotalBilledChargesForAdditionalCpts,
                    SUM(TRY_CAST(MissingCPT_AvgPaidAmount AS DECIMAL(18,2)))        AS LostRevenue,
                    SUM(TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2)))     AS RevenueAtRisk
                FROM dbo.CodingValidation
                WHERE PanelName IS NOT NULL AND PanelName <> ''
                  AND YEAR(TRY_CAST(DateofService AS DATE)) IS NOT NULL
                GROUP BY
                    YEAR(TRY_CAST(DateofService AS DATE)),
                    PanelName
            ) g
            ORDER BY
                g.ServiceYear DESC,
                g.PanelName;
            """;

        return await QueryAsync(connectionString, sql, labName,
            r => new CodingSummaryRow
            {
                Year                               = r.GetInt32(r.GetOrdinal("ServiceYear")),
                PanelName                          = Str(r, "PanelName"),
                BillableCptCombo                   = Str(r, "BillableCptCombo"),
                BilledCptCombo                     = Str(r, "BilledCptCombo"),
                MissingCpts                        = Str(r, "MissingCpts"),
                AdditionalCpts                     = Str(r, "AdditionalCpts"),
                TotalClaims                        = r.GetInt32(r.GetOrdinal("TotalClaims")),
                TotalBilledCharges                 = Dec(r, "TotalBilledCharges"),
                DistinctClaimsWithMissingCpts      = r.GetInt32(r.GetOrdinal("DistinctClaimsWithMissingCpts")),
                TotalBilledChargesForMissingCpts   = Dec(r, "TotalBilledChargesForMissingCpts"),
                DistinctClaimsWithAdditionalCpts   = r.GetInt32(r.GetOrdinal("DistinctClaimsWithAdditionalCpts")),
                TotalBilledChargesForAdditionalCpts = Dec(r, "TotalBilledChargesForAdditionalCpts"),
                LostRevenue                        = Dec(r, "LostRevenue"),
                RevenueAtRisk                      = Dec(r, "RevenueAtRisk"),
                NetImpact                          = Dec(r, "LostRevenue") - Dec(r, "RevenueAtRisk"),
            }, ct);
    }

    // ?? helpers ???????????????????????????????????????????????????????????????

    /// <summary>
    /// Returns WTD Coding Insights rows grouped by WeekFolder / PanelName plus
    /// the four CPT combination columns so each distinct combination appears
    /// as its own row (matches the per-combination breakdown image).
    /// WeekFolder values come directly from CodingValidation.WeekFolder
    /// (e.g. "03/20/2026 to 03/26/2026") as stored by CaptureDataApp.
    /// </summary>
    public async Task<List<CodingWtdInsightRow>> GetWtdInsightsAsync(
        string connectionString, string labName, CancellationToken ct = default)
    {
        // BillableCptCombo = ExpectedCPTCode (panel master / what should have been billed)
        // BilledCptCombo   = ActualCPTCode   (what was actually billed, often with modifiers)
        // Each distinct (Billable / Billed / Missing / Additional) combination becomes
        // its own row. The CPT columns already contain the full comma-separated combo
        // string per claim, so they are selected as-is.
        const string sql = """
            SELECT
                WeekFolder,
                PanelName,
                ISNULL(ExpectedCPTCode,    '')                               AS BillableCptCombo,
                ISNULL(ActualCPTCode,      '')                               AS BilledCptCombo,
                ISNULL(MissingCPTCodes,    '')                               AS MissingCpts,
                ISNULL(AdditionalCPTCodes, '')                               AS AdditionalCpts,
                COUNT(*)                                                     AS TotalClaims,
                SUM(TRY_CAST(TotalCharge              AS DECIMAL(18,2)))     AS TotalBilledCharges,
                SUM(TRY_CAST(MissingCPT_Charges       AS DECIMAL(18,2)))     AS BilledChargesForMissingCpts,
                SUM(TRY_CAST(MissingCPT_AvgPaidAmount AS DECIMAL(18,2)))     AS RevenueLoss,
                SUM(TRY_CAST(AdditionalCPT_Charges    AS DECIMAL(18,2)))     AS BilledChargesForAdditionalCpts,
                SUM(TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2)))  AS PotentialRecoupment
            FROM dbo.CodingValidation
            WHERE WeekFolder IS NOT NULL AND WeekFolder <> ''
              AND PanelName  IS NOT NULL AND PanelName  <> ''
            GROUP BY
                WeekFolder,
                PanelName,
                ISNULL(ExpectedCPTCode,    ''),
                ISNULL(ActualCPTCode,      ''),
                ISNULL(MissingCPTCodes,    ''),
                ISNULL(AdditionalCPTCodes, ''),
                TRY_CAST(TotalCharge                 AS DECIMAL(18,2)),
                TRY_CAST(MissingCPT_Charges          AS DECIMAL(18,2)),
                TRY_CAST(MissingCPT_AvgPaidAmount    AS DECIMAL(18,2)),
                TRY_CAST(AdditionalCPT_Charges       AS DECIMAL(18,2)),
                TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2))
            ORDER BY
                WeekFolder DESC,
                PanelName,
                BillableCptCombo,
                BilledCptCombo;
            """;

        return await QueryAsync(connectionString, sql, labName,
            r => new CodingWtdInsightRow
            {
                WeekFolder                    = Str(r, "WeekFolder"),
                PanelName                     = Str(r, "PanelName"),
                BillableCptCombo              = Str(r, "BillableCptCombo"),
                TotalClaims                   = r.GetInt32(r.GetOrdinal("TotalClaims")),
                TotalBilledCharges            = Dec(r, "TotalBilledCharges"),
                BilledCptCombo                = Str(r, "BilledCptCombo"),
                MissingCpts                   = Str(r, "MissingCpts"),
                BilledChargesForMissingCpts   = Dec(r, "BilledChargesForMissingCpts"),
                RevenueLoss                   = Dec(r, "RevenueLoss"),
                AdditionalCpts                = Str(r, "AdditionalCpts"),
                BilledChargesForAdditionalCpts = Dec(r, "BilledChargesForAdditionalCpts"),
                PotentialRecoupment           = Dec(r, "PotentialRecoupment"),
                NetImpact                     = Dec(r, "RevenueLoss") - Dec(r, "PotentialRecoupment"),
            }, ct);
    }

    /// <summary>
    /// Returns WTD Summary rows grouped by WeekFolder / PanelName.
    /// </summary>
    public async Task<List<CodingWtdSummaryRow>> GetWtdSummaryAsync(
        string connectionString, string labName, CancellationToken ct = default)
    {
        const string sql = """
            SELECT
                g.WeekFolder,
                g.PanelName,
                -- BillableCptCombo = ExpectedCPTCode (panel master / what should be billed)
                STUFF((
                    SELECT DISTINCT '*' + d1.ExpectedCPTCode
                    FROM dbo.CodingValidation d1
                    WHERE d1.WeekFolder  = g.WeekFolder
                      AND d1.PanelName   = g.PanelName
                      AND d1.ExpectedCPTCode IS NOT NULL AND d1.ExpectedCPTCode <> ''
                    ORDER BY '*' + d1.ExpectedCPTCode
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BillableCptCombo,
                -- BilledCptCombo = ActualCPTCode (what was actually billed)
                STUFF((
                    SELECT DISTINCT '*' + d2.ActualCPTCode
                    FROM dbo.CodingValidation d2
                    WHERE d2.WeekFolder  = g.WeekFolder
                      AND d2.PanelName   = g.PanelName
                      AND d2.ActualCPTCode IS NOT NULL AND d2.ActualCPTCode <> ''
                    ORDER BY '*' + d2.ActualCPTCode
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BilledCptCombo,
                -- Distinct MissingCPTCodes values
                STUFF((
                    SELECT DISTINCT '*' + d3.MissingCPTCodes
                    FROM dbo.CodingValidation d3
                    WHERE d3.WeekFolder  = g.WeekFolder
                      AND d3.PanelName   = g.PanelName
                      AND d3.MissingCPTCodes IS NOT NULL AND d3.MissingCPTCodes <> ''
                    ORDER BY '*' + d3.MissingCPTCodes
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS MissingCpts,
                -- Distinct AdditionalCPTCodes values
                STUFF((
                    SELECT DISTINCT '*' + d4.AdditionalCPTCodes
                    FROM dbo.CodingValidation d4
                    WHERE d4.WeekFolder  = g.WeekFolder
                      AND d4.PanelName   = g.PanelName
                      AND d4.AdditionalCPTCodes IS NOT NULL AND d4.AdditionalCPTCodes <> ''
                    ORDER BY '*' + d4.AdditionalCPTCodes
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS AdditionalCpts,
                g.TotalClaims,
                g.DistinctClaimsWithMissingCpts,
                g.TotalBilledChargesForMissingCpts,
                g.AvgAllowedAmountForMissingCpts
            FROM (
                SELECT
                    WeekFolder,
                    PanelName,
                    COUNT(*)                                                                AS TotalClaims,
                    COUNT(DISTINCT CASE WHEN MissingCPTCodes IS NOT NULL
                                         AND MissingCPTCodes <> ''
                                        THEN AccessionNo END)                               AS DistinctClaimsWithMissingCpts,
                    SUM(TRY_CAST(MissingCPT_Charges AS DECIMAL(18,2)))                     AS TotalBilledChargesForMissingCpts,
                    AVG(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2)))            AS AvgAllowedAmountForMissingCpts
                FROM dbo.CodingValidation
                WHERE WeekFolder IS NOT NULL AND WeekFolder <> ''
                  AND PanelName  IS NOT NULL AND PanelName  <> ''
                GROUP BY WeekFolder, PanelName
            ) g
            ORDER BY g.WeekFolder DESC, g.PanelName;
            """;

        return await QueryAsync(connectionString, sql, labName,
            r => new CodingWtdSummaryRow
            {
                WeekFolder                      = Str(r, "WeekFolder"),
                PanelName                       = Str(r, "PanelName"),
                BillableCptCombo                = Str(r, "BillableCptCombo"),
                BilledCptCombo                  = Str(r, "BilledCptCombo"),
                MissingCpts                     = Str(r, "MissingCpts"),
                AdditionalCpts                  = Str(r, "AdditionalCpts"),
                TotalClaims                     = r.GetInt32(r.GetOrdinal("TotalClaims")),
                DistinctClaimsWithMissingCpts   = r.GetInt32(r.GetOrdinal("DistinctClaimsWithMissingCpts")),
                TotalBilledChargesForMissingCpts = Dec(r, "TotalBilledChargesForMissingCpts"),
                AvgAllowedAmountForMissingCpts  = Dec(r, "AvgAllowedAmountForMissingCpts"),
            }, ct);
    }

    /// <summary>
    /// Returns all rows from dbo.CodingFinancialSummary ordered by InsertedDateTime desc.
    /// No LabName filter — each lab has its own database.
    /// </summary>
    public async Task<List<CodingFinancialSummaryRow>> GetFinancialSummaryAsync(
        string connectionString, CancellationToken ct = default)
    {
        const string sql = """
            SELECT
                SummaryId,
                WeekFolder,
                ReportDate,
                TotalClaims,
                TotalBilledCharges,
                ExpectedBilledCharges,
                RevenueImpact_Claims,
                RevenueImpact_ActualBilled,
                RevenueImpact_PotentialLoss,
                RevenueImpact_ExpectedRecoup,
                RevenueLoss_Claims,
                RevenueLoss_ActualBilled,
                RevenueLoss_PotentialLoss,
                RevenueAtRisk_Claims,
                RevenueAtRisk_ActualBilled,
                RevenueAtRisk_PotentialRecoup,
                Compliance_TotalClaims,
                Compliance_ClaimsWithIssues,
                ComplianceRate,
                ClaimsWithMissingCPTs,
                ClaimsWithAdditionalCPTs,
                ClaimsWithBothMissingAndAdditional,
                TotalErrorClaims,
                ComplianceRatePct
            FROM dbo.CodingFinancialSummary
            ORDER BY InsertedDateTime DESC;
            """;

        var results = new List<CodingFinancialSummaryRow>();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd    = new SqlCommand(sql, conn) { CommandTimeout = 120 };
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                results.Add(new CodingFinancialSummaryRow
                {
                    SummaryId                          = reader.GetInt32(reader.GetOrdinal("SummaryId")),
                    WeekFolder                         = Str(reader, "WeekFolder"),
                    ReportDate                         = Str(reader, "ReportDate"),
                    TotalClaims                        = NullInt(reader, "TotalClaims")  ?? 0,
                    TotalBilledCharges                 = Dec(reader, "TotalBilledCharges"),
                    ExpectedBilledCharges              = Dec(reader, "ExpectedBilledCharges"),
                    RevenueImpact_Claims               = NullInt(reader, "RevenueImpact_Claims"),
                    RevenueImpact_ActualBilled         = Dec(reader, "RevenueImpact_ActualBilled"),
                    RevenueImpact_PotentialLoss        = Dec(reader, "RevenueImpact_PotentialLoss"),
                    RevenueImpact_ExpectedRecoup       = Dec(reader, "RevenueImpact_ExpectedRecoup"),
                    RevenueLoss_Claims                 = NullInt(reader, "RevenueLoss_Claims"),
                    RevenueLoss_ActualBilled           = Dec(reader, "RevenueLoss_ActualBilled"),
                    RevenueLoss_PotentialLoss          = Dec(reader, "RevenueLoss_PotentialLoss"),
                    RevenueAtRisk_Claims               = NullInt(reader, "RevenueAtRisk_Claims"),
                    RevenueAtRisk_ActualBilled         = Dec(reader, "RevenueAtRisk_ActualBilled"),
                    RevenueAtRisk_PotentialRecoup      = Dec(reader, "RevenueAtRisk_PotentialRecoup"),
                    Compliance_TotalClaims             = NullInt(reader, "Compliance_TotalClaims"),
                    Compliance_ClaimsWithIssues        = NullInt(reader, "Compliance_ClaimsWithIssues"),
                    ComplianceRate                     = Str(reader, "ComplianceRate"),
                    ClaimsWithMissingCPTs              = NullInt(reader, "ClaimsWithMissingCPTs"),
                    ClaimsWithAdditionalCPTs           = NullInt(reader, "ClaimsWithAdditionalCPTs"),
                    ClaimsWithBothMissingAndAdditional = NullInt(reader, "ClaimsWithBothMissingAndAdditional"),
                    TotalErrorClaims                   = NullInt(reader, "TotalErrorClaims"),
                    ComplianceRatePct                  = Str(reader, "ComplianceRatePct"),
                });
            }
            _logger.LogInformation("CodingFinancialSummary returned {Count} rows.", results.Count);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to query CodingFinancialSummary: {Message}", ex.Message);
            throw;
        }
        return results;
    }

    private async Task<List<T>> QueryAsync<T>(
        string connectionString, string sql, string labName,
        Func<SqlDataReader, T> map, CancellationToken ct)
    {
        var results = new List<T>();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };

            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                results.Add(map(reader));

            _logger.LogInformation(
                "CodingValidation query for '{LabName}' returned {Count} rows.", labName, results.Count);
        }
        catch (Exception ex)
        {
            // Log the full exception — never swallow silently so blank pages are diagnosable.
            _logger.LogError(ex,
                "CodingValidation query failed for lab '{LabName}': {Message}", labName, ex.Message);
            throw;   // re-throw so the controller can show the error in the UI
        }
        return results;
    }

    private static string  Str(SqlDataReader r, string col)
        => r.IsDBNull(r.GetOrdinal(col)) ? string.Empty : r.GetString(r.GetOrdinal(col));

    private static decimal Dec(SqlDataReader r, string col)
        => r.IsDBNull(r.GetOrdinal(col)) ? 0m : r.GetDecimal(r.GetOrdinal(col));

    private static int? NullInt(SqlDataReader r, string col)
        => r.IsDBNull(r.GetOrdinal(col)) ? null : r.GetInt32(r.GetOrdinal(col));

    /// <summary>
    /// Returns the most recent week's raw CodingValidation rows for the Validation Detail tab.
    /// Capped at 5 000 rows to keep page load fast.
    /// </summary>
    public async Task<List<CodingValidationDetailRow>> GetValidationDetailRowsAsync(
        string connectionString, CancellationToken ct = default)
    {
        const string sql = """
            SELECT TOP 5000
                WeekFolder, AccessionNo, PanelName, DateofService,
                ActualCPTCode, ExpectedCPTCode,
                MissingCPTCodes, AdditionalCPTCodes,
                ValidationStatus, TotalCharge,
                MissingCPT_Charges, AdditionalCPT_Charges, Remarks
            FROM dbo.CodingValidation
            WHERE WeekFolder = (
                SELECT TOP 1 WeekFolder FROM dbo.CodingValidation
                ORDER BY InsertedDateTime DESC
            )
              AND AccessionNo   IS NOT NULL AND LTRIM(RTRIM(AccessionNo))   <> ''
              AND PanelName     IS NOT NULL AND LTRIM(RTRIM(PanelName))     <> ''
              AND DateofService IS NOT NULL AND LTRIM(RTRIM(DateofService)) <> ''
            ORDER BY PanelName, AccessionNo;
            """;

        var results = new List<CodingValidationDetailRow>();
        try
        {
            await using var conn   = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd    = new SqlCommand(sql, conn) { CommandTimeout = 120 };
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                results.Add(new CodingValidationDetailRow
                {
                    WeekFolder            = Str(reader, "WeekFolder"),
                    AccessionNo           = Str(reader, "AccessionNo"),
                    PanelName             = Str(reader, "PanelName"),
                    DateofService         = Str(reader, "DateofService"),
                    ActualCPTCode         = Str(reader, "ActualCPTCode"),
                    ExpectedCPTCode       = Str(reader, "ExpectedCPTCode"),
                    MissingCPTCodes       = Str(reader, "MissingCPTCodes"),
                    AdditionalCPTCodes    = Str(reader, "AdditionalCPTCodes"),
                    ValidationStatus      = Str(reader, "ValidationStatus"),
                    TotalCharge           = Str(reader, "TotalCharge"),
                    MissingCPT_Charges    = Str(reader, "MissingCPT_Charges"),
                    AdditionalCPT_Charges = Str(reader, "AdditionalCPT_Charges"),
                    Remarks               = Str(reader, "Remarks"),
                });
            }
            _logger.LogInformation("CodingValidation detail rows returned {Count}.", results.Count);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "GetValidationDetailRowsAsync failed: {Message}", ex.Message);
            throw;
        }
        return results;
    }
}
