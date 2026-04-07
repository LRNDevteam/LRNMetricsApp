using Microsoft.Data.SqlClient;
using CaptureDataApp.Models;

namespace CaptureDataApp.Services;

/// <summary>
/// Reads all coding-dashboard data (YTD Insights, YTD Summary, WTD Insights,
/// WTD Summary, Validation Detail) directly from the CodingValidation database.
///
/// Uses the same SQL logic as <c>SqlCodingValidationRepository</c> in the web
/// project but runs synchronously inside CaptureDataApp's console context.
/// </summary>
public static class CodingDashboardDbReader
{
    // ?? Public API ????????????????????????????????????????????????????????????

    public static List<YtdInsightRecord> GetYtdInsights(string connectionString)
    {
        const string sql = """
            SELECT
                g.ServiceYear,
                g.PanelName,
                STUFF((
                    SELECT DISTINCT '*' + d1.ActualCPTCode
                    FROM dbo.CodingValidation d1
                    WHERE YEAR(TRY_CAST(d1.DateofService AS DATE)) = g.ServiceYear
                      AND d1.PanelName = g.PanelName
                      AND d1.ActualCPTCode IS NOT NULL AND d1.ActualCPTCode <> ''
                    ORDER BY '*' + d1.ActualCPTCode
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BillableCptCombo,
                g.TotalClaims,
                g.BilledChargesPerClaim,
                STUFF((
                    SELECT DISTINCT '*' + d2.ExpectedCPTCode
                    FROM dbo.CodingValidation d2
                    WHERE YEAR(TRY_CAST(d2.DateofService AS DATE)) = g.ServiceYear
                      AND d2.PanelName = g.PanelName
                      AND d2.ExpectedCPTCode IS NOT NULL AND d2.ExpectedCPTCode <> ''
                    ORDER BY '*' + d2.ExpectedCPTCode
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BilledCptCombo,
                STUFF((
                    SELECT DISTINCT '*' + d3.MissingCPTCodes
                    FROM dbo.CodingValidation d3
                    WHERE YEAR(TRY_CAST(d3.DateofService AS DATE)) = g.ServiceYear
                      AND d3.PanelName = g.PanelName
                      AND d3.MissingCPTCodes IS NOT NULL AND d3.MissingCPTCodes <> ''
                    ORDER BY '*' + d3.MissingCPTCodes
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS MissingCpts,
                g.TotalBilledChargesForMissingCpts,
                g.LostRevenue,
                STUFF((
                    SELECT DISTINCT '*' + d4.AdditionalCPTCodes
                    FROM dbo.CodingValidation d4
                    WHERE YEAR(TRY_CAST(d4.DateofService AS DATE)) = g.ServiceYear
                      AND d4.PanelName = g.PanelName
                      AND d4.AdditionalCPTCodes IS NOT NULL AND d4.AdditionalCPTCodes <> ''
                    ORDER BY '*' + d4.AdditionalCPTCodes
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS AdditionalCpts,
                g.TotalBilledChargesForAdditionalCpts,
                g.RevenueAtRisk
            FROM (
                SELECT
                    YEAR(TRY_CAST(DateofService AS DATE))                       AS ServiceYear,
                    PanelName,
                    COUNT(*)                                                     AS TotalClaims,
                    AVG(TRY_CAST(TotalCharge AS DECIMAL(18,2)))                 AS BilledChargesPerClaim,
                    SUM(TRY_CAST(MissingCPT_Charges AS DECIMAL(18,2)))         AS TotalBilledChargesForMissingCpts,
                    SUM(TRY_CAST(MissingCPT_AvgPaidAmount AS DECIMAL(18,2)))   AS LostRevenue,
                    SUM(TRY_CAST(AdditionalCPT_Charges AS DECIMAL(18,2)))      AS TotalBilledChargesForAdditionalCpts,
                    SUM(TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2))) AS RevenueAtRisk
                FROM dbo.CodingValidation
                WHERE PanelName IS NOT NULL AND PanelName <> ''
                  AND YEAR(TRY_CAST(DateofService AS DATE)) IS NOT NULL
                GROUP BY YEAR(TRY_CAST(DateofService AS DATE)), PanelName
            ) g
            ORDER BY g.ServiceYear DESC, g.PanelName;
            """;

        return Query(connectionString, sql, r =>
        {
            var lostRevenue   = Dec(r, "LostRevenue");
            var revenueAtRisk = Dec(r, "RevenueAtRisk");
            return new YtdInsightRecord(
                Year:                               r.GetInt32(r.GetOrdinal("ServiceYear")),
                PanelName:                          Str(r, "PanelName"),
                BillableCptCombo:                   Str(r, "BillableCptCombo"),
                TotalClaims:                        r.GetInt32(r.GetOrdinal("TotalClaims")),
                BilledChargesPerClaim:              Dec(r, "BilledChargesPerClaim"),
                BilledCptCombo:                     Str(r, "BilledCptCombo"),
                MissingCpts:                        Str(r, "MissingCpts"),
                TotalBilledChargesForMissingCpts:   Dec(r, "TotalBilledChargesForMissingCpts"),
                LostRevenue:                        lostRevenue,
                AdditionalCpts:                     Str(r, "AdditionalCpts"),
                TotalBilledChargesForAdditionalCpts: Dec(r, "TotalBilledChargesForAdditionalCpts"),
                RevenueAtRisk:                      revenueAtRisk,
                NetImpact:                          lostRevenue - revenueAtRisk
            );
        });
    }

