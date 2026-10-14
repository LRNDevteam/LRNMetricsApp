namespace LabMetricsDashboard.Models;

/// <summary>
/// View model for the Clinic vs Payment vs Billed pivot (InHealth DTR).
/// Rows: ClinicName (not blank). Columns: DateOfService Year → Month.
/// Values: COUNT(DISTINCT ClaimID), SUM(ChargeAmount), SUM(InsurancePayment).
/// Clinics are sorted by total InsurancePayment, largest first.
/// </summary>
public sealed class ClinicPaymentBilledViewModel
{
    public string SelectedLab { get; init; } = string.Empty;

    /// <summary>Ordered list of distinct DOS years present in the data.</summary>
    public List<int> Years { get; init; } = [];

    /// <summary>Ordered list of (Year, Month) column pairs present in the data.</summary>
    public List<(int Year, int Month)> Columns { get; init; } = [];

    /// <summary>Clinic rows sorted by Total.InsurancePayment descending.</summary>
    public List<ClinicPaymentBilledRow> Clinics { get; init; } = [];

    /// <summary>Grand total per (Year, Month) column. Key = "YYYY-MM".</summary>
    public Dictionary<string, ClinicPaymentBilledCell> ColumnTotals { get; init; } = new();

    /// <summary>Grand total per year.</summary>
    public Dictionary<int, ClinicPaymentBilledCell> YearTotals { get; init; } = new();

    public ClinicPaymentBilledCell GrandTotal { get; init; } = new();

    public string? ErrorMessage { get; init; }

    public static string ColKey(int year, int month) => $"{year}-{month:D2}";
}

/// <summary>One clinic row in the Clinic vs Payment vs Billed pivot.</summary>
public sealed class ClinicPaymentBilledRow
{
    public string ClinicName { get; init; } = string.Empty;

    /// <summary>Values per (Year, Month). Key = "YYYY-MM".</summary>
    public Dictionary<string, ClinicPaymentBilledCell> Months { get; init; } = new();

    public Dictionary<int, ClinicPaymentBilledCell> Years { get; init; } = new();

    public ClinicPaymentBilledCell Total { get; init; } = new();
}

/// <summary>Count of claims, billed charges and insurance payment for one pivot cell.</summary>
public sealed class ClinicPaymentBilledCell
{
    public int ClaimCount { get; set; }
    public decimal ChargeAmount { get; set; }
    public decimal InsurancePayment { get; set; }

    public void Add(ClinicPaymentBilledCell other)
    {
        ClaimCount += other.ClaimCount;
        ChargeAmount += other.ChargeAmount;
        InsurancePayment += other.InsurancePayment;
    }
}
