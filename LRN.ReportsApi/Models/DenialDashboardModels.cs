namespace LRN.ReportsApi.Models;

// Ported from LabMetricsDashboard for the Denial Dashboard data API.
// The property shapes must stay byte-for-byte compatible with the dashboard's
// LabMetricsDashboard.Models equivalents so JSON round-trips cleanly across the boundary.

public class LabOption
{
    /// <summary>Canonical LabId from LRNMaster.dbo.Labs — the id exposed to callers, links and cookies
    /// so it is consistent with the rest of the application. May differ from <see cref="InternalLabId"/>.</summary>
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
    public string ConnectionKey { get; set; } = string.Empty;
    /// <summary>The denial dashboard's own (dbo.LRNMetricsLab) id, which is what the per-lab data tables
    /// embed and are filtered by. Used internally for the [LabId] = @LabId scope only. Defaults to
    /// <see cref="LabId"/> when the lab is not remapped.</summary>
    public int InternalLabId { get; set; }
}

/// <summary>Run provenance shown in the dashboard header: the run id and the source file it came from.</summary>
public class DenialRunInfo
{
    public string RunId { get; set; } = string.Empty;
    public string SourceFileName { get; set; } = string.Empty;
    public string WeekFolder { get; set; } = string.Empty;
}

public class DenialDashboardFilters
{
    public int? LabId { get; set; }

    public string Status { get; set; } = "(All)";
    public string Priority { get; set; } = "(All)";
    public string ActionCategory { get; set; } = "(All)";
    public string Deadline { get; set; } = "(All)";
    public string Classification { get; set; } = "(All)";

