using System.Reflection;
using Parquet;
using Parquet.Schema;

namespace LabMetricsDashboard.Services.ReportSnapshots;

/// <summary>One page of a snapshot Parquet file, as text cells, for the snapshot data view.</summary>
public sealed class ParquetTablePage
{
    public IReadOnlyList<ParquetTableColumn> Columns { get; init; } = [];
    public IReadOnlyList<object?[]> Rows { get; init; } = [];
    public long TotalRows { get; init; }
    public int RowGroups { get; init; }
    public long Offset { get; init; }
}

/// <param name="Type">The column's .NET type name (String, Decimal, DateTime, ...).</param>
public sealed record ParquetTableColumn(string Name, string Type, bool IsNumeric);

/// <summary>
/// Reads the flat Parquet files the master file processor and LRN.SnapshotGenerator write (one column per
/// field, no nesting). Only the row groups that overlap the requested page are decoded.
/// </summary>
public static class ParquetTableReader
{
    private static readonly MethodInfo ReadStructMethod =
        typeof(ParquetTableReader).GetMethod(nameof(ReadStructAsync), BindingFlags.NonPublic | BindingFlags.Static)!;

    public static async Task<ParquetTablePage> ReadPageAsync(byte[] file, long offset, int limit, CancellationToken ct)
    {
        offset = Math.Max(0, offset);
        limit = Math.Clamp(limit, 1, 5000);

        await using var stream = new MemoryStream(file, writable: false);
        await using var reader = await ParquetReader.CreateAsync(stream, null, false, ct);

        var fields = reader.Schema.DataFields;
        var columns = fields.Select(f => new ParquetTableColumn(f.Name, TypeName(f.ClrType), IsNumeric(f.ClrType))).ToList();
        var rows = new List<object?[]>();
        long total = reader.Metadata?.NumRows ?? 0;
        long groupStart = 0;

        for (int g = 0; g < reader.RowGroupCount && rows.Count < limit; g++)
        {
            using var group = reader.OpenRowGroupReader(g);
            long groupRows = group.RowCount;
            long groupEnd = groupStart + groupRows;
            if (groupEnd <= offset) { groupStart = groupEnd; continue; }

            var columnValues = new object?[fields.Length][];
            for (int c = 0; c < fields.Length; c++)
                columnValues[c] = await ReadColumnAsync(group, fields[c], checked((int)groupRows), ct);

            for (long r = Math.Max(0, offset - groupStart); r < groupRows && rows.Count < limit; r++)
            {
                var row = new object?[fields.Length];
                for (int c = 0; c < fields.Length; c++) row[c] = columnValues[c][r];
                rows.Add(row);
            }
            groupStart = groupEnd;
        }

        return new ParquetTablePage
        {
            Columns = columns,
            Rows = rows,
            TotalRows = total,
            RowGroups = reader.RowGroupCount,
            Offset = offset
        };
    }

    private static async Task<object?[]> ReadColumnAsync(ParquetRowGroupReader group, DataField field, int count, CancellationToken ct)
    {
        if (field.IsArray)
            return Enumerable.Repeat<object?>("(list)", count).ToArray();

        var type = Nullable.GetUnderlyingType(field.ClrType) ?? field.ClrType;
        if (type == typeof(string))
        {
            var values = new string?[count];
            await group.ReadAsync(field, values.AsMemory()!, null, ct);
            return values;
        }
        if (type == typeof(byte[]))
        {
            var values = new byte[count][];
            await group.ReadAsync(field, values.AsMemory(), null, ct);
            return values.Select(b => (object?)(b is null ? null : $"({b.Length} bytes)")).ToArray();
        }
        if (type.IsValueType)
        {
            var task = (Task<object?[]>)ReadStructMethod.MakeGenericMethod(type).Invoke(null, [group, field, count, ct])!;
            return await task;
        }
        return new object?[count];
    }

    private static async Task<object?[]> ReadStructAsync<T>(ParquetRowGroupReader group, DataField field, int count, CancellationToken ct)
        where T : struct
    {
        if (field.IsNullable)
        {
            var values = new T?[count];
            await group.ReadAsync<T>(field, values.AsMemory(), null, ct);
            return values.Select(v => (object?)v).ToArray();
        }
        var required = new T[count];
        await group.ReadAsync<T>(field, required.AsMemory(), null, ct);
        return required.Select(v => (object?)v).ToArray();
    }

    private static string TypeName(Type type) => (Nullable.GetUnderlyingType(type) ?? type).Name;

    private static bool IsNumeric(Type type)
    {
        type = Nullable.GetUnderlyingType(type) ?? type;
        return type == typeof(int) || type == typeof(long) || type == typeof(short) || type == typeof(byte)
            || type == typeof(decimal) || type == typeof(double) || type == typeof(float);
    }
}
