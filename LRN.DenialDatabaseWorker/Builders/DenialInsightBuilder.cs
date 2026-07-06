namespace DenialDatabaseProcessorWorker.Builders;

public sealed class DenialInsightBuilder
{
    public sealed record InsightTable(List<string> Headers, List<Dictionary<string, string>> Rows);

    public InsightTable Build(List<Dictionary<string, string>> lineRows)
    {
        if (lineRows == null || lineRows.Count == 0)
            return new InsightTable(new List<string>(), new List<Dictionary<string, string>>());

        // Only rows with valid denial codes
        var validRows = lineRows
            .Where(r => !string.IsNullOrWhiteSpace(r.GetValueOrDefault("DenialCode_Normalized")))
            .ToList();

        var groups = validRows.GroupBy(r => new
        {
            Code = r.GetValueOrDefault("DenialCode_Normalized") ?? "",
            Desc = r.GetValueOrDefault("Denial Description") ?? "",
            Type = r.GetValueOrDefault("Denial Type") ?? "",
            ActionCode = r.GetValueOrDefault("Action Code") ?? "",
            Action = r.GetValueOrDefault("Recommended Action") ?? "",
            Task = r.GetValueOrDefault("Task Guidance") ?? ""
        });

        var insightRows = new List<Dictionary<string, string>>();

        foreach (var g in groups)
        {
            var row = new Dictionary<string, string>();

            row["Denial Codes"] = g.Key.Code;
            row["Descriptions"] = g.Key.Desc;

            // # of Denial = line item count
            row["# of Denial"] = g.Count().ToString();

            // # of Claims = distinct Visit Number
            var claimCount = g
                .Select(r => r.GetValueOrDefault("Visit Number") ?? "")
                .Where(v => !string.IsNullOrWhiteSpace(v))
                .Distinct()
                .Count();
            row["# of Claims"] = claimCount.ToString();

            // Total Balance = sum of Insurance Balance
            decimal totalBalance = g.Sum(r => ParseDecimal(r, "Insurance Balance"));
            row["Total Balance ($)"] = totalBalance.ToString("0.00");

            // Highest impact payer (based on Insurance Balance)
            var highestPayer = g
                .GroupBy(r => r.GetValueOrDefault("PayerName Normalized") ?? "")
                .OrderByDescending(x => x.Sum(r => ParseDecimal(r, "Insurance Balance")))
                .First().Key;
            row["Highest $ Impact - Insurance"] = highestPayer;

            // Ins. Balance ($) = sum of Insurance Balance for highest payer only
            decimal insBalance = g
                .Where(r => (r.GetValueOrDefault("PayerName Normalized") ?? "") == highestPayer)
                .Sum(r => ParseDecimal(r, "Insurance Balance"));
            row["Ins. Balance ($)"] = insBalance.ToString("0.00");

            // % Impact
            row["$ Impact (%)"] = totalBalance == 0
                ? "0%"
                : ((insBalance / totalBalance) * 100).ToString("0.00") + "%";

            // Observation
            row["Observation"] = ExtractObservation(g);

            row["Data"] = "Link";
            row["Category"] = g.Key.Type;
            row["Action Code"] = g.Key.ActionCode;
            row["Action"] = g.Key.Action;
            row["Task"] = g.Key.Task;
            row["Feedback / Response"] = "";
            row["Responsibility"] = "";
            row["Discussion Date"] = "";
            row["ETA"] = "";

            insightRows.Add(row);
        }

        // Sort by Total Balance desc, then Ins. Balance desc
        insightRows = insightRows
            .OrderByDescending(r => decimal.TryParse(r.GetValueOrDefault("Total Balance ($)"), out var tb) ? tb : 0)
            .ThenByDescending(r => decimal.TryParse(r.GetValueOrDefault("Ins. Balance ($)"), out var ib) ? ib : 0)
            .ToList();

        var headers = insightRows.First().Keys.ToList();
        return new InsightTable(headers, insightRows);
    }

    private static decimal ParseDecimal(Dictionary<string, string> row, string key)
    {
        if (row.TryGetValue(key, out var v) && decimal.TryParse(v, out var d))
            return d;
        return 0;
    }

    private static string ExtractObservation(IEnumerable<Dictionary<string, string>> rows)
    {
        var notes = string.Join(" ", rows.Select(r => r.GetValueOrDefault("Notes / Comments") ?? ""));
        if (notes.Contains("UTI", StringComparison.OrdinalIgnoreCase)) return "UTI Panel";
        if (notes.Contains("Wound", StringComparison.OrdinalIgnoreCase)) return "Wound Panel";
        if (notes.Contains("RPP", StringComparison.OrdinalIgnoreCase)) return "RPP Panel";
        return "General";
    }
}