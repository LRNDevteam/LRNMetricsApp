using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.ViewModels;

public class ClaimGroupViewModel
{
    public string ClaimId { get; set; } = string.Empty;
    public string PatientAccountNumber { get; set; } = string.Empty;
    public int TaskCount { get; set; }
    public int OpenCount { get; set; }
    public int OverdueCount { get; set; }
    public decimal TotalInsuranceBalance { get; set; }
    public List<DenialRecord> Tasks { get; set; } = new();
}
