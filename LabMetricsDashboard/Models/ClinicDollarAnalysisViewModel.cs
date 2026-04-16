namespace LabMetricsDashboard.Models;

/// <summary>
/// View model for the Clinic $ Analysis pivot table.
/// Rows: ClinicName with drill-down to ClaimStatus.
/// Columns: No. of Claims (COUNT DISTINCT ClaimID), Total Charge (SUM ChargeAmount), Insurance Payments (SUM InsurancePayment).
/// Sorted by Grand Total (No. of Claims) descending.
/// </summary>
public sealed class ClinicDollarAnalysisViewModel
{
    public string SelectedLab { get; init; } = string.Empty;

    /// <summary>Clinic-level rows with nested status rows, sorted by ClaimCount descending.</summary>
    public List<ClinicDollarAnalysisClinicRow> Clinics { get; init; } = [];

    /// <summary>Grand total across all clinics.</summary>
    public int GrandTotalClaims { get; init; }
    public decimal GrandTotalCharge { get; init; }
    public decimal GrandTotalInsurancePayment { get; init; }

    public string? ErrorMessage { get; init; }
}

/// <summary>One clinic row in the Clinic $ Analysis table.</summary>
public sealed class ClinicDollarAnalysisClinicRow
{
    public string ClinicName { get; init; } = string.Empty;
    public int ClaimCount { get; init; }
    public decimal TotalCharge { get; init; }
    public decimal InsurancePayment { get; init; }

    /// <summary>Status-level drill-down rows under this clinic.</summary>
    public List<ClinicDollarAnalysisStatusRow> Statuses { get; init; } = [];
}

/// <summary>One status row nested under a clinic.</summary>
public sealed class ClinicDollarAnalysisStatusRow
{
    public string ClaimStatus { get; init; } = string.Empty;
    public int ClaimCount { get; init; }
    public decimal TotalCharge { get; init; }
    public decimal InsurancePayment { get; init; }
}
