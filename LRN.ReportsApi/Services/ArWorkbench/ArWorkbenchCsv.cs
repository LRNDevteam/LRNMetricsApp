using System.Text;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Minimal RFC 4180 CSV for the client's CIP response template (T065): quoted fields, doubled
/// quotes, commas and line breaks inside quotes. Excel opens and saves it as-is.
/// </summary>
public static class ArWorkbenchCsv
{
    public static string Write(IReadOnlyList<string> headers, IEnumerable<IReadOnlyList<string?>> rows)
    {
        var sb = new StringBuilder();
        sb.AppendLine(string.Join(",", headers.Select(Escape)));
        foreach (var row in rows) sb.AppendLine(string.Join(",", row.Select(Escape)));
        return sb.ToString();
    }

    public static string Escape(string? value)
    {
        var v = value ?? string.Empty;
        // A leading = + - @ would run as a formula in Excel: neutralise it (CSV injection).
        if (v.Length > 0 && "=+-@".Contains(v[0])) v = "'" + v;
        return v.IndexOfAny([',', '"', '\r', '\n']) >= 0 ? $"\"{v.Replace("\"", "\"\"")}\"" : v;
    }

    public static List<List<string>> Parse(string text)
    {
        var rows = new List<List<string>>();
        var row = new List<string>();
        var field = new StringBuilder();
        var quoted = false;
        var start = text.Length > 0 && text[0] == '﻿' ? 1 : 0;
        for (var i = start; i < text.Length; i++)
        {
            var ch = text[i];
            if (quoted)
            {
                if (ch == '"')
                {
                    if (i + 1 < text.Length && text[i + 1] == '"') { field.Append('"'); i++; }
                    else quoted = false;
                }
                else field.Append(ch);
                continue;
            }
            switch (ch)
            {
                case '"': quoted = true; break;
                case ',': row.Add(field.ToString()); field.Clear(); break;
                case '\r': break;
                case '\n': row.Add(field.ToString()); field.Clear(); rows.Add(row); row = new List<string>(); break;
                default: field.Append(ch); break;
            }
        }
        if (field.Length > 0 || row.Count > 0) { row.Add(field.ToString()); rows.Add(row); }
        return rows;
    }
}
