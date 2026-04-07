namespace LabMetricsDashboard.Models;

/// <summary>YTD Coding Insights row — one row per Year/PanelName.</summary>
public sealed class CodingInsightRow
{
    public int    Year             { get; init; }
    public string PanelName        { get; init; } = string.Empty;
    public string BillableCptCombo { get; init; } = string.Empty;
    public int    TotalClaims      { get; init; }
    public decimal BilledChargesPerClaim { get; init; }
    public string BilledCptCombo   { get; init; } = string.Empty;
    public string MissingCpts      { get; init; } = string.Empty;
    public decimal TotalBilledChargesForMissingCpts { get; init; }
    public decimal LostRevenue     { get; init; }
    public string AdditionalCpts   { get; init; } = string.Empty;
    public decimal TotalBilledChargesForAdditionalCpts { get; init; }
    public decimal RevenueAtRisk   { get; init; }
    public decimal NetImpact       { get; init; }
}

/// <summary>YTD Summary row — one row per Year/PanelName.</summary>
public sealed class CodingSummaryRow
{
    public int     Year                             { get; init; }
    public string  PanelName                        { get; init; } = string.Empty;
    public string  BillableCptCombo                 { get; init; } = string.Empty;
    public string  BilledCptCombo                   { get; init; } = string.Empty;
    public string  MissingCpts                      { get; init; } = string.Empty;
    public string  AdditionalCpts                   { get; init; } = string.Empty;
    public int     TotalClaims                      { get; init; }
    public decimal TotalBilledCharges               { get; init; }
    public int     DistinctClaimsWithMissingCpts    { get; init; }
    public decimal TotalBilledChargesForMissingCpts { get; init; }
    public int     DistinctClaimsWithAdditionalCpts { get; init; }
    public decimal TotalBilledChargesForAdditionalCpts { get; init; }
    public decimal LostRevenue                      { get; init; }
    public decimal RevenueAtRisk                    { get; init; }
    public decimal NetImpact                        { get; init; }
}

/// <summary>WTD Coding Insights row — one row per WeekFolder/PanelName.</summary>
public sealed class CodingWtdInsightRow
{
    public string  WeekFolder      { get; init; } = string.Empty;
    public string  PanelName       { get; init; } = string.Empty;
    public string  BillableCptCombo { get; init; } = string.Empty;
    public int     TotalClaims     { get; init; }
    public decimal TotalBilledCharges { get; init; }
    public string  BilledCptCombo  { get; init; } = string.Empty;
    public string  MissingCpts     { get; init; } = string.Empty;
    public decimal BilledChargesForMissingCpts { get; init; }
    public decimal RevenueLoss     { get; init; }
    public string  AdditionalCpts  { get; init; } = string.Empty;
    public decimal BilledChargesForAdditionalCpts { get; init; }
    public decimal PotentialRecoupment { get; init; }
    public decimal NetImpact       { get; init; }
}

/// <summary>WTD Summary row — one row per WeekFolder/PanelName.</summary>
public sealed class CodingWtdSummaryRow
{
    public string  WeekFolder                        { get; init; } = string.Empty;
    public string  PanelName                         { get; init; } = string.Empty;
    public string  BillableCptCombo                  { get; init; } = string.Empty;
    public string  BilledCptCombo                    { get; init; } = string.Empty;
    public string  MissingCpts                       { get; init; } = string.Empty;
    public string  AdditionalCpts                    { get; init; } = string.Empty;
    public int     TotalClaims                       { get; init; }
    public int     DistinctClaimsWithMissingCpts     { get; init; }
    public decimal TotalBilledChargesForMissingCpts  { get; init; }
    public decimal AvgAllowedAmountForMissingCpts    { get; init; }
}

