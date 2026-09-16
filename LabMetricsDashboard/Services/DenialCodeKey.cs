using System.Text.RegularExpressions;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Denial code normalization for the Denial Claim Report.
///
/// CO45, PI45 and PR45 are the same denial reported under different claim adjustment groups, so
/// they roll up to one common code, 45. Normalizing is what makes a summary row, an insight row and
/// a drill-through filter agree on which claims belong together - a drill-through that matched the
/// raw code would return only a third of its own population.
///
/// The group prefix is the only thing stripped. A code that is not prefixed (or is alphabetic
/// throughout, e.g. "MA130") is left alone rather than guessed at.
/// </summary>
public static class DenialCodeKey
{
    /// <summary>Claim adjustment group codes that prefix a denial code without changing which denial it is.</summary>
    private static readonly string[] GroupPrefixes = ["CO", "PI", "PR", "OA", "CR"];

    /// <summary>
    /// A denial code carrying a group prefix. The tail is <c>[A-Z]{0,2}</c> then digits, not digits
    /// alone, because remark codes are not numeric: "COM127" is CO + M127, and matching only a
    /// numeric tail left it unstripped. At least one digit is required, so a word that merely starts
    /// with a prefix ("CORE") is left alone.
    /// <para>Kept in step with <c>LRN.MasterFileProcessorWorker.BulkLoad.DenialCodeNormalizer</c>,
    /// which applies the same rule when it writes DenialCodeNormalized during the import.</para>
    /// </summary>
    private static readonly Regex PrefixedNumeric = new(@"^(CO|PI|PR|OA|CR)[\s\-]?([A-Z]{0,2}\d+[A-Za-z]?)$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>
    /// The common code a raw denial code rolls up to: "CO-45", "CO45", "PI45", "PR 45" -> "45".
    /// Anything that is not a group-prefixed numeric code comes back trimmed and upper-cased only.
    /// </summary>
    public static string Normalize(string? denialCode)
    {
        var raw = (denialCode ?? string.Empty).Trim();
        if (raw.Length == 0) return string.Empty;

        var match = PrefixedNumeric.Match(raw);
        return match.Success
            ? match.Groups[2].Value.ToUpperInvariant()
            : raw.ToUpperInvariant();
    }

    /// <summary>True when the raw code carries a claim adjustment group prefix.</summary>
    public static bool HasGroupPrefix(string? denialCode) =>
        !string.IsNullOrWhiteSpace(denialCode) && PrefixedNumeric.IsMatch(denialCode.Trim());

    /// <summary>
    /// Payer key for drill-through. Display names drift ("UHC", "U H C", "UnitedHealthcare "), so the
    /// filter matches on a stripped, upper-cased form and the screen still shows the original name.
    /// </summary>
    public static string NormalizePayer(string? payerName) =>
        new((payerName ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

    /// <summary>The group prefixes, for callers building an "any of these" match on a raw code column.</summary>
    public static IReadOnlyList<string> Prefixes => GroupPrefixes;
}