    public static List<YtdSummaryRecord> GetYtdSummary(string connectionString)
    {
        const string sql = """
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
            GROUP BY YEAR(TRY_CAST(DateofService AS DATE)), PanelName
            ORDER BY ServiceYear DESC, PanelName;
            """;

        return Query(connectionString, sql, r =>
        {
            var lost = Dec(r, "LostRevenue");
            var risk = Dec(r, "RevenueAtRisk");
            return new YtdSummaryRecord(
                Year:                               r.GetInt32(r.GetOrdinal("ServiceYear")),
                PanelName:                          Str(r, "PanelName"),
                TotalClaims:                        r.GetInt32(r.GetOrdinal("TotalClaims")),
                TotalBilledCharges:                 Dec(r, "TotalBilledCharges"),
                DistinctClaimsWithMissingCpts:      r.GetInt32(r.GetOrdinal("DistinctClaimsWithMissingCpts")),
                TotalBilledChargesForMissingCpts:   Dec(r, "TotalBilledChargesForMissingCpts"),
                DistinctClaimsWithAdditionalCpts:   r.GetInt32(r.GetOrdinal("DistinctClaimsWithAdditionalCpts")),
                TotalBilledChargesForAdditionalCpts: Dec(r, "TotalBilledChargesForAdditionalCpts"),
                LostRevenue:                        lost,
                RevenueAtRisk:                      risk,
                NetImpact:                          lost - risk
            );
        });
    }

    public static List<WtdInsightRecord> GetWtdInsights(string connectionString)
    {
        const string sql = """
            SELECT
                g.WeekFolder,
                g.PanelName,
                STUFF((
                    SELECT DISTINCT '*' + d1.ActualCPTCode
                    FROM dbo.CodingValidation d1
                    WHERE d1.WeekFolder = g.WeekFolder AND d1.PanelName = g.PanelName
                      AND d1.ActualCPTCode IS NOT NULL AND d1.ActualCPTCode <> ''
                    ORDER BY '*' + d1.ActualCPTCode
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BillableCptCombo,
                g.TotalClaims,
                g.TotalBilledCharges,
                STUFF((
                    SELECT DISTINCT '*' + d2.ExpectedCPTCode
                    FROM dbo.CodingValidation d2
                    WHERE d2.WeekFolder = g.WeekFolder AND d2.PanelName = g.PanelName
                      AND d2.ExpectedCPTCode IS NOT NULL AND d2.ExpectedCPTCode <> ''
                    ORDER BY '*' + d2.ExpectedCPTCode
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BilledCptCombo,
                STUFF((
                    SELECT DISTINCT '*' + d3.MissingCPTCodes
                    FROM dbo.CodingValidation d3
                    WHERE d3.WeekFolder = g.WeekFolder AND d3.PanelName = g.PanelName
                      AND d3.MissingCPTCodes IS NOT NULL AND d3.MissingCPTCodes <> ''
                    ORDER BY '*' + d3.MissingCPTCodes
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS MissingCpts,
                g.BilledChargesForMissingCpts,
                g.RevenueLoss,
                STUFF((
                    SELECT DISTINCT '*' + d4.AdditionalCPTCodes
                    FROM dbo.CodingValidation d4
                    WHERE d4.WeekFolder = g.WeekFolder AND d4.PanelName = g.PanelName
                      AND d4.AdditionalCPTCodes IS NOT NULL AND d4.AdditionalCPTCodes <> ''
                    ORDER BY '*' + d4.AdditionalCPTCodes
                    FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS AdditionalCpts,
                g.BilledChargesForAdditionalCpts,
                g.PotentialRecoupment
            FROM (
                SELECT
                    WeekFolder, PanelName,
                    COUNT(*)                                                        AS TotalClaims,
                    SUM(TRY_CAST(TotalCharge              AS DECIMAL(18,2)))        AS TotalBilledCharges,
                    SUM(TRY_CAST(MissingCPT_Charges       AS DECIMAL(18,2)))        AS BilledChargesForMissingCpts,
                    SUM(TRY_CAST(MissingCPT_AvgPaidAmount AS DECIMAL(18,2)))        AS RevenueLoss,
                    SUM(TRY_CAST(AdditionalCPT_Charges    AS DECIMAL(18,2)))        AS BilledChargesForAdditionalCpts,
                    SUM(TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2)))     AS PotentialRecoupment
                FROM dbo.CodingValidation
                WHERE WeekFolder IS NOT NULL AND WeekFolder <> ''
                  AND PanelName  IS NOT NULL AND PanelName  <> ''
                GROUP BY WeekFolder, PanelName
            ) g
            ORDER BY g.WeekFolder DESC, g.PanelName;
            """;

        return Query(connectionString, sql, r =>
        {
            var loss  = Dec(r, "RevenueLoss");
            var recoup = Dec(r, "PotentialRecoupment");
            return new WtdInsightRecord(
                WeekFolder:                    Str(r, "WeekFolder"),
                PanelName:                     Str(r, "PanelName"),
                BillableCptCombo:              Str(r, "BillableCptCombo"),
                TotalClaims:                   r.GetInt32(r.GetOrdinal("TotalClaims")),
                TotalBilledCharges:            Dec(r, "TotalBilledCharges"),
                BilledCptCombo:                Str(r, "BilledCptCombo"),
                MissingCpts:                   Str(r, "MissingCpts"),
                BilledChargesForMissingCpts:   Dec(r, "BilledChargesForMissingCpts"),
                RevenueLoss:                   loss,
                AdditionalCpts:                Str(r, "AdditionalCpts"),
                BilledChargesForAdditionalCpts: Dec(r, "BilledChargesForAdditionalCpts"),
                PotentialRecoupment:           recoup,
                NetImpact:                     loss - recoup
            );
        });
    }

