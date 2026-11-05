using System.Data;
using System.Globalization;
using System.Text;

namespace LabMetricsDashboard.Services;

/// <summary>
/// CSV download of the Executive Summary value popup for cells with more than <see cref="RowThreshold"/> rows.
/// The .xlsx writer keeps a whole worksheet in memory, which passes the 2 GB stream limit around 450,000 rows;
/// CSV streams straight from the data reader to the output, so any row count works.
/// One header line, then one line per source row (the Excel download's "Rows" sheet).
/// </summary>
public static class ExecSummaryCellRowsCsvBuilder
{
    /// <summary>Cells with more rows than this download as CSV instead of Excel.</summary>
    public const int RowThreshold = 200_000;

    /// <param name="output">Writable stream; left open.</param>
    /// <param name="rows">Result set 3 of usp_Get{prefix}_ExecutiveSummaryCellRows, positioned before its first row.</param>
    /// <param name="onRows">Rows written so far: every 1,000 rows and once at the end.</param>
    public static void Write(Stream output, IDataReader rows, Action<int>? onRows = null)
    {
        // Formula breakdown flags, not data (as in the Excel download).
        var cols = Enumerable.Range(0, rows.FieldCount)
            .Where(c => !rows.GetName(c).Equals("IsMoney", StringComparison.OrdinalIgnoreCase)
                     && !rows.GetName(c).Equals("IsTotal", StringComparison.OrdinalIgnoreCase))
            .ToList();

        // UTF-8 with BOM so Excel reads names with accents correctly.
        using var w = new StreamWriter(output, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true), 1 << 16, leaveOpen: true);
        w.NewLine = "\r\n";

        for (var k = 0; k < cols.Count; k++)
        {
            if (k > 0) w.Write(',');
            WriteField(w, rows.GetName(cols[k]));
        }
        w.WriteLine();

        var written = 0;
        while (rows.Read())
        {
            for (var k = 0; k < cols.Count; k++)
            {
                if (k > 0) w.Write(',');
                var c = cols[k];
                if (rows.IsDBNull(c)) continue;
                switch (rows.GetValue(c))
                {
                    case decimal or double or float or int or long or short or byte:
                        w.Write(Convert.ToDecimal(rows.GetValue(c), CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture));
                        break;
                    case DateTime d:
                        w.Write(d.ToString("MM/dd/yyyy", CultureInfo.InvariantCulture));
                        break;
                    case bool b:
                        w.Write(b ? "TRUE" : "FALSE");
                        break;
                    case var v:
                        WriteField(w, Convert.ToString(v, CultureInfo.InvariantCulture) ?? string.Empty);
                        break;
                }
            }
            w.WriteLine();
            if (++written % 1000 == 0) onRows?.Invoke(written);
        }
        w.Flush();
        onRows?.Invoke(written);
    }

    // Quotes fields with a comma, quote or line break; text starting with = + - @ gets a leading '
    // so Excel shows it as text instead of running it as a formula.
    private static void WriteField(TextWriter w, string text)
    {
        if (text.Length > 0 && text[0] is '=' or '+' or '-' or '@' or '\t' or '\r')
            text = "'" + text;
        if (text.IndexOfAny([',', '"', '\r', '\n']) < 0)
        {
            w.Write(text);
            return;
        }
        w.Write('"');
        w.Write(text.Replace("\"", "\"\""));
        w.Write('"');
    }
}
