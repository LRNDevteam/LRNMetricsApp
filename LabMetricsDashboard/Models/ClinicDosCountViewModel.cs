/// <summary>
/// View model for the Clinic Count by DOS Month pivot table.
/// Rows: ClinicName. Columns: Year ? Month (Jan–Dec). Values: COUNT(DISTINCT ClaimID).
/// </summary>
public sealed class ClinicDosCountViewModel
{
    public string SelectedLab { get; init; } = string.Empty;

    /// <summary>Ordered list of distinct years present in the data.</summary>
    public List<int> Years { get; init; } = [];

    /// <summary>Ordered list of (Year, Month) column pairs present in the data.</summary>
    public List<(int Year, int Month)> Columns { get; init; } = [];

    /// <summary>Clinic rows sorted by GrandTotal descending.</summary>
    public List<ClinicDosCountRow> Clinics { get; init; } = [];

    /// <summary>Grand total per (Year, Month) column. Key = "YYYY-MM".</summary>
    public Dictionary<string, int> ColumnTotals { get; init; } = new();

    /// <summary>Grand total per year. Key = year.</summary>
    public Dictionary<int, int> YearTotals { get; init; } = new();

    public int GrandTotal { get; init; }

    public string? ErrorMessage { get; init; }

    /// <summary>Helper to build a column key.</summary>
    public static string ColKey(int year, int month) => $"{year}-{month:D2}";
}

/// <summary>One clinic row in the DOS count pivot table.</summary>
public sealed class ClinicDosCountRow
{
    public string ClinicName { get; init; } = string.Empty;

    /// <summary>Count per (Year, Month). Key = "YYYY-MM".</summary>
    public Dictionary<string, int> MonthCounts { get; init; } = new();

    /// <summary>Count per year. Key = year.</summary>
    public Dictionary<int, int> YearCounts { get; init; } = new();

    public int GrandTotal { get; init; }
}
