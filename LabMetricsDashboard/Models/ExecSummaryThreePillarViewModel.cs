namespace LabMetricsDashboard.Models;

// =====================================================================
// Beech Tree "Three-Pillar Framework & 7-Check Diagnostic"
// (source: Beech_Tree_Three_Pillar_Diagnostic_2.docx).
//
// Built one pillar/SP at a time:
//   1) LIS  → dbo.usp_GetBeechTree_ThreePillarLisDiagnostic   (this phase)
//   2) PMS  → dbo.usp_GetBeechTree_ThreePillarPmsDiagnostic   (next)
//   3) Cash → dbo.usp_GetBeechTree_ThreePillarCashDiagnostic  (next)
// =====================================================================

/// <summary>One month of LIS Breakdown metrics for charts + tables.</summary>
public sealed class ThreePillarLisMonth
{
    public string MonthLabel { get; set; } = string.Empty;
    public int SortYear { get; set; }
    public int SortMonth { get; set; }
    public long TotalSamples { get; set; }
    public long Resulted { get; set; }
    public decimal? PctResulted { get; set; }
    public long BilledToInsurance { get; set; }
    public decimal? PctBilledOfResulted { get; set; }
    public long SelfPay { get; set; }
    public decimal? SelfPayPct { get; set; }
    public long ClientBill { get; set; }
    public decimal? ClientBillPct { get; set; }
    public long NotResulted { get; set; }
}

public sealed class ThreePillarLisFunnelPeriod
{
    public long Collected { get; set; }
    public long Resulted { get; set; }
    public long BilledToInsurance { get; set; }
    public decimal? PctResulted { get; set; }
    public decimal? PctBilledOfCollected { get; set; }
    public decimal? PctBilledOfResulted { get; set; }
}

public sealed class ThreePillarLisFunnelMonth
{
    public string MonthLabel { get; set; } = string.Empty;
    public long Collected { get; set; }
    public long Resulted { get; set; }
    public long BilledToInsurance { get; set; }
}

public sealed class ThreePillarBacklogSummary
{
    public long TotalBacklog { get; set; }
    public decimal? MedianAgeDays { get; set; }
    public decimal? PctOver60Days { get; set; }
}

public sealed class ThreePillarAgeBucket
{
    public string AgeBucket { get; set; } = string.Empty;
    public int SortOrder { get; set; }
    public long SampleCount { get; set; }
    /// <summary>Populated only for the Insurance Balance aging decomposition (result set 11); 0 for the LIS backlog bucket.</summary>
    public decimal BalanceTotal { get; set; }
}

public sealed class ThreePillarPctBilledOfResultedMonth
{
    public string MonthLabel { get; set; } = string.Empty;
    public long Resulted { get; set; }
    public long BilledToInsurance { get; set; }
    public decimal? PctBilledOfResulted { get; set; }
}

public sealed class ThreePillarSelfPayClientBillMonth
{
    public string MonthLabel { get; set; } = string.Empty;
    public long TotalSamples { get; set; }
    public long SelfPay { get; set; }
    public long ClientBill { get; set; }
    public decimal? SelfPayPct { get; set; }
    public decimal? ClientBillPct { get; set; }
}

public sealed class ThreePillarNotResultedMonth
{
    public string MonthLabel { get; set; } = string.Empty;
    public long NotResulted { get; set; }
}

public sealed class ThreePillarReconciliationMonth
{
    public string MonthLabel { get; set; } = string.Empty;
    public long PmsBilled { get; set; }
    public long LisBilledToInsurance { get; set; }
    public long Gap { get; set; }
}

public sealed class ThreePillarFullyAdjustedMonth
{
    public string MonthLabel { get; set; } = string.Empty;
    public long BilledClaims { get; set; }
    public long FullyAdjusted { get; set; }
    public decimal? PctFullyAdjusted { get; set; }
}

public sealed class ThreePillarFullyAdjustedReason
{
    public string TransactionCodeCombined { get; set; } = string.Empty;
    public long MatchingCount { get; set; }
}

public sealed class ThreePillarFullyPaidMonth
{
    public string MonthLabel { get; set; } = string.Empty;
    public long BilledClaims { get; set; }
    public long FullyPaid { get; set; }
    public decimal? PctFullyPaid { get; set; }
}

public sealed class ThreePillarDenialByCarrier
{
    public string PayerName { get; set; } = string.Empty;
    public decimal TotalAllowed { get; set; }
    public decimal DeniedAllowed { get; set; }
    public decimal? DenialRatePct { get; set; }
}

