using System.Data.Common;
using System.Globalization;
using System.Text.Json;
using Parquet;
using Parquet.Schema;

namespace LRN.MasterFileProcessorWorker.Snapshots;

public sealed record ParquetWriteResult(long RowCount, int ColumnCount, string SchemaJson);

/// <summary>
/// Streams any <see cref="DbDataReader"/> into one Parquet file, one row group per
/// <c>rowGroupSize</c> rows, with typed columns so money, dates and NULLs survive exactly.
/// <para>
/// SQL type mapping: int/bigint stay INT32/INT64 (tinyint and smallint widen to INT32);
/// decimal/numeric/money keep their precision and scale (money = 19,4); date stays DATE;
/// datetime/datetime2/smalldatetime become TIMESTAMP (microseconds, as stored - not shifted to UTC);
/// datetimeoffset becomes a UTC TIMESTAMP; bit = BOOLEAN; float/real = DOUBLE/FLOAT; varbinary and
/// rowversion = BYTE_ARRAY; everything else (strings, uniqueidentifier, time, sql_variant) = UTF8.
/// Every column is written nullable. Unnamed columns become Col{n}; duplicates get _1, _2.
/// </para>
/// </summary>
public static class ParquetSnapshotWriter
{
    public static async Task<ParquetWriteResult> WriteAsync(
        DbDataReader reader, string filePath, int rowGroupSize, CompressionMethod compression, CancellationToken ct)
    {
        rowGroupSize = Math.Max(1, rowGroupSize);

        var columns = reader.GetColumnSchema();
        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var sinks = new List<ColumnSink>(columns.Count);

        for (int i = 0; i < columns.Count; i++)
        {
            var name = Unique(string.IsNullOrWhiteSpace(columns[i].ColumnName) ? $"Col{i}" : columns[i].ColumnName, used);
            sinks.Add(ColumnSink.Create(name, columns[i], rowGroupSize));
        }

        var schema = new ParquetSchema(sinks.Select(s => (Field)s.Field));
        var options = new ParquetOptions { CompressionMethod = compression };
        long total = 0;

        await using (var fs = File.Create(filePath))
        await using (var writer = await ParquetWriter.CreateAsync(schema, fs, options, append: false, ct).ConfigureAwait(false))
        {
            int n = 0;

            while (await reader.ReadAsync(ct).ConfigureAwait(false))
            {
                // In column order: the reader is opened with SequentialAccess.
                for (int c = 0; c < sinks.Count; c++)
                {
                    var value = reader.GetValue(c);
                    sinks[c].Set(n, value is DBNull ? null : value);
                }

                if (++n == rowGroupSize)
                {
                    await WriteGroupAsync(writer, sinks, n, ct).ConfigureAwait(false);
                    total += n;
                    n = 0;
                }
            }

            // An empty table still gets a valid file with its schema, so "no rows that week" is
            // distinguishable from "no snapshot".
            if (n > 0 || total == 0)
            {
                await WriteGroupAsync(writer, sinks, n, ct).ConfigureAwait(false);
                total += n;
            }
        }

        var schemaJson = JsonSerializer.Serialize(sinks.Select((s, i) => new
        {
            name = s.Field.Name,
            sourceName = columns[i].ColumnName,
            type = s.TypeLabel,
            sqlType = columns[i].DataTypeName,
            precision = s.Precision,
            scale = s.Scale
        }));

        return new ParquetWriteResult(total, sinks.Count, schemaJson);
    }

    /// <summary>Row count from the file's own footer - an independent read-back of what was written.</summary>
    public static async Task<long> ReadRowCountAsync(string filePath, CancellationToken ct)
    {
        await using var reader = await ParquetReader.CreateAsync(filePath, null, ct).ConfigureAwait(false);
        return reader.Metadata?.NumRows ?? 0;
    }

    public static CompressionMethod ParseCompression(string? value) =>
        Enum.TryParse<CompressionMethod>(value, ignoreCase: true, out var parsed) ? parsed : CompressionMethod.Snappy;

    private static async Task WriteGroupAsync(ParquetWriter writer, List<ColumnSink> sinks, int count, CancellationToken ct)
    {
        using var group = writer.CreateRowGroup();

        foreach (var sink in sinks)
            await sink.WriteAsync(group, count, ct).ConfigureAwait(false);

        group.CompleteValidate();
    }

    private static string Unique(string name, HashSet<string> used)
    {
        var candidate = name;
        for (int i = 1; !used.Add(candidate); i++)
            candidate = $"{name}_{i}";
        return candidate;
    }

    /// <summary>One column's typed buffer for the current row group. Reused across groups.</summary>
    private abstract class ColumnSink
    {
        public abstract DataField Field { get; }
        public abstract string TypeLabel { get; }
        public virtual int? Precision => null;
        public virtual int? Scale => null;

        public abstract void Set(int row, object? value);
        public abstract Task WriteAsync(ParquetRowGroupWriter group, int count, CancellationToken ct);

