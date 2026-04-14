namespace LabMetricsDashboard.Models;

public sealed class ClaimRecord
{
    public string LabID { get; init; } = string.Empty;
    public string LabName { get; init; } = string.Empty;
    public string ClaimID { get; init; } = string.Empty;
    public string AccessionNumber { get; init; } = string.Empty;
    public string SourceFileID { get; init; } = string.Empty;
    public string IngestedOn { get; init; } = string.Empty;
    public string RowHash { get; init; } = string.Empty;
    public string PayerName_Raw { get; init; } = string.Empty;
    public string PayerName { get; init; } = string.Empty;
    public string Payer_Code { get; init; } = string.Empty;
    public string Payer_Common_Code { get; init; } = string.Empty;
    public string Payer_Group_Code { get; init; } = string.Empty;
    public string Global_Payer_ID { get; init; } = string.Empty;
    public string PayerType { get; init; } = string.Empty;
    public string BillingProvider { get; init; } = string.Empty;
    public string ReferringProvider { get; init; } = string.Empty;
    public string ClinicName { get; init; } = string.Empty;
    public string SalesRepName { get; init; } = string.Empty;
    public string PatientID { get; init; } = string.Empty;
    public string PatientDOB { get; init; } = string.Empty;
    public string DateOfService { get; init; } = string.Empty;
    public string ChargeEnteredDate { get; init; } = string.Empty;
    public string FirstBilledDate { get; init; } = string.Empty;
    public string PanelName { get; init; } = string.Empty;
    public string CPTCodeUnitsModifier { get; init; } = string.Empty;
    public string POS { get; init; } = string.Empty;
    public string TOS { get; init; } = string.Empty;
    public decimal ChargeAmount { get; init; }
    public decimal AllowedAmount { get; init; }
    public decimal InsurancePayment { get; init; }
    public decimal PatientPayment { get; init; }
    public decimal TotalPayments { get; init; }
    public decimal InsuranceAdjustments { get; init; }
    public decimal PatientAdjustments { get; init; }
    public decimal TotalAdjustments { get; init; }
    public decimal InsuranceBalance { get; init; }
    public decimal PatientBalance { get; init; }
    public decimal TotalBalance { get; init; }
    public string CheckDate { get; init; } = string.Empty;
    public string ClaimStatus { get; init; } = string.Empty;
    public string DenialCode { get; init; } = string.Empty;
    public string ICDCode { get; init; } = string.Empty;
    public string DaysToDOS { get; init; } = string.Empty;
    public string RollingDays { get; init; } = string.Empty;
    public string DaysToBill { get; init; } = string.Empty;
    public string DaysToPost { get; init; } = string.Empty;
    public string ICDPointer { get; init; } = string.Empty;
    public string AgingBucket { get; init; } = string.Empty;
}
