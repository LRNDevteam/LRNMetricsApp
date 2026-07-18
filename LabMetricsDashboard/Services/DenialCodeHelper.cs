using System.Text.RegularExpressions;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Splits DenialCode values that contain multiple codes (comma / semicolon / etc.)
/// and helpers for joining per-code descriptions.
/// </summary>
public static partial class DenialCodeHelper
{
    /// <summary>
    /// Splits "CO-18, CO-204" / "CO-11;CO-147" into individual codes.
    /// Does not treat hyphen inside CO-18 as a separator.
    /// Also strips labels like "Denial Code:", "Denial Code =".
    /// </summary>
    public static string[] SplitCodes(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
            return [];

        // Normalize whitespace (incl. NBSP) so "CO-18, CO-204" always splits cleanly
        var cleaned = NormalizeDisplayCode(
            raw.Replace('\u00A0', ' ').Replace('\u2007', ' ').Replace('\u202F', ' '));
        if (string.IsNullOrWhiteSpace(cleaned))
            return [];

        // Split ONLY on comma / semicolon (and unicode comma variants).
        // Do NOT split on "/" — codes like N56/16 must stay intact.
        var parts = CodeSeparatorRegex()
            .Split(cleaned)
            .Select(p => p.Trim())
            .Where(c => !string.IsNullOrWhiteSpace(c))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        // Fallback: extract denial-like tokens when separator was unusual
        // e.g. "CO-18 and CO-204" or "CO-18  CO-204"
        if (parts.Length <= 1)
        {
            var matches = DenialTokenRegex().Matches(cleaned);
            if (matches.Count > 1)
            {
                parts = matches
                    .Select(m => m.Value.Trim())
                    .Where(c => !string.IsNullOrWhiteSpace(c))
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToArray();
            }
        }

        return parts.Length > 0 ? parts : [cleaned];
    }

    /// <summary>
    /// Removes prefixes such as "Denial Code:", "Denial Code =" so only the code remains (e.g. CO-16).
    /// Does not strip internal hyphens (keeps CO-18 intact).
    /// </summary>
    public static string NormalizeDisplayCode(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
            return string.Empty;

        var s = raw.Trim();

        string[] prefixes =
        [
            "Denial Code:",
            "Denial Code =",
            "Denial Code=",
            "Denial Code -",
            "Denial Code –",
            "Denial Code—",
            "DenialCode:",
            "DenialCode =",
            "DenialCode=",
            "Denial Code"
        ];

        foreach (var prefix in prefixes)
        {
            if (s.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                s = s[prefix.Length..].Trim();
                break;
            }
        }

        // Trim label punctuation only — do NOT remove hyphen (needed for CO-18)
        return s.Trim().Trim(':', '=', ' ', '\t');
    }

    /// <summary>
    /// Splits a joined description produced by enrichment ("desc A, desc B" or legacy "desc A | desc B").
    /// </summary>
    public static string[] SplitJoinedDescriptions(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
            return [];

        if (raw.Contains(" | ", StringComparison.Ordinal))
        {
            return raw
                .Split([" | ", "|"], StringSplitOptions.TrimEntries)
                .Select(d => d.Trim())
                .ToArray();
        }

        // Joined master descriptions use ", " — only split when that pattern was used by enrichment.
        // Do not split arbitrary commas inside a single denial description sentence.
        return [raw.Trim()];
    }

    public static string JoinDescriptions(IEnumerable<string?> descriptions) =>
        string.Join(", ", descriptions
            .Select(d => (d ?? string.Empty).Trim())
            .Where(d => d.Length > 0));

    // ASCII , ; plus fullwidth/Arabic comma/semicolon. Do NOT include "/" (N56/16).
    [GeneratedRegex(@"\s*[,;\uFF0C\u060C\u061B]+\s*", RegexOptions.CultureInvariant)]
    private static partial Regex CodeSeparatorRegex();

    // Matches typical denial codes including slash forms: CO-18, CO18, N56/16
    [GeneratedRegex(@"\b[A-Za-z]{1,5}-?\d{1,5}(?:/\d{1,5})?[A-Za-z]?\b", RegexOptions.CultureInvariant)]
    private static partial Regex DenialTokenRegex();
}
