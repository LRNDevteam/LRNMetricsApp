using System.Data;
using System.Globalization;
using System.Text;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Spreadsheet;
using Microsoft.Data.SqlClient;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Flat-memory Excel writer for large SqlDataReader exports.
/// ClosedXML keeps the whole workbook graph in RAM and OOMs on SaveAs for
/// high-volume labs; this streams sheet XML via <see cref="OpenXmlWriter"/>
/// straight into the .xlsx package on disk (one row at a time).
/// </summary>
internal static class OpenXmlRowStreamer
{
    /// <summary>New worksheet every N data rows — keeps Excel usable and per-sheet XML smaller.</summary>
    public const int SheetSplitThreshold = 200_000;

    /// <summary>
    /// Second split trigger, on the worksheet's approximate XML size.
    ///
    /// System.IO.Packaging buffers each package part in a MemoryStream, which throws
    /// "Stream was too long" past 2 GB — so ONE sheet part can never exceed that no matter how
    /// it is written. A row cap alone does not bound this: a lab whose rows carry ~72 KB ICD
    /// code lists blows past 2 GB in ~29K rows, well inside the 200K row cap. Splitting on
    /// estimated bytes as well keeps every part comfortably under the limit.
    /// </summary>
    private const long SheetSplitBytes = 900_000_000;

    /// <summary>Per-cell XML overhead (element, ref attribute, inline-string wrapper).</summary>
    private const int CellXmlOverheadBytes = 48;

    public sealed record ColumnMap(int Ordinal, string Name, bool IsIcd);

    /// <summary>
    /// Scans the open data reader for ICD columns and returns how many overflow
    /// columns (<c>_1</c>…<c>_N</c>) each base ICD column needs. Returns all zeros
    /// when nothing exceeds Excel's 32,767-char cell limit — matching the original
    /// ClosedXML export (no empty dynamic columns).
    /// Consumes the reader; caller must re-execute the query for the write pass.
    /// </summary>
    public static async Task<int[]> MeasureIcdOverflowAsync(
        SqlDataReader reader,
        HashSet<string>? excludedColumns,
        CancellationToken ct)
    {
        var columns = BuildColumns(reader, excludedColumns);
        var extras = new int[columns.Count];
        while (await reader.ReadAsync(ct))
        {
            ct.ThrowIfCancellationRequested();
            for (var i = 0; i < columns.Count; i++)
            {
                var col = columns[i];
                if (!col.IsIcd || reader.IsDBNull(col.Ordinal)) continue;
                var val = reader.GetValue(col.Ordinal);
                if (val is not string s || s.Length <= IcdCellSplitter.MaxCellLength) continue;
                var parts = IcdCellSplitter.Split(s).Count - 1;
                if (parts > extras[i]) extras[i] = parts;
            }
        }
        return extras;
    }

