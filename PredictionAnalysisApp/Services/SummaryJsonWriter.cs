using System.Text.Json;
using System.Text.Encodings.Web;
using System.Text.Json.Serialization;
using System.Text.Unicode;
using PredictionAnalysis.Models;
using PredictionAnalysis.Services;

namespace PredictionAnalysis.Services;

/// <summary>
/// Writes a <see cref="SummaryResult"/> alongside the Excel report as a JSON file
/// with the same base name (e.g. "RunId_Lab_Prediction_vs_NonPayment_…_ddMMyyyyHHmm.json").
/// Sections: Buckets, Ratios, PredictionAccuracy, DenialBreakdown, NoResponseBreakdown.
/// If the JSON file already exists it is skipped (idempotent — safe for re-runs).
/// </summary>
public static class SummaryJsonWriter
{
    private static readonly JsonSerializerOptions _opts = new()
    {
        WriteIndented          = true,
        PropertyNamingPolicy   = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        NumberHandling         = JsonNumberHandling.AllowReadingFromString,
        // Prevent > < & being escaped to \u003E \u003C \u0026 in plain JSON files
        Encoder                = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };



    // Age-bucket boundaries (mirrors dashboard AgeBuckets)
    private static readonly IReadOnlyList<string> _ageBuckets =
        ["0-30", "31-60", "61-90", "91-120", ">120"];

