namespace DenialDatabaseProcessorWorker.Services;

public static class ClaimActionMapperIndexMappingExtensions
{
    public sealed record MappedValues(
        string DenialDescription,
        string DenialClassification,
        string DenialType,
        string DenialValidity,
        string ActionCode,
        string RecommendedAction,
        string ActionCategory,
        string TaskGuidance,
        string ShortCategory,
        string Priority,
        string SlaDays,
        string NotesComments);

    /// <summary>
    /// Rules retained from existing logic:
    /// - Denial Description, Denial Classification => CODE - Value
    /// - Denial Type => same value as Denial Classification (plain distinct values)
    /// - Action/detail columns => grouped by value and prefixed with the matching denial codes
    ///   Example: CO97, OA94 - Correct and Resubmit
    /// </summary>
    public static MappedValues MapForCodes(this ClaimActionMapperIndex index, IReadOnlyList<string> codes)
    {
        if (codes == null || codes.Count == 0)
            return new("", "", "", "", "", "", "", "", "", "", "", "");

        var denialDescription = new List<string>();
        var denialClassification = new List<string>();
        var denialType = new List<string>();

        var denialValidityByValue = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var actionCodeByValue = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var recommendedByValue = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var actionCategoryByValue = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var taskByValue = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var shortCategoryByValue = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var priorityByValue = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var slaDaysByValue = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var notesByValue = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);

        foreach (var code in codes)
        {
            var rows = index.FindByCode(code);
            if (rows.Count == 0)
                continue;

            foreach (var r in rows)
            {
                AddPair(denialDescription, code, r.DenialDescription);
                AddPair(denialClassification, code, r.DenialClassification);
                AddPlain(denialType, r.DenialClassification);

                AddGrouped(denialValidityByValue, r.DenialValidity, code);
                AddGrouped(actionCodeByValue, r.ActionCode, code);
                AddGrouped(recommendedByValue, r.RecommendedAction, code);
                AddGrouped(actionCategoryByValue, r.ActionCategory, code);
                AddGrouped(taskByValue, r.Task, code);
                AddGrouped(shortCategoryByValue, r.ShortCategory, code);
                AddGrouped(priorityByValue, r.Priority, code);
                AddGrouped(slaDaysByValue, r.SlaDays, code);
                AddGrouped(notesByValue, r.NotesComments, code);
            }
        }

        return new MappedValues(
            DenialDescription: Join(denialDescription),
            DenialClassification: Join(denialClassification),
            DenialType: JoinPlain(denialType),
            DenialValidity: JoinGrouped(denialValidityByValue),
            ActionCode: JoinGrouped(actionCodeByValue),
            RecommendedAction: JoinGrouped(recommendedByValue),
            ActionCategory: JoinGrouped(actionCategoryByValue),
            TaskGuidance: JoinGrouped(taskByValue),
            ShortCategory: JoinGrouped(shortCategoryByValue),
            Priority: JoinGrouped(priorityByValue),
            SlaDays: JoinGrouped(slaDaysByValue),
            NotesComments: JoinGrouped(notesByValue)
        );

        static void AddPair(List<string> list, string code, string? value)
        {
            value = (value ?? "").Trim();
            if (string.IsNullOrWhiteSpace(value))
                return;

            var item = $"{code} - {value}";
            if (!list.Any(x => string.Equals(x, item, StringComparison.OrdinalIgnoreCase)))
                list.Add(item);
        }

        static void AddPlain(List<string> list, string? value)
        {
            value = (value ?? "").Trim();
            if (string.IsNullOrWhiteSpace(value))
                return;

            if (!list.Any(x => string.Equals(x, value, StringComparison.OrdinalIgnoreCase)))
                list.Add(value);
        }

        static void AddGrouped(Dictionary<string, List<string>> byValue, string? value, string code)
        {
            value = (value ?? "").Trim();
            if (string.IsNullOrWhiteSpace(value))
                return;

            if (!byValue.TryGetValue(value, out var codes))
            {
                codes = new List<string>();
                byValue[value] = codes;
            }

            if (!codes.Any(c => string.Equals(c, code, StringComparison.OrdinalIgnoreCase)))
                codes.Add(code);
        }

        static string Join(List<string> list) =>
            string.Join(", ", list.Where(s => !string.IsNullOrWhiteSpace(s)));

        static string JoinPlain(List<string> list) =>
            string.Join(", ", list.Where(s => !string.IsNullOrWhiteSpace(s)));

        static string JoinGrouped(Dictionary<string, List<string>> byValue)
        {
            var parts = new List<string>();
            foreach (var kv in byValue)
            {
                var value = kv.Key;
                var codes = kv.Value.Where(c => !string.IsNullOrWhiteSpace(c)).ToList();
                if (codes.Count == 0) continue;

                parts.Add($"{string.Join(", ", codes)} - {value}");
            }

            return string.Join(", ", parts);
        }
    }
}
