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
	public DateTime? DateOfService { get; set; }
	public DateTime? FirstBilledDate { get; set; }
	public string PanelName { get; set; } = string.Empty;
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
	public decimal InsuranceBalance { get; set; }
	public decimal PatientBalance { get; set; }
	public decimal TotalBalance { get; set; }
	public string FinalClaimStatus { get; set; } = string.Empty;
	public string CoverageStatus { get; set; } = string.Empty;
	public string FinalCoverageStatus { get; set; } = string.Empty;
	public string ActionComment { get; set; } = string.Empty;
	public string Resolution { get; set; } = string.Empty;
	public string LabName { get; set; } = string.Empty;
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
	public string RunId { get; set; } = string.Empty;
	public DateTime? CreatedOn { get; set; }

	public string CleanDenialClassification => StripMappedPrefix(DenialClassification);
	public string CleanActionCategory => StripMappedPrefix(ActionCategory);
	public string CleanPriority => StripMappedPrefix(Priority);
}