public sealed class ThreePillarTopDenialReason
{
    public string PayerName { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;
    public string MonthLabel { get; set; } = string.Empty;
    public long DenialCount { get; set; }
}

public sealed class ThreePillarPatientCollectionsReality
{
    public long OpenPatientBalanceClaims { get; set; }
    public decimal OpenBalanceTotal { get; set; }
    public long ClaimsWithAnyPayment { get; set; }
    public decimal? CollectionsRealityPct { get; set; }
}

public sealed class ThreePillarPanelAvgAllowedPaid
{
    public string Panelname { get; set; } = string.Empty;
    public string MonthLabelDos { get; set; } = string.Empty;
    public decimal AvgAllowed { get; set; }
    public long AllowedClaimCount { get; set; }
    public decimal? AvgPaidByPaymentDate { get; set; }
    public long PaidClaimCount { get; set; }
}

public sealed class ThreePillarMaturityPoint
{
    public string DOSMonthLabel { get; set; } = string.Empty;
    public int DaySinceDOS { get; set; }
    public decimal? PctAllowedPaid { get; set; }
}

public sealed class ThreePillarInsuranceBalanceMonth
{
    public string MonthLabel { get; set; } = string.Empty;
    public long BilledClaims { get; set; }
    public long InsuranceBalanceClaims { get; set; }
    public decimal? PctInsuranceBalance { get; set; }
    public long FullyDeniedClaims { get; set; }
    public long NoResponseClaims { get; set; }
    public long PartiallyDeniedClaims { get; set; }
    public decimal InsuranceBalanceAmt { get; set; }
}

public sealed class ThreePillarCashHeadlineMonth
{
    public string MonthLabel { get; set; } = string.Empty;
    public decimal TotalBilledAmt { get; set; }
    public decimal InsurancePaymentFullyPaid { get; set; }
    public decimal? CollectionRatePct { get; set; }
    public decimal PartiallyPaidAmt { get; set; }
    public decimal? PctPartiallyPaidOfBilled { get; set; }
    public decimal PatientWOAmt { get; set; }
    public decimal PatientBalanceAmt { get; set; }
    public decimal PatientPaymentAmt { get; set; }
    public decimal? WriteOffRatioPct { get; set; }
    public decimal? PatientCollectionRatePct { get; set; }
    public decimal FullyAdjustedAmt { get; set; }
    public decimal? PctFullyAdjustedOfBilled { get; set; }
    public decimal InsuranceBalanceAmt { get; set; }
    public decimal? PctInsuranceBalanceOfBilled { get; set; }
    public decimal FullyDeniedIBAmt { get; set; }
    public decimal NoResponseIBAmt { get; set; }
    public decimal PartiallyDeniedIBAmt { get; set; }
    public decimal? NoResponseSharePct { get; set; }
}

/// <summary>Panel × payer prior-vs-latest DOS month avg allowed/paid (PMS RS7).</summary>
public sealed class ThreePillarPanelPayerMom
{
    public string Panelname { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public string PriorMonthLabel { get; set; } = string.Empty;
    public string LatestMonthLabel { get; set; } = string.Empty;
    public decimal PriorAllowed { get; set; }
    public decimal PriorPaid { get; set; }
    public long PriorN { get; set; }
    public decimal LatestAllowed { get; set; }
    public decimal LatestPaid { get; set; }
    public long LatestN { get; set; }
    public decimal? MomPctPaid { get; set; }
}

public sealed class ExecSummaryThreePillarViewModel
{
    public string LabName { get; set; } = string.Empty;

    /// <summary>Legacy calendar year (0 = unused). Prefer <see cref="TrailingMonths"/>.</summary>
    public int Year { get; set; }

    /// <summary>Trailing month count: 3 / 6 / 9 / 12 / 19.</summary>
    public int TrailingMonths { get; set; } = 12;

    /// <summary>Day-of-month cutoff from WeekRange end (Insights comparable window).</summary>
    public int DayWindow { get; set; } = 9;

    /// <summary>WeekRange end date used as AsOf / latest-month anchor.</summary>
    public DateTime? AsOfDate { get; set; }

    public string? WeekFolder { get; set; }

