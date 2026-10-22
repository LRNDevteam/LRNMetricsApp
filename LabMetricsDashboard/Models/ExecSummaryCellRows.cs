namespace LabMetricsDashboard.Models;

/// <summary>One Executive Summary cell (row + period) and the page filters it was computed under.</summary>
public sealed class ExecSummaryCellRowsRequest
{
    public required string Category { get; init; }
    public required string RowCode { get; init; }
    public int Year { get; init; }
    public int Month { get; init; }
    public int? YearFrom { get; init; }
    public int? YearTo { get; init; }
    public int? MonthFrom { get; init; }
    public int? MonthTo { get; init; }
    public DateTime? DosFrom { get; init; }
    public DateTime? DosTo { get; init; }
    public DateTime? BilledFrom { get; init; }
    public DateTime? BilledTo { get; init; }
    public string? Panels { get; init; }
    public string? Clinics { get; init; }
    public string? Providers { get; init; }
    public string? Reps { get; init; }
    public int Page { get; init; } = 1;

    /// <summary>0 = every row (Excel download).</summary>
    public int PageSize { get; init; } = 100;
}

public sealed record ExecSummaryCellRule(string Group, string Text);

/// <summary>The source rows behind one Executive Summary cell and the rules that select them.</summary>
public sealed class ExecSummaryCellRowsResult
{
    public List<ExecSummaryCellRule> Rules { get; } = [];
    public string? SourceTable { get; set; }
    public string Measure { get; set; } = string.Empty;
    public string? AmountColumn { get; set; }
    public int TotalRows { get; set; }
    public decimal TotalAmount { get; set; }
    public bool IsFormula { get; set; }
    public List<string> Columns { get; } = [];
    public List<object?[]> Rows { get; } = [];
    public int Page { get; set; }
    public int PageSize { get; set; }
}
