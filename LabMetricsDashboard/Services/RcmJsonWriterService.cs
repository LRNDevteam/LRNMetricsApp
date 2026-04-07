using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds and writes an RCM summary JSON file from a Claim Level CSV for a given lab.
/// Output path   : <see cref="LabCsvConfig.RCMJsonPath"/>
/// Output filename: same as the Claim Level CSV with "Claim Level" replaced by "RCM".
/// Skipped when  : RCMJsonPath is empty, no CSV is found, or the JSON is already up-to-date.
/// </summary>
public sealed class RcmJsonWriterService
{
    private static readonly JsonSerializerOptions _opts = new()
    {
        WriteIndented          = true,
        PropertyNamingPolicy   = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder                = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private readonly LabSettings             _labSettings;
    private readonly LabCsvFileResolver      _resolver;
    private readonly CsvParserService        _csv;
    private readonly ILogger<RcmJsonWriterService> _logger;

    public RcmJsonWriterService(
        LabSettings             labSettings,
        LabCsvFileResolver      resolver,
        CsvParserService        csv,
        ILogger<RcmJsonWriterService> logger)
    {
        _labSettings = labSettings;
        _resolver    = resolver;
        _csv         = csv;
        _logger      = logger;
    }

    /// <summary>
    /// Generates RCM JSON files for every lab that has both a Claim Level CSV
    /// and a non-empty <see cref="LabCsvConfig.RCMJsonPath"/> configured.
    /// Called in the background at application start.
    /// </summary>
    public void GenerateAll()
    {
        foreach (var (labName, config) in _labSettings.Labs)
        {
            try
            {
                Generate(labName, config);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "[RCM] Failed to generate JSON for lab '{Lab}'.", labName);
            }
        }
    }

    /// <summary>
    /// Generates the RCM JSON for a single lab.
    /// <summary>
    /// Generates the RCM JSON for a single lab.
    /// Output filename mirrors the source CSV with "Claim Level" replaced by "RCM":
    ///   e.g. 20260327R0227_PCR Labs of America_RCM_03.19.2026 to 03.25.2026.json
    /// Skipped when the JSON already exists and is newer than the source CSV.
    /// When a new CSV arrives (new week/run-id) the new JSON is written and any
    /// previous <c>{LabName}_RCM.json</c> stable file is removed.
    /// </summary>
    public void Generate(string labName, LabCsvConfig config)
    {
        if (string.IsNullOrWhiteSpace(config.RCMJsonPath))
        {
            _logger.LogDebug("[RCM] Skipping '{Lab}' — RCMJsonPath not configured.", labName);
            return;
        }

        var csvPath = _resolver.ResolveClaimLevelCsv(labName);
        if (csvPath is null)
        {
            _logger.LogWarning("[RCM] No Claim Level CSV found for '{Lab}' — skipping.", labName);
            return;
        }

        // Derive output filename from the CSV name:
        //   {RunId}_{Lab}_Claim Level_{WeekFolder}.csv
        //   ? {RunId}_{Lab}_RCM_{WeekFolder}.json
        var csvBaseName  = Path.GetFileNameWithoutExtension(csvPath);
        var jsonFileName = csvBaseName.Replace(
            "Claim Level", "RCM", StringComparison.OrdinalIgnoreCase) + ".json";

        Directory.CreateDirectory(config.RCMJsonPath);
        var jsonPath = Path.Combine(config.RCMJsonPath, jsonFileName);

        // Skip if this exact JSON already exists and is newer than the CSV
        if (File.Exists(jsonPath) &&
            File.GetLastWriteTimeUtc(jsonPath) >= File.GetLastWriteTimeUtc(csvPath))
        {
            _logger.LogInformation(
                "[RCM] '{Lab}' JSON is up-to-date — skipping: {File}", labName, jsonFileName);
            return;
        }

        _logger.LogInformation(
            "[RCM] Building JSON for '{Lab}' from: {Csv}", labName, csvPath);

        var records = _csv.ParseClaimLevel(csvPath);
        if (records.Count == 0)
        {
            _logger.LogWarning("[RCM] No records parsed for '{Lab}' — JSON not written.", labName);
            return;
        }

        var payload = BuildPayload(records, csvPath);
        File.WriteAllText(jsonPath, JsonSerializer.Serialize(payload, _opts));

        _logger.LogInformation(
            "[RCM] '{Lab}' JSON written: {File} ({Size:N0} bytes, {Claims} claims)",
            labName, jsonPath, new FileInfo(jsonPath).Length, records.Count);

        // Remove the legacy stable-name file if it exists so the dashboard
        // always reads the current week's file
        var legacyPath = Path.Combine(config.RCMJsonPath, $"{labName}_RCM.json");
        if (File.Exists(legacyPath) &&
            !string.Equals(legacyPath, jsonPath, StringComparison.OrdinalIgnoreCase))
        {
            File.Delete(legacyPath);
            _logger.LogInformation("[RCM] Removed legacy stable file: {File}", legacyPath);
        }
    }

