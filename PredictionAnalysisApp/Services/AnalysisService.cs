using PredictionAnalysis.Models;

namespace PredictionAnalysis.Services;

public class AnalysisService
{
    private readonly AnalysisSettings _settings;

    public AnalysisService(AnalysisSettings settings) => _settings = settings;

    private static DateTime GetCurrentWeekStart()
    {
        var today = DateTime.Today;
        int daysSinceMonday = ((int)today.DayOfWeek + 6) % 7;
        return today.AddDays(-daysSinceMonday);
    }

    public List<ClaimRecord> BuildWorkingDataset(List<ClaimRecord> all)
    {
        var weekStart = GetCurrentWeekStart();

        var step2 = all
            .Where(r => r.ExpectedPaymentDate.HasValue
                     && r.ExpectedPaymentDate.Value.Date < weekStart)
            .ToList();
        Console.WriteLine($"[Step 2] Cutoff < {weekStart:yyyy-MM-dd}. Rows remaining: {step2.Count}");

        var step3 = step2
            .Where(r => _settings.ForecastingPIncludeValues
                .Contains(r.ForecastingP.Trim(), StringComparer.OrdinalIgnoreCase))
            .ToList();
        Console.WriteLine($"[Step 3] ForecastingP filter. Rows remaining: {step3.Count}");
        if (step3.Count == 0 && step2.Count > 0)
            Console.WriteLine($"         [Diag] ForecastingP values in data: {string.Join(" | ", step2.Select(r => r.ForecastingP).Distinct().Take(10))}");

        var step4 = step3
            .Where(r => r.PayStatus.Trim().Equals(_settings.PayStatusDenied,    StringComparison.OrdinalIgnoreCase)
                     || r.PayStatus.Trim().Equals(_settings.PayStatusAdjusted,  StringComparison.OrdinalIgnoreCase)
                     || r.PayStatus.Trim().Equals(_settings.PayStatusNoResponse, StringComparison.OrdinalIgnoreCase))
            .ToList();
        Console.WriteLine($"[Step 4] PayStatus filter. Rows remaining: {step4.Count}");
        if (step4.Count == 0 && step3.Count > 0)
            Console.WriteLine($"         [Diag] PayStatus values in data: {string.Join(" | ", step3.Select(r => r.PayStatus).Distinct().Take(10))}");

        // ── Calculate age fields ──────────────────────────────────────────────
        var today = DateTime.Today;
        foreach (var r in step4)
        {
            if (r.ExpectedPaymentDate.HasValue)
            {
                r.DaysSinceExpectedPayment = (today - r.ExpectedPaymentDate.Value.Date).Days;
                r.AgeGroup = r.DaysSinceExpectedPayment switch
                {
                    >= 0 and < 31 => "0-30",
                    >= 31 and < 61 => "31-60",
                    >= 61 and < 91 => "61-90",
                    >= 91 and < 121 => "91-120",
                    _ => ">120"
                };
            }
        }

        return step4;
    }

    public List<ClaimRecord> BuildPredictedPayableDataset(List<ClaimRecord> all)
    {
        var weekStart = GetCurrentWeekStart();
        return all
            .Where(r => r.ExpectedPaymentDate.HasValue
                     && r.ExpectedPaymentDate.Value.Date < weekStart)
            .Where(r => _settings.ForecastingPIncludeValues
                .Contains(r.ForecastingP.Trim(), StringComparer.OrdinalIgnoreCase))
            .ToList();
    }