/// <summary>
/// One row from dbo.CodingFinancialSummary — one record per LabName/WeekFolder.
/// Maps exactly to the Financial Dashboard sheet captured by CaptureDataApp.
/// </summary>
public sealed class CodingFinancialSummaryRow
{
    public int     SummaryId                          { get; init; }
    public string  WeekFolder                         { get; init; } = string.Empty;
    public string  ReportDate                         { get; init; } = string.Empty;
    // Totals
    public int     TotalClaims                        { get; init; }
    public decimal TotalBilledCharges                 { get; init; }
    public decimal ExpectedBilledCharges              { get; init; }
    // Revenue Impact
    public int?    RevenueImpact_Claims               { get; init; }
    public decimal RevenueImpact_ActualBilled         { get; init; }
    public decimal RevenueImpact_PotentialLoss        { get; init; }
    public decimal RevenueImpact_ExpectedRecoup       { get; init; }
    // Revenue Loss
    public int?    RevenueLoss_Claims                 { get; init; }
    public decimal RevenueLoss_ActualBilled           { get; init; }
    public decimal RevenueLoss_PotentialLoss          { get; init; }
    // Revenue at Risk
    public int?    RevenueAtRisk_Claims               { get; init; }
    public decimal RevenueAtRisk_ActualBilled         { get; init; }
    public decimal RevenueAtRisk_PotentialRecoup      { get; init; }
    // Compliance
    public int?    Compliance_TotalClaims             { get; init; }
    public int?    Compliance_ClaimsWithIssues        { get; init; }
    public string  ComplianceRate                     { get; init; } = string.Empty;
    // Detail breakdown
    public int?    ClaimsWithMissingCPTs              { get; init; }
    public int?    ClaimsWithAdditionalCPTs           { get; init; }
    public int?    ClaimsWithBothMissingAndAdditional { get; init; }
    public int?    TotalErrorClaims                   { get; init; }
    public string  ComplianceRatePct                  { get; init; } = string.Empty;
}

/// <summary>
/// One raw row from dbo.CodingValidation — used in the Validation Detail tab.
/// Only the columns useful for display are mapped.
/// </summary>
public sealed class CodingValidationDetailRow
{
    public string WeekFolder            { get; init; } = string.Empty;
    public string AccessionNo           { get; init; } = string.Empty;
    public string PanelName             { get; init; } = string.Empty;
    public string DateofService         { get; init; } = string.Empty;
    public string ActualCPTCode         { get; init; } = string.Empty;
    public string ExpectedCPTCode       { get; init; } = string.Empty;
    public string MissingCPTCodes       { get; init; } = string.Empty;
    public string AdditionalCPTCodes    { get; init; } = string.Empty;
    public string ValidationStatus      { get; init; } = string.Empty;
    public string TotalCharge           { get; init; } = string.Empty;
    public string MissingCPT_Charges    { get; init; } = string.Empty;
    public string AdditionalCPT_Charges { get; init; } = string.Empty;
    public string Remarks               { get; init; } = string.Empty;
}

public sealed class CodingSummaryViewModel
{
    public string LabName { get; init; } = string.Empty;
    public List<string> AvailableLabs { get; init; } = [];

    /// <summary>Grouped by year descending, then PanelName — for the YTD Insights tab.</summary>
    public List<CodingInsightRow> InsightRows { get; init; } = [];

    /// <summary>Grouped by year descending, then PanelName — for the YTD Summary tab.</summary>
    public List<CodingSummaryRow> SummaryRows { get; init; } = [];

    /// <summary>Grouped by WeekFolder descending, then PanelName — for the WTD Insights tab.</summary>
    public List<CodingWtdInsightRow> WtdInsightRows { get; init; } = [];

    /// <summary>Grouped by WeekFolder descending, then PanelName — for the WTD Summary tab.</summary>
    public List<CodingWtdSummaryRow> WtdSummaryRows { get; init; } = [];

    /// <summary>One row per WeekFolder ordered desc — drives the KPI strip and Financial Dashboard pills.</summary>
    public List<CodingFinancialSummaryRow> FinancialRows { get; init; } = [];

    /// <summary>Raw CodingValidation rows for the Validation Detail tab.</summary>
    public List<CodingValidationDetailRow> DetailRows { get; init; } = [];

    /// <summary>Latest financial summary row — used to populate the KPI hero strip.</summary>
    public CodingFinancialSummaryRow? LatestFinancial => FinancialRows.Count > 0 ? FinancialRows[0] : null;

    public bool HasData => InsightRows.Count > 0 || SummaryRows.Count > 0
                        || WtdInsightRows.Count > 0 || WtdSummaryRows.Count > 0
                        || FinancialRows.Count > 0 || DetailRows.Count > 0;
    public string? ErrorMessage { get; init; }
}

