using System.Collections;
using System.Reflection;
using System.Text.RegularExpressions;

namespace LabMetricsDashboard.Services.ReportSnapshots;

/// <summary>
/// Compares two weeks of the same report (Report Snapshots &gt; Compare) from their snapshot view models.
/// Works on any of the report view models without a per-report list, so a column a report gains later is
/// compared too:
/// <list type="bullet">
///   <item><b>Totals</b>: the model's own numeric properties (GrandTotalClaims, TotalClaims, ...), and those of
///         a nested object one level down.</item>
///   <item><b>Sections</b>: each list of rows (PanelRows, PayerBreakdownRows, ...) and each keyed map of rows
///         (GrandTotalByMonth). A row's label is its name-like text column; its measures are its numeric
///         columns. Rows are matched between the weeks by label; a row only one week has is null in the other.</item>
/// </list>
/// Filter state (Filter*, Selected*, Available*) is left out, as in the snapshot sections.
/// </summary>
public static class ReportSnapshotComparer
{
    private const int MaxRows = 500;
    private const int MaxMeasures = 12;
    private const int MaxTotals = 16;

    public static ReportSnapshotComparison Compare(object a, object b)
    {
        if (a.GetType() != b.GetType())
            throw new ArgumentException($"Cannot compare {a.GetType().Name} with {b.GetType().Name}.");

        var result = new ReportSnapshotComparison();
        CollectTotals(a, b, a.GetType(), "", result.Totals, depth: 0);
        CollectSections(a, b, a.GetType(), "", result.Sections, depth: 0);
        if (result.Totals.Count > MaxTotals) result.Totals.RemoveRange(MaxTotals, result.Totals.Count - MaxTotals);
        result.Totals.RemoveAll(t => (t.A ?? 0) == 0 && (t.B ?? 0) == 0);
        result.Sections.RemoveAll(s => s.Rows.Count == 0);
        return result;
    }

    // ── totals ────────────────────────────────────────────────────────────────

    private static void CollectTotals(object? a, object? b, Type type, string prefix, List<ComparisonTotal> totals, int depth)
    {
        foreach (var p in Readable(type))
        {
            var t = Nullable.GetUnderlyingType(p.PropertyType) ?? p.PropertyType;
            if (IsMeasure(p))
            {
                totals.Add(new ComparisonTotal
                {
                    Key = prefix + p.Name,
                    Label = (prefix.Length > 0 ? Humanize(prefix.TrimEnd('.')) + " · " : "") + Humanize(p.Name),
                    Format = FormatFor(p.Name, t),
                    A = Number(Get(p, a)),
                    B = Number(Get(p, b))
                });
            }
            else if (depth == 0 && IsRowObject(t) && !IsEnumerable(t))
                CollectTotals(Get(p, a), Get(p, b), t, prefix + p.Name + ".", totals, depth + 1);
        }
    }

    // ── sections ──────────────────────────────────────────────────────────────

    private static void CollectSections(object? a, object? b, Type type, string prefix, List<ComparisonSection> sections, int depth)
    {
        foreach (var p in Readable(type))
        {
            var t = p.PropertyType;
            var key = prefix + p.Name;
            var title = (prefix.Length > 0 ? Humanize(prefix.TrimEnd('.')) + " · " : "") + SectionTitle(p.Name);

            if (DictionaryTypes(t) is { } dict && (IsNumeric(Nullable.GetUnderlyingType(dict.Value) ?? dict.Value) || IsRowObject(dict.Value)))
            {
                var section = MapSection(key, title, dict.Value, Get(p, a) as IDictionary, Get(p, b) as IDictionary);
                if (section is not null) sections.Add(section);
            }
            else if (ElementType(t) is { } element && IsRowObject(element))
            {
                var section = ListSection(key, title, element, (IEnumerable?)Get(p, a), (IEnumerable?)Get(p, b));
                if (section is not null) sections.Add(section);
            }
            else if (depth == 0 && IsRowObject(t) && !IsEnumerable(t))
                CollectSections(Get(p, a), Get(p, b), t, key + ".", sections, depth + 1);
        }
    }

    private static ComparisonSection? ListSection(string key, string title, Type element, IEnumerable? a, IEnumerable? b)
    {
        var measures = Measures(element);
        var label = LabelProperty(element);
        if (measures.Count == 0 || label is null) return null;

        var section = new ComparisonSection
        {
            Key = key, Title = title, LabelName = Humanize(label.Name),
            Measures = measures.Select(m => new ComparisonMeasure { Key = m.Name, Label = Humanize(m.Name), Format = FormatFor(m.Name, Nullable.GetUnderlyingType(m.PropertyType) ?? m.PropertyType) }).ToList()
        };
        Match(section, Keyed(a, label), Keyed(b, label), measures);
        return section;
    }