    /// <summary>
    /// Creates <paramref name="tempPath"/> as a multi-sheet workbook from an open
    /// <see cref="SqlDataReader"/> positioned on the data result set.
    /// </summary>
    /// <param name="icdExtraParts">
    /// Per export-column overflow counts from <see cref="MeasureIcdOverflowAsync"/>.
    /// Null / all zeros → no overflow columns (original behavior when nothing overflows).
    /// </param>
    public static async Task<int> WriteFromReaderAsync(
        SqlDataReader reader,
        string tempPath,
        string labName,
        string title,
        IReadOnlyList<(string Label, string? Value)>? activeFilters,
        Func<byte, Task>? reportProgressAsync,
        int? totalFiltered,
        HashSet<string>? excludedColumns,
        bool splitIcdColumns,
        CancellationToken ct,
        IReadOnlyList<int>? icdExtraParts = null)
    {
        if (File.Exists(tempPath)) File.Delete(tempPath);

        var columns = BuildColumns(reader, excludedColumns);
        if (columns.Count == 0)
            throw new InvalidOperationException("Report query returned no exportable columns.");

        // Only append "{Name}_1"… when MeasureIcdOverflowAsync found real overflow.
        var headers = BuildHeaders(columns, splitIcdColumns, icdExtraParts, out var overflowStarts);
        var colRefs = BuildColRefs(headers.Length);

        using var doc = SpreadsheetDocument.Create(tempPath, SpreadsheetDocumentType.Workbook, autoSave: false);
        var workbookPart = doc.AddWorkbookPart();
        workbookPart.Workbook = new Workbook();
        var sheets = workbookPart.Workbook.AppendChild(new Sheets());

        var totalRows = 0;
        var sheetIndex = 0;
        var sheetRowCount = 0;
        OpenXmlWriter? writer = null;
        WorksheetPart? wsPart = null;
        uint excelRow = 1;
        var expectedParts = totalFiltered is > 0
            ? Math.Max(1, (int)Math.Ceiling(totalFiltered.Value / (double)SheetSplitThreshold))
            : 1;
        var doIcdSplit = splitIcdColumns && overflowStarts.Count > 0;

        try
        {
            async Task EnsureSheetAsync()
            {
                if (writer is not null && sheetRowCount < SheetSplitThreshold)
                    return;

                await CloseSheetAsync();
                sheetIndex++;
                sheetRowCount = 0;
                excelRow = 1;

                wsPart = workbookPart.AddNewPart<WorksheetPart>();
                var relId = workbookPart.GetIdOfPart(wsPart);
                var sheetId = (uint)(sheets.Elements<Sheet>().Count() + 1);
                var sheetName = MakeSheetName(title, sheetIndex, expectedParts);
                sheets.Append(new Sheet { Id = relId, SheetId = sheetId, Name = sheetName });

                writer = OpenXmlWriter.Create(wsPart);
                writer.WriteStartElement(new Worksheet());
                writer.WriteStartElement(new SheetData());

                // Title row
                writer.WriteStartElement(new Row { RowIndex = excelRow });
                var partLabel = sheetIndex > 1 || expectedParts > 1
                    ? $" (sheet {sheetIndex} of {Math.Max(expectedParts, sheetIndex)})"
                    : "";
                WriteInline(writer, $"{colRefs[0]}{excelRow}", $"{labName} — {title}{partLabel}");
                writer.WriteEndElement();
                excelRow++;

                // Header row
                writer.WriteStartElement(new Row { RowIndex = excelRow });
                for (var c = 0; c < headers.Length; c++)
                    WriteInline(writer, $"{colRefs[c]}{excelRow}", headers[c]);
                writer.WriteEndElement();
                excelRow++;
            }

            Task CloseSheetAsync()
            {
                if (writer is null) return Task.CompletedTask;
                writer.WriteEndElement(); // SheetData
                writer.WriteEndElement(); // Worksheet
                writer.Dispose();
                writer = null;
                wsPart = null;
                return Task.CompletedTask;
            }

            while (await reader.ReadAsync(ct))
            {
                ct.ThrowIfCancellationRequested();
                await EnsureSheetAsync();

                writer!.WriteStartElement(new Row { RowIndex = excelRow });

                Dictionary<int, string[]>? overflowTexts = doIcdSplit ? new() : null;

                // SequentialAccess requires every source ordinal to be read in order,
                // including columns later dropped from the sheet (ingest / __* names).
                var raw = new object?[reader.FieldCount];
                for (var i = 0; i < reader.FieldCount; i++)
                {
                    var v = reader.GetValue(i);
                    raw[i] = v is DBNull ? null : v;
                }

                for (var c = 0; c < columns.Count; c++)
                {
                    var col = columns[c];
                    var val = raw[col.Ordinal];
                    if (val is null)
                        continue;

                    if (doIcdSplit && col.IsIcd && overflowStarts.TryGetValue(c, out _)
                        && val is string s && s.Length > IcdCellSplitter.MaxCellLength)
                    {
                        var chunks = IcdCellSplitter.Split(s);
                        WriteValue(writer, $"{colRefs[c]}{excelRow}", chunks[0]);
                        // Never write more overflow cells than the header reserved.
                        var maxSlots = icdExtraParts is not null && c < icdExtraParts.Count
                            ? icdExtraParts[c]
                            : 0;
                        var take = Math.Min(chunks.Count - 1, maxSlots);
                        if (take > 0)
                        {
                            var rest = new string[take];
                            for (var k = 0; k < take; k++)
                                rest[k] = chunks[k + 1];
                            overflowTexts![c] = rest;
                        }
                    }
                    else
                    {
                        WriteValue(writer, $"{colRefs[c]}{excelRow}", val);
                    }
                }

                if (overflowTexts is { Count: > 0 })
                {
                    foreach (var (baseIdx, parts) in overflowTexts)
                    {
                        var startCol = overflowStarts[baseIdx];
                        for (var k = 0; k < parts.Length; k++)
                            WriteInline(writer, $"{colRefs[startCol + k]}{excelRow}", parts[k]);
                    }
                }

                writer.WriteEndElement(); // Row
                excelRow++;
                sheetRowCount++;
                totalRows++;

                if (reportProgressAsync is not null && totalRows % 10_000 == 0)
                {
                    byte pct = totalFiltered is > 0
                        ? (byte)Math.Min(90, 5 + totalRows * 85L / totalFiltered.Value)
                        : (byte)Math.Min(90, 5 + totalRows / 10_000 * 2);
                    await reportProgressAsync(pct);
                }
            }

            // Empty result
            if (totalRows == 0)
            {
                await EnsureSheetAsync();
                writer!.WriteStartElement(new Row { RowIndex = excelRow });
                WriteInline(writer, $"{colRefs[0]}{excelRow}", "No data matched the selected filters.");
                writer.WriteEndElement();
                excelRow++;
            }

            // Filter summary on last sheet
            if (activeFilters is { Count: > 0 } && writer is not null)
            {
                excelRow++;
                writer.WriteStartElement(new Row { RowIndex = excelRow });
                WriteInline(writer, $"{colRefs[0]}{excelRow}", "Active Filters");
                writer.WriteEndElement();
                foreach (var (label, value) in activeFilters)
                {
                    if (string.IsNullOrWhiteSpace(value)) continue;
                    excelRow++;
                    writer.WriteStartElement(new Row { RowIndex = excelRow });
                    WriteInline(writer, $"{colRefs[0]}{excelRow}", label);
                    if (headers.Length > 1)
                        WriteInline(writer, $"{colRefs[1]}{excelRow}", value ?? "");
                    writer.WriteEndElement();
                }
            }

            await CloseSheetAsync();
            workbookPart.Workbook.Save();
        }
        finally
        {
            writer?.Dispose();
        }

        if (reportProgressAsync is not null)
            await reportProgressAsync(100);

        return totalRows;
    }

