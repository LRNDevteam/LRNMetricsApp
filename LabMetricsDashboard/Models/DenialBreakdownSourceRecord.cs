namespace LabMetricsDashboard.Models;

public sealed class DenialBreakdownSourceRecord
{
    public DateTime? DenialDate { get; set; }
    public string VisitNumber { get; set; } = string.Empty;
    public decimal InsuranceBalance { get; set; }
    public decimal TotalBalance { get; set; }
    public string PayerName { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;
    public string DenialDescription { get; set; } = string.Empty;
}
