using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Coding Validation summary data via the stored procedures created in
/// CaptureDataApp/Sql/04_CodingAggregates.sql.
///
/// The YTD/WTD Insights and Summary datasets come from pre-computed aggregate
/// tables (CodingAgg_*) that CaptureDataApp refreshes after each weekly load
/// (usp_RefreshCodingAggregates), so page loads no longer run GROUP BY /
/// FOR XML queries over the full CodingValidation table.
///
/// Convention: BillableCptCombo = ExpectedCPTCode (what SHOULD be billed),
///             BilledCptCombo   = ActualCPTCode   (what WAS billed).
/// </summary>
public sealed class SqlCodingValidationRepository : ICodingValidationRepository
{
    private readonly ILogger<SqlCodingValidationRepository> _logger;

    public SqlCodingValidationRepository(ILogger<SqlCodingValidationRepository> logger)
        => _logger = logger;

    /// <summary>
    /// Returns the YTD Coding Insights rows (one per Year / PanelName / distinct
    /// CPT combination) from dbo.CodingAgg_YtdInsights.
    /// </summary>
    public async Task<List<CodingInsightRow>> GetYtdInsightsAsync(
        string connectionString, string labName, CancellationToken ct = default)
    {
        return await QueryProcAsync(connectionString, "dbo.usp_GetCodingAggYtdInsights", labName,
            r => new CodingInsightRow
            {
                Year                               = r.GetInt32(r.GetOrdinal("ServiceYear")),
                PanelName                          = Str(r, "PanelName"),
                BillableCptCombo                   = Str(r, "BillableCptCombo"),
                TotalClaims                        = r.GetInt32(r.GetOrdinal("TotalClaims")),
                BilledChargesPerClaim              = ReadDec(r, "BilledChargesPerClaim"),
                BilledCptCombo                     = Str(r, "BilledCptCombo"),
                MissingCpts                        = Str(r, "MissingCpts"),
                TotalBilledChargesForMissingCpts   = ReadDec(r, "TotalBilledChargesForMissingCpts"),
                LostRevenue                        = ReadDec(r, "LostRevenue"),
                AdditionalCpts                     = Str(r, "AdditionalCpts"),
                TotalBilledChargesForAdditionalCpts = ReadDec(r, "TotalBilledChargesForAdditionalCpts"),
                RevenueAtRisk                      = ReadDec(r, "RevenueAtRisk"),
                // >>> CVTPL-1.4 CHANGE (2026-07-27): Net Impact = Revenue at Risk - Lost Revenue per template v1.4.
                //     REVERT: restore -> ReadDec(r, "LostRevenue") - ReadDec(r, "RevenueAtRisk")
                NetImpact                          = ReadDec(r, "RevenueAtRisk") - ReadDec(r, "LostRevenue"),
                // <<< END CVTPL-1.4 CHANGE
            }, ct);
    }

