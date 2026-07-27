using System.Data;
using Microsoft.Data.SqlClient;
using CaptureDataApp.Models;

namespace CaptureDataApp.Services;

/// <summary>
/// Reads all coding-dashboard data (YTD Insights, YTD Summary, WTD Insights,
/// WTD Summary, Validation Detail) via the stored procedures created in
/// 04_CodingAggregates.sql. The YTD/WTD datasets come from the pre-computed
/// aggregate tables (refreshed by usp_RefreshCodingAggregates after each load),
/// so results are identical to what the LabMetricsDashboard web UI shows.
///
/// Convention (matches the dashboard):
///   BillableCptCombo = ExpectedCPTCode (panel master / what SHOULD be billed)
///   BilledCptCombo   = ActualCPTCode   (what WAS billed)
/// </summary>
public static class CodingDashboardDbReader
{
    // ?? Public API ????????????????????????????????????????????????????????????

    public static List<YtdInsightRecord> GetYtdInsights(string connectionString)
        => QueryProc(connectionString, "dbo.usp_GetCodingAggYtdInsights", r =>
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

    public static List<YtdSummaryRecord> GetYtdSummary(string connectionString)
        => QueryProc(connectionString, "dbo.usp_GetCodingAggYtdSummary", r =>
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

    public static List<WtdInsightRecord> GetWtdInsights(string connectionString)
        => QueryProc(connectionString, "dbo.usp_GetCodingAggWtdInsights", r =>
        {
            var loss   = Dec(r, "RevenueLoss");
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

    public static List<WtdSummaryRecord> GetWtdSummary(string connectionString)
        => QueryProc(connectionString, "dbo.usp_GetCodingAggWtdSummary", r => new WtdSummaryRecord(
            WeekFolder:                      Str(r, "WeekFolder"),
            PanelName:                       Str(r, "PanelName"),
            TotalClaims:                     r.GetInt32(r.GetOrdinal("TotalClaims")),
            DistinctClaimsWithMissingCpts:   r.GetInt32(r.GetOrdinal("DistinctClaimsWithMissingCpts")),
            TotalBilledChargesForMissingCpts: Dec(r, "TotalBilledChargesForMissingCpts"),
            AvgAllowedAmountForMissingCpts:  Dec(r, "AvgAllowedAmountForMissingCpts")
        ));

    public static List<ValidationDetailRecord> GetValidationDetail(string connectionString)
        => QueryProc(connectionString, "dbo.usp_GetCodingValidationDetail", r => new ValidationDetailRecord(
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

    // ?? Generic proc helper ???????????????????????????????????????????????????

    private static List<T> QueryProc<T>(
        string connectionString, string procName, Func<SqlDataReader, T> map)
    {
        var results = new List<T>();
        using var conn = new SqlConnection(connectionString);
        conn.Open();
        using var cmd = new SqlCommand(procName, conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 180
        };
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