    public SummaryResult BuildSummary(
        List<ClaimRecord> predicted,
        List<ClaimRecord> unpaid)
    {
        static decimal Pct(decimal num, decimal denom)
            => denom == 0 ? 0m : Math.Round(num / denom * 100, 2);

        // ── Aggregate helper: count, predAllowed, predInsurance, actAllowed, actInsurance ──
        static (int cnt, decimal predAllowed, decimal predIns, decimal actAllowed, decimal actIns)
            Agg(List<ClaimRecord> rows) => (
                rows.Select(r => r.VisitNumber).Distinct().Count(),
                rows.Sum(r => r.ModeAllowedAmount),
                rows.Sum(r => r.ModeInsurancePaid),
                rows.Sum(r => r.AllowedAmount),
                rows.Sum(r => r.InsurancePayment));

        // ── Predicted To Pay ──────────────────────────────────────────────────
        var (predCnt, predAllowed, predIns, _, _) = Agg(predicted);

        // ── Predicted - Paid ──────────────────────────────────────────────────
        var paid = predicted
            .Where(r => r.PayStatus.Trim().Equals(
                _settings.PayStatusPaid, StringComparison.OrdinalIgnoreCase))
            .ToList();
        var (paidCnt, paidPredAllowed, paidPredIns, paidActAllowed, paidActIns) = Agg(paid);

        // ── Predicted - Unpaid ────────────────────────────────────────────────
        var (unpaidCnt, unpaidPredAllowed, unpaidPredIns, unpaidActAllowed, unpaidActIns) = Agg(unpaid);

        // ── Unpaid sub-breakdown ──────────────────────────────────────────────
        var denied = unpaid.Where(r => r.PayStatus.Trim().Equals(
            _settings.PayStatusDenied,    StringComparison.OrdinalIgnoreCase)).ToList();
        var noResp = unpaid.Where(r => r.PayStatus.Trim().Equals(
            _settings.PayStatusNoResponse, StringComparison.OrdinalIgnoreCase)).ToList();
        var adjusted = unpaid.Where(r => r.PayStatus.Trim().Equals(
            _settings.PayStatusAdjusted,  StringComparison.OrdinalIgnoreCase)).ToList();

        var (denCnt, denPredAll, denPredIns, denActAll, denActIns)   = Agg(denied);
        var (noRCnt, noRPredAll, noRPredIns, noRActAll, noRActIns)   = Agg(noResp);
        var (adjCnt, adjPredAll, adjPredIns, adjActAll, adjActIns)   = Agg(adjusted);

        return new SummaryResult
        {
            // ── Predicted To Pay ──────────────────────────────────────────────
            TotalPredictedClaims       = predCnt,
            TotalPredictedAllowed      = predAllowed,
            TotalPredictedInsurance    = predIns,

            // ── Predicted - Paid ──────────────────────────────────────────────
            TotalPaidClaims            = paidCnt,
            TotalPaidPredAllowed       = paidPredAllowed,
            TotalPaidPredInsurance     = paidPredIns,
            TotalPaidActualAllowed     = paidActAllowed,
            TotalPaidActualInsurance   = paidActIns,

            // ── Predicted - Unpaid ────────────────────────────────────────────
            TotalUnpaidClaims          = unpaidCnt,
            TotalUnpaidPredAllowed     = unpaidPredAllowed,
            TotalUnpaidPredInsurance   = unpaidPredIns,
            TotalUnpaidActualAllowed   = unpaidActAllowed,
            TotalUnpaidActualInsurance = unpaidActIns,

            // ── Denied ────────────────────────────────────────────────────────
            DeniedClaims               = denCnt,
            DeniedPredAllowed          = denPredAll,
            DeniedPredInsurance        = denPredIns,
            DeniedActualAllowed        = denActAll,
            DeniedActualInsurance      = denActIns,

            // ── No Response ───────────────────────────────────────────────────
            NoResponseClaims           = noRCnt,
            NoResponsePredAllowed      = noRPredAll,
            NoResponsePredInsurance    = noRPredIns,
            NoResponseActualAllowed    = noRActAll,
            NoResponseActualInsurance  = noRActIns,

            // ── Adjusted ──────────────────────────────────────────────────────
            AdjustedClaims             = adjCnt,
            AdjustedPredAllowed        = adjPredAll,
            AdjustedPredInsurance      = adjPredIns,
            AdjustedActualAllowed      = adjActAll,
            AdjustedActualInsurance    = adjActIns,

            // ── Ratios — Claim (%) ────────────────────────────────────────────
            PaymentRatioCount          = Pct(paidCnt,   predCnt),
            NonPaymentRateCount        = Pct(unpaidCnt, predCnt),
            DeniedRatioCount           = Pct(denCnt,    unpaidCnt),
            NoResponseRatioCount       = Pct(noRCnt,    unpaidCnt),
            AdjustedRatioCount         = Pct(adjCnt,    unpaidCnt),

            // ── Ratios — Predicted Allowed (%) ────────────────────────────────
            PaymentRatioAllowed        = Pct(paidPredAllowed,   predAllowed),
            NonPaymentRateAllowed      = Pct(unpaidPredAllowed, predAllowed),
            DeniedRatioAllowed         = Pct(denPredAll,        unpaidPredAllowed),
            NoResponseRatioAllowed     = Pct(noRPredAll,        unpaidPredAllowed),
            AdjustedRatioAllowed       = Pct(adjPredAll,        unpaidPredAllowed),

            // ── Ratios — Predicted Insurance Payment (%) ──────────────────────
            PaymentRatioInsurance      = Pct(paidPredIns,   predIns),
            NonPaymentRateInsurance    = Pct(unpaidPredIns, predIns),
            DeniedRatioInsurance       = Pct(denPredIns,    unpaidPredIns),
            NoResponseRatioInsurance   = Pct(noRPredIns,    unpaidPredIns),
            AdjustedRatioInsurance     = Pct(adjPredIns,    unpaidPredIns),

            // ── Prediction Accuracy ───────────────────────────────────────────
            PredVsActualRatioCount     = Pct(paidCnt,        predCnt),
            PredVsActualRatioAllowed   = Pct(paidActAllowed, paidPredAllowed),
            PredVsActualRatioInsurance = Pct(paidActIns,     paidPredIns),
        };
    }
    //public SummaryResult BuildSummary(
    //    List<ClaimRecord> predicted,
    //    List<ClaimRecord> unpaid,
    //    List<ClaimRecord> allFiltered)
    //{
    //    // ── Predicted to Pay ─────────────────────────────────────────────────
    //    int     predictedCount  = predicted.Select(r => r.VisitNumber).Distinct().Count();
    //    decimal predictedAmount = predicted.Sum(r => r.ModeAllowedAmount);

