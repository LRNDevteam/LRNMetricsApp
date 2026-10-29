using System.Collections;
using System.Data;
using System.Reflection;

namespace LRN.SnapshotGenerator;

/// <summary>One table of a page snapshot: a Parquet file (ReportSnapshotFile.ResultSetName = Name).</summary>
public sealed record SnapshotSection(string Name, DataTable Table);

/// <summary>
/// Turns a page's view model into flat tables, one per grid / tab, without knowing the page:
/// <list type="bullet">
///   <item>the model's scalar properties (totals, run id, labels) -> one <c>Summary</c> row;</item>
///   <item>a list of rows (PanelRows, Rows, ...) -> a section named after the property; each row's scalars
///         are columns, and a dictionary of scalars on a row (ByMonth = {"2026-01": 12, ...}) becomes one
///         column per key (<c>ByMonth.2026-01</c>), so a month pivot keeps its shape;</item>
///   <item>a row's own list of child rows -> a child section <c>Parent.Child</c> with <c>ParentRow</c>;</item>
///   <item>a dictionary (GrandTotalByMonth) -> a section with a <c>Key</c> column;</item>
///   <item>a list of scalars (Months, PayerNames) -> a section with <c>Ordinal</c> and <c>Value</c>, so the
///         page's column order survives;</item>
///   <item>a nested object -> its members, prefixed with its name.</item>
/// </list>
/// Filter state and dropdown option lists (Filter*, Selected*, Available*) are left out: a snapshot is the
/// data, not the page's controls. New properties on a view model are picked up with no change here.
/// </summary>
public static class ViewModelSections
{
    private const int MaxDepth = 4;

    private static readonly string[] SkippedPrefixes = ["Filter", "Selected", "Available"];

    public static List<SnapshotSection> Extract(object model)
    {
        var sections = new List<SnapshotSection>();
        var summary = new RowSet("Summary");
        summary.NewRow();
        Walk(model, "", summary, 0, sections, depth: 0);
        if (summary.Columns.Count > 0)
            sections.Insert(0, new SnapshotSection("Summary", summary.ToDataTable()));
        return sections;
    }

    // ── model level ───────────────────────────────────────────────────────────

    /// <summary>
    /// Members of <paramref name="obj"/>: scalars into <paramref name="row"/> (row <paramref name="rowIndex"/>),
    /// collections into their own sections.
    /// </summary>
    private static void Walk(object obj, string prefix, RowSet row, int rowIndex, List<SnapshotSection> sections, int depth)
    {
        foreach (var (name, value, type) in Members(obj))
        {
            var path = prefix.Length == 0 ? name : $"{prefix}.{name}";

            if (IsScalar(type))
            {
                row.Set(rowIndex, path, ToCell(value), type);
                continue;
            }
            if (value is null || depth >= MaxDepth) continue;

            if (value is IDictionary dict)
            {
                if (DictionaryOfScalars(dict))
                    sections.Add(new SnapshotSection(path, KeyValueTable(dict)));
                else
                    sections.Add(new SnapshotSection(path, DictionaryOfRows(dict, path, sections, depth)));
                continue;
            }
            if (value is IEnumerable list)
            {
                var items = list.Cast<object?>().ToList();
                if (ElementIsScalar(type, items))
                    sections.Add(new SnapshotSection(path, ValueListTable(items)));
                else
                    sections.Add(new SnapshotSection(path, RowsTable(items, ElementType(type), path, sections, depth)));
                continue;
            }
            // A nested object (e.g. a result record): its members, prefixed.
            Walk(value, path, row, rowIndex, sections, depth + 1);
        }
    }

    // ── a list of rows ────────────────────────────────────────────────────────

