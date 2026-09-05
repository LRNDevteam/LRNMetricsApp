namespace LabMetricsDashboard.Models;

// =====================================================================
// Executive Summary – Drill-Down / Detail View Models
// =====================================================================

/// <summary>One claim-level row returned by the detail SP.</summary>
public sealed class ExecSummaryDetailRow
{
    public string   VisitNumber     { get; set; } = string.Empty;
    public string   PatientName     { get; set; } = string.Empty;
    public string   PayerName       { get; set; } = string.Empty;
    public string   PanelName       { get; set; } = string.Empty;
    public string   ClinicName      { get; set; } = string.Empty;
    public string   BillingProvider { get; set; } = string.Empty;
    public DateTime? DateOfService  { get; set; }
    public DateTime? FirstBilledDate{ get; set; }
    public string   BilledUnbilled  { get; set; } = string.Empty;
    public string   ClaimStatus     { get; set; } = string.Empty;
    public decimal  ChargeAmount    { get; set; }
    public decimal  InsurancePayment{ get; set; }
    public decimal  PatientPayment  { get; set; }

    // Cash-only columns (null for PMS category)
    public decimal? InsuranceAdjustments { get; set; }
    public decimal? PatientAdjustments   { get; set; }

    public decimal  InsuranceBalance{ get; set; }
    public decimal  PatientBalance  { get; set; }
}

/// <summary>View model passed to the detail full page view.</summary>
public sealed class ExecSummaryDetailViewModel
{
    public string Category    { get; set; } = string.Empty;
    public string RowCode     { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public int    Year        { get; set; }
    public int    Month       { get; set; }
    public string MonthLabel  { get; set; } = string.Empty;  // e.g. "Jan 2025" or "All"

    /// <summary>The value of the cell that was clicked on the Executive Summary grid.</summary>
    public decimal? SelectedValue { get; set; }

    /// <summary>Selected value formatted as currency (Cash/Avg categories) or a whole-number count.</summary>
    public string SelectedValueFormatted =>
        SelectedValue is not { } v ? string.Empty :
        (Category is "Cash" or "Avg") ? LabMetricsDashboard.Helpers.AccountingHtml.Text(v) : ((long)v).ToString("N0");

    /// <summary>URL to return to the Executive Summary index (with original filters).</summary>
    public string BackUrl     { get; set; } = string.Empty;

    public List<ExecSummaryDetailRow> Rows { get; set; } = [];
    public string? ErrorMessage { get; set; }
    public bool HasData => Rows.Count > 0;

    // Aggregates shown in the footer
    public decimal TotalCharge            => Rows.Sum(r => r.ChargeAmount);
    public decimal TotalInsurancePayment  => Rows.Sum(r => r.InsurancePayment);
    public decimal TotalPatientPayment    => Rows.Sum(r => r.PatientPayment);
    public decimal TotalInsuranceBalance  => Rows.Sum(r => r.InsuranceBalance);
    public decimal TotalPatientBalance    => Rows.Sum(r => r.PatientBalance);
    public decimal TotalInsuranceAdj      => Rows.Sum(r => r.InsuranceAdjustments ?? 0m);
    public decimal TotalPatientAdj        => Rows.Sum(r => r.PatientAdjustments   ?? 0m);
}