    //    // ── Paid ─────────────────────────────────────────────────────────────
    //    var paid = allFiltered
    //        .Where(r => r.PayStatus.Trim().Equals(_settings.PayStatusPaid, StringComparison.OrdinalIgnoreCase))
    //        .ToList();
    //    int     paidCount     = paid.Select(r => r.VisitNumber).Distinct().Count();
    //    decimal paidExpected  = paid.Sum(r => r.ModeAllowedAmount);
    //    decimal paidAllowed   = paid.Sum(r => r.AllowedAmount);
    //    decimal paidInsurance = paid.Sum(r => r.InsurancePayment);

    //    // ── Unpaid breakdown ─────────────────────────────────────────────────
    //    int     unpaidCount  = unpaid.Select(r => r.VisitNumber).Distinct().Count();
    //    decimal unpaidAmount = unpaid.Sum(r => r.ModeAllowedAmount);

    //    var denied     = unpaid.Where(r => r.PayStatus.Trim().Equals(_settings.PayStatusDenied,     StringComparison.OrdinalIgnoreCase)).ToList();
    //    var noResponse = unpaid.Where(r => r.PayStatus.Trim().Equals(_settings.PayStatusNoResponse, StringComparison.OrdinalIgnoreCase)).ToList();
    //    var adjusted   = unpaid.Where(r => r.PayStatus.Trim().Equals(_settings.PayStatusAdjusted,   StringComparison.OrdinalIgnoreCase)).ToList();

    //    int     deniedCount     = denied.Select(r => r.VisitNumber).Distinct().Count();
    //    decimal deniedAmount    = denied.Sum(r => r.ModeAllowedAmount);
    //    int     noRespCount     = noResponse.Select(r => r.VisitNumber).Distinct().Count();
    //    decimal noRespAmount    = noResponse.Sum(r => r.ModeAllowedAmount);
    //    int     adjustedCount   = adjusted.Select(r => r.VisitNumber).Distinct().Count();
    //    decimal adjustedAmount  = adjusted.Sum(r => r.ModeAllowedAmount);

    //    // ── Ratios ────────────────────────────────────────────────────────────
    //    static decimal Pct(decimal num, decimal denom)
    //        => denom == 0 ? 0m : Math.Round(num / denom * 100, 2);

    //    return new SummaryResult
    //    {
    //        TotalPredictedClaims  = predictedCount,
    //        TotalPredictedAmount  = predictedAmount,

    //        TotalPaidClaims       = paidCount,
    //        TotalPaidExpected     = paidExpected,
    //        TotalPaidAllowed      = paidAllowed,
    //        TotalPaidInsurance    = paidInsurance,

    //        TotalUnpaidClaims     = unpaidCount,
    //        TotalUnpaidAmount     = unpaidAmount,

    //        DeniedClaims          = deniedCount,
    //        DeniedAmount          = deniedAmount,
    //        NoResponseClaims      = noRespCount,
    //        NoResponseAmount      = noRespAmount,
    //        AdjustedClaims        = adjustedCount,
    //        AdjustedAmount        = adjustedAmount,

    //        NonPaymentRateCount   = Pct(unpaidCount,   predictedCount),
    //        NonPaymentRateAmount  = Pct(unpaidAmount,  predictedAmount),

    //        PaymentRatioCount     = Pct(paidCount,     predictedCount),
    //        PaymentRatioAmount    = Pct(paidExpected,  predictedAmount),

    //        DeniedRatioCount      = Pct(deniedCount,   unpaidCount),
    //        DeniedRatioAmount     = Pct(deniedAmount,  unpaidAmount),

    //        NoResponseRatioCount  = Pct(noRespCount,   unpaidCount),
    //        NoResponseRatioAmount = Pct(noRespAmount,  unpaidAmount),