    /// <summary>
    /// Returns the YTD Summary rows (panel-level totals per Year / PanelName)
    /// from dbo.CodingAgg_YtdSummary.
    /// </summary>
    public async Task<List<CodingSummaryRow>> GetYtdSummaryAsync(
        string connectionString, string labName, CancellationToken ct = default)
    {
        return await QueryProcAsync(connectionString, "dbo.usp_GetCodingAggYtdSummary", labName,
            r => new CodingSummaryRow
            {
                Year                               = r.GetInt32(r.GetOrdinal("ServiceYear")),
                PanelName                          = Str(r, "PanelName"),
                BillableCptCombo                   = Str(r, "BillableCptCombo"),
                BilledCptCombo                     = Str(r, "BilledCptCombo"),
                MissingCpts                        = Str(r, "MissingCpts"),
                AdditionalCpts                     = Str(r, "AdditionalCpts"),
                TotalClaims                        = r.GetInt32(r.GetOrdinal("TotalClaims")),
                TotalBilledCharges                 = ReadDec(r, "TotalBilledCharges"),
                DistinctClaimsWithMissingCpts      = r.GetInt32(r.GetOrdinal("DistinctClaimsWithMissingCpts")),
                TotalBilledChargesForMissingCpts   = ReadDec(r, "TotalBilledChargesForMissingCpts"),
                DistinctClaimsWithAdditionalCpts   = r.GetInt32(r.GetOrdinal("DistinctClaimsWithAdditionalCpts")),
                TotalBilledChargesForAdditionalCpts = ReadDec(r, "TotalBilledChargesForAdditionalCpts"),
                LostRevenue                        = ReadDec(r, "LostRevenue"),
                RevenueAtRisk                      = ReadDec(r, "RevenueAtRisk"),
                // >>> CVTPL-1.4 CHANGE (2026-07-27): Net Impact = Revenue at Risk - Lost Revenue per template v1.4.
                //     REVERT: restore -> ReadDec(r, "LostRevenue") - ReadDec(r, "RevenueAtRisk")
                NetImpact                          = ReadDec(r, "RevenueAtRisk") - ReadDec(r, "LostRevenue"),
                // <<< END CVTPL-1.4 CHANGE
            }, ct);
    }

    /// <summary>
    /// Returns WTD Coding Insights rows (one per WeekFolder / PanelName / distinct
    /// CPT combination) from dbo.CodingAgg_WtdInsights.
    /// WeekFolder values come directly from CodingValidation.WeekFolder
    /// (e.g. "03/20/2026 to 03/26/2026") as stored by CaptureDataApp.
    /// </summary>
    public async Task<List<CodingWtdInsightRow>> GetWtdInsightsAsync(
        string connectionString, string labName, CancellationToken ct = default)
    {
        return await QueryProcAsync(connectionString, "dbo.usp_GetCodingAggWtdInsights", labName,
            r => new CodingWtdInsightRow
            {
                WeekFolder                    = Str(r, "WeekFolder"),
                PanelName                     = Str(r, "PanelName"),
                BillableCptCombo              = Str(r, "BillableCptCombo"),
                TotalClaims                   = r.GetInt32(r.GetOrdinal("TotalClaims")),
                TotalBilledCharges            = ReadDec(r, "TotalBilledCharges"),
                BilledCptCombo                = Str(r, "BilledCptCombo"),
                MissingCpts                   = Str(r, "MissingCpts"),
                BilledChargesForMissingCpts   = ReadDec(r, "BilledChargesForMissingCpts"),
                RevenueLoss                   = ReadDec(r, "RevenueLoss"),
                AdditionalCpts                = Str(r, "AdditionalCpts"),
                BilledChargesForAdditionalCpts = ReadDec(r, "BilledChargesForAdditionalCpts"),
                PotentialRecoupment           = ReadDec(r, "PotentialRecoupment"),
                // >>> CVTPL-1.4 CHANGE (2026-07-27): Net Impact = Potential Recoupment - Revenue Loss per template v1.4.
                //     REVERT: restore -> ReadDec(r, "RevenueLoss") - ReadDec(r, "PotentialRecoupment")
                NetImpact                     = ReadDec(r, "PotentialRecoupment") - ReadDec(r, "RevenueLoss"),
                // <<< END CVTPL-1.4 CHANGE
            }, ct);
    }

