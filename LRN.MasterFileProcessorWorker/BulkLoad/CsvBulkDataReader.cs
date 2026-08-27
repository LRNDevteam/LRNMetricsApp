using System.Data;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.VisualBasic.FileIO;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>
/// Streams a standardized CSV as an <see cref="IDataReader"/> for <c>SqlBulkCopy</c>, stamping the
/// audit block and the computed RowHash onto every row.
/// <para>
/// Streaming, not buffered: only one CSV row is in memory at a time, so a multi-million row file
/// costs the same as a small one. Uses <see cref="TextFieldParser"/> - the CSV reader already used
/// throughout this project - rather than adding a package.
/// </para>
/// <para>
/// Column order presented to SqlBulkCopy is: the level's mapped fields in lab-JSON order, then the
/// nine audit columns, then <c>AdditionalFields</c> when it is enabled. Callers must still add
/// explicit ColumnMappings by NAME; nothing here relies on ordinal alignment with the destination
/// table.
/// </para>
/// <para>
/// <b>AdditionalFields</b> is the answer to labs adding columns to their files: every CSV header no
/// mapped field claimed is written into one JSON object per row instead of forcing an ALTER TABLE
/// for each new column. It is off unless the caller confirms the destination has the column.
/// </para>
/// </summary>
public sealed class CsvBulkDataReader : IDataReader
{
    /// <summary>Relaxed escaping keeps the stored JSON readable (&amp;, &lt;, quotes stay legible).</summary>
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private readonly IReadOnlyList<FieldMapping> _fields;
    private readonly AuditColumns.AuditValues _audit;
    private readonly RowHasher _hasher;
    private readonly string[] _columnNames;
    private readonly int[] _csvIndexByField;
    private readonly TextFieldParser _parser;

    /// <summary>
    /// Header name + CSV ordinal for every column that goes into the AdditionalFields JSON, and
    /// whether a value there means the row carries data (an export stamp does not).
    /// </summary>
    private readonly (string Header, int CsvIndex, bool CountsAsData)[] _additionalColumns;

    /// <summary>CSV headers refused by <see cref="SensitiveColumns"/>. Never read, never stored.</summary>
    public IReadOnlyList<string> ExcludedSensitiveHeaders { get; } = Array.Empty<string>();

    private readonly bool _captureAdditionalFields;
    private readonly int _auditCount = AuditColumns.Names.Count;

    private string?[] _current;
    private string _currentHash = "";
    private string? _currentAdditional;
    private bool _currentAdditionalHasData;
    private bool _closed;

    /// <summary>
    /// SQL column names treated as a row's identity. A row with data but none of these set is
    /// loaded and reported; it is never dropped. Matched on <see cref="Norm"/>, so "Claim ID",
    /// "claim_id" and "ClaimID" are the same column.
    /// </summary>
    private static readonly string[] IdentityColumnNames = { "ClaimID", "VisitNumber", "VisitNum" };

    private readonly int[] _identityFieldIndexes;

    /// <summary>Per mapped field: does a value here mean the row carries real data?</summary>
    private readonly bool[] _countsAsData;
    private readonly List<long> _missingIdentityLines = new();
    private const int MaxMissingIdentitySamples = 5;

    /// <summary>Data rows returned so far. Compared against the destination count after the load.</summary>
    public long RowsRead { get; private set; }

    /// <summary>
    /// Rows dropped because every mapped column was blank. Not an error: Excel routinely leaves
    /// trailing rows, and an exporter that stamps a value on every line (NWL's combined multi-sheet
    /// export adds "Source") turns those into rows that look populated but carry no data.
    /// </summary>
    public long BlankRowsSkipped { get; private set; }

    /// <summary>
    /// Rows that DID carry data but had no value in any identity column. These are still loaded -
    /// the data is real - but they cannot be tied back to a claim, so they are worth reporting.
    /// </summary>
    public long RowsMissingIdentity { get; private set; }

    /// <summary>CSV line numbers of the first few <see cref="RowsMissingIdentity"/>, for the log.</summary>
    public IReadOnlyList<long> MissingIdentitySampleLines => _missingIdentityLines;