    //        AdjustedRatioCount    = Pct(adjustedCount, unpaidCount),
    //        AdjustedRatioAmount   = Pct(adjustedAmount,unpaidAmount),
    //};
    //}



    // ── Shared: split "CO-109,CO-16" → one record per individual code ─────────
    private static IEnumerable<ExplodedDenialRecord> ExplodeByCodes(IEnumerable<ClaimRecord> denied)
    {
        foreach (var r in denied)
        {
            var codes = r.DenialCode
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (codes.Length == 0) codes = [string.Empty];

            foreach (var code in codes)
                yield return new ExplodedDenialRecord(
                    r.VisitNumber, r.PayerName, code,
                    r.DenialDescription, r.ExpectedPaymentDate,
                    r.ModeAllowedAmount,
                    r.ModeInsurancePaid);   // ← new field
        }
    }

    // ── Step 6a: Top N denial codes per payer ─────────────────────────────────
    public List<DenialSummaryRow> BuildDenialSummary(List<ClaimRecord> working)
    {
        var denied   = working.Where(r =>
            r.PayStatus.Trim().Equals(_settings.PayStatusDenied, StringComparison.OrdinalIgnoreCase));
        var exploded = ExplodeByCodes(denied).ToList();
        Console.WriteLine($"[Step 6a] Denied records: {denied.Count()}  |  Exploded rows: {exploded.Count}");

        return exploded
            .GroupBy(r => new { r.PayerName, r.DenialCode })
            .Select(g => new
            {
                g.Key.PayerName,
                g.Key.DenialCode,
                ClaimCount            = g.Select(r => r.VisitNumber).Distinct().Count(),
                ExpectedPaymentAmount = g.GroupBy(r => r.VisitNumber).Sum(vg => vg.Max(r => r.ModeAllowedAmount))
            })
            .GroupBy(r => r.PayerName)
            .SelectMany(pg => pg
                .OrderByDescending(r => r.ClaimCount)
                .Take(_settings.TopDenialCodesPerPayer)
                .Select((r, idx) => new DenialSummaryRow
                {
                    Rank                  = idx + 1,
                    PayerName             = r.PayerName,
                    DenialCode            = r.DenialCode,
                    DenialDescription     = string.Empty,
                    ClaimCount            = r.ClaimCount,
                    ExpectedPaymentAmount = r.ExpectedPaymentAmount
                }))
            .OrderBy(r => r.PayerName)
            .ThenBy(r => r.Rank)
            .ToList();
    }

    // ── Denial Code Analysis: all codes across all payers ────────────────────
    /// <summary>
    /// Builds a flat denial-code analysis table (one row per unique denial code),
    /// sorted by line-item count descending.
    /// </summary>
    public List<DenialCodeAnalysisRow> BuildDenialCodeAnalysis(List<ClaimRecord> working)
    {
        var denied   = working.Where(r =>
            r.PayStatus.Trim().Equals(_settings.PayStatusDenied, StringComparison.OrdinalIgnoreCase));
        var exploded = ExplodeByCodes(denied).ToList();

        int totalLineItems = exploded.Select(r => r.VisitNumber).Distinct().Count();

        return exploded
            .GroupBy(r => r.DenialCode, StringComparer.OrdinalIgnoreCase)
            .Select(g =>
            {
                int lineItems = g.Select(r => r.VisitNumber).Distinct().Count();
                var payers    = g.Select(r => r.PayerName.Trim())
                                 .Where(p => !string.IsNullOrWhiteSpace(p))
                                 .Distinct(StringComparer.OrdinalIgnoreCase)
                                 .OrderBy(p => p)
                                 .ToList();

                string description = g
                    .Where(r => !string.IsNullOrWhiteSpace(r.DenialDescription))
                    .Select(r => r.DenialDescription.Trim())
                    .FirstOrDefault() ?? string.Empty;

                decimal allowed = g
                    .GroupBy(r => r.VisitNumber)
                    .Sum(vg => vg.Max(r => r.ModeAllowedAmount));

                return new DenialCodeAnalysisRow
                {
                    DenialCode        = g.Key,
                    DenialDescription = description,
                    LineItemCount     = lineItems,
                    PctOfAllDenials   = totalLineItems == 0 ? 0m
                                        : Math.Round((decimal)lineItems / totalLineItems * 100, 1),
                    UniquePayers      = payers.Count,
                    AllowedAmount     = allowed,
                    PayerList         = string.Join(", ", payers)
                };
            })
            .OrderByDescending(r => r.LineItemCount)
            .ToList();
    }

