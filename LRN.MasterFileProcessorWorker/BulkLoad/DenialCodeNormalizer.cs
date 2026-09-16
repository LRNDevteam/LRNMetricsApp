using System.Text;
using System.Text.RegularExpressions;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>
/// Turns a raw claim-level denial code into the common code it rolls up to, and formats the
/// description that goes with it.
///
/// <para><b>Why normalize at all.</b> A denial code arrives carrying its claim adjustment group:
/// CO10, PR10 and PI10 are the same denial reported against contractual obligation, patient
/// responsibility and payer initiated reduction. LRNMaster.DenialMapperSuperMaster stores the
/// prefixed forms - it has CO10, PR10 and PI10 but no bare "10" - and all three carry the same
/// description. Stripping the prefix groups them under one number, so one claim-level row can say
/// "10" once and carry one description, and every downstream summary counts the three variants as
/// one denial instead of three.</para>
///
/// <para><b>Multi-code claims.</b> A claim-level denial cell routinely holds several codes
/// ("CO10, CO189"). Both halves are kept: the normalized column lists every code ("10, 189") and
/// the description column pairs each code with its own description ("10 - ...; 189 - ...") so the
/// codes and the descriptions stay readable against each other.</para>
///
/// <para>This duplicates <c>LabMetricsDashboard.Services.DenialCodeKey</c> on purpose. Workers in
/// this repo are self-contained and take no project reference on the web apps; the rule is small
/// enough that a shared assembly would cost more than the duplication.</para>
/// </summary>
public static class DenialCodeNormalizer
{
    /// <summary>Claim adjustment group codes that prefix a denial code without changing which denial it is.</summary>
    private static readonly Regex PrefixedNumeric = new(
        @"^(CO|PI|PR|OA|CR)[\s\-]?(\d+[A-Za-z]?)$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>
    /// What separates one code from the next inside a single cell.
    /// <para>A bare space is deliberately NOT a separator: "CO 45" is one code written loosely, and
    /// splitting on space would turn it into "CO" and "45". A hyphen is not one either, for the same
    /// reason - "CO-45".</para>
    /// </summary>
    private static readonly char[] Separators = [',', ';', '|', '/', '\n', '\r', '\t'];

    /// <summary>Joins the normalized codes in the NormalizedDenialCode column.</summary>
    private const string CodeSeparator = ", ";

    /// <summary>
    /// Joins the code/description pairs in the DenialDescription column. Semicolon rather than comma
    /// because descriptions contain commas of their own.
    /// </summary>
    private const string DescriptionSeparator = "; ";

    /// <summary>
    /// The individual codes inside one denial cell, trimmed, blanks dropped, original order kept.
    /// Duplicates within the cell are collapsed - "CO45, PR45" is one denial, twice reported.
    /// </summary>
    public static IReadOnlyList<string> Split(string? rawDenialCode)
    {
        var raw = (rawDenialCode ?? string.Empty).Trim();
        if (raw.Length == 0) return Array.Empty<string>();

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var codes = new List<string>();

        foreach (var part in raw.Split(Separators, StringSplitOptions.RemoveEmptyEntries))
        {
            var code = part.Trim();
            if (code.Length > 0 && seen.Add(code))
                codes.Add(code);
        }

        return codes;
    }

    /// <summary>
    /// The common code one raw code rolls up to: "CO45", "CO-45", "PI 45", "PR45" -> "45".
    /// A code that carries no group prefix ("MA130", "N130") is trimmed and upper-cased only -
    /// guessing at it would invent a grouping the master table does not have.
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

    /// <summary>
    /// Every code in the cell, normalized and de-duplicated: "CO10, CO189" -> "10, 189",
    /// "CO45, PR45" -> "45". Null when the cell holds no code.
    /// </summary>
    public static string? NormalizeAll(string? rawDenialCode)
    {
        var normalized = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var code in Split(rawDenialCode))
        {
            var key = Normalize(code);
            if (key.Length > 0 && seen.Add(key))
                normalized.Add(key);
        }

        return normalized.Count == 0 ? null : string.Join(CodeSeparator, normalized);
    }