    /// <summary>
    /// Streams an ad-hoc SQL SELECT into <paramref name="tempPath"/> (same shape as
    /// <see cref="WriteFromReaderAsync"/>). Used by Claim/Line detail exports.
    /// </summary>
    public static async Task<int> WriteFromSqlAsync(
        string connectionString,
        string dataSql,
        List<SqlParameter> parameters,
        string tempPath,
        string labName,
        string title,
        IReadOnlyList<(string Label, string? Value)>? activeFilters,
        Func<byte, Task>? reportProgressAsync,
        int? totalFiltered,
        CancellationToken ct,
        int commandTimeoutSeconds = 3600)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(dataSql, conn) { CommandTimeout = commandTimeoutSeconds };
        DetailExportStreamer.ApplyCommand(cmd, dataSql, parameters);

        await using var reader = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct);
        return await WriteFromReaderAsync(
            reader, tempPath, labName, title, activeFilters,
            reportProgressAsync, totalFiltered,
            excludedColumns: null, splitIcdColumns: false, ct);
    }

    /// <summary>
    /// Appends one or more OpenXml-streamed sheets (from a SELECT) onto an existing
    /// .xlsx that already holds summary tabs (ClosedXML-generated).
    /// </summary>
    public static async Task<int> AppendSqlSheetsToWorkbookAsync(
        string workbookPath,
        string connectionString,
        string dataSql,
        List<SqlParameter> parameters,
        string baseSheetName,
        Func<int, Task>? onRowsProgress,
        CancellationToken ct,
        int commandTimeoutSeconds = 1800)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(dataSql, conn) { CommandTimeout = commandTimeoutSeconds };
        DetailExportStreamer.ApplyCommand(cmd, dataSql, parameters);

        await using var reader = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct);

        var columns = BuildColumns(reader, excludedColumns: null);
        var headers = columns.Select(c => c.Name).ToArray();

        return await AppendSheetsCoreAsync(
            workbookPath, baseSheetName, headers, ReadRowsAsync(), onRowsProgress, ct);

        async IAsyncEnumerable<object?[]> ReadRowsAsync()
        {
            while (await reader.ReadAsync(ct))
            {
                ct.ThrowIfCancellationRequested();
                var raw = new object?[reader.FieldCount];
                for (var i = 0; i < reader.FieldCount; i++)
                {
                    var v = reader.GetValue(i);
                    raw[i] = v is DBNull ? null : v;
                }
                var values = new object?[columns.Count];
                for (var c = 0; c < columns.Count; c++)
                    values[c] = raw[columns[c].Ordinal];
                yield return values;
            }
        }
    }

    /// <summary>
    /// Appends a sheet built from rows already in memory, using the same bounded-memory writer
    /// the SQL variant uses. ClosedXML holds the entire sheet XML in a MemoryStream while
    /// saving and dies with "Stream was too long" past 2 GB — this path never buffers more
    /// than one row.
    /// </summary>
    public static Task<int> AppendRowsToWorkbookAsync(
        string workbookPath,
        string baseSheetName,
        string[] headers,
        IEnumerable<object?[]> rows,
        Func<int, Task>? onRowsProgress,
        CancellationToken ct)
        => AppendSheetsCoreAsync(workbookPath, baseSheetName, headers, ToAsync(rows, ct), onRowsProgress, ct);

    private static async IAsyncEnumerable<object?[]> ToAsync(
        IEnumerable<object?[]> rows,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        foreach (var row in rows)
        {
            ct.ThrowIfCancellationRequested();
            yield return row;
        }
        await Task.CompletedTask;
    }

    private static async Task<int> AppendSheetsCoreAsync(
        string workbookPath,
        string baseSheetName,
        string[] headers,
        IAsyncEnumerable<object?[]> rowSource,
        Func<int, Task>? onRowsProgress,
        CancellationToken ct)
    {
        var colRefs = BuildColRefs(Math.Max(1, headers.Length));

        // Column widths must be declared BEFORE <sheetData>, so sample the first rows into a
        // buffer, size the columns from what they actually contain, then write the buffer out
        // and keep streaming the rest.
        await using var rowEnumerator = rowSource.GetAsyncEnumerator(ct);
        var sample = new List<object?[]>(WidthSampleRows);
        while (sample.Count < WidthSampleRows && await rowEnumerator.MoveNextAsync())
            sample.Add(rowEnumerator.Current);
        var widths = MeasureColumnWidths(headers, sample);

        // Green header style, registered in the MAIN workbook's stylesheet: the bucket sheets
        // are byte-copied into that package, so their style indices must resolve there.
        var headerStyle = EnsureGreenHeaderStyle(workbookPath);

        var usedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var probe = SpreadsheetDocument.Open(workbookPath, isEditable: false))
        {
            var probeSheets = probe.WorkbookPart?.Workbook.GetFirstChild<Sheets>();
            if (probeSheets is not null)
            {
                foreach (var s in probeSheets.Elements<Sheet>())
                {
                    if (s.Name?.Value is { } n) usedNames.Add(n);
                }
            }
        }

        var tempFolder = Path.Combine(
            Path.GetDirectoryName(workbookPath) ?? Path.GetTempPath(),
            $"_ox_{baseSheetName}_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempFolder);

        var bucketFiles = new List<(string Path, string SheetName)>();
        var totalRows = 0;
        var sheetIndex = 0;
        var sheetRowCount = 0;
        long sheetBytes = 0;
        string? currentBucket = null;
        SpreadsheetDocument? bucketDoc = null;
        WorkbookPart? bucketWb = null;
        Sheets? bucketSheets = null;
        OpenXmlWriter? writer = null;
        uint excelRow = 1;

        try
        {
            void CloseBucket()
            {
                if (writer is not null)
                {
                    writer.WriteEndElement();
                    writer.WriteEndElement();
                    writer.Dispose();
                    writer = null;
                }
                if (bucketWb is not null)
                {
                    bucketWb.Workbook.Save();
                    bucketWb = null;
                    bucketSheets = null;
                }
                bucketDoc?.Dispose();
                bucketDoc = null;
                currentBucket = null;
            }

            void OpenBucket()
            {
                sheetIndex++;
                sheetRowCount = 0;
                sheetBytes = 0;
                excelRow = 1;
                var sheetName = UniqueSheetName(
                    sheetIndex == 1 ? baseSheetName : $"{baseSheetName}_P{sheetIndex}", usedNames);
                currentBucket = Path.Combine(tempFolder, $"{SanitizeFile(sheetName)}.xlsx");
                bucketFiles.Add((currentBucket, sheetName));

                bucketDoc = SpreadsheetDocument.Create(currentBucket, SpreadsheetDocumentType.Workbook, autoSave: false);
                bucketWb = bucketDoc.AddWorkbookPart();
                bucketWb.Workbook = new Workbook();
                bucketSheets = bucketWb.Workbook.AppendChild(new Sheets());

                var wsPart = bucketWb.AddNewPart<WorksheetPart>();
                var relId = bucketWb.GetIdOfPart(wsPart);
                bucketSheets.Append(new Sheet { Id = relId, SheetId = 1U, Name = sheetName });

                writer = OpenXmlWriter.Create(wsPart);
                writer.WriteStartElement(new Worksheet());

                // Header row frozen on every split sheet, then the fixed column widths.
                writer.WriteElement(new SheetViews(new SheetView
                {
                    WorkbookViewId = 0U,
                    Pane = new Pane
                    {
                        VerticalSplit = 1D,
                        TopLeftCell = "A2",
                        ActivePane = PaneValues.BottomLeft,
                        State = PaneStateValues.Frozen,
                    },
                }));
                writer.WriteElement(BuildColumnsElement(widths));

                writer.WriteStartElement(new SheetData());

                writer.WriteStartElement(new Row { RowIndex = excelRow });
                for (var c = 0; c < headers.Length; c++)
                    WriteInline(writer, $"{colRefs[c]}{excelRow}", headers[c], headerStyle);
                writer.WriteEndElement();
                excelRow++;
            }

            void WriteRow(object?[] values)
            {
                // Estimate before writing, so a row never straddles the size limit.
                long rowBytes = 0;
                for (var c = 0; c < values.Length && c < colRefs.Length; c++)
                {
                    if (values[c] is null) continue;
                    rowBytes += CellXmlOverheadBytes + (values[c] is string s ? s.Length : 16);
                }

                if (writer is null
                    || sheetRowCount >= SheetSplitThreshold
                    || (sheetRowCount > 0 && sheetBytes + rowBytes > SheetSplitBytes))
                {
                    CloseBucket();
                    OpenBucket();
                }

                writer!.WriteStartElement(new Row { RowIndex = excelRow });
                for (var c = 0; c < values.Length && c < colRefs.Length; c++)
                {
                    if (values[c] is null) continue;
                    WriteValue(writer, $"{colRefs[c]}{excelRow}", values[c]!);
                }
                writer.WriteEndElement();
                excelRow++;
                sheetRowCount++;
                sheetBytes += rowBytes;
                totalRows++;
            }

            // The rows already pulled for width measurement, then the rest of the source.
            foreach (var values in sample)
                WriteRow(values);

            while (await rowEnumerator.MoveNextAsync())
            {
                ct.ThrowIfCancellationRequested();
                WriteRow(rowEnumerator.Current);

                if (onRowsProgress is not null && totalRows % 10_000 == 0)
                    await onRowsProgress(totalRows);
            }

            if (totalRows == 0)
            {
                OpenBucket();
                writer!.WriteStartElement(new Row { RowIndex = excelRow });
                WriteInline(writer, $"{colRefs[0]}{excelRow}", "No data available.");
                writer.WriteEndElement();
            }

            CloseBucket();

            // Merge bucket files into the main workbook (byte-copy worksheet parts).
            using (var main = SpreadsheetDocument.Open(workbookPath, isEditable: true, new OpenSettings { AutoSave = false }))
            {
                var mainWb = main.WorkbookPart!;
                var mainSheets = mainWb.Workbook.GetFirstChild<Sheets>()
                    ?? mainWb.Workbook.AppendChild(new Sheets());

                foreach (var (path, sheetName) in bucketFiles)
                {
                    using var src = SpreadsheetDocument.Open(path, isEditable: false);
                    var srcPart = src.WorkbookPart?.WorksheetParts.FirstOrDefault()
                        ?? throw new InvalidOperationException($"Bucket {path} has no worksheet.");
                    var dstPart = mainWb.AddNewPart<WorksheetPart>();
                    using (var inStream = srcPart.GetStream(FileMode.Open, FileAccess.Read))
                    using (var outStream = dstPart.GetStream(FileMode.Create, FileAccess.Write))
                        inStream.CopyTo(outStream);

                    var relId = mainWb.GetIdOfPart(dstPart);
                    var sheetId = (uint)(mainSheets.Elements<Sheet>().Count() + 1);
                    mainSheets.Append(new Sheet { Id = relId, SheetId = sheetId, Name = sheetName });
                }

                mainWb.Workbook.Save();
            }
        }
        finally
        {
            writer?.Dispose();
            bucketDoc?.Dispose();
            try { if (Directory.Exists(tempFolder)) Directory.Delete(tempFolder, recursive: true); }
            catch { /* best effort */ }
        }

        if (onRowsProgress is not null)
            await onRowsProgress(totalRows);

        return totalRows;
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// <summary>Rows buffered to size the columns before <c>&lt;sheetData&gt;</c> is opened.</summary>
    private const int WidthSampleRows = 200;

    private const double MinColumnWidth = 12;
    private const double MaxColumnWidth = 42;

    /// <summary>Accent 6 Darker 25 % (#548235) — the same green ExcelTheme.HeaderBg uses.</summary>
    private const string HeaderGreenArgb = "FF548235";

    /// <summary>
    /// Content-fitted width per column, clamped so nothing is clipped and no free-text column
    /// runs off the screen. Approximates Excel's character-width unit from the longest sampled
    /// value, which is all AdjustToContents does — and unlike it, costs nothing on a huge sheet.
    /// </summary>
    private static double[] MeasureColumnWidths(string[] headers, List<object?[]> sample)
    {
        var widths = new double[headers.Length];
        for (var c = 0; c < headers.Length; c++)
            widths[c] = headers[c].Length;

        foreach (var row in sample)
        {
            for (var c = 0; c < headers.Length && c < row.Length; c++)
            {
                var text = row[c] switch
                {
                    null => null,
                    string s => s,
                    DateTime => "0000-00-00",
                    _ => Convert.ToString(row[c], CultureInfo.InvariantCulture),
                };
                if (text is null) continue;
                if (text.Length > widths[c]) widths[c] = text.Length;
            }
        }

        for (var c = 0; c < widths.Length; c++)
            widths[c] = Math.Clamp(widths[c] + 2, MinColumnWidth, MaxColumnWidth);

        return widths;
    }

    private static Columns BuildColumnsElement(double[] widths)
    {
        var cols = new Columns();
        for (var c = 0; c < widths.Length; c++)
        {
            cols.Append(new Column
            {
                Min = (uint)(c + 1),
                Max = (uint)(c + 1),
                Width = widths[c],
                CustomWidth = true,
            });
        }
        return cols;
    }

    /// <summary>
    /// Appends a bold-white-on-green cell format to the workbook's existing (ClosedXML-built)
    /// stylesheet and returns its index. Returns 0 — the default format — when the workbook has
    /// no stylesheet, so a styling problem can never fail the export itself.
    /// </summary>
    private static uint EnsureGreenHeaderStyle(string workbookPath)
    {
        try
        {
            using var doc = SpreadsheetDocument.Open(workbookPath, isEditable: true);
            var stylesPart = doc.WorkbookPart?.WorkbookStylesPart;
            var stylesheet = stylesPart?.Stylesheet;
            if (stylesheet is null) return 0;

            stylesheet.Fonts ??= new Fonts();
            // CT_Font is an ORDERED sequence — b, sz, color, name. Out-of-order children make
            // the part schema-invalid and Excel offers to "repair" the workbook on open.
            stylesheet.Fonts.Append(new Font(
                new Bold(),
                new FontSize { Val = 10D },
                new Color { Rgb = "FFFFFFFF" },
                new FontName { Val = "Calibri" }));
            stylesheet.Fonts.Count = (uint)stylesheet.Fonts.ChildElements.Count;
            var fontId = (uint)(stylesheet.Fonts.ChildElements.Count - 1);

            stylesheet.Fills ??= new Fills();
            stylesheet.Fills.Append(new Fill(new PatternFill
            {
                PatternType = PatternValues.Solid,
                ForegroundColor = new ForegroundColor { Rgb = HeaderGreenArgb },
                BackgroundColor = new BackgroundColor { Indexed = 64U },
            }));
            stylesheet.Fills.Count = (uint)stylesheet.Fills.ChildElements.Count;
            var fillId = (uint)(stylesheet.Fills.ChildElements.Count - 1);

            stylesheet.CellFormats ??= new CellFormats();
            stylesheet.CellFormats.Append(new CellFormat
            {
                FontId = fontId,
                FillId = fillId,
                BorderId = 0U,
                ApplyFont = true,
                ApplyFill = true,
                ApplyAlignment = true,
                Alignment = new Alignment
                {
                    Horizontal = HorizontalAlignmentValues.Center,
                    Vertical = VerticalAlignmentValues.Center,
                },
            });
            stylesheet.CellFormats.Count = (uint)stylesheet.CellFormats.ChildElements.Count;
            var styleIndex = (uint)(stylesheet.CellFormats.ChildElements.Count - 1);

            stylesheet.Save();
            return styleIndex;
        }
        catch
        {
            // Unstyled header beats no report.
            return 0;
        }
    }

    private static List<ColumnMap> BuildColumns(SqlDataReader reader, HashSet<string>? excludedColumns)
    {
        var list = new List<ColumnMap>(reader.FieldCount);
        for (var i = 0; i < reader.FieldCount; i++)
        {
            var name = reader.GetName(i);
            if (name.StartsWith("__", StringComparison.Ordinal)) continue;
            if (excludedColumns is not null && excludedColumns.Contains(name)) continue;
            list.Add(new ColumnMap(i, name, IcdCellSplitter.IsIcdColumn(name)));
        }
        return list;
    }

    /// <summary>
    /// Builds the header row. Overflow columns <c>{Name}_1</c>… are appended only when
    /// <paramref name="icdExtraParts"/>[i] &gt; 0 — never pre-allocated for every ICD column.
    /// </summary>
    private static string[] BuildHeaders(
        List<ColumnMap> columns,
        bool splitIcd,
        IReadOnlyList<int>? icdExtraParts,
        out Dictionary<int, int> overflowStarts)
    {
        overflowStarts = new Dictionary<int, int>();
        var headers = new List<string>(columns.Count);
        foreach (var c in columns)
            headers.Add(c.Name);

        if (!splitIcd || icdExtraParts is null)
            return headers.ToArray();

        for (var i = 0; i < columns.Count; i++)
        {
            if (!columns[i].IsIcd) continue;
            var extras = i < icdExtraParts.Count ? icdExtraParts[i] : 0;
            if (extras <= 0) continue;
            overflowStarts[i] = headers.Count;
            for (var k = 1; k <= extras; k++)
                headers.Add($"{columns[i].Name}_{k}");
        }

        return headers.ToArray();
    }

    private static string[] BuildColRefs(int count)
    {
        var refs = new string[count];
        for (var i = 0; i < count; i++)
            refs[i] = ColumnLetter(i + 1);
        return refs;
    }

    private static string MakeSheetName(string title, int sheetIndex, int expectedParts)
    {
        var baseName = title.Length <= 20 ? title.Replace(' ', '_') : "Data";
        var name = (expectedParts > 1 || sheetIndex > 1) ? $"{baseName}_P{sheetIndex}" : baseName;
        return name.Length <= 31 ? name : name[..31];
    }

    private static string UniqueSheetName(string desired, HashSet<string> used)
    {
        var name = desired.Length <= 31 ? desired : desired[..31];
        if (used.Add(name)) return name;
        for (var i = 2; i < 1000; i++)
        {
            var suffix = $"_{i}";
            var candidate = (desired.Length + suffix.Length <= 31 ? desired : desired[..(31 - suffix.Length)]) + suffix;
            if (used.Add(candidate)) return candidate;
        }
        var fallback = Guid.NewGuid().ToString("N")[..8];
        used.Add(fallback);
        return fallback;
    }

    private static string SanitizeFile(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        return string.Concat(name.Select(c => invalid.Contains(c) ? '_' : c));
    }

    private static string ColumnLetter(int col)
    {
        var sb = new StringBuilder();
        while (col > 0)
        {
            col--;
            sb.Insert(0, (char)('A' + col % 26));
            col /= 26;
        }
        return sb.ToString();
    }

    private static void WriteInline(OpenXmlWriter writer, string cellRef, string value, uint? styleIndex = null)
    {
        var cell = new Cell { CellReference = cellRef, DataType = CellValues.InlineString };
        if (styleIndex is > 0) cell.StyleIndex = styleIndex.Value;
        writer.WriteStartElement(cell);
        writer.WriteStartElement(new InlineString());
        writer.WriteElement(new Text(SanitizeXml(value)));
        writer.WriteEndElement();
        writer.WriteEndElement();
    }

    private static void WriteValue(OpenXmlWriter writer, string cellRef, object val)
    {
        switch (val)
        {
            case string s:
                WriteInline(writer, cellRef, s);
                break;
            case DateTime dt:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(dt.ToOADate().ToString(CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case DateTimeOffset dto:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(dto.DateTime.ToOADate().ToString(CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case decimal d:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(d.ToString(CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case double dbl:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(dbl.ToString("R", CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case float f:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(f.ToString("R", CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case int i:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(i.ToString(CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case long l:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(l.ToString(CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case short sh:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(sh.ToString(CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case byte b:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(b.ToString(CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case bool bo:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Boolean });
                writer.WriteElement(new CellValue(bo ? "1" : "0"));
                writer.WriteEndElement();
                break;
            case Guid g:
                WriteInline(writer, cellRef, g.ToString());
                break;
            default:
                WriteInline(writer, cellRef, Convert.ToString(val, CultureInfo.InvariantCulture) ?? "");
                break;
        }
    }

    private static string SanitizeXml(string? value)
    {
        if (string.IsNullOrEmpty(value)) return string.Empty;
        int i = 0;
        for (; i < value.Length; i++)
        {
            if (!IsLegalXmlChar(value[i])) break;
        }
        if (i == value.Length) return value;

        var sb = new StringBuilder(value.Length);
        if (i > 0) sb.Append(value, 0, i);
        for (; i < value.Length; i++)
        {
            if (IsLegalXmlChar(value[i])) sb.Append(value[i]);
        }
        return sb.ToString();
    }

    private static bool IsLegalXmlChar(char c) =>
        c == 0x09 || c == 0x0A || c == 0x0D ||
        (c >= 0x20 && c <= 0xD7FF) ||
        (c >= 0xE000 && c <= 0xFFFD);
}