    // ── Step 6b: Flat breakdown by month ──────────────────────────────────────
    public List<DenialMonthRow> BuildDenialMonthBreakdown(
        List<ClaimRecord> working, List<DenialSummaryRow> summary)
    {
        var topCodesByPayer = summary
            .GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(
                g => g.Key,
                g => g.Select(r => r.DenialCode).ToHashSet(StringComparer.OrdinalIgnoreCase),
                StringComparer.OrdinalIgnoreCase);

        var denied   = working.Where(r =>
            r.PayStatus.Trim().Equals(_settings.PayStatusDenied, StringComparison.OrdinalIgnoreCase)
            && topCodesByPayer.ContainsKey(r.PayerName));
        var exploded = ExplodeByCodes(denied)
            .Where(r => topCodesByPayer.TryGetValue(r.PayerName, out var c) && c.Contains(r.DenialCode))
            .ToList();
        Console.WriteLine($"[Step 6b] Exploded rows for month breakdown: {exploded.Count}");

        return exploded
            .GroupBy(r => new
            {
                r.PayerName, r.DenialCode, r.DenialDescription,
                Month     = r.ExpectedPaymentDate.HasValue ? r.ExpectedPaymentDate.Value.ToString("MMMM yyyy") : "Unknown",
                MonthSort = r.ExpectedPaymentDate.HasValue ? r.ExpectedPaymentDate.Value.ToString("yyyy-MM")   : "9999-99"
            })
            .Select(g => new DenialMonthRow
            {
                PayerName             = g.Key.PayerName,
                DenialCode            = g.Key.DenialCode,
                DenialDescription     = g.Key.DenialDescription,
                ExpectedPaymentMonth  = g.Key.Month,
                MonthSort             = g.Key.MonthSort,
                ClaimCount            = g.Select(r => r.VisitNumber).Distinct().Count(),
                ExpectedPaymentAmount = g.GroupBy(r => r.VisitNumber).Sum(vg => vg.Max(r => r.ModeAllowedAmount))
            })
            .OrderBy(r => r.PayerName).ThenBy(r => r.DenialCode).ThenBy(r => r.MonthSort)
            .ToList();
    }

    // ── Step 6 Pivot: Payer → Denial Code rows × Month columns ───────────────
    public DenialPivotResult BuildDenialPivot(
        List<ClaimRecord> working, List<DenialSummaryRow> summary)
    {
        var topCodesByPayer = summary
            .GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(
                g => g.Key,
                g => g.OrderBy(r => r.Rank).Select(r => r.DenialCode).ToList(),
                StringComparer.OrdinalIgnoreCase);

        var denied   = working.Where(r =>
            r.PayStatus.Trim().Equals(_settings.PayStatusDenied, StringComparison.OrdinalIgnoreCase)
            && topCodesByPayer.ContainsKey(r.PayerName));
        var exploded = ExplodeByCodes(denied)
            .Where(r => topCodesByPayer.TryGetValue(r.PayerName, out var c) && c.Contains(r.DenialCode))
            .ToList();

        // Use "MMM-yy" (e.g. "Mar-26") — avoids any quote character in format strings
        static string MonthLabel(DateTime d) => d.ToString("MMM-yy");
        static string MonthSort(DateTime d)  => d.ToString("yyyy-MM");

        var allMonths = exploded
            .Where(r => r.ExpectedPaymentDate.HasValue)
            .Select(r => new
            {
                Label = MonthLabel(r.ExpectedPaymentDate!.Value),
                Sort  = MonthSort(r.ExpectedPaymentDate!.Value)
            })
            .DistinctBy(m => m.Sort)
            .OrderBy(m => m.Sort)
            .Select(m => m.Label)
            .ToList();

        // ── Cell data: Payer + Code + Month → (ClaimCount, Allowed, Insurance) ─
        var cellData = exploded
            .GroupBy(r => new
            {
                r.PayerName,
                r.DenialCode,
                Month = r.ExpectedPaymentDate.HasValue
                    ? MonthLabel(r.ExpectedPaymentDate.Value) : "Unknown"
            })
            .ToDictionary(
                g => (g.Key.PayerName, g.Key.DenialCode, g.Key.Month),
                g => new DenialPivotCell(
                    g.Select(r => r.VisitNumber).Distinct().Count(),
                    g.GroupBy(r => r.VisitNumber).Sum(vg => vg.Max(r => r.ModeAllowedAmount)),
                    g.GroupBy(r => r.VisitNumber).Sum(vg => vg.Max(r => r.ModeInsurancePaid))));

        // ── Payer totals ──────────────────────────────────────────────────────
        var payerTotals = exploded
            .GroupBy(r => r.PayerName)
            .ToDictionary(
                g => g.Key,
                g => new DenialPivotCell(
                    g.Select(r => r.VisitNumber).Distinct().Count(),
                    g.GroupBy(r => r.VisitNumber).Sum(vg => vg.Max(r => r.ModeAllowedAmount)),
                    g.GroupBy(r => r.VisitNumber).Sum(vg => vg.Max(r => r.ModeInsurancePaid))));

        // ── Code totals ───────────────────────────────────────────────────────
        var codeTotals = exploded
            .GroupBy(r => new { r.PayerName, r.DenialCode })
            .ToDictionary(
                g => (g.Key.PayerName, g.Key.DenialCode),
                g => new DenialPivotCell(
                    g.Select(r => r.VisitNumber).Distinct().Count(),
                    g.GroupBy(r => r.VisitNumber).Sum(vg => vg.Max(r => r.ModeAllowedAmount)),
                    g.GroupBy(r => r.VisitNumber).Sum(vg => vg.Max(r => r.ModeInsurancePaid))));

        var orderedPayers = summary.Select(r => r.PayerName).Distinct().ToList();

        return new DenialPivotResult(
            orderedPayers, topCodesByPayer, allMonths, cellData, payerTotals, codeTotals);
    }

