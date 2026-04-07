using System.Text.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using CaptureDataApp.Models;

namespace CaptureDataApp.Services;

/// <summary>
/// Writes the full CodingMaster dashboard payload as a JSON sidecar file
/// alongside the source Excel report. The output file uses the same path
/// and base name as the <c>.xlsx</c> with the extension changed to <c>.json</c>.
///
/// Example:
///   Source : E:\...\ReportsOutput\03.19.2026\20260327_PhiLife_CodingValidated.xlsx
///   Output : E:\...\ReportsOutput\03.19.2026\20260327_PhiLife_CodingValidated.json
///
/// Payload sections:
///   Meta              – lab name, week, report date, generated timestamp
///   FinancialSummary  – totals, revenue loss, revenue at risk, compliance
///   YtdInsights       – per-panel YTD coding insights (lost revenue, revenue at risk, net impact)
///   YtdSummary        – per-panel YTD aggregated summary
///   WtdInsights       – per-panel WTD coding insights
///   WtdSummary        – per-panel WTD aggregated summary
///   ValidationDetail  – latest week raw validation rows
/// </summary>
public static class DashboardJsonWriter
{
    private static readonly JsonSerializerOptions _jsonOptions = new()
    {
        WriteIndented          = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy   = null,   // keep PascalCase
    };

    // ?? Public API ????????????????????????????????????????????????????????????