    /// <summary>Identity columns this level actually maps. Empty when the mapping declares none.</summary>
    public IReadOnlyList<string> IdentityColumns { get; }

    /// <summary>CSV headers that no mapped field claimed. Reported so mappings can be corrected.</summary>
    public IReadOnlyList<string> UnmappedCsvHeaders { get; }

    /// <summary>Mapped fields whose CsvHeader is absent from the file. These load as NULL.</summary>
    public IReadOnlyList<string> MissingCsvHeaders { get; }

    public CsvBulkDataReader(
        string csvPath,
        IReadOnlyList<FieldMapping> fields,
        AuditColumns.AuditValues audit,
        int headerRow = 1,
        bool captureAdditionalFields = false)
    {
        ArgumentNullException.ThrowIfNull(fields);

        // LabID and LabName are legitimately mapped from the CSV AND are part of the audit block.
        // Keeping both would emit the column twice, which SqlBulkCopy tolerates but the
        // INSERT...SELECT swap rejects with "column ... specified more than once". The stamped
        // audit value wins - it comes from the lab configuration rather than the file.
        _fields = fields.Where(f => !AuditColumns.IsPipelineOwned(f.SqlColumn)).ToList();
        _audit = audit;
        _hasher = new RowHasher(_fields);

        _parser = new TextFieldParser(csvPath)
        {
            TextFieldType = FieldType.Delimited,
            HasFieldsEnclosedInQuotes = true,
            TrimWhiteSpace = false
        };
        _parser.SetDelimiters(",");

        string[]? header = null;
        for (int i = 1; i <= headerRow && !_parser.EndOfData; i++)
            header = _parser.ReadFields();

        if (header is null)
        {
            _parser.Dispose();
            throw new InvalidDataException($"Header row {headerRow} not found in CSV: {csvPath}");
        }

        // Normalized lookup so a header that differs only by case/spacing/punctuation still binds.
        var headerIndex = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var headerNorm = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        for (int i = 0; i < header.Length; i++)
        {
            var name = (header[i] ?? "").Trim().TrimStart('﻿');
            if (string.IsNullOrWhiteSpace(name)) continue;

            headerIndex.TryAdd(name, i);
            headerNorm.TryAdd(Norm(name), i);
        }

        _csvIndexByField = new int[_fields.Count];
        var missing = new List<string>();
        var claimed = new HashSet<int>();

        for (int f = 0; f < _fields.Count; f++)
        {
            var csvHeader = (_fields[f].CsvHeader ?? "").Trim();

            if (headerIndex.TryGetValue(csvHeader, out var idx) ||
                headerNorm.TryGetValue(Norm(csvHeader), out idx))
            {
                _csvIndexByField[f] = idx;
                claimed.Add(idx);
            }
            else
            {
                _csvIndexByField[f] = -1;
                missing.Add($"{_fields[f].CsvHeader} -> {_fields[f].SqlColumn}");
            }
        }

        MissingCsvHeaders = missing;

        // A CSV column that matches an audit column (LabID, LabName, RunId, ...) is not unmapped -
        // it is supplied by the stamped audit block instead of read from the file. Reporting it as
        // dropped would send someone hunting for a mapping bug that does not exist.
        UnmappedCsvHeaders = headerIndex
            .Where(kv => !claimed.Contains(kv.Value) && !AuditColumns.IsPipelineOwned(kv.Key))
            .Select(kv => kv.Key)
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .ToList();

        // The unmapped headers are exactly what AdditionalFields captures - same list, so a column
        // is either mapped to its own SQL column or lands in the JSON, never both and never dropped.
        // The one exception is the policy deny-list: those are refused outright rather than captured.
        _captureAdditionalFields = captureAdditionalFields;

        if (captureAdditionalFields)
        {
            _additionalColumns = UnmappedCsvHeaders
                .Where(h => !SensitiveColumns.IsBlocked(h))
                .Select(h => (Header: h, CsvIndex: headerIndex[h], CountsAsData: !AuditColumns.IsExportStamp(h)))
                .ToArray();

            ExcludedSensitiveHeaders = UnmappedCsvHeaders.Where(SensitiveColumns.IsBlocked).ToList();
        }
        else
        {
            _additionalColumns = Array.Empty<(string, int, bool)>();
        }

        _columnNames = _fields.Select(f => f.SqlColumn)
            .Concat(AuditColumns.Names)
            .Concat(captureAdditionalFields ? new[] { AuditColumns.AdditionalFields } : Array.Empty<string>())
            .ToArray();

        // The exporter's Source stamp is written on every emitted line, so it must not be what
        // keeps an otherwise-blank row alive. It is still read and still stored - it just does not
        // count towards "this row has data".
        _countsAsData = _fields
            .Select(f => !AuditColumns.IsExportStamp(f.SqlColumn) && !AuditColumns.IsExportStamp(f.CsvHeader))
            .ToArray();

        var identityNorms = IdentityColumnNames.Select(Norm).ToHashSet(StringComparer.Ordinal);

        _identityFieldIndexes = Enumerable.Range(0, _fields.Count)
            .Where(f => identityNorms.Contains(Norm(_fields[f].SqlColumn ?? "")))
            .ToArray();

        IdentityColumns = _identityFieldIndexes.Select(f => _fields[f].SqlColumn).ToList();

        _current = new string?[_fields.Count];
    }