    /// <summary>
    /// Writes the summary JSON next to the Excel output file.
    /// Skips writing if the JSON already exists.
    /// </summary>
    /// <param name="excelOutputPath">Full path to the Excel file that was just written.</param>
    /// <param name="summary">The <see cref="SummaryResult"/> computed by <see cref="AnalysisService"/>.</param>
    /// <param name="working">Filtered unpaid claim records (Denied + NoResponse + Adjusted).</param>
    /// <param name="settings">Analysis settings supplying PayStatus label strings.</param>
    /// <param name="labName">Lab name — embedded in the JSON for traceability.</param>
    /// <param name="runId">Run identifier — embedded in the JSON for traceability.</param>
    /// <param name="weekFolderName">Week folder label (e.g. "03.12.2026 - 03.18.2026").</param>
    /// <returns>Full path of the JSON file (written or already existing).</returns>
    public static string Write(
        string           excelOutputPath,
        SummaryResult    summary,
        List<ClaimRecord> working,
        AnalysisSettings  settings,
        string           labName,

        string           runId,
        string           weekFolderName)
    {
        var jsonPath = Path.ChangeExtension(excelOutputPath, ".json");

        // ?? Idempotency: skip if JSON already exists ??????????????????????????
        if (File.Exists(jsonPath))
        {
            Console.WriteLine($"[Step 5] Summary JSON already exists — skipping: {Path.GetFileName(jsonPath)}");
            AppLogger.LogWarn($"[SummaryJson] Skipped — file already exists: {jsonPath}");
            return jsonPath;
        }

        var payload = new SummaryJsonPayload
        {
            LabName      = labName,
            RunId        = runId,
            ReportPeriod = weekFolderName,
            GeneratedAt  = DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss"),
            ExcelFile    = Path.GetFileName(excelOutputPath),

            Buckets = new BucketsSection
            {
                PredictedToPay = new BucketRow
                {
                    ClaimCount         = summary.TotalPredictedClaims,
                    PredictedAllowed   = summary.TotalPredictedAllowed,
                    PredictedInsurance = summary.TotalPredictedInsurance,
                },
                PredictedPaid = new BucketRow
                {
                    ClaimCount         = summary.TotalPaidClaims,
                    PredictedAllowed   = summary.TotalPaidPredAllowed,
                    PredictedInsurance = summary.TotalPaidPredInsurance,
                    ActualAllowed      = summary.TotalPaidActualAllowed,
                    ActualInsurance    = summary.TotalPaidActualInsurance,
                    VarianceAllowed    = summary.TotalPaidPredAllowed   - summary.TotalPaidActualAllowed,
                    VarianceInsurance  = summary.TotalPaidPredInsurance - summary.TotalPaidActualInsurance,
                },
                PredictedUnpaid = new BucketRow
                {
                    ClaimCount         = summary.TotalUnpaidClaims,
                    PredictedAllowed   = summary.TotalUnpaidPredAllowed,
                    PredictedInsurance = summary.TotalUnpaidPredInsurance,
                    ActualAllowed      = summary.TotalUnpaidActualAllowed,
                    ActualInsurance    = summary.TotalUnpaidActualInsurance,
                    VarianceAllowed    = summary.TotalUnpaidPredAllowed   - summary.TotalUnpaidActualAllowed,
                    VarianceInsurance  = summary.TotalUnpaidPredInsurance - summary.TotalUnpaidActualInsurance,
                },
                UnpaidDenied = new BucketRow
                {
                    ClaimCount         = summary.DeniedClaims,
                    PredictedAllowed   = summary.DeniedPredAllowed,
                    PredictedInsurance = summary.DeniedPredInsurance,
                    ActualAllowed      = summary.DeniedActualAllowed,
                    ActualInsurance    = summary.DeniedActualInsurance,
                    VarianceAllowed    = summary.DeniedPredAllowed   - summary.DeniedActualAllowed,
                    VarianceInsurance  = summary.DeniedPredInsurance - summary.DeniedActualInsurance,
                },
                UnpaidNoResponse = new BucketRow
                {
                    ClaimCount         = summary.NoResponseClaims,
                    PredictedAllowed   = summary.NoResponsePredAllowed,
                    PredictedInsurance = summary.NoResponsePredInsurance,
                    ActualAllowed      = summary.NoResponseActualAllowed,
                    ActualInsurance    = summary.NoResponseActualInsurance,
                    VarianceAllowed    = summary.NoResponsePredAllowed   - summary.NoResponseActualAllowed,
                    VarianceInsurance  = summary.NoResponsePredInsurance - summary.NoResponseActualInsurance,
                },
                UnpaidAdjusted = new BucketRow
                {
                    ClaimCount         = summary.AdjustedClaims,
                    PredictedAllowed   = summary.AdjustedPredAllowed,
                    PredictedInsurance = summary.AdjustedPredInsurance,
                    ActualAllowed      = summary.AdjustedActualAllowed,
                    ActualInsurance    = summary.AdjustedActualInsurance,
                    VarianceAllowed    = summary.AdjustedPredAllowed   - summary.AdjustedActualAllowed,
                    VarianceInsurance  = summary.AdjustedPredInsurance - summary.AdjustedActualInsurance,
                },
            },

            Ratios = new RatiosSection
            {
                PaymentRatio = new RatioRow
                {
                    ClaimPct     = summary.PaymentRatioCount,
                    AllowedPct   = summary.PaymentRatioAllowed,
                    InsurancePct = summary.PaymentRatioInsurance,
                },
                NonPaymentRate = new RatioRow
                {
                    ClaimPct     = summary.NonPaymentRateCount,
                    AllowedPct   = summary.NonPaymentRateAllowed,
                    InsurancePct = summary.NonPaymentRateInsurance,
                },
                DeniedRate = new RatioRow
                {
                    ClaimPct     = summary.DeniedRatioCount,
                    AllowedPct   = summary.DeniedRatioAllowed,
                    InsurancePct = summary.DeniedRatioInsurance,
                },
                NoResponseRate = new RatioRow
                {
                    ClaimPct     = summary.NoResponseRatioCount,
                    AllowedPct   = summary.NoResponseRatioAllowed,
                    InsurancePct = summary.NoResponseRatioInsurance,
                },
                AdjustedRate = new RatioRow
                {
                    ClaimPct     = summary.AdjustedRatioCount,
                    AllowedPct   = summary.AdjustedRatioAllowed,
                    InsurancePct = summary.AdjustedRatioInsurance,
                },
            },

            PredictionAccuracy = new PredictionAccuracySection
            {
                ClaimPct         = summary.PredVsActualRatioCount,
                AllowedAmountPct = summary.PredVsActualRatioAllowed,
                InsurancePct     = summary.PredVsActualRatioInsurance,
            },

            DenialBreakdown    = BuildDenialBreakdown(working, settings),
            NoResponseBreakdown = BuildNoResponseBreakdown(working, settings),
        };

        try
        {
            AppLogger.Log($"[SummaryJson] Writing: {jsonPath}");

            File.WriteAllText(jsonPath, JsonSerializer.Serialize(payload, _opts));

            var fileSize = new FileInfo(jsonPath).Length;
            var denial   = payload.DenialBreakdown.PayerRows.Count;
            var noResp   = payload.NoResponseBreakdown.PayerRows.Count;
            Console.WriteLine($"[Step 5] Summary JSON written ({fileSize / 1024.0:F1} KB): {Path.GetFileName(jsonPath)}");
            AppLogger.Log($"[SummaryJson] Created successfully | Size: {fileSize:N0} bytes | " +
                          $"DenialPayers: {denial} | NoResponsePayers: {noResp} | Path: {jsonPath}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Step 5] [WARN] Failed to write summary JSON: {ex.Message}");
            AppLogger.LogError($"[SummaryJson] Failed to write: {jsonPath}", ex);
        }

        return jsonPath;
    }

