using System.Globalization;
using System.Text;
using ExcelDataReader;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads a fee schedule file for the "Fees Schedule Import" screen: the Medicare Clinical Laboratory
/// Fee Schedule as CMS publishes it (docs/ClinicalLaboratoryFeeSchedule_2026_Q1V1.xls - a legacy
/// .xls), or the same columns as .xlsx or .csv.
/// <list type="bullet">
///   <item>Mandatory columns: <b>HCPCS</b> (the CPT code on the claim lines) and <b>RATE</b>.</item>
///   <item>Optional: MOD, YEAR, EFF_DATE (yyyyMMdd or a date), INDICATOR, SHORTDESC.</item>
/// </list>
/// The header row is found by name within the first rows of the first sheet that has both mandatory
/// columns, so a title row above it is fine. Header matching ignores case, spaces and underscores.
/// <para>One row per HCPCS is kept: the CLFS lists some codes again with modifier QW at the same rate.
/// The row without a modifier wins, else the first one read.</para>
/// </summary>
public static class FeeScheduleWorkbook
{
    private const int HeaderSearchRows = 25;
    public const int MaxHcpcsLength = 20;

    private static readonly string[] HcpcsHeaders = ["HCPCS", "HCPCSCODE", "CPT", "CPTCODE"];
    private static readonly string[] RateHeaders = ["RATE", "FEE", "AMOUNT", "PAYMENTRATE"];

    static FeeScheduleWorkbook()
    {
        // .xls (BIFF8) stores text in Windows code pages, which .NET only knows once registered.
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    }

    public static FeeScheduleFileImport Read(Stream stream, string fileName)
    {
        var isCsv = string.Equals(Path.GetExtension(fileName), ".csv", StringComparison.OrdinalIgnoreCase);
        using var reader = isCsv ? ExcelReaderFactory.CreateCsvReader(stream) : ExcelReaderFactory.CreateReader(stream);

        do
        {
            var rows = new List<object?[]>();
            while (reader.Read())
            {
                var values = new object?[reader.FieldCount];
                for (var i = 0; i < reader.FieldCount; i++) values[i] = reader.GetValue(i);
                rows.Add(values);
            }

            var parsed = ReadSheet(rows, isCsv ? null : reader.Name);
            if (parsed is not null) return parsed;
        } while (reader.NextResult());

        return new FeeScheduleFileImport
        {
            Error = "No sheet in the file has both an HCPCS column and a RATE column. Nothing was imported."
        };
    }