    private static ComparisonSection? MapSection(string key, string title, Type valueType, IDictionary? a, IDictionary? b)
    {
        var scalar = IsNumeric(Nullable.GetUnderlyingType(valueType) ?? valueType);
        var measures = scalar ? [] : Measures(valueType);
        if (!scalar && measures.Count == 0) return null;

        var section = new ComparisonSection
        {
            Key = key, Title = title, LabelName = "Key",
            Measures = scalar
                ? [new ComparisonMeasure { Key = "Value", Label = "Value", Format = FormatFor(key, Nullable.GetUnderlyingType(valueType) ?? valueType) }]
                : measures.Select(m => new ComparisonMeasure { Key = m.Name, Label = Humanize(m.Name), Format = FormatFor(m.Name, Nullable.GetUnderlyingType(m.PropertyType) ?? m.PropertyType) }).ToList()
        };

        static List<(string, object?)> Entries(IDictionary? d) =>
            d is null ? [] : d.Keys.Cast<object>().Select(k => (KeyText(k), d[k])).ToList();

        if (scalar)
        {
            var bMap = Unique(Entries(b));
            var aMap = Unique(Entries(a));
            foreach (var label in Order(aMap, bMap))
                section.Rows.Add(new ComparisonRow
                {
                    Label = label,
                    A = aMap.TryGetValue(label, out var av) ? [Number(av)] : null,
                    B = bMap.TryGetValue(label, out var bv) ? [Number(bv)] : null
                });
        }
        else
            Match(section, Unique(Entries(a)), Unique(Entries(b)), measures);
        return section;
    }

    private static void Match(ComparisonSection section, Dictionary<string, object?> a, Dictionary<string, object?> b, List<PropertyInfo> measures)
    {
        decimal?[]? Values(Dictionary<string, object?> map, string label) =>
            map.TryGetValue(label, out var row) && row is not null ? measures.Select(m => Number(Get(m, row))).ToArray() : null;

        foreach (var label in Order(a, b).Take(MaxRows))
            section.Rows.Add(new ComparisonRow { Label = label, A = Values(a, label), B = Values(b, label) });
    }

    /// <summary>Week B's order (the later week, usually), then the rows only week A has.</summary>
    private static IEnumerable<string> Order(Dictionary<string, object?> a, Dictionary<string, object?> b) =>
        b.Keys.Concat(a.Keys.Where(k => !b.ContainsKey(k)));

    private static Dictionary<string, object?> Keyed(IEnumerable? rows, PropertyInfo label) =>
        Unique(rows is null ? [] : rows.Cast<object?>().Where(r => r is not null).Select(r => (Text(Get(label, r)), r)).ToList());

    /// <summary>A label repeated in one week (a blank, or a payer listed twice) keeps every row: "X (2)".</summary>
    private static Dictionary<string, object?> Unique(List<(string Label, object? Row)> rows)
    {
        var map = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        foreach (var (label, row) in rows)
        {
            var name = string.IsNullOrWhiteSpace(label) ? "(blank)" : label.Trim();
            var unique = name;
            for (var n = 2; map.ContainsKey(unique); n++) unique = $"{name} ({n})";
            map[unique] = row;
        }
        return map;
    }

    // ── reflection helpers ────────────────────────────────────────────────────

    private static readonly string[] SkippedPrefixes = ["Filter", "Selected", "Available"];

    private static IEnumerable<PropertyInfo> Readable(Type type) =>
        type.GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Where(p => p.GetMethod is { IsPublic: true } && p.GetIndexParameters().Length == 0
                        && !SkippedPrefixes.Any(s => p.Name.StartsWith(s, StringComparison.Ordinal))
                        && p.Name is not ("Error" or "ErrorMessage"));

    private static List<PropertyInfo> Measures(Type row) =>
        Readable(row).Where(IsMeasure).Take(MaxMeasures).ToList();

    /// <summary>
    /// A number the page reports, not one that places a row: a LIS Summary row's outline Level, a month's Year and
    /// Month, a sort order or an id are not compared.
    /// </summary>
    private static readonly Regex Structural = new("^(Level|Depth|Indent|Year|Month|Day|Order|SortOrder|DisplayOrder|Sequence|Rank|Index)$|Id$", RegexOptions.Compiled);

    private static bool IsMeasure(PropertyInfo p) =>
        IsNumeric(Nullable.GetUnderlyingType(p.PropertyType) ?? p.PropertyType) && !Structural.IsMatch(p.Name);

    /// <summary>
    /// The text columns a row is labelled by, best first: the words the page prints (a description or name)
    /// before the short codes beside them - a LIS Summary row is "Total Samples", not its outline code "A".
    /// </summary>
    private static readonly string[] LabelRanks =
        ["Description", "Name", "Label", "Title", "Payer", "Panel", "Provider", "Clinic", "Category", "Bucket", "Status", "Month", "Week", "Key", "Code"];

    private static PropertyInfo? LabelProperty(Type row)
    {
        var texts = Readable(row).Where(p => p.PropertyType == typeof(string) || p.PropertyType == typeof(DateTime) || p.PropertyType == typeof(DateOnly)).ToList();
        return LabelRanks
                   .Select(rank => texts.FirstOrDefault(p => p.PropertyType == typeof(string) && p.Name.Contains(rank, StringComparison.Ordinal)))
                   .FirstOrDefault(p => p is not null)
               ?? texts.FirstOrDefault(p => p.PropertyType == typeof(string))
               ?? texts.FirstOrDefault();
    }