    private static DataTable RowsTable(List<object?> items, Type? elementType, string sectionName, List<SnapshotSection> sections, int depth)
    {
        var set = new RowSet(sectionName);
        var children = new Dictionary<string, RowSet>(StringComparer.Ordinal);
        set.EnsureColumn("RowNumber", typeof(int));
        // No rows this week: the section still records its columns, so "empty" is distinguishable from "missing".
        if (items.Count == 0)
            AddScalarColumns(set, elementType);

        for (int i = 0; i < items.Count; i++)
        {
            var r = set.NewRow();
            set.Set(r, "RowNumber", i + 1, typeof(int));
            if (items[i] is { } item)
                FlattenRow(item, "", set, r, sectionName, i + 1, children, sections, depth + 1);
        }

        foreach (var (name, child) in children)
            sections.Add(new SnapshotSection(name, child.ToDataTable()));
        return set.ToDataTable();
    }

    private static DataTable DictionaryOfRows(IDictionary dict, string sectionName, List<SnapshotSection> sections, int depth)
    {
        var set = new RowSet(sectionName);
        var children = new Dictionary<string, RowSet>(StringComparer.Ordinal);
        set.EnsureColumn("Key", typeof(string));
        int n = 0;
        foreach (DictionaryEntry e in dict)
        {
            var r = set.NewRow();
            set.Set(r, "Key", e.Key?.ToString(), typeof(string));
            n++;
            if (e.Value is null) continue;
            if (IsScalar(e.Value.GetType()))
                set.Set(r, "Value", ToCell(e.Value), e.Value.GetType());
            else
                FlattenRow(e.Value, "", set, r, sectionName, n, children, sections, depth + 1);
        }
        foreach (var (name, child) in children)
            sections.Add(new SnapshotSection(name, child.ToDataTable()));
        return set.ToDataTable();
    }

    /// <summary>One row object into columns of <paramref name="set"/>; its own row lists into child sections.</summary>
    private static void FlattenRow(object item, string prefix, RowSet set, int rowIndex, string sectionName, int rowNumber,
        Dictionary<string, RowSet> children, List<SnapshotSection> sections, int depth)
    {
        if (IsScalar(item.GetType()))
        {
            set.Set(rowIndex, prefix.Length == 0 ? "Value" : prefix, ToCell(item), item.GetType());
            return;
        }

        foreach (var (name, value, type) in Members(item))
        {
            var path = prefix.Length == 0 ? name : $"{prefix}.{name}";

            if (IsScalar(type))
            {
                set.Set(rowIndex, path, ToCell(value), type);
                continue;
            }
            if (value is null || depth >= MaxDepth) continue;

            if (value is IDictionary dict)
            {
                // A pivot's cells: ByMonth = {"2026-01": 12} -> column "ByMonth.2026-01";
                // a dictionary of cell objects -> "ByMonth.2026-01.Claims", "ByMonth.2026-01.Charges".
                foreach (DictionaryEntry e in dict)
                {
                    var keyPath = $"{path}.{e.Key}";
                    if (e.Value is null) { set.Set(rowIndex, keyPath, null, typeof(string)); continue; }
                    if (IsScalar(e.Value.GetType()))
                        set.Set(rowIndex, keyPath, ToCell(e.Value), e.Value.GetType());
                    else if (depth + 1 < MaxDepth)
                        FlattenRow(e.Value, keyPath, set, rowIndex, sectionName, rowNumber, children, sections, depth + 1);
                }
                continue;
            }
            if (value is IEnumerable list)
            {
                var items = list.Cast<object?>().ToList();
                if (ElementIsScalar(type, items))
                {
                    // A short list of values on a row (codes, tags): one text cell, in order.
                    set.Set(rowIndex, path, string.Join(", ", items.Select(x => ToCell(x)?.ToString())), typeof(string));
                    continue;
                }

                // Child rows (a panel's payers, a payer's CPTs): their own section, linked by ParentRow.
                var childName = $"{sectionName}.{(prefix.Length == 0 ? name : path)}";
                if (!children.TryGetValue(childName, out var child))
                {
                    children[childName] = child = new RowSet(childName);
                    child.EnsureColumn("ParentRow", typeof(int));
                    child.EnsureColumn("RowNumber", typeof(int));
                    AddScalarColumns(child, ElementType(type));
                }
                for (int i = 0; i < items.Count; i++)
                {
                    var r = child.NewRow();
                    child.Set(r, "ParentRow", rowNumber, typeof(int));
                    child.Set(r, "RowNumber", i + 1, typeof(int));
                    if (items[i] is { } c)
                        FlattenRow(c, "", child, r, childName, i + 1, children, sections, depth + 1);
                }
                continue;
            }
            FlattenRow(value, path, set, rowIndex, sectionName, rowNumber, children, sections, depth + 1);
        }
    }