    // ?? Denial Breakdown builder ???????????????????????????????????????????????

    /// <summary>
    /// Predicted to Pay vs Denial breakdown.
    /// Groups denied rows by Payer ? top denial codes ? month columns.
    /// </summary>
    private static DenialBreakdownJson BuildDenialBreakdown(
        List<ClaimRecord> working, AnalysisSettings settings)
    {
        var denied = working
            .Where(r => r.PayStatus.Trim().Equals(
                settings.PayStatusDenied, StringComparison.OrdinalIgnoreCase))
            .ToList();

        if (denied.Count == 0)
            return new DenialBreakdownJson();

        // Distinct ordered months
        var months = denied
            .Where(r => r.ExpectedPaymentDate.HasValue)
            .Select(r => r.ExpectedPaymentDate!.Value.ToString("MMM-yy"))
            .Distinct()
            .OrderBy(m => m)
            .ToList();

        static int DistinctClaims(IEnumerable<ClaimRecord> rows) =>
            rows.Select(r => r.VisitNumber)
                .Where(v => !string.IsNullOrWhiteSpace(v))
                .Distinct(StringComparer.OrdinalIgnoreCase).Count();

        Dictionary<string, DenialMonthAmountJson> ByMonth(IEnumerable<ClaimRecord> rows)
        {
            var list = rows.ToList();
            return months.ToDictionary(
                m => m,
                m =>
                {
                    var mRows = list.Where(r =>
                        r.ExpectedPaymentDate.HasValue &&
                        r.ExpectedPaymentDate.Value.ToString("MMM-yy") == m).ToList();
                    return new DenialMonthAmountJson(
                        DistinctClaims(mRows),
                        mRows.Sum(r => r.ModeAllowedAmount),
                        mRows.Sum(r => r.ModeInsurancePaid));
                });
        }

        var payerRows = denied
            .GroupBy(r => string.IsNullOrWhiteSpace(r.PayerName) ? "(Unknown)" : r.PayerName,
                     StringComparer.OrdinalIgnoreCase)
            .Select(pg =>
            {
                var pgList = pg.ToList();

                // Top-5 denial codes for this payer
                var topCodes = pgList
                    .GroupBy(r => new
                    {
                        Code = string.IsNullOrWhiteSpace(r.DenialCode) ? "(No Code)" : r.DenialCode,
                        Desc = string.IsNullOrWhiteSpace(r.DenialDescription) ? string.Empty : r.DenialDescription,
                    })
                    .Select(dg =>
                    {
                        var dgList = dg.ToList();
                        return new DenialCodeJson(
                            dg.Key.Code,
                            dg.Key.Desc,
                            DistinctClaims(dgList),
                            dgList.Sum(r => r.ModeAllowedAmount),
                            dgList.Sum(r => r.ModeInsurancePaid),
                            ByMonth(dgList));
                    })
                    .OrderByDescending(d => d.TotalClaims)
                    .Take(settings.TopDenialCodesPerPayer)
                    .ToList();

                return new DenialPayerJson(
                    pg.Key,
                    DistinctClaims(pgList),
                    pgList.Sum(r => r.ModeAllowedAmount),
                    pgList.Sum(r => r.ModeInsurancePaid),
                    ByMonth(pgList),
                    topCodes);
            })
            .OrderByDescending(p => p.TotalClaims)
            .ToList();

        return new DenialBreakdownJson
        {
            Months              = months,
            TotalClaims         = DistinctClaims(denied),
            TotalPredAllowed    = denied.Sum(r => r.ModeAllowedAmount),
            TotalPredInsurance  = denied.Sum(r => r.ModeInsurancePaid),
            TotalByMonth        = ByMonth(denied),
            PayerRows           = payerRows,
        };
    }