    public string ScopeLabel
    {
        get
        {
            var months = $"Last {TrailingMonths} months";
            var days = DayWindow > 0 ? $" · days 1–{DayWindow} each month" : "";
            var asOf = AsOfDate is { } d ? $" · as of {d:MM/dd/yyyy}" : "";
            return months + days + asOf;
        }
    }

    public string BackUrl { get; set; } = string.Empty;

    public string? ErrorMessage { get; set; }

    /// <summary>Which pillar sections are loaded. Phase 1 = LIS only.</summary>
    public bool LisLoaded { get; set; }
    public bool PmsLoaded { get; set; }
    public bool CashLoaded { get; set; }

    /// <summary>LIS monthly series from usp_GetBeechTree_ThreePillarLisDiagnostic RS1.</summary>
    public List<ThreePillarLisMonth> LisMonthly { get; set; } = [];

    /// <summary>Full-period funnel totals (RS4) for the connected Sample-to-Claim funnel chart.</summary>
    public ThreePillarLisFunnelPeriod FunnelPeriod { get; set; } = new();

    public List<ThreePillarLisFunnelMonth> LisFunnel { get; set; } = [];
    public ThreePillarBacklogSummary BacklogSummary { get; set; } = new();
    public List<ThreePillarAgeBucket> BacklogBuckets { get; set; } = [];
    public List<ThreePillarPctBilledOfResultedMonth> PctBilledOfResulted { get; set; } = [];
    public List<ThreePillarSelfPayClientBillMonth> SelfPayClientBill { get; set; } = [];
    public List<ThreePillarNotResultedMonth> NotResulted { get; set; } = [];
    public List<ThreePillarReconciliationMonth> Reconciliation { get; set; } = [];
    public List<ThreePillarFullyAdjustedMonth> FullyAdjusted { get; set; } = [];
    public List<ThreePillarFullyAdjustedReason> FullyAdjustedReasons { get; set; } = [];
    public List<ThreePillarFullyPaidMonth> FullyPaid { get; set; } = [];
    public List<ThreePillarDenialByCarrier> DenialByCarrier { get; set; } = [];
    public List<ThreePillarTopDenialReason> TopDenialReasons { get; set; } = [];
    public List<ThreePillarAgeBucket> InsuranceBalanceAging { get; set; } = [];
    public ThreePillarPatientCollectionsReality PatientCollections { get; set; } = new();
    public List<ThreePillarPanelAvgAllowedPaid> PanelAvgAllowedPaid { get; set; } = [];
    public List<ThreePillarMaturityPoint> MaturityCurve { get; set; } = [];
    public List<ThreePillarInsuranceBalanceMonth> InsuranceBalanceTrend { get; set; } = [];
    public List<ThreePillarCashHeadlineMonth> CashHeadline { get; set; } = [];
    public List<ThreePillarPanelPayerMom> PanelPayerMom { get; set; } = [];

    /// <summary>Cash pillar write-off reason Pareto (shares FullyAdjustedReasons list shape).</summary>
    public List<ThreePillarFullyAdjustedReason> CashWriteOffReasons { get; set; } = [];

    public bool HasData =>
        LisMonthly.Count > 0 || FunnelPeriod.Collected > 0 || BacklogSummary.TotalBacklog > 0
        || LisFunnel.Count > 0
        || Reconciliation.Count > 0 || FullyAdjusted.Count > 0
        || DenialByCarrier.Count > 0 || PanelAvgAllowedPaid.Count > 0 || MaturityCurve.Count > 0
        || InsuranceBalanceTrend.Count > 0 || CashHeadline.Count > 0
        || PanelPayerMom.Count > 0;

    public bool PmsHasData =>
        Reconciliation.Count > 0 || FullyAdjusted.Count > 0 || FullyPaid.Count > 0
        || InsuranceBalanceTrend.Count > 0 || PanelAvgAllowedPaid.Count > 0
        || MaturityCurve.Count > 0 || DenialByCarrier.Count > 0;

    public bool CashHasData => CashHeadline.Count > 0;

    /// <summary>Distinct DOS-month cohorts in the maturity curve, in order — drives one chart line per cohort.</summary>
    public List<string> MaturityCohorts =>
        MaturityCurve.Select(m => m.DOSMonthLabel).Distinct().ToList();

    /// <summary>Distinct panels in the Avg Allowed/Paid band — drives one card per panel.</summary>
    public List<string> AvgAllowedPaidPanels =>
        PanelAvgAllowedPaid.Select(p => p.Panelname).Distinct().ToList();
}