    // ── Step 7: No-response aging pivot (one row per payer × fixed buckets) ───
    public List<AgingPivotRow> BuildAgingBuckets(List<ClaimRecord> working)
    {
        var today = DateTime.Today;
        var noResponse = working
            .Where(r => r.PayStatus.Trim().Equals(
                _settings.PayStatusNoResponse, StringComparison.OrdinalIgnoreCase))
            .ToList();

        return noResponse
            .GroupBy(r => r.PayerName)
            .Select(pg =>
            {
                int     b0_30    = CountBucket   (pg,   0,  30,          today);
                decimal a0_30    = AmountBucket  (pg,   0,  30,          today);
                decimal i0_30    = InsuranceBucket(pg,  0,  30,          today);

                int     b31_60   = CountBucket   (pg,  31,  60,          today);
                decimal a31_60   = AmountBucket  (pg,  31,  60,          today);
                decimal i31_60   = InsuranceBucket(pg, 31,  60,          today);

                int     b61_90   = CountBucket   (pg,  61,  90,          today);
                decimal a61_90   = AmountBucket  (pg,  61,  90,          today);
                decimal i61_90   = InsuranceBucket(pg, 61,  90,          today);

                int     b91_120  = CountBucket   (pg,  91, 120,          today);
                decimal a91_120  = AmountBucket  (pg,  91,  120,          today);
                decimal i91_120  = InsuranceBucket(pg, 91, 120,          today);

                int     b121p    = CountBucket   (pg, 121, int.MaxValue, today);
                decimal a121p    = AmountBucket  (pg, 121, int.MaxValue, today);
                decimal i121p    = InsuranceBucket(pg, 121, int.MaxValue, today);

                int     total    = b0_30 + b31_60 + b61_90 + b91_120 + b121p;

                string priority  = b121p   > 0 ? "Critical / Timely Filing Risk"
                                 : b91_120 > 0 ? "Urgent Review"
                                 : b61_90  > 0 ? "Escalate"
                                 : b31_60  > 0 ? "Follow-Up Required"
                                 :               "Monitor";

                return new AgingPivotRow
                {
                    PayerName             = pg.Key,

                    Bucket0_30            = b0_30,
                    AmountBucket0_30      = a0_30,
                    InsuranceBucket0_30   = i0_30,

                    Bucket31_60           = b31_60,
                    AmountBucket31_60     = a31_60,
                    InsuranceBucket31_60  = i31_60,

                    Bucket61_90           = b61_90,
                    AmountBucket61_90     = a61_90,
                    InsuranceBucket61_90  = i61_90,

                    Bucket91_120          = b91_120,
                    AmountBucket91_120    = a91_120,
                    InsuranceBucket91_120 = i91_120,

                    Bucket121Plus         = b121p,
                    AmountBucket121Plus   = a121p,
                    InsuranceBucket121Plus = i121p,

                    Total                 = total,
                    TotalAmount           = a0_30 + a31_60 + a61_90 + a91_120 + a121p,
                    TotalInsurance        = i0_30 + i31_60 + i61_90 + i91_120 + i121p,

                    PriorityLevel         = priority
                };
            })
            .Where(r => r.Total > 0)
            .OrderByDescending(r => r.Total)   // Sort By: Claim Count descending
            .ToList();
    }