    /// <summary>
    /// Builds the full dashboard payload from all data sources and writes it to
    /// a <c>.json</c> file next to <paramref name="sourceXlsxPath"/>.
    /// Returns the path of the written file.
    /// </summary>
    public static string Write(
        string                        sourceXlsxPath,
        CodingFinancialSummary        financialSummary,
        List<YtdInsightRecord>        ytdInsights,
        List<YtdSummaryRecord>        ytdSummary,
        List<WtdInsightRecord>        wtdInsights,
        List<WtdSummaryRecord>        wtdSummary,
        List<ValidationDetailRecord>  validationDetail)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceXlsxPath);
        ArgumentNullException.ThrowIfNull(financialSummary);

        var payload = BuildPayload(
            financialSummary,
            ytdInsights, ytdSummary,
            wtdInsights, wtdSummary,
            validationDetail);

        var jsonPath = Path.ChangeExtension(sourceXlsxPath, ".json");
        File.WriteAllText(jsonPath, JsonSerializer.Serialize(payload, _jsonOptions),
                          System.Text.Encoding.UTF8);
        return jsonPath;
    }

    // ?? Payload builder ???????????????????????????????????????????????????????

    private static DashboardPayload BuildPayload(
        CodingFinancialSummary       fs,
        List<YtdInsightRecord>       ytdInsights,
        List<YtdSummaryRecord>       ytdSummary,
        List<WtdInsightRecord>       wtdInsights,
        List<WtdSummaryRecord>       wtdSummary,
        List<ValidationDetailRecord> detail)
    {
        return new DashboardPayload
        {
            Meta = new MetaSection
            {
                GeneratedUtc = DateTime.UtcNow.ToString("o"),
                LabName      = fs.LabName,
                WeekFolder   = fs.WeekFolder,
                ReportDate   = fs.ReportDate,
            },

            FinancialSummary = new FinancialSummarySection
            {
                Totals = new TotalsBlock
                {
                    TotalClaims           = fs.TotalClaims,
                    TotalBilledCharges    = fs.TotalBilledCharges,
                    ExpectedBilledCharges = fs.ExpectedBilledCharges,
                },
                RevenueImpact = new RevenueImpactBlock
                {
                    Claims           = fs.RevenueImpact_Claims,
                    ActualBilled     = fs.RevenueImpact_ActualBilled,
                    PotentialLoss    = fs.RevenueImpact_PotentialLoss,
                    ExpectedRecoup   = fs.RevenueImpact_ExpectedRecoup,
                },
                RevenueLoss = new RevenueLossBlock
                {
                    Claims        = fs.RevenueLoss_Claims,
                    ActualBilled  = fs.RevenueLoss_ActualBilled,
                    PotentialLoss = fs.RevenueLoss_PotentialLoss,
                },
                RevenueAtRisk = new RevenueAtRiskBlock
                {
                    Claims          = fs.RevenueAtRisk_Claims,
                    ActualBilled    = fs.RevenueAtRisk_ActualBilled,
                    PotentialRecoup = fs.RevenueAtRisk_PotentialRecoup,
                },
                Compliance = new ComplianceBlock
                {
                    TotalClaims                       = fs.Compliance_TotalClaims,
                    ClaimsWithIssues                  = fs.Compliance_ClaimsWithIssues,
                    ComplianceRate                    = fs.ComplianceRate,
                    ComplianceRatePct                 = fs.ComplianceRatePct,
                    ClaimsWithMissingCPTs             = fs.ClaimsWithMissingCPTs,
                    ClaimsWithAdditionalCPTs          = fs.ClaimsWithAdditionalCPTs,
                    ClaimsWithBothMissingAndAdditional= fs.ClaimsWithBothMissingAndAdditional,
                    TotalErrorClaims                  = fs.TotalErrorClaims,
                },
            },

            YtdInsights      = ytdInsights,
            YtdSummary       = ytdSummary,
            WtdInsights      = wtdInsights,
            WtdSummary       = wtdSummary,
            ValidationDetail = detail,
        };
    }

    // ?? Root payload ??????????????????????????????????????????????????????????

    private sealed class DashboardPayload
    {
        public MetaSection              Meta             { get; init; } = new();
        public FinancialSummarySection  FinancialSummary { get; init; } = new();
        public List<YtdInsightRecord>   YtdInsights      { get; init; } = [];
        public List<YtdSummaryRecord>   YtdSummary       { get; init; } = [];
        public List<WtdInsightRecord>   WtdInsights      { get; init; } = [];
        public List<WtdSummaryRecord>   WtdSummary       { get; init; } = [];
        public List<ValidationDetailRecord> ValidationDetail { get; init; } = [];
    }

    // ?? Meta ??????????????????????????????????????????????????????????????????

    private sealed class MetaSection
    {
        public string GeneratedUtc { get; init; } = string.Empty;
        public string LabName      { get; init; } = string.Empty;
        public string WeekFolder   { get; init; } = string.Empty;
        public string ReportDate   { get; init; } = string.Empty;
    }

    // ?? Financial summary sections ????????????????????????????????????????????

    private sealed class FinancialSummarySection
    {
        public TotalsBlock       Totals        { get; init; } = new();
        public RevenueImpactBlock RevenueImpact { get; init; } = new();
        public RevenueLossBlock   RevenueLoss   { get; init; } = new();
        public RevenueAtRiskBlock RevenueAtRisk { get; init; } = new();
        public ComplianceBlock    Compliance    { get; init; } = new();
    }

    private sealed class TotalsBlock
    {
        public int?     TotalClaims           { get; init; }
        public decimal? TotalBilledCharges    { get; init; }
        public decimal? ExpectedBilledCharges { get; init; }
    }

    private sealed class RevenueImpactBlock
    {
        public int?     Claims         { get; init; }
        public decimal? ActualBilled   { get; init; }
        public decimal? PotentialLoss  { get; init; }
        public decimal? ExpectedRecoup { get; init; }
    }

    private sealed class RevenueLossBlock
    {
        public int?     Claims        { get; init; }
        public decimal? ActualBilled  { get; init; }
        public decimal? PotentialLoss { get; init; }
    }

    private sealed class RevenueAtRiskBlock
    {
        public int?     Claims          { get; init; }
        public decimal? ActualBilled    { get; init; }
        public decimal? PotentialRecoup { get; init; }
    }

    private sealed class ComplianceBlock
    {
        public int?    TotalClaims                        { get; init; }
        public int?    ClaimsWithIssues                   { get; init; }
        public string  ComplianceRate                     { get; init; } = string.Empty;
        public string  ComplianceRatePct                  { get; init; } = string.Empty;
        public int?    ClaimsWithMissingCPTs              { get; init; }
        public int?    ClaimsWithAdditionalCPTs           { get; init; }
        public int?    ClaimsWithBothMissingAndAdditional { get; init; }
        public int?    TotalErrorClaims                   { get; init; }
    }
}