        public static ColumnSink Create(string name, DbColumn col, int size)
        {
            var type = col.DataType ?? typeof(string);
            var sqlType = col.DataTypeName ?? string.Empty;

            if (type == typeof(bool))
                return new ValueSink<bool>(new DataField<bool?>(name), size, v => Convert.ToBoolean(v, CultureInfo.InvariantCulture));
            if (type == typeof(byte) || type == typeof(short) || type == typeof(int))
                return new ValueSink<int>(new DataField<int?>(name), size, v => Convert.ToInt32(v, CultureInfo.InvariantCulture));
            if (type == typeof(long))
                return new ValueSink<long>(new DataField<long?>(name), size, v => Convert.ToInt64(v, CultureInfo.InvariantCulture));
            if (type == typeof(float))
                return new ValueSink<float>(new DataField<float?>(name), size, v => Convert.ToSingle(v, CultureInfo.InvariantCulture));
            if (type == typeof(double))
                return new ValueSink<double>(new DataField<double?>(name), size, v => Convert.ToDouble(v, CultureInfo.InvariantCulture));

            if (type == typeof(decimal))
            {
                // money/smallmoney report a scale of 255; System.Decimal tops out at 28 digits of scale.
                int p = col.NumericPrecision is > 0 and <= 38 ? col.NumericPrecision.Value : 38;
                int s = col.NumericScale is >= 0 && col.NumericScale <= p && col.NumericScale <= 28 ? col.NumericScale.Value : 4;
                var field = new DecimalDataField(name, p, s, forceByteArrayEncoding: false, isNullable: true);
                return new ValueSink<decimal>(field, size, v => Convert.ToDecimal(v, CultureInfo.InvariantCulture), p, s);
            }

            if (type == typeof(DateTime))
            {
                var field = string.Equals(sqlType, "date", StringComparison.OrdinalIgnoreCase)
                    ? new DateTimeDataField(name, DateTimeFormat.Date, isNullable: true)
                    : new DateTimeDataField(name, DateTimeFormat.Timestamp, isAdjustedToUTC: false, unit: DateTimeTimeUnit.Micros, isNullable: true);
                return new ValueSink<DateTime>(field, size, v => (DateTime)v);
            }

            if (type == typeof(DateTimeOffset))
            {
                var field = new DateTimeDataField(name, DateTimeFormat.Timestamp, isAdjustedToUTC: true, unit: DateTimeTimeUnit.Micros, isNullable: true);
                return new ValueSink<DateTime>(field, size, v => ((DateTimeOffset)v).UtcDateTime);
            }

            if (type == typeof(byte[]))
                return new BytesSink(new DataField<byte[]>(name, true), size);

            // Strings, uniqueidentifier, time, sql_variant and anything unforeseen.
            return new StringSink(new DataField<string>(name, true), size);
        }
    }

    private sealed class ValueSink<T> : ColumnSink where T : struct
    {
        private readonly T?[] _buffer;
        private readonly Func<object, T> _convert;
        private readonly int? _precision;
        private readonly int? _scale;

        public ValueSink(DataField field, int size, Func<object, T> convert, int? precision = null, int? scale = null)
        {
            Field = field;
            _buffer = new T?[size];
            _convert = convert;
            _precision = precision;
            _scale = scale;
        }

        public override DataField Field { get; }
        public override string TypeLabel => typeof(T).Name;
        public override int? Precision => _precision;
        public override int? Scale => _scale;

        public override void Set(int row, object? value) => _buffer[row] = value is null ? null : _convert(value);

        public override async Task WriteAsync(ParquetRowGroupWriter group, int count, CancellationToken ct) =>
            await group.WriteAsync<T>(Field, new ReadOnlyMemory<T?>(_buffer, 0, count), null, null, ct).ConfigureAwait(false);
    }

    private sealed class StringSink : ColumnSink
    {
        private readonly string?[] _buffer;

        public StringSink(DataField field, int size)
        {
            Field = field;
            _buffer = new string?[size];
        }

        public override DataField Field { get; }
        public override string TypeLabel => nameof(String);

        public override void Set(int row, object? value) => _buffer[row] = value switch
        {
            null => null,
            string s => s,
            TimeSpan t => t.ToString("c", CultureInfo.InvariantCulture),
            IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
            _ => value.ToString()
        };

        public override async Task WriteAsync(ParquetRowGroupWriter group, int count, CancellationToken ct) =>
            await group.WriteAsync(Field, new ArraySegment<string>(_buffer!, 0, count), null).ConfigureAwait(false);
    }

    private sealed class BytesSink : ColumnSink
    {
        private readonly byte[]?[] _buffer;

        public BytesSink(DataField field, int size)
        {
            Field = field;
            _buffer = new byte[]?[size];
        }

        public override DataField Field { get; }
        public override string TypeLabel => "Byte[]";

        public override void Set(int row, object? value) => _buffer[row] = (byte[]?)value;

        public override async Task WriteAsync(ParquetRowGroupWriter group, int count, CancellationToken ct) =>
            await group.WriteAsync(Field, new ArraySegment<byte[]>(_buffer!, 0, count), null).ConfigureAwait(false);
    }
}