    private static string Norm(string s) =>
        new(s.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());

    /// <summary>Destination column names in the order this reader exposes them.</summary>
    public IReadOnlyList<string> ColumnNames => _columnNames;

    public bool Read()
    {
        while (!_parser.EndOfData)
        {
            string[] row;

            // Read it before ReadFields: LineNumber has already advanced to the next line by the
            // time that call returns.
            var lineNumber = _parser.LineNumber;

            try
            {
                row = _parser.ReadFields() ?? Array.Empty<string>();
            }
            catch (MalformedLineException ex)
            {
                // Fail rather than skip: a malformed line means the file is not what we think it is,
                // and silently dropping rows would corrupt the load with no trace.
                throw new InvalidDataException(
                    $"Malformed CSV at line {ex.Message}. File: {_parser.ErrorLine}", ex);
            }

            var hasMappedValue = false;

            for (int f = 0; f < _fields.Count; f++)
            {
                var idx = _csvIndexByField[f];
                var value = idx >= 0 && idx < row.Length ? row[idx] : null;
                _current[f] = string.IsNullOrWhiteSpace(value) ? null : value.Trim();

                if (_current[f] is not null && _countsAsData[f]) hasMappedValue = true;
            }

            _currentAdditionalHasData = false;
            _currentAdditional = BuildAdditionalFields(row);

            // An empty row is one with nothing in ANY mapped column and nothing worth capturing in
            // AdditionalFields. Testing the mapped values rather than the raw CSV cells is what
            // matters: a column the exporter stamps on every line (NWL's "Source") makes a blank
            // sheet row look populated, and it would otherwise load as an all-NULL record.
            // Dropped silently - a trailing blank row is normal, not a problem to report.
            if (!hasMappedValue && !_currentAdditionalHasData)
            {
                BlankRowsSkipped++;
                continue;
            }

            // The row has data. If it carries no identity at all it still loads - the data is
            // real - but it is counted so the caller can warn once with a total.
            if (_identityFieldIndexes.Length > 0 &&
                _identityFieldIndexes.All(i => _current[i] is null))
            {
                RowsMissingIdentity++;
                if (_missingIdentityLines.Count < MaxMissingIdentitySamples)
                    _missingIdentityLines.Add(lineNumber);
            }

            _currentHash = _hasher.Compute(_current);
            RowsRead++;
            return true;
        }

        return false;
    }