    // ?? No Response Breakdown builder ??????????????????????????????????????????

    /// <summary>
    /// Predicted to Pay vs No Response breakdown.
    /// Groups no-response rows by Payer ? age buckets (0-30, 31-60, 61-90, 91-120, >120).
    /// Age is derived from FirstBilledDate days-to-today.
    /// </summary>
    private static NoResponseBreakdownJson BuildNoResponseBreakdown(
        List<ClaimRecord> working, AnalysisSettings settings)
    {
        var noResp = working
            .Where(r => r.PayStatus.Trim().Equals(
                settings.PayStatusNoResponse, StringComparison.OrdinalIgnoreCase))
            .ToList();

        if (noResp.Count == 0)
            return new NoResponseBreakdownJson();

        var today = DateTime.Today;

        static string ClassifyAge(int days) => days switch
        {
            <= 30  => "0-30",
            <= 60  => "31-60",
            <= 90  => "61-90",
            <= 120 => "91-120",
            _      => ">120",
        };

        // Tag each row with its age bucket
        var tagged = noResp
            .Select(r =>
            {
                var ageDays = r.FirstBilledDate.HasValue
                    ? (today - r.FirstBilledDate.Value.Date).Days
                    : -1;
                return (Record: r, Bucket: ageDays >= 0 ? ClassifyAge(ageDays) : "0-30");
            })
            .ToList();

        static int DistinctClaims(IEnumerable<ClaimRecord> rows) =>
            rows.Select(r => r.VisitNumber)
                .Where(v => !string.IsNullOrWhiteSpace(v))
                .Distinct(StringComparer.OrdinalIgnoreCase).Count();

        AgeBucketJson AggregateBucket(IEnumerable<(ClaimRecord Record, string Bucket)> items)
        {
            var list = items.ToList();
            return new AgeBucketJson(
                DistinctClaims(list.Select(x => x.Record)),
                list.Sum(x => x.Record.ModeAllowedAmount),
                list.Sum(x => x.Record.ModeInsurancePaid));
        }

        Dictionary<string, AgeBucketJson> ByBucket(
            IEnumerable<(ClaimRecord Record, string Bucket)> items)
        {
            var list = items.ToList();
            return _ageBuckets.ToDictionary(
                b => b,
                b => AggregateBucket(list.Where(x => x.Bucket == b)));
        }

        var payerRows = tagged
            .GroupBy(
                x => string.IsNullOrWhiteSpace(x.Record.PayerName) ? "(Unknown)" : x.Record.PayerName,
                StringComparer.OrdinalIgnoreCase)
            .Select(pg =>
            {
                var pgItems    = pg.ToList();
                var byBucket   = ByBucket(pgItems);
                var totalClaims = DistinctClaims(pgItems.Select(x => x.Record));

                // Priority bucket = bucket with highest claim count
                var priority = _ageBuckets
                    .OrderByDescending(b => byBucket[b].ClaimCount)
                    .First();

                return new NoResponsePayerJson(
                    pg.Key,
                    totalClaims,
                    pgItems.Sum(x => x.Record.ModeAllowedAmount),
                    pgItems.Sum(x => x.Record.ModeInsurancePaid),
                    byBucket,
                    priority);
            })
            .OrderByDescending(p => p.TotalClaims)
            .ToList();

        return new NoResponseBreakdownJson
        {
            TotalClaims         = DistinctClaims(noResp),
            TotalPredAllowed    = noResp.Sum(r => r.ModeAllowedAmount),
            TotalPredInsurance  = noResp.Sum(r => r.ModeInsurancePaid),
            TotalByBucket       = ByBucket(tagged),
            PayerRows           = payerRows,
        };
    }

    // ?? JSON shape ?????????????????????????????????????????????????????????????