    /// <summary>
    /// The description for every code in the cell, each prefixed by the common code it belongs to:
    /// "10 - Description of 10; 189 - Description of 189".
    /// </summary>
    /// <param name="lookup">The four-step description cascade - see <see cref="DenialDescriptionLookup"/>.</param>
    /// <param name="unresolved">Collects codes neither master had a description for.</param>
    /// <remarks>
    /// A code with no description anywhere is left out of the text rather than written as an empty
    /// pair, so the column stays readable on screen. The gap is not swallowed: every unresolved code
    /// is reported through <paramref name="unresolved"/> and logged by the caller, and the Denial
    /// Database worker already raises the missing-code notification for the same condition.
    /// </remarks>
    public static string? DescribeAll(
        string? rawDenialCode,
        DenialDescriptionLookup lookup,
        ICollection<string>? unresolved = null)
    {
        var builder = new StringBuilder();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var code in Split(rawDenialCode))
        {
            var key = Normalize(code);
            if (key.Length == 0 || !seen.Add(key)) continue;

            // Resolved from the RAW code first, so a master row that exists only under the
            // prefixed spelling still wins before the normalized fallback is tried.
            var description = lookup.Resolve(code);

            if (string.IsNullOrWhiteSpace(description))
            {
                unresolved?.Add(key);
                continue;
            }

            if (builder.Length > 0) builder.Append(DescriptionSeparator);
            builder.Append(key).Append(" - ").Append(description.Trim());
        }

        return builder.Length == 0 ? null : builder.ToString();
    }
}

/// <summary>
/// The denial description cascade, in the order the requirements define it.
///
/// <list type="number">
///   <item>The lab's own Denial-Action master (<c>dbo.DenialCodeMaster</c>) matched on the RAW code.</item>
///   <item>The Denial-Action Super Master (<c>LRNMaster.dbo.DenialMapperSuperMaster</c>), RAW code.</item>
///   <item>The lab's Denial-Action master matched on the NORMALIZED code.</item>
///   <item>The Super Master, normalized code.</item>
/// </list>
///
/// <para>The lab's own table outranks the Super Master at both steps because a lab that has
/// customised a description means it; the raw code outranks the normalized one because it is the
/// more specific match, and falling back to the normalized code is what lets a claim carrying
/// CO10 pick up a description the master stores only under PR10.</para>
/// </summary>
public sealed class DenialDescriptionLookup
{
    private readonly Dictionary<string, string> _labByRaw = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _labByNormalized = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _superByRaw = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _superByNormalized = new(StringComparer.OrdinalIgnoreCase);

    public int LabCodeCount => _labByRaw.Count;
    public int SuperCodeCount => _superByRaw.Count;
    public bool IsEmpty => _labByRaw.Count == 0 && _superByRaw.Count == 0;

    /// <summary>Adds one row of the lab's own Denial-Action master.</summary>
    public void AddLab(string? denialCode, string? description) =>
        Add(_labByRaw, _labByNormalized, denialCode, description);

    /// <summary>Adds one row of the Denial-Action Super Master.</summary>
    public void AddSuper(string? denialCode, string? description) =>
        Add(_superByRaw, _superByNormalized, denialCode, description);

    private static void Add(
        Dictionary<string, string> byRaw,
        Dictionary<string, string> byNormalized,
        string? denialCode,
        string? description)
    {
        var code = (denialCode ?? string.Empty).Trim();
        if (code.Length == 0 || string.IsNullOrWhiteSpace(description)) return;

        var text = description.Trim();
        byRaw.TryAdd(code, text);

        // CO10, PR10 and PI10 all collapse onto "10" here. They carry the same description, so the
        // first one read wins and which one that was does not matter.
        var normalized = DenialCodeNormalizer.Normalize(code);
        if (normalized.Length > 0) byNormalized.TryAdd(normalized, text);
    }

    /// <summary>The description for one raw code, or null when no master has one.</summary>
    public string? Resolve(string? rawDenialCode)
    {
        var raw = (rawDenialCode ?? string.Empty).Trim();
        if (raw.Length == 0) return null;

        if (_labByRaw.TryGetValue(raw, out var labRaw)) return labRaw;
        if (_superByRaw.TryGetValue(raw, out var superRaw)) return superRaw;

        var normalized = DenialCodeNormalizer.Normalize(raw);
        if (normalized.Length == 0) return null;

        if (_labByNormalized.TryGetValue(normalized, out var labNormalized)) return labNormalized;
        if (_superByNormalized.TryGetValue(normalized, out var superNormalized)) return superNormalized;

        return null;
    }
}