    // ── scalar collections ────────────────────────────────────────────────────

    private static DataTable KeyValueTable(IDictionary dict)
    {
        var set = new RowSet("kv");
        foreach (DictionaryEntry e in dict)
        {
            var r = set.NewRow();
            set.Set(r, "Key", e.Key?.ToString(), typeof(string));
            set.Set(r, "Value", ToCell(e.Value), e.Value?.GetType() ?? typeof(string));
        }
        // An empty dictionary still documents the section.
        if (set.Columns.Count == 0) { set.EnsureColumn("Key", typeof(string)); set.EnsureColumn("Value", typeof(string)); }
        return set.ToDataTable();
    }

    private static DataTable ValueListTable(List<object?> items)
    {
        var set = new RowSet("list");
        set.EnsureColumn("Ordinal", typeof(int));
        for (int i = 0; i < items.Count; i++)
        {
            var r = set.NewRow();
            set.Set(r, "Ordinal", i + 1, typeof(int));
            set.Set(r, "Value", ToCell(items[i]), items[i]?.GetType() ?? typeof(string));
        }
        set.EnsureColumn("Value", typeof(string));
        return set.ToDataTable();
    }

    // ── reflection helpers ────────────────────────────────────────────────────

    private static IEnumerable<(string Name, object? Value, Type Type)> Members(object obj)
    {
        foreach (var p in obj.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            if (!p.CanRead || p.GetIndexParameters().Length > 0) continue;
            if (SkippedPrefixes.Any(s => p.Name.StartsWith(s, StringComparison.Ordinal))) continue;
            if (p.PropertyType == typeof(Type) || typeof(Delegate).IsAssignableFrom(p.PropertyType)) continue;

            object? value;
            try { value = p.GetValue(obj); }
            catch { continue; }   // a computed property that throws on this data: not part of the snapshot
            yield return (p.Name, value, p.PropertyType);
        }
    }

    private static bool IsScalar(Type type)
    {
        type = Nullable.GetUnderlyingType(type) ?? type;
        return type.IsPrimitive || type.IsEnum || type == typeof(string) || type == typeof(decimal)
               || type == typeof(DateTime) || type == typeof(DateOnly) || type == typeof(DateTimeOffset)
               || type == typeof(TimeOnly) || type == typeof(TimeSpan) || type == typeof(Guid);
    }

    private static Type? ElementType(Type declared) =>
        declared.IsArray
            ? declared.GetElementType()
            : declared.GetInterfaces().Append(declared)
                .FirstOrDefault(i => i.IsGenericType && i.GetGenericTypeDefinition() == typeof(IEnumerable<>))
                ?.GetGenericArguments()[0];

    /// <summary>The declared scalar members of a row type as columns (for a section with no rows).</summary>
    private static void AddScalarColumns(RowSet set, Type? rowType)
    {
        if (rowType is null || rowType == typeof(object) || IsScalar(rowType)) return;
        foreach (var p in rowType.GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            if (!p.CanRead || p.GetIndexParameters().Length > 0 || !IsScalar(p.PropertyType)) continue;
            if (SkippedPrefixes.Any(s => p.Name.StartsWith(s, StringComparison.Ordinal))) continue;
            set.EnsureColumn(p.Name, p.PropertyType);
        }
    }

    private static bool ElementIsScalar(Type declared, List<object?> items)
    {
        var element = ElementType(declared);
        if (element is not null && element != typeof(object)) return IsScalar(element);
        var first = items.FirstOrDefault(x => x is not null);
        return first is null || IsScalar(first.GetType());
    }

    private static bool DictionaryOfScalars(IDictionary dict)
    {
        var args = dict.GetType().GetInterfaces().Append(dict.GetType())
            .FirstOrDefault(i => i.IsGenericType && i.GetGenericTypeDefinition() == typeof(IDictionary<,>))
            ?.GetGenericArguments();
        if (args is not null && args[1] != typeof(object)) return IsScalar(args[1]);
        foreach (DictionaryEntry e in dict)
            if (e.Value is not null) return IsScalar(e.Value.GetType());
        return true;
    }

