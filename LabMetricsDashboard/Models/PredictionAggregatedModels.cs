namespace LabMetricsDashboard.Models;

// Aggregated result types returned by Prediction aggregation SPs.

/// <summary>Row from usp_GetPredictionSummaryBuckets (Section A).</summary>
public sealed record PredictionBucketSpRow(
    string   GroupName,
    string   BucketName,
    string?  PayStatus,
    bool     IsGroupTotal,
    int      SortOrder,
    int      LineItemCount,
    decimal  PredictedAllowed,
    decimal  PredictedInsurance,
    decimal? ActualAllowed,
    decimal? ActualInsurance,
    decimal? VarianceAllowed,
    decimal? VariancePaid);

/// <summary>Row from usp_GetPredictionValidationByPayer (Section B).</summary>
public sealed record PredictionPayerSpRow(
    string  PayerName,
    string  PayerType,
    int     TotalLineItems,
    int     PaidCount,
    int     DeniedCount,
    int     NoResponseCount,
    int     AdjustedCount,
    int     UnpaidCount,
    decimal PredictedAllowed,
    decimal PredictedInsurance,
    decimal ActualAllowed,
    decimal ActualInsurance,
    decimal VarianceAllowed,
    decimal VariancePaid);

/// <summary>Row from usp_GetPredictionPayerPayStatusBreakdown (Section B modal).</summary>
public sealed record PayerPayStatusSpRow(
    string  PayerName,
    string  PayStatus,
    int     LineItemCount,
    decimal PredictedAllowed,
    decimal PredictedInsurance,
    decimal ActualAllowed,
    decimal ActualInsurance,
    decimal VarianceAllowed,
    decimal VariancePaid);

/// <summary>Row from usp_GetPredictionValidationByPanel (legacy).</summary>
public sealed record PredictionPanelSpRow(
    string  PanelName,
    int     TotalLineItems,
    int     PaidCount,
    int     DeniedCount,
    int     NoResponseCount,
    int     AdjustedCount,
    int     UnpaidCount,
    decimal PredictedAllowed,
    decimal PredictedInsurance,
    decimal ActualAllowed,
    decimal ActualInsurance);

/// <summary>Row from usp_GetPredictionValidationByCPT (legacy).</summary>
public sealed record PredictionCptSpRow(
    string  CPTCode,
    int     LineItemCount,
    decimal BilledAmount,
    decimal PredictedAllowed,
    decimal PredictedInsurance);

/// <summary>Row from usp_GetPredictionDenialBreakdown (Section C).</summary>
public sealed record DenialBreakdownSpRow(
    string  PayerName,
    string  DenialCode,
    string  DenialDescription,
    string  ExpectedPaymentMonth,
    int     LineItemCount,
    decimal PredictedAllowed,
    decimal PredictedInsurance,
    decimal ActualAllowed,
    decimal ActualInsurance,
    decimal VarianceAllowed,
    decimal VariancePaid);

/// <summary>Row from usp_GetPredictionNoResponseBreakdown (Section D).</summary>
public sealed record NoResponseBreakdownSpRow(
    string   PayerName,
    string   AgeBucket,
    int      LineItemCount,
    decimal  VarianceAllowed,
    decimal  VariancePaid,
    decimal? PctVarianceAllowed,
    decimal? PctVariancePaid,
    decimal  TotalVarianceAllowed,
    decimal  TotalVariancePaid);

/// <summary>Row from usp_GetPredictionAdjustedByPayer (Section E).</summary>
public sealed record AdjustedByPayerSpRow(
    string  PayerName,
    int     LineItemCount,
    decimal PredictedAllowed,
    decimal PredictedInsurance,
    decimal ActualAllowed,
    decimal ActualInsurance,
    decimal VarianceAllowed,
    decimal VariancePaid);

/// <summary>Single row from usp_GetPredictionSummaryMetrics (Ratios + Accuracy).</summary>
public sealed record PredictionSummaryMetricsSpRow(
    int      ToPay_LineItems,   decimal ToPay_ModeAllowed,   decimal ToPay_ModeIns,
    int      Paid_LineItems,    decimal Paid_ModeAllowed,    decimal Paid_ModeIns,
    decimal  Paid_ActAllowed,   decimal Paid_ActIns,
    int      Unpaid_LineItems,  decimal Unpaid_ModeAllowed,  decimal Unpaid_ModeIns,
    int      Denied_LineItems,  decimal Denied_ModeAllowed,  decimal Denied_ModeIns,
    int      NoResp_LineItems,  decimal NoResp_ModeAllowed,  decimal NoResp_ModeIns,
    int      Adj_LineItems,     decimal Adj_ModeAllowed,     decimal Adj_ModeIns,
    decimal? PaymentRatio_Claim,       decimal? PaymentRatio_Allowed,       decimal? PaymentRatio_Insurance,
    decimal? NonPaymentRate_Claim,     decimal? NonPaymentRate_Allowed,     decimal? NonPaymentRate_Insurance,
    decimal? DeniedPct_Claim,          decimal? DeniedPct_Allowed,          decimal? DeniedPct_Insurance,
    decimal? NoResponsePct_Claim,      decimal? NoResponsePct_Allowed,      decimal? NoResponsePct_Insurance,
    decimal? AdjustedPct_Claim,        decimal? AdjustedPct_Allowed,        decimal? AdjustedPct_Insurance,
    decimal? PredAccuracy_Claim,       decimal? PredAccuracy_AllowedAmount, decimal? PredAccuracy_InsurancePayment);

/// <summary>Filter dropdown options from usp_GetPredictionFilterOptions.</summary>
public sealed record PredictionFilterOptions(
    List<string> PayerNames,
    List<string> ForecastingPayabilities,
    List<string> PayStatuses,
    List<string> ForecastingPayabilitySubstatuses,
    List<string> PredictionStatuses,
    List<string> PayerTypes,
    List<string> PanelNames,
    List<string> FinalCoverageStatuses,
    List<string> Payabilities,
    List<string> CPTCodes);
