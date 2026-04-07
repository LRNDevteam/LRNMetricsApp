namespace LabMetricsDashboard.Models;

/// <summary>
/// One row from the "output" sheet of the Payer Policy Validation Report Excel file.
/// Column names match the header row of the report.
/// </summary>
public sealed class PredictionRecord
{
    public string AccessionNo { get; init; } = string.Empty;
    public string VisitNumber { get; init; } = string.Empty;
    public string CPTCode { get; init; } = string.Empty;
    public string PatientDOB { get; init; } = string.Empty;
    public string PayerCode { get; init; } = string.Empty;
    public string PayerName { get; init; } = string.Empty;
    public string PayerNameNormalized { get; init; } = string.Empty;
    public string PayStatus { get; init; } = string.Empty;
    public string HistoricalPayment { get; init; } = string.Empty;
    public string HistoricalPaidLineItemCount { get; init; } = string.Empty;
    public string HistoricalPaymentConfidenceScore { get; init; } = string.Empty;
    public int TotalLineItemCount { get; init; }
    public int PaidLineItemCount { get; init; }
    public string PctPaidLineItemCount { get; init; } = string.Empty;
    public string PayerType { get; init; } = string.Empty;
    public string PayerFoundInPolicy { get; init; } = string.Empty;
    public string DateOfService { get; init; } = string.Empty;
    public string FirstBilledDate { get; init; } = string.Empty;
    public string PanelName { get; init; } = string.Empty;
    public string LISIcd10Codes { get; init; } = string.Empty;
    public string CCWIcd10Code { get; init; } = string.Empty;
    public string Units { get; init; } = string.Empty;
    public string Modifier { get; init; } = string.Empty;
    public string DenialCode { get; init; } = string.Empty;
    public string DenialDescription { get; init; } = string.Empty;
    public decimal BilledAmount { get; init; }
    public decimal AllowedAmount { get; init; }
    public decimal InsurancePayment { get; init; }
    public decimal InsuranceAdjustment { get; init; }
    public decimal PatientPaidAmount { get; init; }
    public decimal PatientAdjustment { get; init; }
    public decimal InsuranceBalance { get; init; }
    public decimal PatientBalance { get; init; }
    public decimal TotalBalance { get; init; }
    public decimal MedicareFee { get; init; }
    public string FinalClaimStatus { get; init; } = string.Empty;
    public string CoveredIcd10CodesBilled { get; init; } = string.Empty;
    public string NonCoveredIcd10CodesBilled { get; init; } = string.Empty;
    public string BilledIcdCodesNotAvailableInPayerPolicy { get; init; } = string.Empty;
    public string CoverageStatus { get; init; } = string.Empty;
    public string FinalCoverageStatus { get; init; } = string.Empty;
    public string CoveredIcd10CodesAsPerPayerPolicy { get; init; } = string.Empty;
    public string NonCoveredIcd10CodesAsPerPayerPolicy { get; init; } = string.Empty;
    public string ActionComment { get; init; } = string.Empty;
    public string Resolution { get; init; } = string.Empty;
    public string LabName { get; init; } = string.Empty;
    public string CodingValidation { get; init; } = string.Empty;
    public string CodingValidationSubStatus { get; init; } = string.Empty;
    public string ICDComplianceStatus { get; init; } = string.Empty;
    public string ICDComplianceSubstatus { get; init; } = string.Empty;
    public string ICDPrimaryIndicatorAvailable { get; init; } = string.Empty;
    public string CoveredICDPresence { get; init; } = string.Empty;
    public string ICDValidationConfidence { get; init; } = string.Empty;
    public string FrequencyConditionMet { get; init; } = string.Empty;
    public string GenderConditionMet { get; init; } = string.Empty;
    public string Payability { get; init; } = string.Empty;
    public string ForecastingPayability { get; init; } = string.Empty;
    public string PolicyCoverageExpectation { get; init; } = string.Empty;
    public string DenialValidity { get; init; } = string.Empty;
    public string CoverageExpectationRemarks { get; init; } = string.Empty;
    public decimal ExpectedAverageAllowedAmount { get; init; }
    public decimal ExpectedAverageInsurancePayment { get; init; }
    public decimal ExpectedAllowedAmountSameLab { get; init; }
    public decimal ExpectedInsurancePaymentSameLab { get; init; }
    public decimal ModeAllowedAmountSameLab { get; init; }
    public decimal ModeInsurancePaidSameLab { get; init; }
    public decimal ModeAllowedAmountPeer { get; init; }
    public decimal ModeInsurancePaidPeer { get; init; }
    public decimal MedianAllowedAmountSameLab { get; init; }
    public decimal MedianInsurancePaidSameLab { get; init; }
    public decimal MedianAllowedAmountPeer { get; init; }
    public decimal MedianInsurancePaidPeer { get; init; }
    public decimal ModeAllowedAmountDifference { get; init; }
    public decimal ModeInsurancePaidDifference { get; init; }
    public decimal MedianAllowedAmountDifference { get; init; }
    public decimal MedianInsurancePaidDifference { get; init; }
    public string DenialRate { get; init; } = string.Empty;
    public string AdjustmentRate { get; init; } = string.Empty;
    public string PaymentDays { get; init; } = string.Empty;
    public string ExpectedPaymentDate { get; init; } = string.Empty;
    public string ExpectedPaymentMonth { get; init; } = string.Empty;
}