    /// <summary>Null when this sheet has no HCPCS + RATE header row.</summary>
    internal static FeeScheduleFileImport? ReadSheet(IReadOnlyList<object?[]> rows, string? sheetName)
    {
        int headerIndex = -1, hcpcsCol = -1, rateCol = -1;
        var columns = new Dictionary<string, int>(StringComparer.Ordinal);

        for (var r = 0; r < Math.Min(rows.Count, HeaderSearchRows) && headerIndex < 0; r++)
        {
            var names = rows[r].Select(v => NormalizeHeader(Text(v))).ToArray();
            var h = Array.FindIndex(names, n => HcpcsHeaders.Contains(n));
            var rt = Array.FindIndex(names, n => RateHeaders.Contains(n));
            if (h < 0 || rt < 0) continue;

            headerIndex = r;
            hcpcsCol = h;
            rateCol = rt;
            for (var i = 0; i < names.Length; i++)
                if (names[i].Length > 0) columns.TryAdd(names[i], i);
        }

        if (headerIndex < 0) return null;

        int Col(params string[] names) => names.Select(n => columns.TryGetValue(n, out var i) ? i : -1).FirstOrDefault(i => i >= 0, -1);
        var modCol = Col("MOD", "MODIFIER");
        var yearCol = Col("YEAR");
        var effCol = Col("EFFDATE", "EFFECTIVEDATE");
        var indCol = Col("INDICATOR");
        var descCol = Col("SHORTDESC", "SHORTDESCRIPTION", "DESCRIPTION");

        var kept = new Dictionary<string, (FeeScheduleImportRow Row, bool HasModifier, int Order)>(StringComparer.OrdinalIgnoreCase);
        var conflicts = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        var invalid = new List<string>();
        int duplicates = 0, blank = 0;

        for (var r = headerIndex + 1; r < rows.Count; r++)
        {
            var row = rows[r];
            var hcpcs = Code(Cell(row, hcpcsCol));
            if (hcpcs.Length == 0)
            {
                // A fully empty row (e.g. trailing rows) is not worth reporting.
                if (row.Any(v => Text(v).Length > 0)) blank++;
                continue;
            }

            var rateCell = Cell(row, rateCol);
            if (hcpcs.Length > MaxHcpcsLength || !TryRate(rateCell, out var rate))
            {
                invalid.Add($"{(hcpcs.Length > 40 ? hcpcs[..40] + "..." : hcpcs)} (row {r + 1}): {(hcpcs.Length > MaxHcpcsLength ? "code too long" : Text(rateCell) is { Length: > 0 } t ? t : "no rate")}");
                continue;
            }

            var modifier = Optional(Cell(row, modCol), 20);
            var item = new FeeScheduleImportRow(
                hcpcs,
                rate,
                modifier,
                Year(Cell(row, yearCol)),
                Date(Cell(row, effCol)),
                Optional(Cell(row, indCol), 10),
                Optional(Cell(row, descCol), 300));

            if (kept.TryGetValue(hcpcs, out var existing))
            {
                duplicates++;
                if (existing.Row.Rate != rate) conflicts.Add(hcpcs);
                // The base (no modifier) row is the code's own rate.
                if (existing.HasModifier && modifier is null)
                    kept[hcpcs] = (item, false, existing.Order);
                continue;
            }

            kept[hcpcs] = (item, modifier is not null, kept.Count);
        }

        return new FeeScheduleFileImport
        {
            SheetName = sheetName,
            Rows = kept.Values.OrderBy(v => v.Order).Select(v => v.Row).ToList(),
            DuplicateRows = duplicates,
            ConflictingRates = conflicts.ToList(),
            BlankHcpcsRows = blank,
            InvalidRates = invalid,
            Error = kept.Count == 0 ? "The file has the HCPCS and RATE columns but no rows with a code and a valid rate. Nothing was imported." : null
        };
    }

    private static object? Cell(object?[] row, int index) => index >= 0 && index < row.Length ? row[index] : null;

    private static string NormalizeHeader(string value)
        => new string(value.Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

    /// <summary>Text of a cell; a whole number read as a double (80053 in .xls) has no ".0".</summary>
    internal static string Text(object? value) => value switch
    {
        null or DBNull => string.Empty,
        double d when d == Math.Floor(d) && Math.Abs(d) < 1e15 => ((long)d).ToString(CultureInfo.InvariantCulture),
        double d => d.ToString(CultureInfo.InvariantCulture),
        DateTime dt => dt.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        _ => Convert.ToString(value, CultureInfo.InvariantCulture)?.Trim() ?? string.Empty
    };

    internal static string Code(object? value) => Text(value).Trim().ToUpperInvariant();

    private static string? Optional(object? value, int max)
    {
        var text = Text(value);
        return text.Length == 0 ? null : text.Length <= max ? text : text[..max];
    }

    internal static bool TryRate(object? value, out decimal rate)
    {
        rate = 0;
        switch (value)
        {
            case double d when !double.IsNaN(d) && !double.IsInfinity(d) && d >= 0 && d < 1e12:
                rate = Math.Round((decimal)d, 2, MidpointRounding.AwayFromZero);
                return true;
            case decimal m when m >= 0:
                rate = Math.Round(m, 2, MidpointRounding.AwayFromZero);
                return true;
            case string s:
                var cleaned = s.Trim().Replace("$", string.Empty).Replace(",", string.Empty);
                if (decimal.TryParse(cleaned, NumberStyles.Number, CultureInfo.InvariantCulture, out var parsed) && parsed >= 0)
                {
                    rate = Math.Round(parsed, 2, MidpointRounding.AwayFromZero);
                    return true;
                }
                return false;
            default:
                return false;
        }
    }

    private static int? Year(object? value)
        => int.TryParse(Text(value), NumberStyles.Integer, CultureInfo.InvariantCulture, out var y) && y is > 1900 and < 3000 ? y : null;

    /// <summary>The CLFS writes 20260101; a spreadsheet may hold a real date or "01/01/2026".</summary>
    internal static DateTime? Date(object? value)
    {
        if (value is DateTime dt) return dt.Date;
        var text = Text(value);
        if (text.Length == 0) return null;
        if (DateTime.TryParseExact(text, "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var compact)) return compact;
        return DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed) ? parsed.Date : null;
    }
}