    private static bool IsNumeric(Type t) =>
        t == typeof(int) || t == typeof(long) || t == typeof(decimal) || t == typeof(double) || t == typeof(float) || t == typeof(short);

    private static bool IsEnumerable(Type t) => t != typeof(string) && typeof(IEnumerable).IsAssignableFrom(t);

    /// <summary>A class or record with properties of its own: a row, or a nested part of the model.</summary>
    private static bool IsRowObject(Type t) =>
        !t.IsPrimitive && !t.IsEnum && t != typeof(string) && t != typeof(decimal) && t != typeof(DateTime) && t != typeof(DateOnly)
        && t != typeof(object) && !IsEnumerable(t) && (t.IsClass || (t.IsValueType && !t.IsGenericType && t.Namespace?.StartsWith("System") != true));

    private static Type? ElementType(Type t)
    {
        if (!IsEnumerable(t) || DictionaryTypes(t) is not null) return null;
        if (t.IsArray) return t.GetElementType();
        var e = (t.IsGenericType && t.GetGenericTypeDefinition() == typeof(IEnumerable<>) ? t : null)
                ?? t.GetInterfaces().FirstOrDefault(i => i.IsGenericType && i.GetGenericTypeDefinition() == typeof(IEnumerable<>));
        return e?.GetGenericArguments()[0];
    }

    private static (Type Key, Type Value)? DictionaryTypes(Type t)
    {
        if (t == typeof(string)) return null;
        var d = new[] { t }.Concat(t.GetInterfaces()).FirstOrDefault(i => i.IsGenericType
            && (i.GetGenericTypeDefinition() == typeof(IDictionary<,>) || i.GetGenericTypeDefinition() == typeof(IReadOnlyDictionary<,>)));
        if (d is null) return null;
        var args = d.GetGenericArguments();
        return (args[0], args[1]);
    }

    private static object? Get(PropertyInfo p, object? owner)
    {
        if (owner is null) return null;
        try { return p.GetValue(owner); }
        catch (TargetInvocationException) { return null; }   // a computed property over missing data
    }

    private static decimal? Number(object? v) => v switch
    {
        null => null,
        int i => i,
        long l => l,
        short s => s,
        decimal d => d,
        double d when double.IsFinite(d) => (decimal)Math.Round(d, 6),
        float f when float.IsFinite(f) => (decimal)Math.Round(f, 6),
        _ => null
    };

    private static string Text(object? v) => v switch
    {
        null => "",
        DateTime d => d.ToString("yyyy-MM-dd"),
        DateOnly d => d.ToString("yyyy-MM-dd"),
        _ => v.ToString() ?? ""
    };

    private static string KeyText(object key) => key switch
    {
        System.Runtime.CompilerServices.ITuple t => string.Join("-", Enumerable.Range(0, t.Length).Select(i => t[i])),
        _ => Text(key)
    };

    private static readonly Regex Money = new("Charge|Paid|Payment|Balance|Amount|Revenue|Allowed|Billed|Collected|Cost|Price|Reimburse|Expected|Dollar", RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex Percent = new("Pct|Percent|Rate|Ratio|Share", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    /// <summary>money | percent | count | number - how the page prints the column.</summary>
    internal static string FormatFor(string name, Type type) =>
        Percent.IsMatch(name) ? "percent"
        : Money.IsMatch(name) ? "money"
        : type == typeof(int) || type == typeof(long) || type == typeof(short) ? "count"
        : "number";

    internal static string Humanize(string name)
    {
        var spaced = Regex.Replace(name, "(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", " ");
        return spaced.Replace("Pct", "%").Replace(" By ", " by ").Trim();
    }

    private static string SectionTitle(string name)
    {
        var title = Humanize(name);
        return title.EndsWith(" Rows", StringComparison.Ordinal) && title.Length > 5 ? title[..^5] : title;
    }
}

public sealed class ReportSnapshotComparison
{
    public List<ComparisonTotal> Totals { get; } = [];
    public List<ComparisonSection> Sections { get; } = [];
}

public sealed class ComparisonTotal
{
    public string Key { get; set; } = "";
    public string Label { get; set; } = "";
    public string Format { get; set; } = "number";
    public decimal? A { get; set; }
    public decimal? B { get; set; }
}

public sealed class ComparisonSection
{
    public string Key { get; set; } = "";
    public string Title { get; set; } = "";
    public string LabelName { get; set; } = "";
    public List<ComparisonMeasure> Measures { get; set; } = [];
    public List<ComparisonRow> Rows { get; } = [];
}

public sealed class ComparisonMeasure
{
    public string Key { get; set; } = "";
    public string Label { get; set; } = "";
    public string Format { get; set; } = "number";
}

/// <summary>One row of a section: its values per measure in each week, or null when that week has no such row.</summary>
public sealed class ComparisonRow
{
    public string Label { get; set; } = "";
    public decimal?[]? A { get; set; }
    public decimal?[]? B { get; set; }
}
