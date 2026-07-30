namespace LabMetricsDashboard.Models;

/// <summary>YTD Coding Insights row � one row per Year/PanelName.</summary>
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

/// <summary>YTD Summary row � one row per Year/PanelName.</summary>
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

/// <summary>WTD Coding Insights row � one row per WeekFolder/PanelName.</summary>
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

/// <summary>WTD Summary row � one row per WeekFolder/PanelName.</summary>
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
    // >>> CVTPL-1.4 CHANGE (2026-07-27): WTD Summary aligned to Output Template v1.4.
    //     REVERT: delete the five properties below.
    public int     DistinctClaimsWithAdditionalCpts     { get; init; }
    public decimal TotalBilledChargesForAdditionalCpts  { get; init; }
    public decimal LostRevenue                          { get; init; }
    public decimal RevenueAtRisk                        { get; init; }
    public decimal NetImpact                            { get; init; }
    // <<< END CVTPL-1.4 CHANGE
}

/// <summary>
/// One row from dbo.CodingFinancialSummary � one record per LabName/WeekFolder.
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
/// One raw row from dbo.CodingValidation � used in the Validation Detail tab.
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

    // >>> CVDETAIL+ (2026-07-27): extra columns requested for the Validation Detail sheet.
    //     REVERT: delete these properties (and the matching SP columns / mappings / sheet cells).
    public string VisitNumber                                 { get; init; } = string.Empty;
    public string PayerName_Raw                               { get; init; } = string.Empty;
    public string Carrier                                     { get; init; } = string.Empty;
    public string Payer_Code                                  { get; init; } = string.Empty;
    public string PayerCommonCode                             { get; init; } = string.Empty;
    public string Payer_Group_Code                            { get; init; } = string.Empty;
    public string Global_Payer_ID                             { get; init; } = string.Empty;
    public string FirstBillDate                               { get; init; } = string.Empty;
    public string AllowedAmount                               { get; init; } = string.Empty;
    public string InsurancePayment                            { get; init; } = string.Empty;
    public string ExpectedCharges                             { get; init; } = string.Empty;
    public string MissingCPT_AvgAllowedAmount                 { get; init; } = string.Empty;
    public string MissingCPT_AvgPaidAmount                    { get; init; } = string.Empty;
    public string MissingCPT_AvgPatientResponsibilityAmount   { get; init; } = string.Empty;
    public string AdditionalCPT_AvgAllowedAmount              { get; init; } = string.Empty;
    public string AdditionalCPT_AvgPaidAmount                 { get; init; } = string.Empty;
    public string AdditionalCPT_AvgPatientResponsibilityAmount{ get; init; } = string.Empty;
    public string MissingCPT_ChargeSource                     { get; init; } = string.Empty;
    public string AdditionalCPT_ChargeSource                  { get; init; } = string.Empty;
    // <<< END CVDETAIL+
}

// >>> CVDETAIL-PAGE (2026-07-28): one server-side page of Validation Detail rows.
//     REVERT: delete this class and the paging fields on CodingSummaryViewModel.
/// <summary>A page of Validation Detail rows plus the filtered total and drop-down options.</summary>
public sealed class CodingValidationDetailPage
{
    public List<CodingValidationDetailRow> Rows      { get; init; } = [];
    public int           TotalRows                   { get; init; }
    public List<string>  Panels                      { get; init; } = [];
    public List<string>  Statuses                    { get; init; } = [];
}
// <<< END CVDETAIL-PAGE

// >>> CVUI-SRC CHANGE (2026-07-27): source-data provenance for the Coding Summary header.
//     REVERT: delete this CodingSourceFileRow class.
/// <summary>One row from dbo.CodingValidationFileLog — the source file that fed CodingValidation.</summary>
public sealed class CodingSourceFileRow
{
    public string    RunId               { get; init; } = string.Empty;
    public string    WeekFolder          { get; init; } = string.Empty;
    public string    LabName             { get; init; } = string.Empty;
    public string    FileName            { get; init; } = string.Empty;
    public DateTime? FileCreatedDateTime { get; init; }
    public DateTime  InsertedDateTime    { get; init; }
}
// <<< END CVUI-SRC CHANGE

/// <summary>Drill-down payload for the View Calculation modal.</summary>
public sealed class CodingCalculationDetail
{
    public string LabName { get; init; } = string.Empty;
    public string Scope { get; init; } = string.Empty; // ytd | wtd | financial
    public int? Year { get; init; }
    public string? WeekFolder { get; init; }
    public string? PanelName { get; init; }
    public string? MissingCptsFilter { get; init; }
    public string? AdditionalCptsFilter { get; init; }

    public int TotalClaims { get; init; }
    public int ClaimsWithMissingCpts { get; init; }
    public int ClaimsWithAdditionalCpts { get; init; }
    public decimal MissingChargesTotal { get; init; }
    public decimal AdditionalChargesTotal { get; init; }
    public decimal LostRevenue { get; init; }
    public decimal RevenueAtRisk { get; init; }
    // >>> CVTPL-1.4 CHANGE (2026-07-27): Net Impact = Revenue at Risk - Lost Revenue per template v1.4.
    //     REVERT: restore -> NetImpact => LostRevenue - RevenueAtRisk;
    public decimal NetImpact => RevenueAtRisk - LostRevenue;
    // <<< END CVTPL-1.4 CHANGE