    // ?? Payload builder ???????????????????????????????????????????????????????

    private static RcmPayload BuildPayload(List<ClaimRecord> records, string csvPath)
    {
        var totalClaims   = records.Select(r => r.ClaimID).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        var totalCharges  = records.Sum(r => r.ChargeAmount);
        var totalPayments = records.Sum(r => r.TotalPayments);
        var totalBalance  = records.Sum(r => r.TotalBalance);
        var totalAdj      = records.Sum(r => r.TotalAdjustments);

        // Claim-level aggregation (one row per distinct ClaimID, take first occurrence)
        var byClaim = records
            .GroupBy(r => r.ClaimID, StringComparer.OrdinalIgnoreCase)
            .Select(g => g.First())
            .ToList();

        int claimCount = byClaim.Count;

        // Denial = claims with a non-empty DenialCode
        int denialCount = byClaim.Count(r => !string.IsNullOrWhiteSpace(r.DenialCode));

        // Adjustment = claims with TotalAdjustments != 0
        int adjCount = byClaim.Count(r => r.InsuranceAdjustments != 0 || r.PatientAdjustments != 0);

        decimal collectionRate     = totalCharges == 0 ? 0 : Math.Round(totalPayments / totalCharges, 3);
        decimal denialRate         = claimCount   == 0 ? 0 : Math.Round((decimal)denialCount / claimCount, 3);
        decimal adjustmentRate     = claimCount   == 0 ? 0 : Math.Round((decimal)adjCount    / claimCount, 3);
        decimal outstandingCharges = totalCharges == 0 ? 0 : Math.Round(totalBalance / totalCharges, 3);

        // ?? Claim status breakdown ????????????????????????????????????????????
        var statusBreakdown = byClaim
            .GroupBy(r => string.IsNullOrWhiteSpace(r.ClaimStatus) ? "Unknown" : r.ClaimStatus)
            .Select(g => new ClaimStatusItem(
                g.Key,
                g.Count(),
                claimCount == 0 ? 0 : Math.Round((decimal)g.Count() / claimCount, 3)))
            .OrderByDescending(x => x.Claims)
            .ToList();

        // ?? Payments by payer type ????????????????????????????????????????????
        var paymentsByType = records
            .GroupBy(r => string.IsNullOrWhiteSpace(r.PayerType) ? "Unknown" : r.PayerType)
            .Select(g => new PayerTypeItem(g.Key, Math.Round(g.Sum(r => r.InsurancePayment), 2)))
            .OrderByDescending(x => x.Payments)
            .ToList();

        // ?? Payer level insights ??????????????????????????????????????????????
        var payerInsights = byClaim
            .GroupBy(r => string.IsNullOrWhiteSpace(r.PayerName) ? "No Payer Name" : r.PayerName,
                     StringComparer.OrdinalIgnoreCase)
            .Select(g =>
            {
                var charges  = records.Where(r => string.Equals(r.PayerName, g.Key, StringComparison.OrdinalIgnoreCase)).Sum(r => r.ChargeAmount);
                var payments = records.Where(r => string.Equals(r.PayerName, g.Key, StringComparison.OrdinalIgnoreCase)).Sum(r => r.TotalPayments);
                var balance  = records.Where(r => string.Equals(r.PayerName, g.Key, StringComparison.OrdinalIgnoreCase)).Sum(r => r.TotalBalance);
                return new PayerInsightItem(
                    g.Key,
                    g.Count(),
                    Math.Round(charges,  2),
                    Math.Round(payments, 2),
                    Math.Round(balance,  2),
                    charges == 0 ? 0 : Math.Round(payments / charges, 3));
            })
            .OrderByDescending(x => x.Claims)
            .Take(15)
            .ToList();

        // ?? Panel level insights ??????????????????????????????????????????????
        var panelInsights = byClaim
            .GroupBy(r => string.IsNullOrWhiteSpace(r.PanelName) ? "No Order Info" : r.PanelName,
                     StringComparer.OrdinalIgnoreCase)
            .Select(g =>
            {
                var charges  = records.Where(r => string.Equals(r.PanelName, g.Key, StringComparison.OrdinalIgnoreCase)).Sum(r => r.ChargeAmount);
                var payments = records.Where(r => string.Equals(r.PanelName, g.Key, StringComparison.OrdinalIgnoreCase)).Sum(r => r.TotalPayments);
                var balance  = records.Where(r => string.Equals(r.PanelName, g.Key, StringComparison.OrdinalIgnoreCase)).Sum(r => r.TotalBalance);
                return new PanelInsightItem(
                    g.Key,
                    g.Count(),
                    Math.Round(charges,  2),
                    Math.Round(payments, 2),
                    Math.Round(balance,  2),
                    charges == 0 ? 0 : Math.Round(payments / charges, 3));
            })
            .OrderByDescending(x => x.Claims)
            .ToList();

        // ?? Clinic level insights ?????????????????????????????????????????????
        var clinicInsights = byClaim
            .GroupBy(r => string.IsNullOrWhiteSpace(r.ClinicName) ? "No Clinic Name" : r.ClinicName,
                     StringComparer.OrdinalIgnoreCase)
            .Select(g =>
            {
                var charges  = records.Where(r => string.Equals(r.ClinicName, g.Key, StringComparison.OrdinalIgnoreCase)).Sum(r => r.ChargeAmount);
                var payments = records.Where(r => string.Equals(r.ClinicName, g.Key, StringComparison.OrdinalIgnoreCase)).Sum(r => r.TotalPayments);
                var balance  = records.Where(r => string.Equals(r.ClinicName, g.Key, StringComparison.OrdinalIgnoreCase)).Sum(r => r.TotalBalance);
                return new ClinicInsightItem(
                    g.Key,
                    g.Count(),
                    Math.Round(charges,  2),
                    Math.Round(payments, 2),
                    Math.Round(balance,  2),
                    charges == 0 ? 0 : Math.Round(payments / charges, 3));
            })
            .OrderByDescending(x => x.Claims)
            .ToList();

        // ?? Monthly claims by date of service ????????????????????????????????
        var monthlyClaims = byClaim
            .Where(r => !string.IsNullOrWhiteSpace(r.DateOfService))
            .GroupBy(r => TryParseYearMonth(r.DateOfService))
            .Where(g => g.Key is not null)
            .Select(g => new MonthlyClaimsItem(g.Key!, g.Count()))
            .OrderBy(x => x.Month)
            .ToList();

        // ?? Monthly claims by billed date ?????????????????????????????????????
        var monthlyBilled = byClaim
            .Where(r => !string.IsNullOrWhiteSpace(r.FirstBilledDate))
            .GroupBy(r => TryParseYearMonth(r.FirstBilledDate))
            .Where(g => g.Key is not null)
            .Select(g => new MonthlyClaimsItem(g.Key!, g.Count()))
            .OrderBy(x => x.Month)
            .ToList();

        // ?? CPT level insights ????????????????????????????????????????????????
        var cptInsights = records
            .Where(r => !string.IsNullOrWhiteSpace(r.CPTCodeUnitsModifier))
            .GroupBy(r => ExtractCptCode(r.CPTCodeUnitsModifier), StringComparer.OrdinalIgnoreCase)
            .Select(g =>
            {
                var charges = g.Sum(r => r.ChargeAmount);
                var allowed = g.Sum(r => r.AllowedAmount);
                var balance = g.Sum(r => r.InsuranceBalance);
                var noRespCount = g.Count(r =>
                    r.ClaimStatus.Contains("No Response", StringComparison.OrdinalIgnoreCase));
                return new CptInsightItem(
                    g.Key,
                    Math.Round(charges, 2),
                    Math.Round(allowed, 2),
                    Math.Round(balance, 2),
                    charges == 0 ? 0 : Math.Round((charges - balance) / charges, 6),
                    g.Count() == 0 ? 0 : Math.Round((decimal)noRespCount / g.Count(), 6));
            })
            .OrderByDescending(x => x.Charges)
            .ToList();

        return new RcmPayload
        {
            SourceCsvPath              = csvPath,
            GeneratedAt                = DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss"),
            RevenueMetrics = new RevenueMetrics(
                totalClaims,
                Math.Round(totalCharges,  2),
                Math.Round(totalPayments, 2),
                Math.Round(totalBalance,  2),
                collectionRate,
                denialRate,
                adjustmentRate,
                outstandingCharges),
            ClaimStatusBreakdown         = statusBreakdown,
            PaymentsByPayerType          = paymentsByType,
            PayerLevelInsights           = payerInsights,
            PanelLevelInsights           = panelInsights,
            ClinicLevelInsights          = clinicInsights,
            MonthlyClaimsByDateOfService = monthlyClaims,
            MonthlyClaimsByBilledDate    = monthlyBilled,
            CptLevelInsights             = cptInsights,
        };
    }

