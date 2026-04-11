namespace LabMetricsDashboard.Models;

public sealed class DenialLineItemRecord
{
	private static string StripMappedPrefix(string? value)
	{
		if (string.IsNullOrWhiteSpace(value)) return string.Empty;

		var trimmed = value.Trim();
		var colonIndex = trimmed.IndexOf(':');
		if (colonIndex <= 0 || colonIndex >= trimmed.Length - 1) return trimmed;

		var prefix = trimmed[..colonIndex].Trim();
		var suffix = trimmed[(colonIndex + 1)..].Trim();

		var looksLikeDenialCode = prefix.Any(char.IsDigit)
			&& prefix.Any(char.IsLetter)
			&& prefix.Length <= 30
			&& !suffix.Contains(':');

		return looksLikeDenialCode ? suffix : trimmed;
	}

	public string AccessionNo { get; set; } = string.Empty;
	public string VisitNumber { get; set; } = string.Empty;
	public string CptCode { get; set; } = string.Empty;
	public DateTime? PatientDob { get; set; }
	public int? PayerCode { get; set; }
	public string PayerName { get; set; } = string.Empty;
	public string PayerNameNormalized { get; set; } = string.Empty;
	public string PayerType { get; set; } = string.Empty;
	public string PayStatus { get; set; } = string.Empty;
	public string HistoricalPayment { get; set; } = string.Empty;
	public string HistoricalPaidLineItemCount { get; set; } = string.Empty;
	public string HistoricalPaymentConfidenceScore { get; set; } = string.Empty;
	public int? TotalLineItemCount { get; set; }
	public int? PaidLineItemCount { get; set; }
	public decimal? PaidLineItemCountPercent { get; set; }
	public string PayerFoundInPolicy { get; set; } = string.Empty;
	public DateTime? DateOfService { get; set; }
	public DateTime? FirstBilledDate { get; set; }
	public DateTime? DenialDate { get; set; }
	public string PanelName { get; set; } = string.Empty;
	public string LisIcd10Codes { get; set; } = string.Empty;
	public string CcwIcd10Code { get; set; } = string.Empty;
	public int? Units { get; set; }
	public string Modifier { get; set; } = string.Empty;
	public string ReferringProvider { get; set; } = string.Empty;
	public string ClinicName { get; set; } = string.Empty;
	public string SalesRepname { get; set; } = string.Empty;
	public string DenialCodeOriginal { get; set; } = string.Empty;
	public string DenialCodeNormalized { get; set; } = string.Empty;
	public string DenialDescription { get; set; } = string.Empty;
	public decimal BilledAmount { get; set; }
	public decimal AllowedAmount { get; set; }
	public decimal InsurancePayment { get; set; }
	public decimal InsuranceAdjustment { get; set; }
	public decimal PatientPaidAmount { get; set; }
	public decimal PatientAdjustment { get; set; }
	public decimal InsuranceBalance { get; set; }
	public decimal PatientBalance { get; set; }
	public decimal TotalBalance { get; set; }
	public decimal MedicareFee { get; set; }
	public string FinalClaimStatus { get; set; } = string.Empty;
	public string CoveredIcd10CodesBilled { get; set; } = string.Empty;
	public string NonCoveredIcd10CodesBilled { get; set; } = string.Empty;
	public string BilledIcdCodesNotAvailableInPayerPolicy { get; set; } = string.Empty;
	public string CoverageStatus { get; set; } = string.Empty;
	public string FinalCoverageStatus { get; set; } = string.Empty;
	public string CoveredIcd10CodesAsPerPayerPolicy { get; set; } = string.Empty;
	public string NonCoveredIcd10CodesAsPerPayerPolicy { get; set; } = string.Empty;
	public string ActionComment { get; set; } = string.Empty;
	public string Resolution { get; set; } = string.Empty;
	public string LabName { get; set; } = string.Empty;
	public string CodingValidation { get; set; } = string.Empty;
	public string CodingValidationSubStatus { get; set; } = string.Empty;
	public string IcdComplianceStatus { get; set; } = string.Empty;
	public string IcdComplianceSubstatus { get; set; } = string.Empty;
	public string IcdPrimaryIndicatorAvailable { get; set; } = string.Empty;
	public string CoveredIcdPresence { get; set; } = string.Empty;
	public string IcdValidationConfidence { get; set; } = string.Empty;
	public string FrequencyConditionMet { get; set; } = string.Empty;
	public string GenderConditionMet { get; set; } = string.Empty;
	public string Payability { get; set; } = string.Empty;
	public string ForecastingPayability { get; set; } = string.Empty;
	public string PolicyCoverageExpectation { get; set; } = string.Empty;
	public string DenialValidity { get; set; } = string.Empty;
	public string CoverageExpectationRemarks { get; set; } = string.Empty;
	public decimal? ExpectedAverageAllowedAmount { get; set; }
	public decimal? ExpectedAverageInsurancePayment { get; set; }
	public decimal? ExpectedAllowedAmountSameLab { get; set; }
	public decimal? ExpectedInsurancePaymentSameLab { get; set; }
	public decimal? ModeAllowedAmountSameLab { get; set; }
	public decimal? ModeInsurancePaidSameLab { get; set; }
	public decimal? ModeAllowedAmountPeer { get; set; }
	public decimal? ModeInsurancePaidPeer { get; set; }
	public decimal? MedianAllowedAmountSameLab { get; set; }
	public decimal? MedianInsurancePaidSameLab { get; set; }
	public decimal? MedianAllowedAmountPeer { get; set; }
	public decimal? MedianInsurancePaidPeer { get; set; }
	public decimal? ModeAllowedAmountDifference { get; set; }
	public decimal? ModeInsurancePaidDifference { get; set; }
	public decimal? MedianAllowedAmountDifference { get; set; }
	public decimal? MedianInsurancePaidDifference { get; set; }
	public decimal? DenialRate { get; set; }
	public decimal? AdjustmentRate { get; set; }
	public int? PaymentDays { get; set; }
	public DateTime? ExpectedPaymentDate { get; set; }
	public string ExpectedPaymentMonth { get; set; } = string.Empty;
	public string BillingProvider { get; set; } = string.Empty;
	public string DenialClassification { get; set; } = string.Empty;
	public string DenialType { get; set; } = string.Empty;
	public string ActionCategory { get; set; } = string.Empty;
	public string ActionCode { get; set; } = string.Empty;
	public string RecommendedAction { get; set; } = string.Empty;
	public string TaskGuidance { get; set; } = string.Empty;
	public string TaskStatus { get; set; } = string.Empty;
	public string Priority { get; set; } = string.Empty;
	public string SlaDays { get; set; } = string.Empty;
	public string PatientId { get; set; } = string.Empty;
	public DateTime? ChargeEnteredDate { get; set; }
	public string Pos { get; set; } = string.Empty;
	public string Tos { get; set; } = string.Empty;
	public DateTime? CheckDate { get; set; }
	public int? DaystoDos { get; set; }
	public string RollingDays { get; set; } = string.Empty;
	public int? DaystoBill { get; set; }
	public int? DaystoPost { get; set; }
	public string RunId { get; set; } = string.Empty;
	public DateTime? CreatedOn { get; set; }

	public string CleanDenialClassification => StripMappedPrefix(DenialClassification);
	public string CleanActionCategory => StripMappedPrefix(ActionCategory);
	public string CleanPriority => StripMappedPrefix(Priority);
}
