using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>What a bulk replace does to one list: values to add, values whose sort / active flag changes.</summary>
public sealed record ArWorkbenchMasterListReplacePlan(
    IReadOnlyList<ArWorkbenchMasterValidated> Adds,
    IReadOnlyList<ArWorkbenchMasterValidated> Updates,
    IReadOnlyList<string> Deactivations,
    IReadOnlyList<string> KeptReserved,
    string? Error)
{
    public bool HasChanges => Adds.Count + Updates.Count + Deactivations.Count > 0;
}

/// <summary>
/// FR-SET-01: Download Template (CSV) / Upload Template (CSV) for the Workbench Lists. The template is
/// the list as it stands (Value, Sort Order, Active); the upload replaces the list with the file. A value
/// left out of the file is deactivated, not deleted, because claims, notes and requests store the text
/// (the same reason a single value in use can only be deactivated). Values the workbench's own rules use
/// stay active, and the list must keep one active value. Free of SQL so it can be unit-tested.
/// </summary>
public static class ArWorkbenchMasterListCsv
{
    public const int MaxRows = 2000;
    public static readonly string[] Headers = ["Value", "Sort Order", "Active"];

    public static string Template(IEnumerable<ArWorkbenchMasterValue> values) =>
        ArWorkbenchCsv.Write(Headers, values.Select(v => (IReadOnlyList<string?>)[v.Value, v.SortOrder.ToString(), v.IsActive ? "Yes" : "No"]));

    /// <summary>The file's rows, validated as the single-value editor would; every problem is reported, with its row number.</summary>
    public static (List<ArWorkbenchMasterValidated> Rows, List<string> Errors) Parse(ArWorkbenchMasterType type, string text)
    {
        var rows = new List<ArWorkbenchMasterValidated>();
        var errors = new List<string>();
        var lines = ArWorkbenchCsv.Parse(text ?? string.Empty);
        if (lines.Count == 0) { errors.Add("The file is empty. Download the template, fill it in and upload it again."); return (rows, errors); }

        var header = lines[0].Select(h => h.Trim()).ToList();
        int Col(string name) => header.FindIndex(h => string.Equals(h, name, StringComparison.OrdinalIgnoreCase));
        var valueCol = Col("Value");
        var sortCol = Col("Sort Order");
        var activeCol = Col("Active");
        if (valueCol < 0) { errors.Add("The first row must be the template's headers: Value, Sort Order, Active."); return (rows, errors); }

        var seen = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (var i = 1; i < lines.Count; i++)
        {
            var line = lines[i];
            var rowNumber = i + 1;
            string Cell(int c) => c >= 0 && c < line.Count ? line[c].Trim() : string.Empty;
            if (line.All(string.IsNullOrWhiteSpace)) continue;
            if (rows.Count + errors.Count >= MaxRows) { errors.Add($"The file has more than {MaxRows:N0} rows."); break; }

            int? sort = null;
            var sortText = Cell(sortCol);
            if (sortText.Length > 0)
            {
                if (!int.TryParse(sortText, out var s)) { errors.Add($"Row {rowNumber}: Sort Order \"{sortText}\" is not a whole number."); continue; }
                sort = s;
            }
            var active = ArWorkbenchMasterRules.ParseActive(Cell(activeCol));
            if (active is null) { errors.Add($"Row {rowNumber}: Active must be Yes or No (blank = Yes)."); continue; }

            var validation = ArWorkbenchMasterRules.Validate(type, new ArWorkbenchMasterValueSaveRequest { Value = Unescape(Cell(valueCol)), SortOrder = sort, IsActive = active.Value });
            if (validation.Error is not null) { errors.Add($"Row {rowNumber}: {validation.Error}"); continue; }

            var key = ArWorkbenchMasterRules.Normalize(type, validation.Result!.Value);
            if (seen.TryGetValue(key, out var first)) { errors.Add($"Row {rowNumber}: \"{validation.Result.Value}\" is already on row {first}."); continue; }
            seen[key] = rowNumber;
            rows.Add(validation.Result);
        }
        if (rows.Count == 0 && errors.Count == 0) errors.Add("The file has no values under the headers.");
        return (rows, errors);
    }

    /// <summary>
    /// Compares the file with the list. A file value matches a list value by the duplicate key, so
    /// "Write-Off" in the file is the list's "Write Off" (kept as spelled in the list - never renamed).
    /// </summary>
    public static ArWorkbenchMasterListReplacePlan Plan(ArWorkbenchMasterType type, IReadOnlyList<ArWorkbenchMasterValidated> existing, IReadOnlyList<ArWorkbenchMasterValidated> uploaded)
    {
        var byKey = existing.GroupBy(e => ArWorkbenchMasterRules.Normalize(type, e.Value), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        var adds = new List<ArWorkbenchMasterValidated>();
        var updates = new List<ArWorkbenchMasterValidated>();
        var matched = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var nextSort = existing.Count == 0 ? 10 : existing.Max(e => e.SortOrder ?? 0) + 10;

        foreach (var u in uploaded)
        {
            var key = ArWorkbenchMasterRules.Normalize(type, u.Value);
            if (byKey.TryGetValue(key, out var current))
            {
                matched.Add(key);
                var active = u.IsActive || ArWorkbenchMasterRules.IsReserved(type, current.Value);
                var sort = u.SortOrder ?? current.SortOrder;
                if (active != current.IsActive || sort != current.SortOrder)
                    updates.Add(new ArWorkbenchMasterValidated(current.Value, sort, active));
            }
            else
            {
                adds.Add(new ArWorkbenchMasterValidated(u.Value, u.SortOrder ?? nextSort, u.IsActive));
                if (u.SortOrder is null) nextSort += 10;
            }
        }

        var deactivations = new List<string>();
        var keptReserved = new List<string>();
        foreach (var (key, e) in byKey)
        {
            if (matched.Contains(key) || !e.IsActive) continue;
            if (ArWorkbenchMasterRules.IsReserved(type, e.Value)) keptReserved.Add(e.Value);
            else deactivations.Add(e.Value);
        }

        var activeAfter = adds.Count(a => a.IsActive)
            + existing.Count(e => updates.FirstOrDefault(x => string.Equals(x.Value, e.Value, StringComparison.Ordinal)) is { } update
                ? update.IsActive
                : e.IsActive && !deactivations.Contains(e.Value));
        var error = activeAfter == 0 ? $"{type.Label} must keep at least one active value. Mark at least one row Active = Yes." : null;
        return new ArWorkbenchMasterListReplacePlan(adds, updates, deactivations, keptReserved, error);
    }

    /// <summary>The template writer puts ' before a value starting with = + - @ (CSV injection); take it off again.</summary>
    private static string Unescape(string value) =>
        value.Length > 1 && value[0] == '\'' && "=+-@".Contains(value[1]) ? value[1..] : value;
}
