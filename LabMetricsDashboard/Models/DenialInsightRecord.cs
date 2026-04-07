namespace LabMetricsDashboard.Models;

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
    public DateTime? DiscussionDate { get; set; }
    public string ETA { get; set; } = string.Empty;
    public string LabName { get; set; } = string.Empty;
    public int LabId { get; set; }
    public string RunId { get; set; } = string.Empty;
    public DateTime? CreatedOn { get; set; }

    public string ImpactPercentageDisplay => $"{ImpactPercentage:0.##}%";
}
