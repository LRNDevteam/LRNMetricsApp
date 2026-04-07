namespace LabMetricsDashboard.Models;

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
