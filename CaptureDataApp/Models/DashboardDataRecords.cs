namespace CaptureDataApp.Models;

/// <summary>One YTD Coding Insights row (per Year / PanelName).</summary>
public sealed record YtdInsightRecord(
    int     Year,
    string  PanelName,
    string  BillableCptCombo,
    int     TotalClaims,
    decimal BilledChargesPerClaim,
    string  BilledCptCombo,
    string  MissingCpts,
    decimal TotalBilledChargesForMissingCpts,
    decimal LostRevenue,
    string  AdditionalCpts,
    decimal TotalBilledChargesForAdditionalCpts,
    decimal RevenueAtRisk,
    decimal NetImpact
);

/// <summary>One YTD Summary row (per Year / PanelName).</summary>
public sealed record YtdSummaryRecord(
    int     Year,
    string  PanelName,
    int     TotalClaims,
    decimal TotalBilledCharges,
    int     DistinctClaimsWithMissingCpts,
    decimal TotalBilledChargesForMissingCpts,
    int     DistinctClaimsWithAdditionalCpts,
    decimal TotalBilledChargesForAdditionalCpts,
    decimal LostRevenue,
    decimal RevenueAtRisk,
    decimal NetImpact
);

/// <summary>One WTD Coding Insights row (per WeekFolder / PanelName).</summary>
public sealed record WtdInsightRecord(
    string  WeekFolder,
    string  PanelName,
    string  BillableCptCombo,
    int     TotalClaims,
    decimal TotalBilledCharges,
    string  BilledCptCombo,
    string  MissingCpts,
    decimal BilledChargesForMissingCpts,
    decimal RevenueLoss,
    string  AdditionalCpts,
    decimal BilledChargesForAdditionalCpts,
    decimal PotentialRecoupment,
    decimal NetImpact
);

/// <summary>One WTD Summary row (per WeekFolder / PanelName).</summary>
public sealed record WtdSummaryRecord(
    string  WeekFolder,
    string  PanelName,
    int     TotalClaims,
    int     DistinctClaimsWithMissingCpts,
    decimal TotalBilledChargesForMissingCpts,
    decimal AvgAllowedAmountForMissingCpts
);

/// <summary>One raw validation detail row for the latest week.</summary>
public sealed record ValidationDetailRecord(
    string WeekFolder,
    string AccessionNo,
    string PanelName,
    string DateofService,
    string ActualCPTCode,
    string ExpectedCPTCode,
    string MissingCPTCodes,
    string AdditionalCPTCodes,
    string ValidationStatus,
    string TotalCharge,
    string MissingCPT_Charges,
    string AdditionalCPT_Charges,
    string Remarks
);