    public string SalesRepname { get; set; } = string.Empty;
    public string ClinicName { get; set; } = string.Empty;
    public string ReferringProvider { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public string PayerType { get; set; } = string.Empty;
    public string PanelName { get; set; } = string.Empty;

    public DateTime? FirstBilledDateFrom { get; set; }
    public DateTime? FirstBilledDateTo { get; set; }
    public DateTime? DateOfServiceFrom { get; set; }
    public DateTime? DateOfServiceTo { get; set; }
    public DateTime? DenialDateFrom { get; set; }
    public DateTime? DenialDateTo { get; set; }

    public string ActiveTab { get; set; } = "dashboard";
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 100;
    public int InsightPage { get; set; } = 1;
    public int InsightPageSize { get; set; } = 25;
    public int LineItemPage { get; set; } = 1;
    public int LineItemPageSize { get; set; } = 100;

    /// <summary>
    /// Excel-style per-column "contains" filters keyed by DB column name. Applied
    /// server-side (whitelisted against the table's real columns) on top of the
    /// global filters above.
    /// </summary>
    public Dictionary<string, string> ColumnFilters { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public class DenialRecord
{
    public string TaskId { get; set; } = string.Empty;
    public string ClaimId { get; set; } = string.Empty;
    public string PatientId { get; set; } = string.Empty;
    public string PatientAccountNumber
    {
        get => PatientId;
        set => PatientId = value ?? string.Empty;
    }
    public string CptCode { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;
    public string DenialDescription { get; set; } = string.Empty;
    public string DenialClassification { get; set; } = string.Empty;
    public string ActionCode { get; set; } = string.Empty;
    public string RecommendedAction { get; set; } = string.Empty;
    public string ActionCategory { get; set; } = string.Empty;
    public string AssignedTo { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public int SlaDays { get; set; }
    public string Priority { get; set; } = string.Empty;
    public decimal InsuranceBalance { get; set; }
    public decimal TotalBalance { get; set; }
    public bool IsCurrentDenial { get; set; }
    public string Status { get; set; } = string.Empty;
    public DateTime DateOpened { get; set; }
    public DateTime DueDate { get; set; }
    public DateTime? DateCompleted { get; set; }
    public int? StoredDaysRemaining { get; set; }
    public string? StoredSlaStatus { get; set; }
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
    public string RunId { get; set; } = string.Empty;
    public DateTime? CreatedOn { get; set; }
    public string UniqueTrackId { get; set; } = string.Empty;

    public string SalesRepname { get; set; } = string.Empty;
    public string ClinicName { get; set; } = string.Empty;
    public string ReferringProvider { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public string PayerNameNormalized { get; set; } = string.Empty;
    public string PayerType { get; set; } = string.Empty;
    public string PanelName { get; set; } = string.Empty;
    public DateTime? FirstBilledDate { get; set; }
    public DateTime? DateOfService { get; set; }

    public string Feedback { get; set; } = string.Empty;
    public string Responsibility { get; set; } = string.Empty;
    public DateTime? DiscussionDate { get; set; }
    public string ETA { get; set; } = string.Empty;

    public string EffectiveActionCategory =>
        !string.IsNullOrWhiteSpace(ActionCategory)
            ? ActionCategory
            : string.IsNullOrWhiteSpace(RecommendedAction)
                ? "Unspecified"
                : RecommendedAction;

    public decimal EffectiveTotalBalance => TotalBalance > 0 ? TotalBalance : InsuranceBalance;

    public int? DaysRemaining =>
        Status.Equals("Completed", StringComparison.OrdinalIgnoreCase)
            ? null
            : StoredDaysRemaining ?? (DueDate.Date - DateTime.Today).Days;

    public string SlaStatus =>
        !string.IsNullOrWhiteSpace(StoredSlaStatus)
            ? StoredSlaStatus!
            : Status.Equals("Completed", StringComparison.OrdinalIgnoreCase)
                ? "Met"
                : DueDate.Date < DateTime.Today
                    ? "Overdue"
                    : DueDate.Date <= DateTime.Today.AddDays(3)
                        ? "Due Soon"
                        : "On Track";

    public string EscalationFlag =>
        Status.Equals("Completed", StringComparison.OrdinalIgnoreCase)
            ? string.Empty
            : DueDate.Date < DateTime.Today
                ? "Escalate - Overdue"
                : DueDate.Date <= DateTime.Today.AddDays(2)
                    ? "Warn - Due Soon"
                    : string.Empty;
}

public sealed class DenialInsightRecord
{
    public string DenialCodes { get; set; } = string.Empty;
    public string Descriptions { get; set; } = string.Empty;
    public int NoOfDenialCount { get; set; }
    public int NoOfClaimsCount { get; set; }
    public decimal TotalBalance { get; set; }
    public string HighImpactInsurance { get; set; } = string.Empty;
    public decimal InsuranceBalance { get; set; }
    public decimal ImpactPercentage { get; set; }
    public string ActionCategory { get; set; } = string.Empty;
    public string ActionCode { get; set; } = string.Empty;
    public string Action { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public string Feedback { get; set; } = string.Empty;
    public string Responsibility { get; set; } = string.Empty;
    public string AssignedTo { get; set; } = string.Empty;
    public string ResponsibilityReviewer
    {
        get => AssignedTo;
        set => AssignedTo = value ?? string.Empty;
    }
    public DateTime? DiscussionDate { get; set; }
    public string ETA { get; set; } = string.Empty;
    public string LabName { get; set; } = string.Empty;
    public int LabId { get; set; }
    public string RunId { get; set; } = string.Empty;
    public DateTime? CreatedOn { get; set; }

    public string ImpactPercentageDisplay => $"{ImpactPercentage:0.##}%";
}

public sealed class DenialBreakdownSourceRecord
{
    public DateTime? DenialDate { get; set; }
    public string VisitNumber { get; set; } = string.Empty;
    public decimal InsuranceBalance { get; set; }
    public decimal TotalBalance { get; set; }
    public string PayerName { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;
    public string DenialDescription { get; set; } = string.Empty;
    public string DenialCodeNormalized { get; set; } = string.Empty;
    public string PayerNameNormalized { get; set; } = string.Empty;
}

public sealed class DenialFilterAutocompleteOptions
{
    public IReadOnlyList<string> PayerNames { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> PayerTypes { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> PanelNames { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> ReferringProviders { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> ClinicNames { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> SalesRepnames { get; init; } = Array.Empty<string>();
}

public class TaskBoardCsvUpdate
{
    public string UniqueTrackId { get; set; } = string.Empty;
    public string TaskId { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string AssignedTo { get; set; } = string.Empty;
    public string RunId { get; set; } = string.Empty;
    public DateTime? DateCompleted { get; set; }
}

public class TaskBoardUploadResult
{
    public int TotalRows { get; set; }
    public int UpdatedRows { get; set; }
    public int SkippedRows { get; set; }
    public List<string> Errors { get; set; } = new();
}

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