    private sealed class SummaryJsonPayload
    {
        public string                  LabName             { get; init; } = string.Empty;
        public string                  RunId               { get; init; } = string.Empty;
        public string                  ReportPeriod        { get; init; } = string.Empty;
        public string                  GeneratedAt         { get; init; } = string.Empty;
        public string                  ExcelFile           { get; init; } = string.Empty;
        public BucketsSection          Buckets             { get; init; } = new();
        public RatiosSection           Ratios              { get; init; } = new();
        public PredictionAccuracySection PredictionAccuracy { get; init; } = new();
        public DenialBreakdownJson     DenialBreakdown     { get; init; } = new();
        public NoResponseBreakdownJson NoResponseBreakdown { get; init; } = new();
    }

    private sealed class BucketsSection
    {
        public BucketRow PredictedToPay   { get; init; } = new();
        public BucketRow PredictedPaid    { get; init; } = new();
        public BucketRow PredictedUnpaid  { get; init; } = new();
        public BucketRow UnpaidDenied     { get; init; } = new();
        public BucketRow UnpaidNoResponse { get; init; } = new();
        public BucketRow UnpaidAdjusted   { get; init; } = new();
    }

    private sealed class BucketRow
    {
        public int      ClaimCount         { get; init; }
        public decimal  PredictedAllowed   { get; init; }
        public decimal  PredictedInsurance { get; init; }
        public decimal? ActualAllowed      { get; init; }
        public decimal? ActualInsurance    { get; init; }
        public decimal? VarianceAllowed    { get; init; }
        public decimal? VarianceInsurance  { get; init; }
    }

    private sealed class RatiosSection
    {
        public RatioRow PaymentRatio   { get; init; } = new();
        public RatioRow NonPaymentRate { get; init; } = new();
        public RatioRow DeniedRate     { get; init; } = new();
        public RatioRow NoResponseRate { get; init; } = new();
        public RatioRow AdjustedRate   { get; init; } = new();
    }

    private sealed class RatioRow
    {
        public decimal ClaimPct     { get; init; }
        public decimal AllowedPct   { get; init; }
        public decimal InsurancePct { get; init; }
    }

    private sealed class PredictionAccuracySection
    {
        public decimal ClaimPct         { get; init; }
        public decimal AllowedAmountPct { get; init; }
        public decimal InsurancePct     { get; init; }
    }

    // ?? Denial Breakdown JSON shape ????????????????????????????????????????????

    private sealed class DenialBreakdownJson
    {
        public IReadOnlyList<string>         Months             { get; init; } = [];
        public int                           TotalClaims        { get; init; }
        public decimal                       TotalPredAllowed   { get; init; }
        public decimal                       TotalPredInsurance { get; init; }
        public Dictionary<string, DenialMonthAmountJson> TotalByMonth { get; init; } = [];
        public IReadOnlyList<DenialPayerJson> PayerRows         { get; init; } = [];
    }

    private sealed record DenialMonthAmountJson(
        int     ClaimCount,
        decimal PredictedAllowed,
        decimal PredictedInsurance);

    private sealed record DenialCodeJson(
        string  DenialCode,
        string  DenialDescription,
        int     TotalClaims,
        decimal TotalPredAllowed,
        decimal TotalPredInsurance,
        Dictionary<string, DenialMonthAmountJson> ByMonth);

    private sealed record DenialPayerJson(
        string  PayerName,
        int     TotalClaims,
        decimal TotalPredAllowed,
        decimal TotalPredInsurance,
        Dictionary<string, DenialMonthAmountJson> ByMonth,
        IReadOnlyList<DenialCodeJson> TopDenialCodes);

    // ?? No Response Breakdown JSON shape ??????????????????????????????????????

    private sealed class NoResponseBreakdownJson
    {
        public int                               TotalClaims        { get; init; }
        public decimal                           TotalPredAllowed   { get; init; }
        public decimal                           TotalPredInsurance { get; init; }
        public Dictionary<string, AgeBucketJson> TotalByBucket      { get; init; } = [];
        public IReadOnlyList<NoResponsePayerJson> PayerRows         { get; init; } = [];
    }

    private sealed record AgeBucketJson(
        int     ClaimCount,
        decimal PredictedAllowed,
        decimal PredictedInsurance);

    private sealed record NoResponsePayerJson(
        string  PayerName,
        int     TotalClaims,
        decimal TotalPredAllowed,
        decimal TotalPredInsurance,
        Dictionary<string, AgeBucketJson> ByBucket,
        string  PriorityBucket);
}