    /// <summary>Parquet-friendly cell values: dates as DateTime, enums and times as text.</summary>
    private static object? ToCell(object? value) => value switch
    {
        null => null,
        DateOnly d => d.ToDateTime(TimeOnly.MinValue),
        TimeOnly t => t.ToString("HH:mm:ss"),
        TimeSpan ts => ts.ToString("c"),
        Enum e => e.ToString(),
        Guid g => g.ToString(),
        _ => value
    };

    private static Type CellType(Type type)
    {
        type = Nullable.GetUnderlyingType(type) ?? type;
        if (type == typeof(DateOnly)) return typeof(DateTime);
        if (type.IsEnum || type == typeof(TimeOnly) || type == typeof(TimeSpan) || type == typeof(Guid) || type == typeof(char)) return typeof(string);
        if (type == typeof(byte) || type == typeof(sbyte) || type == typeof(short) || type == typeof(ushort)) return typeof(int);
        if (type == typeof(uint)) return typeof(long);
        if (type == typeof(ulong)) return typeof(decimal);
        return IsScalar(type) ? type : typeof(string);
    }

    /// <summary>
    /// Rows whose columns appear as they are first seen (a pivot's month keys differ per row), with one
    /// CLR type per column; a column that receives two different types falls back to text.
    /// </summary>
    private sealed class RowSet(string name)
    {
        private readonly List<Dictionary<string, object?>> _rows = [];
        public readonly List<(string Name, Type Type)> Columns = [];
        private readonly Dictionary<string, int> _index = new(StringComparer.OrdinalIgnoreCase);

        public string Name { get; } = name;

        public int NewRow()
        {
            _rows.Add(new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase));
            return _rows.Count - 1;
        }

        public void EnsureColumn(string column, Type type)
        {
            if (!_index.ContainsKey(column))
            {
                _index[column] = Columns.Count;
                Columns.Add((column, CellType(type)));
            }
        }

        public void Set(int row, string column, object? value, Type type)
        {
            var cellType = CellType(value?.GetType() ?? type);
            if (_index.TryGetValue(column, out var i))
            {
                if (value is not null && Columns[i].Type != cellType && Columns[i].Type != typeof(string))
                    Columns[i] = (Columns[i].Name, Widen(Columns[i].Type, cellType));
            }
            else
            {
                _index[column] = Columns.Count;
                Columns.Add((column, cellType));
            }
            _rows[row][column] = value;
        }

        private static Type Widen(Type a, Type b)
        {
            Type[] numeric = [typeof(int), typeof(long), typeof(float), typeof(double), typeof(decimal)];
            var ia = Array.IndexOf(numeric, a);
            var ib = Array.IndexOf(numeric, b);
            if (ia < 0 || ib < 0) return typeof(string);
            // int/long/decimal widen to decimal; anything with a float stays a double.
            if (a == typeof(double) || b == typeof(double) || a == typeof(float) || b == typeof(float)) return typeof(double);
            return numeric[Math.Max(ia, ib)];
        }

        public DataTable ToDataTable()
        {
            var table = new DataTable(Name);
            foreach (var (col, type) in Columns)
                table.Columns.Add(col, type);

            foreach (var row in _rows)
            {
                var values = new object[Columns.Count];
                for (int c = 0; c < Columns.Count; c++)
                {
                    var (col, type) = Columns[c];
                    values[c] = row.TryGetValue(col, out var v) && v is not null ? Convert(v, type) : DBNull.Value;
                }
                table.Rows.Add(values);
            }
            return table;
        }

        private static object Convert(object value, Type type)
        {
            if (value.GetType() == type) return value;
            if (type == typeof(string)) return value is IFormattable f ? f.ToString(null, System.Globalization.CultureInfo.InvariantCulture) : value.ToString() ?? "";
            return System.Convert.ChangeType(value, type, System.Globalization.CultureInfo.InvariantCulture);
        }
    }
}
