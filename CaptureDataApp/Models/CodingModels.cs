namespace CaptureDataApp.Models;

/// <summary>One row from the CodingValidated sheet.</summary>
public sealed class CodingValidationRow
{
    public string FileLogId      { get; set; } = string.Empty;
    public string WeekFolder     { get; set; } = string.Empty;
    public string SourceFilePath { get; set; } = string.Empty;
    public string RunNumber      { get; set; } = string.Empty;

    public string AccessionNo    { get; set; } = string.Empty;
    public string VisitNumber    { get; set; } = string.Empty;
    public string PayerName_Raw  { get; set; } = string.Empty;
    public string Carrier        { get; set; } = string.Empty;
    public string Payer_Code     { get; set; } = string.Empty;
    public string PayerCommonCode { get; set; } = string.Empty;
    public string Payer_Group_Code { get; set; } = string.Empty;
    public string Global_Payer_ID  { get; set; } = string.Empty;
    public string PayerType        { get; set; } = string.Empty;
    public string BillingProvider  { get; set; } = string.Empty;
    public string ReferringProvider { get; set; } = string.Empty;
    public string ClinicName       { get; set; } = string.Empty;
    public string SalesRepname     { get; set; } = string.Empty;
    public string PatientID        { get; set; } = string.Empty;
    public string PatientDOB       { get; set; } = string.Empty;
    public string DateofService    { get; set; } = string.Empty;
    public string ChargeEnteredDate { get; set; } = string.Empty;
    public string FirstBillDate    { get; set; } = string.Empty;
    public string PanelName        { get; set; } = string.Empty;
    public string POS              { get; set; } = string.Empty;
    public string TOS              { get; set; } = string.Empty;
    public string TotalCharge      { get; set; } = string.Empty;
    public string AllowedAmount    { get; set; } = string.Empty;
    public string InsurancePayment { get; set; } = string.Empty;
    public string PatientPayment   { get; set; } = string.Empty;
    public string TotalPayments    { get; set; } = string.Empty;
    public string InsuranceAdjustments { get; set; } = string.Empty;
    public string PatientAdjustments   { get; set; } = string.Empty;
    public string TotalAdjustments     { get; set; } = string.Empty;
    public string InsuranceBalance     { get; set; } = string.Empty;
    public string PatientBalance       { get; set; } = string.Empty;
    public string TotalBalance         { get; set; } = string.Empty;
    public string CheckDate            { get; set; } = string.Empty;
    public string ClaimStatus          { get; set; } = string.Empty;
    public string DenialCode           { get; set; } = string.Empty;
    public string ICDCode              { get; set; } = string.Empty;
    public string DaystoDOS            { get; set; } = string.Empty;
    public string RollingDays          { get; set; } = string.Empty;
    public string DaystoBill           { get; set; } = string.Empty;
    public string DaystoPost           { get; set; } = string.Empty;
    public string ICDPointer           { get; set; } = string.Empty;
    public string ActualCPTCode        { get; set; } = string.Empty;
    public string ExpectedCPTCode      { get; set; } = string.Empty;
    public string MissingCPTCodes      { get; set; } = string.Empty;
    public string AdditionalCPTCodes   { get; set; } = string.Empty;
    public string MissingCPT_Charges   { get; set; } = string.Empty;
    public string MissingCPT_ChargeSource { get; set; } = string.Empty;
    public string AdditionalCPT_Charges   { get; set; } = string.Empty;
    public string AdditionalCPT_ChargeSource { get; set; } = string.Empty;
    public string ExpectedCharges         { get; set; } = string.Empty;
    public string ValidationStatus        { get; set; } = string.Empty;
    public string Remarks                 { get; set; } = string.Empty;
    public string MissingCPT_AvgAllowedAmount               { get; set; } = string.Empty;
    public string MissingCPT_AvgPaidAmount                  { get; set; } = string.Empty;
    public string MissingCPT_AvgPatientResponsibilityAmount  { get; set; } = string.Empty;
    public string AdditionalCPT_AvgAllowedAmount             { get; set; } = string.Empty;
    public string AdditionalCPT_AvgPaidAmount                { get; set; } = string.Empty;
    public string AdditionalCPT_AvgPatientResponsibilityAmount { get; set; } = string.Empty;
    public string LabID   { get; set; } = string.Empty;
    public string LabName { get; set; } = string.Empty;
}

/// <summary>Parsed summary block from the Financial Dashboard sheet.</summary>
public sealed class CodingFinancialSummary
{
    public string LabName        { get; set; } = string.Empty;
    public string WeekFolder     { get; set; } = string.Empty;
    public string SourceFilePath { get; set; } = string.Empty;
    public string ReportDate     { get; set; } = string.Empty;

    public int?     TotalClaims          { get; set; }
    public decimal? TotalBilledCharges   { get; set; }
    public decimal? ExpectedBilledCharges { get; set; }

    public int?     RevenueImpact_Claims           { get; set; }
    public decimal? RevenueImpact_ActualBilled      { get; set; }
    public decimal? RevenueImpact_PotentialLoss     { get; set; }
    public decimal? RevenueImpact_ExpectedRecoup    { get; set; }

    public int?     RevenueLoss_Claims       { get; set; }
    public decimal? RevenueLoss_ActualBilled  { get; set; }
    public decimal? RevenueLoss_PotentialLoss { get; set; }

    public int?     RevenueAtRisk_Claims          { get; set; }
    public decimal? RevenueAtRisk_ActualBilled     { get; set; }
    public decimal? RevenueAtRisk_PotentialRecoup  { get; set; }

    public int?    Compliance_TotalClaims       { get; set; }
    public int?    Compliance_ClaimsWithIssues  { get; set; }
    public string  ComplianceRate               { get; set; } = string.Empty;

    public int?   ClaimsWithMissingCPTs              { get; set; }
    public int?   ClaimsWithAdditionalCPTs            { get; set; }
    public int?   ClaimsWithBothMissingAndAdditional  { get; set; }
    public int?   TotalErrorClaims                    { get; set; }
    public string ComplianceRatePct                   { get; set; } = string.Empty;
}