    /// <summary>
    /// The row's unmapped columns as one JSON object, or null when the row filled none of them.
    /// Empty values are left out so a mostly-empty extra column costs nothing per row.
    /// </summary>
    private string? BuildAdditionalFields(string[] row)
    {
        if (!_captureAdditionalFields || _additionalColumns.Length == 0)
            return null;

        Dictionary<string, string>? payload = null;

        foreach (var (header, csvIndex, countsAsData) in _additionalColumns)
        {
            if (csvIndex >= row.Length) continue;

            var value = row[csvIndex];
            if (string.IsNullOrWhiteSpace(value)) continue;

            payload ??= new Dictionary<string, string>(StringComparer.Ordinal);
            payload[header] = value.Trim();

            // A captured export stamp is still stored, but on its own it does not make the row
            // count as data - otherwise a blank sheet row survives purely because of it.
            if (countsAsData) _currentAdditionalHasData = true;
        }

        return payload is null ? null : JsonSerializer.Serialize(payload, JsonOptions);
    }

    public object GetValue(int i)
    {
        if (i < _fields.Count)
            return (object?)_current[i] ?? DBNull.Value;

        if (_captureAdditionalFields && i == _fields.Count + _auditCount)
            return (object?)_currentAdditional ?? DBNull.Value;

        // Audit block, in AuditColumns.All order.
        return (i - _fields.Count) switch
        {
            0 => _audit.FileLogId,
            1 => _audit.RunId,
            2 => (object?)_audit.WeekFolder ?? DBNull.Value,
            3 => (object?)_audit.SourceFullPath ?? DBNull.Value,
            4 => (object?)_audit.FileName ?? DBNull.Value,
            5 => _audit.FileType,
            6 => _currentHash,
            7 => _audit.LabId,
            8 => _audit.LabName,
            _ => DBNull.Value
        };
    }

    public int FieldCount => _columnNames.Length;
    public string GetName(int i) => _columnNames[i];
    public int GetOrdinal(string name)
    {
        for (int i = 0; i < _columnNames.Length; i++)
            if (string.Equals(_columnNames[i], name, StringComparison.OrdinalIgnoreCase))
                return i;

        throw new IndexOutOfRangeException(name);
    }

    public bool IsDBNull(int i) => GetValue(i) is DBNull;
    public object this[int i] => GetValue(i);
    public object this[string name] => GetValue(GetOrdinal(name));

    public void Close()
    {
        if (_closed) return;
        _closed = true;
        _parser.Dispose();
    }

    public void Dispose() => Close();
    public bool IsClosed => _closed;

    // SqlBulkCopy only calls Read/GetValue/FieldCount/GetName/GetOrdinal/IsDBNull/Close.
    public int Depth => 0;
    public int RecordsAffected => -1;
    public bool NextResult() => false;
    public DataTable? GetSchemaTable() => null;

    public string GetString(int i) => Convert.ToString(GetValue(i)) ?? "";
    public int GetValues(object[] values)
    {
        var n = Math.Min(values.Length, FieldCount);
        for (int i = 0; i < n; i++) values[i] = GetValue(i);
        return n;
    }

    public Type GetFieldType(int i) =>
        i < _fields.Count || i >= _fields.Count + _auditCount
            ? typeof(string)
            : AuditColumns.All[i - _fields.Count].ClrType;
    public string GetDataTypeName(int i) => GetFieldType(i).Name;

    public bool GetBoolean(int i) => Convert.ToBoolean(GetValue(i));
    public byte GetByte(int i) => Convert.ToByte(GetValue(i));
    public char GetChar(int i) => Convert.ToChar(GetValue(i));
    public DateTime GetDateTime(int i) => Convert.ToDateTime(GetValue(i));
    public decimal GetDecimal(int i) => Convert.ToDecimal(GetValue(i));
    public double GetDouble(int i) => Convert.ToDouble(GetValue(i));
    public float GetFloat(int i) => Convert.ToSingle(GetValue(i));
    public Guid GetGuid(int i) => Guid.Parse(GetString(i));
    public short GetInt16(int i) => Convert.ToInt16(GetValue(i));
    public int GetInt32(int i) => Convert.ToInt32(GetValue(i));
    public long GetInt64(int i) => Convert.ToInt64(GetValue(i));
    public IDataReader GetData(int i) => throw new NotSupportedException();
    public long GetBytes(int i, long fieldOffset, byte[]? buffer, int bufferoffset, int length) => throw new NotSupportedException();
    public long GetChars(int i, long fieldoffset, char[]? buffer, int bufferoffset, int length) => throw new NotSupportedException();
}
