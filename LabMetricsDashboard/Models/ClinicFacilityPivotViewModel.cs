namespace LabMetricsDashboard.Models;

public enum ClinicFacilityPivotKind
{
    /// <summary>Facility Production: billed claims by ChargeEnteredDate month, Sum of ChargeAmount.</summary>
    Production,

    /// <summary>Facility Collection: paid claims by PostedDate month, Clinic &gt; Panel, Sum of InsurancePayment.</summary>
    Collection,
}

/// <summary>
/// Texas Diagnostic Clinic Summary pivots (Facility Production / Facility Collection).
/// Rows: ClinicName, optionally with panel child rows. Columns: Year → Month of the date basis.
/// Values: Count of unique ClaimID and one amount (ChargeAmount or InsurancePayment).
/// Clinics and panels are sorted by claim count, largest first.
/// </summary>
public sealed class ClinicFacilityPivotViewModel
{
    public string SelectedLab { get; init; } = string.Empty;

    public string Title { get; init; } = string.Empty;

    /// <summary>Column behind the month columns, e.g. "ChargeEnteredDate".</summary>
    public string DateBasisLabel { get; init; } = string.Empty;

    /// <summary>Header for the amount measure, e.g. "Sum of ChargeAmount".</summary>
    public string AmountLabel { get; init; } = string.Empty;

    /// <summary>Filter / source note shown under the table and on the Excel sheet.</summary>
    public string Note { get; init; } = string.Empty;

    public bool HasPanelRows { get; init; }

    public List<int> Years { get; init; } = [];

    public List<(int Year, int Month)> Columns { get; init; } = [];

    public List<ClinicFacilityPivotRow> Clinics { get; init; } = [];

    /// <summary>Grand total per (Year, Month) column. Key = "YYYY-MM".</summary>
    public Dictionary<string, ClinicFacilityPivotCell> ColumnTotals { get; init; } = new();

    public Dictionary<int, ClinicFacilityPivotCell> YearTotals { get; init; } = new();

    public ClinicFacilityPivotCell GrandTotal { get; init; } = new();

    public string? ErrorMessage { get; init; }

    public static string ColKey(int year, int month) => $"{year}-{month:D2}";
}

/// <summary>One clinic (or panel under a clinic) row.</summary>
public sealed class ClinicFacilityPivotRow
{
    public string Name { get; init; } = string.Empty;

    /// <summary>Values per (Year, Month). Key = "YYYY-MM".</summary>
    public Dictionary<string, ClinicFacilityPivotCell> Months { get; init; } = new();

    public Dictionary<int, ClinicFacilityPivotCell> Years { get; init; } = new();

    public ClinicFacilityPivotCell Total { get; init; } = new();

    public List<ClinicFacilityPivotRow> Children { get; init; } = [];
}

public sealed class ClinicFacilityPivotCell
{
    public int ClaimCount { get; set; }
    public decimal Amount { get; set; }

    public void Add(ClinicFacilityPivotCell other)
    {
        ClaimCount += other.ClaimCount;
        Amount += other.Amount;
    }
}
