namespace LabMetricsDashboard.Models;

public class TaskBoardCsvRow
{
    public string UniqueTrackId { get; set; } = string.Empty;
    public string TaskId { get; set; } = string.Empty;
    public string ClaimId { get; set; } = string.Empty;
    public string PatientAccountNumber { get; set; } = string.Empty;
    public string CptCode { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;
    public string DenialDescription { get; set; } = string.Empty;
    public string DenialClassification { get; set; } = string.Empty;
    public string ActionCode { get; set; } = string.Empty;
    public string RecommendedAction { get; set; } = string.Empty;
    public string ActionCategory { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public string Priority { get; set; } = string.Empty;
    public decimal InsuranceBalance { get; set; }
    public string Status { get; set; } = string.Empty;
    public string AssignedTo { get; set; } = string.Empty;
    public DateTime? DateOpened { get; set; }
    public DateTime? DueDate { get; set; }
    public DateTime? DateCompleted { get; set; }
    public int SlaDays { get; set; }
    public string SlaStatus { get; set; } = string.Empty;
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
    public string RunId { get; set; } = string.Empty;
}