    public List<CodingCalcCptGroup> CptGroups { get; init; } = [];
    public List<CodingCalcClaimSample> ClaimSamples { get; init; } = [];
}

/// <summary>One CPT-combination rollup contributing to Lost / At Risk.</summary>
public sealed class CodingCalcCptGroup
{
    public string MissingCpts { get; init; } = string.Empty;
    public string AdditionalCpts { get; init; } = string.Empty;
    public int ClaimCount { get; init; }
    public decimal MissingCharges { get; init; }
    public decimal MissingAvgPaid { get; init; }
    public decimal AdditionalCharges { get; init; }
    public decimal AdditionalAvgPaid { get; init; }
}

/// <summary>Sample claim line showing the exact AvgPaid values used.</summary>
public sealed class CodingCalcClaimSample
{
    public string AccessionNo { get; init; } = string.Empty;
    public string DateofService { get; init; } = string.Empty;
    public string WeekFolder { get; init; } = string.Empty;
    public string PanelName { get; init; } = string.Empty;
    public string PayerCommonCode { get; init; } = string.Empty;
    public string MissingCpts { get; init; } = string.Empty;
    public string AdditionalCpts { get; init; } = string.Empty;
    public decimal MissingCharges { get; init; }
    public decimal MissingAvgPaid { get; init; }
    public decimal AdditionalCharges { get; init; }
    public decimal AdditionalAvgPaid { get; init; }
}

public sealed class CodingSummaryViewModel
{
    public string LabName { get; init; } = string.Empty;
    public List<string> AvailableLabs { get; init; } = [];

    /// <summary>Grouped by year descending, then PanelName � for the YTD Insights tab.</summary>
    public List<CodingInsightRow> InsightRows { get; init; } = [];

    /// <summary>Grouped by year descending, then PanelName � for the YTD Summary tab.</summary>
    public List<CodingSummaryRow> SummaryRows { get; init; } = [];

    /// <summary>Grouped by WeekFolder descending, then PanelName � for the WTD Insights tab.</summary>
    public List<CodingWtdInsightRow> WtdInsightRows { get; init; } = [];

    /// <summary>Grouped by WeekFolder descending, then PanelName � for the WTD Summary tab.</summary>
    public List<CodingWtdSummaryRow> WtdSummaryRows { get; init; } = [];

    /// <summary>One row per WeekFolder ordered desc � drives the KPI strip and Financial Dashboard pills.</summary>
    public List<CodingFinancialSummaryRow> FinancialRows { get; init; } = [];

    /// <summary>Raw CodingValidation rows for the Validation Detail tab.</summary>
    public List<CodingValidationDetailRow> DetailRows { get; init; } = [];

    // >>> CVDETAIL-PAGE (2026-07-28): server-side paging state for the Validation Detail tab.
    //     REVERT: delete these properties.
    public int          DetailPage       { get; init; } = 1;
    public int          DetailPageSize   { get; init; } = 50;
    public int          DetailTotalRows  { get; init; }
    public List<string> DetailPanels     { get; init; } = [];
    public List<string> DetailStatuses   { get; init; } = [];
    public string?      DetailPanelFilter  { get; init; }
    public string?      DetailStatusFilter { get; init; }
    public string?      DetailSearch       { get; init; }
    public int          DetailTotalPages =>
        DetailPageSize <= 0 ? 1 : Math.Max(1, (int)Math.Ceiling(DetailTotalRows / (double)DetailPageSize));
    // <<< END CVDETAIL-PAGE

    // >>> CVUI-SRC CHANGE (2026-07-27): source files (dbo.CodingValidationFileLog) feeding this data.
    //     REVERT: delete SourceFiles + LatestSource.
    /// <summary>Source files that populated CodingValidation, newest first.</summary>
    public List<CodingSourceFileRow> SourceFiles { get; init; } = [];
    /// <summary>Most recently inserted source file — drives the header provenance line.</summary>
    public CodingSourceFileRow? LatestSource => SourceFiles.Count > 0 ? SourceFiles[0] : null;
    // <<< END CVUI-SRC CHANGE

    /// <summary>Latest financial summary row � used to populate the KPI hero strip.</summary>
    public CodingFinancialSummaryRow? LatestFinancial => FinancialRows.Count > 0 ? FinancialRows[0] : null;

    public bool HasData => InsightRows.Count > 0 || SummaryRows.Count > 0
                        || WtdInsightRows.Count > 0 || WtdSummaryRows.Count > 0
                        || FinancialRows.Count > 0 || DetailRows.Count > 0;
    public string? ErrorMessage { get; init; }

    /// <summary>
    /// When true, Download packages Coding Summary Excel with CptAverage / PanelAverage CSVs (ZIP).
    /// Driven by lab config <c>Avgs</c> path.
    /// </summary>
    public bool PackageAverageFiles { get; init; }
}

