using System.Globalization;

public sealed class BreakdownBuilder
{
	private const string InsuranceField = "Payer Name";
	private const string DenialCodeField = "DenialCode";
	private const string DenialDescriptionField = "DenialDescription";
	private const string DenialDateField = "Denial Date";
	private const string BalanceField = "Insurance Balance";

	public BreakdownPivotViewModel BuildWeekly(List<Dictionary<string, string>> rows)
	{
		var dates = GetDenialDates(rows);
		if (!dates.Any())
			return BuildEmptyModel("Last 4 Weeks | Denials | Covering 80% of the AR | Denial Posted Date", "Weekly");

		var periods = BuildLast4Weeks(dates);
		return BuildPivot(rows, periods,
			"Last 4 Weeks | Denials | Covering 80% of the AR | Denial Posted Date",
			"Denial Posted Date");
	}

	public BreakdownPivotViewModel BuildMonthly(List<Dictionary<string, string>> rows)
	{
		var dates = GetDenialDates(rows);
		if (!dates.Any())
			return BuildEmptyModel("Last 4 Months | Denials | Covering 80% of the AR | Denial Posted Date", "Monthly");

		var periods = BuildLast4Months(dates);
		return BuildPivot(rows, periods,
			"Last 4 Months | Denials | Covering 80% of the AR | Denial Posted Date",
			"Denial Posted Date");
	}

	private BreakdownPivotViewModel BuildEmptyModel(string headerTitle, string sectionTitle)
	{
		return new BreakdownPivotViewModel
		{
			HeaderTitle = headerTitle,
			SectionTitle = sectionTitle,
			Periods = new List<BreakdownPeriod>(),
			Rows = new List<BreakdownPivotRow>(),
			TotalsByPeriod = new List<BreakdownPivotCell>(),
			GrandTotalBalance = 0,
			GrandTotalClaimCount = 0
		};
	}

	private List<DateTime> GetDenialDates(List<Dictionary<string, string>> rows)
	{
		return rows
			.Select(r => TryParseDate(Get(r, DenialDateField)))
			.Where(d => d.HasValue)
			.Select(d => d!.Value.Date)
			.OrderBy(d => d)
			.ToList();
	}

	private BreakdownPivotViewModel BuildPivot(
		List<Dictionary<string, string>> rows,
		List<BreakdownPeriod> periods,
		string headerTitle,
		string sectionTitle)
	{
		var model = new BreakdownPivotViewModel
		{
			HeaderTitle = headerTitle,
			SectionTitle = sectionTitle,
			Periods = periods
		};

		if (!periods.Any())
			return model;

		// Group by insurance
		var insuranceGroups = rows
			.GroupBy(r => Get(r, InsuranceField).Trim())
			.Select(g => new
			{
				Insurance = string.IsNullOrWhiteSpace(g.Key) ? "(Blank)" : g.Key,
				Rows = g.ToList(),
				TotalBalance = g.Sum(r => GetDecimal(r, BalanceField)),
				TotalClaims = g.Count()
			})
			.OrderByDescending(x => x.TotalBalance)
			.ThenByDescending(x => x.TotalClaims)
			.Take(10) // Top 10 insurances
			.ToList();

		var allPeriodTotals = periods
			.Select(p => new BreakdownPivotCell())
			.ToList();

		foreach (var insurance in insuranceGroups)
		{
			// Insurance row
			var insuranceRow = new BreakdownPivotRow
			{
				IsInsuranceRow = true,
				Label = insurance.Insurance,
				Cells = BuildCells(insurance.Rows, periods)
			};
			insuranceRow.TotalClaimCount = insuranceRow.Cells.Sum(c => c.ClaimCount);
			insuranceRow.TotalBalance = insuranceRow.Cells.Sum(c => c.DenialBalance);
			model.Rows.Add(insuranceRow);

			// Denial rows under this insurance
			var denialGroups = insurance.Rows
				.GroupBy(r => new
				{
					Code = Get(r, DenialCodeField).Trim(),
					Desc = CleanDenialDescription(Get(r, DenialDescriptionField))
				})
				.Select(g => new
				{
					Key = $"{(string.IsNullOrWhiteSpace(g.Key.Code) ? "(Blank)" : g.Key.Code)} - {g.Key.Desc}",
					Rows = g.ToList(),
					TotalBalance = g.Sum(r => GetDecimal(r, BalanceField)),
					TotalClaims = g.Count()
				})
				.OrderByDescending(x => x.TotalBalance)
				.ThenByDescending(x => x.TotalClaims)
				.ToList();

			foreach (var denial in denialGroups)
			{
				var denialRow = new BreakdownPivotRow
				{
					IsInsuranceRow = false,
					Label = denial.Key,
					Cells = BuildCells(denial.Rows, periods)
				};
				denialRow.TotalClaimCount = denialRow.Cells.Sum(c => c.ClaimCount);
				denialRow.TotalBalance = denialRow.Cells.Sum(c => c.DenialBalance);
				model.Rows.Add(denialRow);
			}

			// Add to grand period totals
			for (int i = 0; i < periods.Count; i++)
			{
				allPeriodTotals[i].ClaimCount += insuranceRow.Cells[i].ClaimCount;
				allPeriodTotals[i].DenialBalance += insuranceRow.Cells[i].DenialBalance;
			}
		}

		model.TotalsByPeriod = allPeriodTotals;
		model.GrandTotalClaimCount = allPeriodTotals.Sum(c => c.ClaimCount);
		model.GrandTotalBalance = allPeriodTotals.Sum(c => c.DenialBalance);

		return model;
	}

