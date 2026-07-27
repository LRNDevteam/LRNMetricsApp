namespace LabMetricsDashboard.Services;

/// <summary>
/// Helper for the Payer Policy Validation export: Excel cells can hold at most
/// 32,767 characters, but the ICD code-list columns (e.g.
/// <c>NonCoveredIcd10CodesAsPerPayerPolicy</c>) can far exceed that. When a value
/// overflows, it is split across the base column plus additional
/// <c>{ColumnName}_1</c>, <c>{ColumnName}_2</c>, … columns.
/// </summary>
internal static class IcdCellSplitter
{
    /// <summary>Excel's hard per-cell character limit.</summary>
    public const int MaxCellLength = 32_767;

    /// <summary>
    /// True when a column should be subject to ICD overflow splitting.
    /// Matches any header containing "Icd" (case-insensitive) — covers
    /// LISIcd10Codes, CCWIcd10Code, Covered/NonCovered Icd10 code lists, etc.,
    /// and auto-adapts to any future ICD column. Non-code ICD status fields are
    /// harmlessly included: the split only ever triggers past 32,767 chars.
    /// </summary>
    public static bool IsIcdColumn(string header) =>
        header.IndexOf("Icd", StringComparison.OrdinalIgnoreCase) >= 0;

    /// <summary>
    /// Splits <paramref name="value"/> into chunks that each fit within
    /// <see cref="MaxCellLength"/>. Breaks preferentially at a comma so an ICD
    /// code is never cut in half; falls back to a hard split only when a single
    /// run has no comma. Returns a single-element list when the value already fits.
    /// </summary>
    public static List<string> Split(string value)
    {
        var chunks = new List<string>();
        if (string.IsNullOrEmpty(value) || value.Length <= MaxCellLength)
        {
            chunks.Add(value ?? string.Empty);
            return chunks;
        }

        var start = 0;
        while (start < value.Length)
        {
            var remaining = value.Length - start;
            if (remaining <= MaxCellLength)
            {
                chunks.Add(value.Substring(start));
                break;
            }

            var hardEndExclusive = start + MaxCellLength;      // first index NOT allowed in this chunk
            var comma = value.LastIndexOf(',', hardEndExclusive - 1, MaxCellLength);
            var cut = comma >= start ? comma + 1 : hardEndExclusive; // keep the comma with this chunk
            if (cut <= start) cut = hardEndExclusive;               // safety: always make progress

            chunks.Add(value.Substring(start, cut - start));
            start = cut;
        }

        return chunks;
    }
}