    /// <summary>
    /// Returns WTD Summary rows (per WeekFolder / PanelName) from
    /// dbo.CodingAgg_WtdSummary.
    /// </summary>
    public async Task<List<CodingWtdSummaryRow>> GetWtdSummaryAsync(
        string connectionString, string labName, CancellationToken ct = default)
    {
        return await QueryProcAsync(connectionString, "dbo.usp_GetCodingAggWtdSummary", labName,
            r => new CodingWtdSummaryRow
            {
                WeekFolder                       = Str(r, "WeekFolder"),
                PanelName                        = Str(r, "PanelName"),
                BillableCptCombo                 = Str(r, "BillableCptCombo"),
                BilledCptCombo                   = Str(r, "BilledCptCombo"),
                MissingCpts                      = Str(r, "MissingCpts"),
                AdditionalCpts                   = Str(r, "AdditionalCpts"),
                TotalClaims                      = r.GetInt32(r.GetOrdinal("TotalClaims")),
                TotalBilledCharges               = ReadDec(r, "TotalBilledCharges"),
                DistinctClaimsWithMissingCpts    = r.GetInt32(r.GetOrdinal("DistinctClaimsWithMissingCpts")),
                TotalBilledChargesForMissingCpts = ReadDec(r, "TotalBilledChargesForMissingCpts"),
                AvgAllowedAmountForMissingCpts   = ReadDec(r, "AvgAllowedAmountForMissingCpts"),
                // >>> CVTPL-1.4 CHANGE (2026-07-27): map WTD Summary additional-CPT + revenue columns per template v1.4.
                //     REVERT: delete the five mappings below.
                DistinctClaimsWithAdditionalCpts    = r.GetInt32(r.GetOrdinal("DistinctClaimsWithAdditionalCpts")),
                TotalBilledChargesForAdditionalCpts = ReadDec(r, "TotalBilledChargesForAdditionalCpts"),
                LostRevenue                         = ReadDec(r, "LostRevenue"),
                RevenueAtRisk                       = ReadDec(r, "RevenueAtRisk"),
                NetImpact                           = ReadDec(r, "NetImpact"),
                // <<< END CVTPL-1.4 CHANGE
            }, ct);
    }

