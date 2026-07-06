public sealed class BreakdownPivotViewModel
{
	public string HeaderTitle { get; set; } = "";
	public string SectionTitle { get; set; } = "";

	// Weekly or Monthly periods
	public List<BreakdownPeriod> Periods { get; set; } = new();

	// Insurance rows + Denial rows
	public List<BreakdownPivotRow> Rows { get; set; } = new();

	// Totals for each period
	public List<BreakdownPivotCell> TotalsByPeriod { get; set; } = new();

	public int GrandTotalClaimCount { get; set; }
	public decimal GrandTotalBalance { get; set; }

	public bool HasData => Rows.Count > 0;
}

public sealed class BreakdownPeriod
{
	public string Label { get; set; } = "";
	public DateTime Start { get; set; }
	public DateTime End { get; set; }
}

public sealed class BreakdownPivotRow
{
	public bool IsInsuranceRow { get; set; }   // True = Insurance, False = Denial
	public string Label { get; set; } = "";    // Insurance name or Denial description
	public string IndexLabel { get; set; } = ""; // Optional numbering (not required)

	public List<BreakdownPivotCell> Cells { get; set; } = new();

	public int TotalClaimCount { get; set; }
	public decimal TotalBalance { get; set; }
}

public sealed class BreakdownPivotCell
{
	public int ClaimCount { get; set; }
	public decimal DenialBalance { get; set; }
}