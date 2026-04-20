namespace LabMetricsDashboard.ViewModels;

public sealed class BreakdownPivotViewModel
{
    public string HeaderTitle { get; set; } = string.Empty;
    public string SectionTitle { get; set; } = string.Empty;
    public string GrandTotalTitle { get; set; } = "Grand Total";
    public decimal CoveragePercentage { get; set; }
    public int TopPayerCount { get; set; }
    public List<BreakdownPivotColumnGroup> ColumnGroups { get; set; } = new();
    public List<BreakdownPivotPeriod> Periods { get; set; } = new();
    public List<BreakdownPivotRow> Rows { get; set; } = new();
    public List<BreakdownPivotCell> TotalsByPeriod { get; set; } = new();
    public int GrandTotalClaimCount { get; set; }
    public decimal GrandTotalBalance { get; set; }
    public bool HasData => Periods.Count > 0 && Rows.Count > 0;
}

public sealed class BreakdownPivotColumnGroup
{
    public string Label { get; set; } = string.Empty;
    public int ColumnSpan { get; set; }
}

public sealed class BreakdownPivotPeriod
{
    public string Key { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public DateTime StartDate { get; set; }
    public DateTime EndDate { get; set; }
    public int Year { get; set; }
    public int? Month { get; set; }
    public bool IsYearTotal { get; set; }
}

public sealed class BreakdownPivotRow
{
    public string IndexLabel { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public bool IsInsuranceRow { get; set; }
    public List<BreakdownPivotCell> Cells { get; set; } = new();
    public int TotalClaimCount { get; set; }
    public decimal TotalBalance { get; set; }
}

public sealed class BreakdownPivotCell
{
    public int ClaimCount { get; set; }
    public decimal DenialBalance { get; set; }
}
