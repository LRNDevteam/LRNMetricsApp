namespace LabMetricsDashboard.Models;

// ?????????????????????????????????????????????????????????????????????????????
// Aggregated result types returned by the new Prediction aggregation SPs.
// These are populated directly from SP result-sets, so in-memory LINQ
// aggregation in the controller is no longer needed for these widgets.
// ?????????????????????????????????????????????????????????????????????????????

/// <summary>
/// One row returned by usp_GetPredictionSummaryBuckets (SP 6).
/// Maps directly to a row in the Prediction vs Non-Payment Summary table.
/// </summary>
public sealed record PredictionBucketSpRow(
    string  BucketName,
    int     SortOrder,
    int     LineItemCount,
    decimal PredictedAllowed,
    decimal PredictedInsurance,
    decimal? ActualAllowed,
    decimal? ActualInsurance);

/// <summary>
/// One row returned by usp_GetPredictionValidationByPayer (SP 7).
/// </summary>
public sealed record PredictionPayerSpRow(
    string   PayerName,
    string   PayerType,
    int      TotalLineItems,
    int      PaidCount,
    int      DeniedCount,
    int      NoResponseCount,
    int      AdjustedCount,
    int      UnpaidCount,
    decimal  PredictedAllowed,
    decimal  PredictedInsurance,
    decimal  ActualAllowed,
    decimal  ActualInsurance);

/// <summary>
/// One row returned by usp_GetPredictionValidationByPanel (SP 8).
/// </summary>
public sealed record PredictionPanelSpRow(
    string   PanelName,
    int      TotalLineItems,
    int      PaidCount,
    int      DeniedCount,
    int      NoResponseCount,
    int      AdjustedCount,
    int      UnpaidCount,
    decimal  PredictedAllowed,
    decimal  PredictedInsurance,
    decimal  ActualAllowed,
    decimal  ActualInsurance);

/// <summary>
/// One row returned by usp_GetPredictionValidationByCPT (SP 9).
/// </summary>
public sealed record PredictionCptSpRow(
    string  CPTCode,
    int     LineItemCount,
    decimal BilledAmount,
    decimal PredictedAllowed,
    decimal PredictedInsurance);

/// <summary>
/// One flat row returned by usp_GetPredictionDenialBreakdown (SP 10).
/// C# pivots these into the DenialBreakdown model.
/// </summary>
public sealed record DenialBreakdownSpRow(
    string  PayerName,
    string  DenialCode,
    string  DenialDescription,
    string  ExpectedPaymentMonth,
    int     LineItemCount,
    decimal PredictedAllowed,
    decimal PredictedInsurance);

/// <summary>
/// One flat row returned by usp_GetPredictionNoResponseBreakdown (SP 11).
/// C# assembles these into the NoResponseBreakdown model.
/// </summary>
public sealed record NoResponseBreakdownSpRow(
    string  PayerName,
    string  AgeBucket,
    int     LineItemCount,
    decimal PredictedAllowed,
    decimal PredictedInsurance);

/// <summary>
/// Single-row result returned by usp_GetPredictionSummaryMetrics (SP 12).
/// Contains all Section 1 bucket raw counts/amounts, all Section 2 Ratio
/// percentages, and all Section 3 Prediction Accuracy percentages.
/// Every percentage column is nullable — NULL when the denominator is zero.
/// </summary>
public sealed record PredictionSummaryMetricsSpRow(
    // ?? Section 1: Non-Payment Summary raw values ???????????????????????????
    int     ToPay_LineItems,   decimal ToPay_ModeAllowed,   decimal ToPay_ModeIns,
    int     Paid_LineItems,    decimal Paid_ModeAllowed,    decimal Paid_ModeIns,
    decimal Paid_ActAllowed,   decimal Paid_ActIns,
    int     Unpaid_LineItems,  decimal Unpaid_ModeAllowed,  decimal Unpaid_ModeIns,
    int     Denied_LineItems,  decimal Denied_ModeAllowed,  decimal Denied_ModeIns,
    int     NoResp_LineItems,  decimal NoResp_ModeAllowed,  decimal NoResp_ModeIns,
    int     Adj_LineItems,     decimal Adj_ModeAllowed,     decimal Adj_ModeIns,

    // ?? Section 2: Ratios ????????????????????????????????????????????????????
    // Payment Ratio % = Paid / ToPay * 100
    decimal? PaymentRatio_Claim,
    decimal? PaymentRatio_Allowed,
    decimal? PaymentRatio_Insurance,

    // Non-Payment Rate % = Unpaid / ToPay * 100
    decimal? NonPaymentRate_Claim,
    decimal? NonPaymentRate_Allowed,
    decimal? NonPaymentRate_Insurance,

    // Denied % = Denied / Unpaid * 100
    decimal? DeniedPct_Claim,
    decimal? DeniedPct_Allowed,
    decimal? DeniedPct_Insurance,

    // No Response % = NoResp / Unpaid * 100
    decimal? NoResponsePct_Claim,
    decimal? NoResponsePct_Allowed,
    decimal? NoResponsePct_Insurance,

    // Adjusted % = Adj / Unpaid * 100
    decimal? AdjustedPct_Claim,
    decimal? AdjustedPct_Allowed,
    decimal? AdjustedPct_Insurance,

    // ?? Section 3: Prediction Accuracy ??????????????????????????????????????
    // Claim %            = PaidLineItems / ToPayLineItems * 100
    decimal? PredAccuracy_Claim,
    // Allowed Amount %   = Paid ActualAllowed / Paid ModeAllowed * 100
    decimal? PredAccuracy_AllowedAmount,
    // Insurance Payment % = Paid ActualInsurance / Paid ModeInsurance * 100
    decimal? PredAccuracy_InsurancePayment);