    public static List<WtdSummaryRecord> GetWtdSummary(string connectionString)
    {
        const string sql = """
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
            ORDER BY WeekFolder DESC, PanelName;
            """;

        return Query(connectionString, sql, r => new WtdSummaryRecord(
            WeekFolder:                      Str(r, "WeekFolder"),
            PanelName:                       Str(r, "PanelName"),
            TotalClaims:                     r.GetInt32(r.GetOrdinal("TotalClaims")),
            DistinctClaimsWithMissingCpts:   r.GetInt32(r.GetOrdinal("DistinctClaimsWithMissingCpts")),
            TotalBilledChargesForMissingCpts: Dec(r, "TotalBilledChargesForMissingCpts"),
            AvgAllowedAmountForMissingCpts:  Dec(r, "AvgAllowedAmountForMissingCpts")
        ));
    }

    public static List<ValidationDetailRecord> GetValidationDetail(string connectionString)
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
                SELECT TOP 1 WeekFolder
                FROM dbo.CodingValidation
                ORDER BY InsertedDateTime DESC
            )
            ORDER BY PanelName, AccessionNo;
            """;

        return Query(connectionString, sql, r => new ValidationDetailRecord(
            WeekFolder:            Str(r, "WeekFolder"),
            AccessionNo:           Str(r, "AccessionNo"),
            PanelName:             Str(r, "PanelName"),
            DateofService:         Str(r, "DateofService"),
            ActualCPTCode:         Str(r, "ActualCPTCode"),
            ExpectedCPTCode:       Str(r, "ExpectedCPTCode"),
            MissingCPTCodes:       Str(r, "MissingCPTCodes"),
            AdditionalCPTCodes:    Str(r, "AdditionalCPTCodes"),
            ValidationStatus:      Str(r, "ValidationStatus"),
            TotalCharge:           Str(r, "TotalCharge"),
            MissingCPT_Charges:    Str(r, "MissingCPT_Charges"),
            AdditionalCPT_Charges: Str(r, "AdditionalCPT_Charges"),
            Remarks:               Str(r, "Remarks")
        ));
    }

    // ?? Generic query helper ??????????????????????????????????????????????????

    private static List<T> Query<T>(
        string connectionString, string sql, Func<SqlDataReader, T> map)
    {
        var results = new List<T>();
        using var conn = new SqlConnection(connectionString);
        conn.Open();
        using var cmd    = new SqlCommand(sql, conn) { CommandTimeout = 180 };
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            results.Add(map(reader));
        return results;
    }

    // ?? Field helpers ?????????????????????????????????????????????????????????

    private static string  Str(SqlDataReader r, string col)
        => r.IsDBNull(r.GetOrdinal(col)) ? string.Empty : r.GetString(r.GetOrdinal(col));

    private static decimal Dec(SqlDataReader r, string col)
        => r.IsDBNull(r.GetOrdinal(col)) ? 0m : r.GetDecimal(r.GetOrdinal(col));
}