    /// <summary>
    /// Returns all rows from dbo.CodingFinancialSummary (newest first) via
    /// dbo.usp_GetCodingFinancialSummary. No LabName filter - each lab has its
    /// own database.
    /// </summary>
    public async Task<List<CodingFinancialSummaryRow>> GetFinancialSummaryAsync(
        string connectionString, CancellationToken ct = default)
    {
        var results = new List<CodingFinancialSummaryRow>();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand("dbo.usp_GetCodingFinancialSummary", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 120
            };
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                results.Add(new CodingFinancialSummaryRow
                {
                    SummaryId                          = reader.GetInt32(reader.GetOrdinal("SummaryId")),
                    WeekFolder                         = Str(reader, "WeekFolder"),
                    ReportDate                         = Str(reader, "ReportDate"),
                    TotalClaims                        = NullInt(reader, "TotalClaims")  ?? 0,
                    TotalBilledCharges                 = ReadDec(reader, "TotalBilledCharges"),
                    ExpectedBilledCharges              = ReadDec(reader, "ExpectedBilledCharges"),
                    RevenueImpact_Claims               = NullInt(reader, "RevenueImpact_Claims"),
                    RevenueImpact_ActualBilled         = ReadDec(reader, "RevenueImpact_ActualBilled"),
                    RevenueImpact_PotentialLoss        = ReadDec(reader, "RevenueImpact_PotentialLoss"),
                    RevenueImpact_ExpectedRecoup       = ReadDec(reader, "RevenueImpact_ExpectedRecoup"),
                    RevenueLoss_Claims                 = NullInt(reader, "RevenueLoss_Claims"),
                    RevenueLoss_ActualBilled           = ReadDec(reader, "RevenueLoss_ActualBilled"),
                    RevenueLoss_PotentialLoss          = ReadDec(reader, "RevenueLoss_PotentialLoss"),
                    RevenueAtRisk_Claims               = NullInt(reader, "RevenueAtRisk_Claims"),
                    RevenueAtRisk_ActualBilled         = ReadDec(reader, "RevenueAtRisk_ActualBilled"),
                    RevenueAtRisk_PotentialRecoup      = ReadDec(reader, "RevenueAtRisk_PotentialRecoup"),
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

    /// <summary>
    /// Returns the most recent week's raw CodingValidation rows for the
    /// Validation Detail tab via dbo.usp_GetCodingValidationDetail
    /// (capped at 5 000 rows to keep page load fast).
    /// </summary>
    public Task<List<CodingValidationDetailRow>> GetValidationDetailRowsAsync(
        string connectionString, CancellationToken ct = default)
        => GetValidationDetailCoreAsync(connectionString, "dbo.usp_GetCodingValidationDetail", ct);

    // >>> CVDETAIL-ALL (2026-07-27): uncapped variant for the Excel export — every row, all weeks.
    //     REVERT: delete this method (and its interface entry) and re-point callers to GetValidationDetailRowsAsync.
    /// <summary>Returns ALL CodingValidation rows (no TOP, all weeks) for the Excel export.</summary>
    public Task<List<CodingValidationDetailRow>> GetValidationDetailExportRowsAsync(
        string connectionString, CancellationToken ct = default)
        => GetValidationDetailCoreAsync(connectionString, "dbo.usp_GetCodingValidationDetailExport", ct);
    // <<< END CVDETAIL-ALL

    // >>> CVDETAIL-PAGE (2026-07-28): one page of Validation Detail rows, filtered in SQL.
    //     REVERT: delete this method (and its interface entry).
    public async Task<CodingValidationDetailPage> GetValidationDetailPagedAsync(
        string connectionString, int page, int pageSize,
        string? panelName, string? status, string? search, CancellationToken ct = default)
    {
        if (page     < 1) page     = 1;
        if (pageSize < 1) pageSize = 50;

        var rows     = new List<CodingValidationDetailRow>();
        var panels   = new List<string>();
        var statuses = new List<string>();
        var total    = 0;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand("dbo.usp_GetCodingValidationDetailPaged", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 120
            };
            cmd.Parameters.AddWithValue("@Offset",    (page - 1) * pageSize);
            cmd.Parameters.AddWithValue("@PageSize",  pageSize);
            cmd.Parameters.AddWithValue("@PanelName", (object?)panelName ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@Status",    (object?)status    ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@Search",    (object?)search    ?? DBNull.Value);

            await using var reader = await cmd.ExecuteReaderAsync(ct);

            // 1) page rows (+ filtered total)
            var readTotal = false;
            while (await reader.ReadAsync(ct))
            {
                if (!readTotal)
                {
                    total = reader.IsDBNull(reader.GetOrdinal("TotalRows"))
                        ? 0 : reader.GetInt32(reader.GetOrdinal("TotalRows"));
                    readTotal = true;
                }
                rows.Add(MapDetailRow(reader));
            }

            // 2) panel options
            if (await reader.NextResultAsync(ct))
                while (await reader.ReadAsync(ct))
                    panels.Add(Str(reader, "PanelName"));

            // 3) status options
            if (await reader.NextResultAsync(ct))
                while (await reader.ReadAsync(ct))
                    statuses.Add(Str(reader, "ValidationStatus"));

            _logger.LogInformation(
                "CodingValidation detail page {Page} (size {Size}) returned {Count} of {Total} rows.",
                page, pageSize, rows.Count, total);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "GetValidationDetailPagedAsync failed: {Message}", ex.Message);
            throw;
        }

        return new CodingValidationDetailPage
        {
            Rows = rows, TotalRows = total, Panels = panels, Statuses = statuses
        };
    }
    // <<< END CVDETAIL-PAGE

    private async Task<List<CodingValidationDetailRow>> GetValidationDetailCoreAsync(
        string connectionString, string procName, CancellationToken ct)
    {
        var results = new List<CodingValidationDetailRow>();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(procName, conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 300   // CVDETAIL-ALL: export variant can return 30k+ rows
            };
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                results.Add(MapDetailRow(reader));   // CVDETAIL-PAGE: shared mapper
            _logger.LogInformation("CodingValidation detail rows returned {Count}.", results.Count);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "GetValidationDetailRowsAsync failed: {Message}", ex.Message);
            throw;
        }
        return results;
    }

    /// <inheritdoc />
    // >>> CVTPL-1.4 CHANGE (2026-07-27): drill-down "View Calculation" now sums Average ALLOWED amounts
    //     (MissingCPT_AvgAllowedAmount / AdditionalCPT_AvgAllowedAmount) so it reconciles with the
    //     Allowed-based Lost Revenue / Revenue at Risk headline figures per Output Template v1.4.
    //     REVERT: change every "AvgAllowedAmount" back to "AvgPaidAmount" inside this method.
    // <<< END CVTPL-1.4 CHANGE
    public async Task<CodingCalculationDetail> GetCalculationDetailAsync(
        string connectionString,
        string labName,
        string scope,
        int? year,
        string? weekFolder,
        string? panelName,
        string? missingCpts,
        string? additionalCpts,
        CancellationToken ct = default)
    {
        scope = (scope ?? "ytd").Trim().ToLowerInvariant();
        panelName = string.IsNullOrWhiteSpace(panelName) ? null : panelName.Trim();
        weekFolder = string.IsNullOrWhiteSpace(weekFolder) ? null : weekFolder.Trim();
        // null = do not filter; empty string = match blank CPT codes (insight rows).
        missingCpts = missingCpts is null ? null : missingCpts.Trim();
        additionalCpts = additionalCpts is null ? null : additionalCpts.Trim();

        var where = new List<string> { "1 = 1" };
        if (!string.IsNullOrEmpty(panelName))
            where.Add("PanelName = @PanelName");
        if (string.Equals(scope, "ytd", StringComparison.OrdinalIgnoreCase) && year.HasValue)
            where.Add("YEAR(TRY_CAST(DateofService AS DATE)) = @Year");
        if ((string.Equals(scope, "wtd", StringComparison.OrdinalIgnoreCase)
             || string.Equals(scope, "financial", StringComparison.OrdinalIgnoreCase))
            && !string.IsNullOrEmpty(weekFolder))
            where.Add("WeekFolder = @WeekFolder");
        if (missingCpts is not null)
            where.Add("ISNULL(MissingCPTCodes, '') = @MissingCpts");
        if (additionalCpts is not null)
            where.Add("ISNULL(AdditionalCPTCodes, '') = @AdditionalCpts");

        var whereSql = string.Join(" AND ", where);

        var totalsSql = $"""
            SELECT
                COUNT(*) AS TotalClaims,
                COUNT(CASE WHEN MissingCPTCodes IS NOT NULL AND LTRIM(RTRIM(MissingCPTCodes)) <> '' THEN 1 END) AS ClaimsWithMissing,
                COUNT(CASE WHEN AdditionalCPTCodes IS NOT NULL AND LTRIM(RTRIM(AdditionalCPTCodes)) <> '' THEN 1 END) AS ClaimsWithAdditional,
                ISNULL(SUM(TRY_CAST(MissingCPT_Charges AS DECIMAL(18,2))), 0) AS MissingCharges,
                ISNULL(SUM(TRY_CAST(AdditionalCPT_Charges AS DECIMAL(18,2))), 0) AS AdditionalCharges,
                ISNULL(SUM(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2))), 0) AS LostRevenue,
                ISNULL(SUM(TRY_CAST(AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2))), 0) AS RevenueAtRisk
            FROM dbo.CodingValidation WITH (NOLOCK)
            WHERE {whereSql}
            """;

        var groupsSql = $"""
            SELECT TOP (75)
                ISNULL(MissingCPTCodes, '') AS MissingCpts,
                ISNULL(AdditionalCPTCodes, '') AS AdditionalCpts,
                COUNT(*) AS ClaimCount,
                ISNULL(SUM(TRY_CAST(MissingCPT_Charges AS DECIMAL(18,2))), 0) AS MissingCharges,
                ISNULL(SUM(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2))), 0) AS MissingAvgPaid,
                ISNULL(SUM(TRY_CAST(AdditionalCPT_Charges AS DECIMAL(18,2))), 0) AS AdditionalCharges,
                ISNULL(SUM(TRY_CAST(AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2))), 0) AS AdditionalAvgPaid
            FROM dbo.CodingValidation WITH (NOLOCK)
            WHERE {whereSql}
              AND (
                    (MissingCPTCodes IS NOT NULL AND LTRIM(RTRIM(MissingCPTCodes)) <> '')
                 OR (AdditionalCPTCodes IS NOT NULL AND LTRIM(RTRIM(AdditionalCPTCodes)) <> '')
              )
            GROUP BY ISNULL(MissingCPTCodes, ''), ISNULL(AdditionalCPTCodes, '')
            ORDER BY
                ISNULL(SUM(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2))), 0)
              + ISNULL(SUM(TRY_CAST(AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2))), 0) DESC
            """;

        var samplesSql = $"""
            SELECT TOP (100)
                ISNULL(AccessionNo, '') AS AccessionNo,
                ISNULL(DateofService, '') AS DateofService,
                ISNULL(WeekFolder, '') AS WeekFolder,
                ISNULL(PanelName, '') AS PanelName,
                ISNULL(PayerCommonCode, '') AS PayerCommonCode,
                ISNULL(MissingCPTCodes, '') AS MissingCpts,
                ISNULL(AdditionalCPTCodes, '') AS AdditionalCpts,
                ISNULL(TRY_CAST(MissingCPT_Charges AS DECIMAL(18,2)), 0) AS MissingCharges,
                ISNULL(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2)), 0) AS MissingAvgPaid,
                ISNULL(TRY_CAST(AdditionalCPT_Charges AS DECIMAL(18,2)), 0) AS AdditionalCharges,
                ISNULL(TRY_CAST(AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2)), 0) AS AdditionalAvgPaid
            FROM dbo.CodingValidation WITH (NOLOCK)
            WHERE {whereSql}
              AND (
                    ISNULL(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2)), 0) <> 0
                 OR ISNULL(TRY_CAST(AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2)), 0) <> 0
                 OR (MissingCPTCodes IS NOT NULL AND LTRIM(RTRIM(MissingCPTCodes)) <> '')
                 OR (AdditionalCPTCodes IS NOT NULL AND LTRIM(RTRIM(AdditionalCPTCodes)) <> '')
              )
            ORDER BY
                ISNULL(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2)), 0)
              + ISNULL(TRY_CAST(AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2)), 0) DESC,
                AccessionNo
            """;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            int totalClaims = 0, claimsMissing = 0, claimsAddl = 0;
            decimal missingCharges = 0, addlCharges = 0, lost = 0, atRisk = 0;

            await using (var cmd = new SqlCommand(totalsSql, conn) { CommandTimeout = 120 })
            {
                BindCalcParams(cmd, year, weekFolder, panelName, missingCpts, additionalCpts);
                await using var reader = await cmd.ExecuteReaderAsync(ct);
                if (await reader.ReadAsync(ct))
                {
                    totalClaims = reader.GetInt32(0);
                    claimsMissing = reader.GetInt32(1);
                    claimsAddl = reader.GetInt32(2);
                    missingCharges = reader.GetDecimal(3);
                    addlCharges = reader.GetDecimal(4);
                    lost = reader.GetDecimal(5);
                    atRisk = reader.GetDecimal(6);
                }
            }

            var groups = new List<CodingCalcCptGroup>();
            await using (var cmd = new SqlCommand(groupsSql, conn) { CommandTimeout = 120 })
            {
                BindCalcParams(cmd, year, weekFolder, panelName, missingCpts, additionalCpts);
                await using var reader = await cmd.ExecuteReaderAsync(ct);
                while (await reader.ReadAsync(ct))
                {
                    groups.Add(new CodingCalcCptGroup
                    {
                        MissingCpts = reader.GetString(0),
                        AdditionalCpts = reader.GetString(1),
                        ClaimCount = reader.GetInt32(2),
                        MissingCharges = reader.GetDecimal(3),
                        MissingAvgPaid = reader.GetDecimal(4),
                        AdditionalCharges = reader.GetDecimal(5),
                        AdditionalAvgPaid = reader.GetDecimal(6),
                    });
                }
            }

            var samples = new List<CodingCalcClaimSample>();
            await using (var cmd = new SqlCommand(samplesSql, conn) { CommandTimeout = 120 })
            {
                BindCalcParams(cmd, year, weekFolder, panelName, missingCpts, additionalCpts);
                await using var reader = await cmd.ExecuteReaderAsync(ct);
                while (await reader.ReadAsync(ct))
                {
                    samples.Add(new CodingCalcClaimSample
                    {
                        AccessionNo = reader.GetString(0),
                        DateofService = reader.GetString(1),
                        WeekFolder = reader.GetString(2),
                        PanelName = reader.GetString(3),
                        PayerCommonCode = reader.GetString(4),
                        MissingCpts = reader.GetString(5),
                        AdditionalCpts = reader.GetString(6),
                        MissingCharges = reader.GetDecimal(7),
                        MissingAvgPaid = reader.GetDecimal(8),
                        AdditionalCharges = reader.GetDecimal(9),
                        AdditionalAvgPaid = reader.GetDecimal(10),
                    });
                }
            }

            _logger.LogInformation(
                "CalculationDetail scope={Scope} year={Year} week={Week} panel={Panel} claims={Claims} groups={Groups} samples={Samples}",
                scope, year, weekFolder, panelName, totalClaims, groups.Count, samples.Count);

            return new CodingCalculationDetail
            {
                LabName = labName,
                Scope = scope,
                Year = year,
                WeekFolder = weekFolder,
                PanelName = panelName,
                MissingCptsFilter = missingCpts,
                AdditionalCptsFilter = additionalCpts,
                TotalClaims = totalClaims,
                ClaimsWithMissingCpts = claimsMissing,
                ClaimsWithAdditionalCpts = claimsAddl,
                MissingChargesTotal = missingCharges,
                AdditionalChargesTotal = addlCharges,
                LostRevenue = lost,
                RevenueAtRisk = atRisk,
                CptGroups = groups,
                ClaimSamples = samples,
            };
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "GetCalculationDetailAsync failed for lab '{LabName}'.", labName);
            throw;
        }
    }

    private static void BindCalcParams(
        SqlCommand cmd,
        int? year,
        string? weekFolder,
        string? panelName,
        string? missingCpts,
        string? additionalCpts)
    {
        if (year.HasValue)
            cmd.Parameters.AddWithValue("@Year", year.Value);
        if (!string.IsNullOrEmpty(weekFolder))
            cmd.Parameters.AddWithValue("@WeekFolder", weekFolder);
        if (!string.IsNullOrEmpty(panelName))
            cmd.Parameters.AddWithValue("@PanelName", panelName);
        if (missingCpts is not null)
            cmd.Parameters.AddWithValue("@MissingCpts", missingCpts);
        if (additionalCpts is not null)
            cmd.Parameters.AddWithValue("@AdditionalCpts", additionalCpts);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    // >>> CVUI-SRC CHANGE (2026-07-27): read source files (RunId + inserted datetime) for the header.
    //     REVERT: delete this method.
    public async Task<List<CodingSourceFileRow>> GetSourceFilesAsync(
        string connectionString, string labName, CancellationToken ct = default)
    {
        return await QueryProcAsync(connectionString, "dbo.usp_GetCodingValidationSourceInfo", labName,
            r => new CodingSourceFileRow
            {
                RunId               = Str(r, "RunId"),
                WeekFolder          = Str(r, "WeekFolder"),
                LabName             = Str(r, "LabName"),
                FileName            = Str(r, "FileName"),
                FileCreatedDateTime = DtNull(r, "FileCreatedDateTime"),
                InsertedDateTime    = DtNull(r, "InsertedDateTime") ?? default,
            }, ct);
    }
    // <<< END CVUI-SRC CHANGE

    private async Task<List<T>> QueryProcAsync<T>(
        string connectionString, string procName, string labName,
        Func<SqlDataReader, T> map, CancellationToken ct)
    {
        var results = new List<T>();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            await using var cmd = new SqlCommand(procName, conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 120
            };

            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                results.Add(map(reader));

            _logger.LogInformation(
                "{Proc} for '{LabName}' returned {Count} rows.", procName, labName, results.Count);
        }
        catch (Exception ex)
        {
            // Log the full exception — never swallow silently so blank pages are diagnosable.
            _logger.LogError(ex,
                "{Proc} failed for lab '{LabName}': {Message}", procName, labName, ex.Message);
            throw;   // re-throw so the controller can show the error in the UI
        }
        return results;
    }

    private static string  Str(SqlDataReader r, string col)
        => r.IsDBNull(r.GetOrdinal(col)) ? string.Empty : r.GetString(r.GetOrdinal(col));

    private static decimal ReadDec(SqlDataReader r, string col)
        => r.IsDBNull(r.GetOrdinal(col)) ? 0m : r.GetDecimal(r.GetOrdinal(col));

    private static int? NullInt(SqlDataReader r, string col)
        => r.IsDBNull(r.GetOrdinal(col)) ? null : r.GetInt32(r.GetOrdinal(col));

    private static bool HasCol(SqlDataReader r, string col)
    {
        for (var i = 0; i < r.FieldCount; i++)
        {
            if (string.Equals(r.GetName(i), col, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    // >>> CVDETAIL-PAGE (2026-07-28): shared row mapper used by the paged, capped and export readers.
    //     REVERT: inline this back into GetValidationDetailCoreAsync.
    private static CodingValidationDetailRow MapDetailRow(SqlDataReader reader) => new()
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
        VisitNumber                                  = Str(reader, "VisitNumber"),
        PayerName_Raw                                = Str(reader, "PayerName_Raw"),
        Carrier                                      = Str(reader, "Carrier"),
        Payer_Code                                   = Str(reader, "Payer_Code"),
        PayerCommonCode                              = Str(reader, "PayerCommonCode"),
        Payer_Group_Code                             = Str(reader, "Payer_Group_Code"),
        Global_Payer_ID                              = Str(reader, "Global_Payer_ID"),
        FirstBillDate                                = Str(reader, "FirstBillDate"),
        AllowedAmount                                = Str(reader, "AllowedAmount"),
        InsurancePayment                             = Str(reader, "InsurancePayment"),
        ExpectedCharges                              = Str(reader, "ExpectedCharges"),
        MissingCPT_AvgAllowedAmount                  = Str(reader, "MissingCPT_AvgAllowedAmount"),
        MissingCPT_AvgPaidAmount                     = Str(reader, "MissingCPT_AvgPaidAmount"),
        MissingCPT_AvgPatientResponsibilityAmount    = Str(reader, "MissingCPT_AvgPatientResponsibilityAmount"),
        AdditionalCPT_AvgAllowedAmount               = Str(reader, "AdditionalCPT_AvgAllowedAmount"),
        AdditionalCPT_AvgPaidAmount                  = Str(reader, "AdditionalCPT_AvgPaidAmount"),
        AdditionalCPT_AvgPatientResponsibilityAmount = Str(reader, "AdditionalCPT_AvgPatientResponsibilityAmount"),
        MissingCPT_ChargeSource                      = Str(reader, "MissingCPT_ChargeSource"),
        AdditionalCPT_ChargeSource                   = Str(reader, "AdditionalCPT_ChargeSource"),
    };
    // <<< END CVDETAIL-PAGE

    // >>> CVUI-SRC CHANGE (2026-07-27): nullable DateTime reader for source-file columns.
    //     REVERT: delete this helper.
    private static DateTime? DtNull(SqlDataReader r, string col)
        => r.IsDBNull(r.GetOrdinal(col)) ? null : r.GetDateTime(r.GetOrdinal(col));
    // <<< END CVUI-SRC CHANGE
}