    // ?? Helpers ???????????????????????????????????????????????????????????????

    /// <summary>Parses common date formats and returns "yyyy-MM", or null on failure.</summary>
    private static string? TryParseYearMonth(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        if (DateTime.TryParse(raw, out var dt))
            return dt.ToString("yyyy-MM");
        return null;
    }

    /// <summary>Extracts the CPT code from "87798 X 1 X " style strings.</summary>
    private static string ExtractCptCode(string raw)
    {
        var parts = raw.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 0 ? parts[0] : raw;
    }

    // ?? JSON shape records ????????????????????????????????????????????????????

    private sealed class RcmPayload
    {
        // Metadata — used by IsUpToDate() to detect when the source CSV has changed
        public string                        SourceCsvPath               { get; init; } = string.Empty;
        public string                        GeneratedAt                 { get; init; } = string.Empty;
        public RevenueMetrics                RevenueMetrics              { get; init; } = new(0,0,0,0,0,0,0,0);
        public List<ClaimStatusItem>         ClaimStatusBreakdown        { get; init; } = [];
        public List<PayerTypeItem>           PaymentsByPayerType         { get; init; } = [];
        public List<PayerInsightItem>        PayerLevelInsights          { get; init; } = [];
        public List<PanelInsightItem>        PanelLevelInsights          { get; init; } = [];
        public List<ClinicInsightItem>       ClinicLevelInsights         { get; init; } = [];
        public List<MonthlyClaimsItem>       MonthlyClaimsByDateOfService { get; init; } = [];
        public List<MonthlyClaimsItem>       MonthlyClaimsByBilledDate   { get; init; } = [];
        public List<CptInsightItem>          CptLevelInsights            { get; init; } = [];
    }

    private sealed record RevenueMetrics(
        int     TotalClaims,
        decimal TotalCharges,
        decimal TotalPayments,
        decimal OutstandingBalance,
        decimal CollectionRate,
        decimal DenialRate,
        decimal AdjustmentRate,
        decimal OutstandingChargesPct);

    private sealed record ClaimStatusItem(string Status, int Claims, decimal Ratio);
    private sealed record PayerTypeItem(string PayerType, decimal Payments);

    private sealed record PayerInsightItem(
        string Payer, int Claims, decimal Charges,
        decimal Payments, decimal Balance, decimal CollectionRate);

    private sealed record PanelInsightItem(
        string Panel, int Claims, decimal Charges,
        decimal Payments, decimal Balance, decimal CollectionRate);

    private sealed record ClinicInsightItem(
        string Clinic, int Claims, decimal Charges,
        decimal Payments, decimal Balance, decimal CollectionRate);

    private sealed record MonthlyClaimsItem(string Month, int Claims);

    private sealed record CptInsightItem(
        string CptCode, decimal Charges, decimal AllowedAmount,
        decimal InsuranceBalance, decimal CollectionRate, decimal NoResponseRate);
}