    private static decimal InsuranceBucket(
        IGrouping<string, ClaimRecord> group,
        int minDays, int maxDays, DateTime today)
    {
        return group
            .Where(r =>
            {
                if (!r.ExpectedPaymentDate.HasValue) return false;
                int days = (today - r.ExpectedPaymentDate.Value.Date).Days;
                return days >= minDays && days <= maxDays;
            })
            .GroupBy(r => r.VisitNumber)
            .Sum(vg => vg.Max(r => r.ModeInsurancePaid));
    }

    private static int CountBucket(
        IGrouping<string, ClaimRecord> group,
        int minDays, int maxDays, DateTime today)
    {
        return group
            .Where(r =>
            {
                if (!r.ExpectedPaymentDate.HasValue) return false;
                int days = (today - r.ExpectedPaymentDate.Value.Date).Days;
                return days >= minDays && days <= maxDays;
            })
            .Select(r => r.VisitNumber)
            .Distinct()
            .Count();
    }

    private static decimal AmountBucket(
        IGrouping<string, ClaimRecord> group,
        int minDays, int maxDays, DateTime today)
    {
        return group
            .Where(r =>
            {
                if (!r.ExpectedPaymentDate.HasValue) return false;
                int days = (today - r.ExpectedPaymentDate.Value.Date).Days;
                return days >= minDays && days <= maxDays;
            })
            .GroupBy(r => r.VisitNumber)
            .Sum(vg => vg.Max(r => r.ModeAllowedAmount));
    }
}

// ── Internal ──────────────────────────────────────────────────────────────────

internal record ExplodedDenialRecord(
    string    VisitNumber,
    string    PayerName,
    string    DenialCode,
    string    DenialDescription,
    DateTime? ExpectedPaymentDate,
    decimal   ModeAllowedAmount,
    decimal   ModeInsurancePaid);

// ── Public models ─────────────────────────────────────────────────────────────

public record SummaryResult
{
    // ── Predicted To Pay (base: ForecastingP filter + cutoff, all PayStatuses) ─
    public int     TotalPredictedClaims       { get; init; }
    public decimal TotalPredictedAllowed      { get; init; }   // SUM(ModeAllowedAmount)
    public decimal TotalPredictedInsurance    { get; init; }   // SUM(ModeInsurancePaid)

    // ── Predicted - Paid ──────────────────────────────────────────────────────
    public int     TotalPaidClaims            { get; init; }
    public decimal TotalPaidPredAllowed       { get; init; }   // SUM(ModeAllowedAmount) for Paid rows
    public decimal TotalPaidPredInsurance     { get; init; }   // SUM(ModeInsurancePaid) for Paid rows
    public decimal TotalPaidActualAllowed     { get; init; }   // SUM(AllowedAmount)
    public decimal TotalPaidActualInsurance   { get; init; }   // SUM(InsurancePayment)

    // ── Predicted - Unpaid (Denied + Adjusted + No Response) ─────────────────
    public int     TotalUnpaidClaims          { get; init; }
    public decimal TotalUnpaidPredAllowed     { get; init; }
    public decimal TotalUnpaidPredInsurance   { get; init; }
    public decimal TotalUnpaidActualAllowed   { get; init; }
    public decimal TotalUnpaidActualInsurance { get; init; }

    // ── Unpaid - Denied ───────────────────────────────────────────────────────
    public int     DeniedClaims               { get; init; }
    public decimal DeniedPredAllowed          { get; init; }
    public decimal DeniedPredInsurance        { get; init; }
    public decimal DeniedActualAllowed        { get; init; }
    public decimal DeniedActualInsurance      { get; init; }

    // ── Unpaid - No Response ──────────────────────────────────────────────────
    public int     NoResponseClaims           { get; init; }
    public decimal NoResponsePredAllowed      { get; init; }
    public decimal NoResponsePredInsurance    { get; init; }
    public decimal NoResponseActualAllowed    { get; init; }
    public decimal NoResponseActualInsurance  { get; init; }

    // ── Unpaid - Adjusted ─────────────────────────────────────────────────────
    public int     AdjustedClaims             { get; init; }
    public decimal AdjustedPredAllowed        { get; init; }
    public decimal AdjustedPredInsurance      { get; init; }
    public decimal AdjustedActualAllowed      { get; init; }
    public decimal AdjustedActualInsurance    { get; init; }

    // ── Ratios — Claim (%), Predicted Allowed (%), Predicted Insurance (%) ────
    public decimal PaymentRatioCount          { get; init; }
    public decimal PaymentRatioAllowed        { get; init; }
    public decimal PaymentRatioInsurance      { get; init; }

    public decimal NonPaymentRateCount        { get; init; }
    public decimal NonPaymentRateAllowed      { get; init; }
    public decimal NonPaymentRateInsurance    { get; init; }