	private List<BreakdownPivotCell> BuildCells(
		List<Dictionary<string, string>> rows,
		List<BreakdownPeriod> periods)
	{
		var cells = new List<BreakdownPivotCell>();

		foreach (var period in periods)
		{
			var filtered = rows.Where(r =>
			{
				var d = TryParseDate(Get(r, DenialDateField));
				if (!d.HasValue) return false;
				var dt = d.Value.Date;
				return dt >= period.Start.Date && dt <= period.End.Date;
			});

			var cell = new BreakdownPivotCell
			{
				ClaimCount = filtered.Count(),
				DenialBalance = filtered.Sum(r => GetDecimal(r, BalanceField))
			};

			cells.Add(cell);
		}

		return cells;
	}

	private List<BreakdownPeriod> BuildLast4Weeks(List<DateTime> dates)
	{
		var max = dates.Max();
		var endOfLastWeek = max.Date;
		var periods = new List<BreakdownPeriod>();

		for (int i = 3; i >= 0; i--)
		{
			var end = endOfLastWeek.AddDays(-7 * i);
			var start = end.AddDays(-6);
			periods.Add(new BreakdownPeriod
			{
				Start = start,
				End = end,
				Label = $"{start:MMM dd} - {end:MMM dd}"
			});
		}

		return periods;
	}

	private List<BreakdownPeriod> BuildLast4Months(List<DateTime> dates)
	{
		var max = dates.Max();
		var lastMonth = new DateTime(max.Year, max.Month, 1);
		var periods = new List<BreakdownPeriod>();

		for (int i = 3; i >= 0; i--)
		{
			var monthStart = lastMonth.AddMonths(-i);
			var monthEnd = monthStart.AddMonths(1).AddDays(-1);
			periods.Add(new BreakdownPeriod
			{
				Start = monthStart,
				End = monthEnd,
				Label = monthStart.ToString("MMM yyyy", CultureInfo.InvariantCulture)
			});
		}

		return periods;
	}

	private static string Get(Dictionary<string, string> row, string key)
		=> row.TryGetValue(key, out var v) ? v ?? "" : "";

	private static DateTime? TryParseDate(string value)
	{
		if (string.IsNullOrWhiteSpace(value)) return null;
		if (DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var d))
			return d;
		if (DateTime.TryParse(value, CultureInfo.CurrentCulture, DateTimeStyles.AllowWhiteSpaces, out d))
			return d;
		return null;
	}

	private static decimal GetDecimal(Dictionary<string, string> row, string key)
	{
		var raw = Get(row, key);
		if (decimal.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out var d))
			return d;
		if (decimal.TryParse(raw, NumberStyles.Any, CultureInfo.CurrentCulture, out d))
			return d;
		return 0m;
	}

	private static string CleanDenialDescription(string raw)
	{
		if (string.IsNullOrWhiteSpace(raw)) return "(Blank)";

		// Remove leading "CODE - " if present
		var idx = raw.IndexOf(" - ", StringComparison.Ordinal);
		if (idx > 0 && idx + 3 < raw.Length)
			return raw[(idx + 3)..].Trim();

		return raw.Trim();
	}
}