    public decimal DeniedRatioCount           { get; init; }
    public decimal DeniedRatioAllowed         { get; init; }
    public decimal DeniedRatioInsurance       { get; init; }

    public decimal NoResponseRatioCount       { get; init; }
    public decimal NoResponseRatioAllowed     { get; init; }
    public decimal NoResponseRatioInsurance   { get; init; }

    public decimal AdjustedRatioCount         { get; init; }
    public decimal AdjustedRatioAllowed       { get; init; }
    public decimal AdjustedRatioInsurance     { get; init; }

    // ── Prediction Accuracy ───────────────────────────────────────────────────
    public decimal PredVsActualRatioCount     { get; init; }  // Paid Count / Predicted Count × 100
    public decimal PredVsActualRatioAllowed   { get; init; }  // Actual Allowed / Predicted Paid Allowed × 100
    public decimal PredVsActualRatioInsurance { get; init; }  // Actual Insurance / Predicted Paid Insurance × 100

    // ── kept for Teams notification compatibility ─────────────────────────────
    public decimal TotalPredictedAmount  => TotalPredictedAllowed;
    public decimal TotalUnpaidAmount     => TotalUnpaidPredAllowed;
    public decimal NonPaymentRateAmount  => NonPaymentRateAllowed;
}

public record DenialSummaryRow
{
    public int     Rank                  { get; init; }
    public string  PayerName             { get; init; } = string.Empty;
    public string  DenialCode            { get; init; } = string.Empty;
    public string  DenialDescription     { get; init; } = string.Empty;
    public int     ClaimCount            { get; init; }
    public decimal ExpectedPaymentAmount { get; init; }
}

public record DenialMonthRow
{
    public string  PayerName             { get; init; } = string.Empty;
    public string  DenialCode            { get; init; } = string.Empty;
    public string  DenialDescription     { get; init; } = string.Empty;
    public string  ExpectedPaymentMonth  { get; init; } = string.Empty;
    public string  MonthSort             { get; init; } = string.Empty;
    public int     ClaimCount            { get; init; }
    public decimal ExpectedPaymentAmount { get; init; }
}

public record DenialPivotCell(int ClaimCount, decimal Amount, decimal InsuranceAmount);

public record DenialPivotResult(
    List<string>                                                             OrderedPayers,
    Dictionary<string, List<string>>                                         TopCodesByPayer,
    List<string>                                                             AllMonths,
    Dictionary<(string Payer, string Code, string Month), DenialPivotCell>  CellData,
    Dictionary<string, DenialPivotCell>                                      PayerTotals,
    Dictionary<(string Payer, string Code), DenialPivotCell>                 CodeTotals);

public record AgingPivotRow
{
    public string  PayerName                  { get; init; } = string.Empty;

    public int     Bucket0_30                 { get; init; }
    public decimal AmountBucket0_30           { get; init; }
    public decimal InsuranceBucket0_30        { get; init; }

    public int     Bucket31_60                { get; init; }
    public decimal AmountBucket31_60          { get; init; }
    public decimal InsuranceBucket31_60       { get; init; }

    public int     Bucket61_90                { get; init; }
    public decimal AmountBucket61_90          { get; init; }
    public decimal InsuranceBucket61_90       { get; init; }

    public int     Bucket91_120               { get; init; }
    public decimal AmountBucket91_120         { get; init; }
    public decimal InsuranceBucket91_120      { get; init; }

    public int     Bucket121Plus              { get; init; }
    public decimal AmountBucket121Plus        { get; init; }
    public decimal InsuranceBucket121Plus     { get; init; }

    public int     Total                      { get; init; }
    public decimal TotalAmount                { get; init; }
    public decimal TotalInsurance             { get; init; }

    public string  PriorityLevel              { get; init; } = string.Empty;
}

public record DenialCodeAnalysisRow
{
    public string  DenialCode        { get; init; } = string.Empty;
    public string  DenialDescription { get; init; } = string.Empty;
    /// <summary>Distinct visit count (line items) for this denial code.</summary>
    public int     LineItemCount     { get; init; }
    /// <summary>LineItemCount as a percentage of total denied line items.</summary>
    public decimal PctOfAllDenials   { get; init; }
    /// <summary>Number of distinct payers that issued this denial code.</summary>
    public int     UniquePayers      { get; init; }
    /// <summary>Sum of ModeAllowedAmount for all visits carrying this code.</summary>
    public decimal AllowedAmount     { get; init; }
    /// <summary>Comma-separated list of distinct payer names for this code.</summary>
    public string  PayerList         { get; init; } = string.Empty;
}