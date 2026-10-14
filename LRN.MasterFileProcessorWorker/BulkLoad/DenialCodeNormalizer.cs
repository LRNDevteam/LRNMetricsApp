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
/// ("CO10, CO189"). Both halves are kept: the normalized column lists every code ("10; 189") and
/// the description column lists each code's description in the same order, text only
/// ("Description of 10; Description of 189") - no code in front.</para>
///
/// <para>This duplicates <c>LabMetricsDashboard.Services.DenialCodeKey</c> on purpose. Workers in
/// this repo are self-contained and take no project reference on the web apps; the rule is small
/// enough that a shared assembly would cost more than the duplication.</para>
/// </summary>
public static class DenialCodeNormalizer
{
    /// <summary>
    /// A denial code carrying a claim adjustment group prefix, which strips to the code underneath.
    ///
    /// <para>The tail is <c>[A-Z]{0,2}</c> then digits, not digits alone, because the codes the
    /// group prefixes attach to are not all numeric. CARC codes are (45, 189), but remark codes are
    /// not: M127, MA130, N130, B9. "COM127" is CO + M127, and matching only a numeric tail left it
    /// unstripped, so it found no description - the master holds M127, never COM127.</para>
    ///
    /// <para>At least one digit is required, which is what keeps the rule safe: a word beginning
    /// with a prefix ("CORE") has no digits and is left alone.</para>
    ///
    /// <para>CO, PR, PI and OA are stripped, so OA97 reads as 97 and OAB11 as B11. Anything else
    /// (CR1, MA130) is kept as it is.</para>
    /// <para>Runs on the code with '-' and '.' already removed (see <see cref="Clean"/>).</para>
    /// </summary>
    private static readonly Regex PrefixedNumeric = new(
        @"^(CO|PI|PR|OA)\s?([A-Z]{0,2}\d+[A-Za-z]?)$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>
    /// "COA97" is an OA code with a stray C in front, so it strips like OA97, to "97".
    /// Checked before <see cref="PrefixedNumeric"/>, which would otherwise read it as CO + A97.
    /// </summary>
    private static readonly Regex CPrefixedOtherAdjustment = new(
        @"^C(OA)\s?(\d+[A-Za-z]?)$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>
    /// CO/PR/PI codes left out of the normalized and description columns entirely:
    /// CO1, CO2, CO3, CO253, CO45 and the same numbers under PR and PI. Only these exact codes -
    /// a bare "45", OA45 or CO45A is kept (OA45 normalizes to 45 but is not excluded).
    /// </summary>
    private static readonly HashSet<string> ExcludedPrefixedCodes =
        new(StringComparer.OrdinalIgnoreCase) { "1", "2", "3", "253", "45" };

    /// <summary>
    /// What separates one code from the next inside a single cell.
    /// <para>A bare space is deliberately NOT a separator: "CO 45" is one code written loosely, and
    /// splitting on space would turn it into "CO" and "45". A hyphen is not one either, for the same
    /// reason - "CO-45".</para>
    /// </summary>
    private static readonly char[] Separators = [',', ';', '|', '/', '\n', '\r', '\t'];

    /// <summary>Joins the normalized codes in the DenialCodeNormalized column.</summary>
    private const string CodeSeparator = "; ";

    /// <summary>
    /// Joins the descriptions (and the other derived values) of a multi-code cell. Semicolon rather
    /// than comma because descriptions contain commas of their own.
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
    /// The common code one raw code rolls up to: "CO97", "CO-97", "PI 97", "PR97", "OA97", "COA97"
    /// -> "97"; "OAB11" -> "B11"; "N-130", "N.130" -> "N130". '-' and '.' are removed everywhere in
    /// the code. A code with no CO/PR/PI/OA prefix ("MA130", "CR1") is otherwise trimmed and
    /// upper-cased only - guessing at it would invent a grouping the master table does not have.
    /// </summary>
    public static string Normalize(string? denialCode) => Strip(denialCode).Code;

    /// <summary>
    /// The OA form of a code that carried an OA group ("OA-97", "COA97" -> "OA97"), for the master
    /// lookup's second try when the normalized code has no entry; null for any other code.
    /// </summary>
    public static string? OaForm(string? denialCode)
    {
        var (code, _, isOa) = StripCore(denialCode);
        return isOa && code.Length > 0 ? "OA" + code : null;
    }

    /// <summary>
    /// The code with '-' and '.' removed, trimmed and upper-cased, prefix kept: "OA-97" -> "OA97",
    /// "M.127" -> "M127". The key the masters are stored under.
    /// </summary>
    public static string Clean(string? denialCode)
        => (denialCode ?? string.Empty).Replace("-", string.Empty).Replace(".", string.Empty).Trim().ToUpperInvariant();

    /// <summary>
    /// True for the CO/PR/PI codes that are dropped from the derived columns
    /// (see <see cref="ExcludedPrefixedCodes"/>).
    /// </summary>
    public static bool IsExcluded(string? denialCode) => Strip(denialCode).Excluded;

    private static (string Code, bool Excluded) Strip(string? denialCode)
    {
        var (code, excluded, _) = StripCore(denialCode);
        return (code, excluded);
    }

    private static (string Code, bool Excluded, bool IsOa) StripCore(string? denialCode)
    {
        var raw = Clean(denialCode);
        if (raw.Length == 0) return (string.Empty, false, false);

        var otherAdjustment = CPrefixedOtherAdjustment.Match(raw);
        if (otherAdjustment.Success)
            return (otherAdjustment.Groups[2].Value.ToUpperInvariant(), false, true);

        var match = PrefixedNumeric.Match(raw);
        if (!match.Success) return (raw, false, false);

        var code = match.Groups[2].Value.ToUpperInvariant();
        var isOa = match.Groups[1].Value.Equals("OA", StringComparison.OrdinalIgnoreCase);
        // The exclusion list is for CO/PR/PI only; OA45 is kept.
        return (code, !isOa && ExcludedPrefixedCodes.Contains(code), isOa);
    }

    /// <summary>
    /// Every code in the cell, normalized and de-duplicated, excluded codes dropped:
    /// "CO10, CO189" -> "10; 189", "CO97; COA97; PR243; PR45" -> "97; OA97; 243".
    /// Null when the cell holds no code that survives.
    /// </summary>
    public static string? NormalizeAll(string? rawDenialCode)
    {
        var normalized = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var code in Split(rawDenialCode))
        {
            var (key, excluded) = Strip(code);
            if (!excluded && key.Length > 0 && seen.Add(key))
                normalized.Add(key);
        }

        return normalized.Count == 0 ? null : string.Join(CodeSeparator, normalized);
    }

    /// <summary>
    /// The description of every code in the cell, the text alone - no code in front:
    /// "Description of 10; Description of 189".
    /// </summary>
    /// <param name="lookup">The description cascade - see <see cref="DenialDescriptionLookup"/>.</param>
    /// <param name="unresolved">Collects codes no master had a description for.</param>
    /// <remarks>
    /// A code with no description anywhere is left out of the text, so the column stays readable on
    /// screen. The gap is not swallowed: every unresolved code is reported through
    /// <paramref name="unresolved"/> and logged by the caller.
    /// </remarks>
    public static string? DescribeAll(
        string? rawDenialCode,
        DenialDescriptionLookup lookup,
        ICollection<string>? unresolved = null)
        => DeriveAll(rawDenialCode, lookup, unresolved).Description;

    /// <summary>
    /// Everything the derived columns carry for one denial cell. For each code that survives
    /// normalization: description and action category from the Denial Category Master (matched on
    /// the normalized code), else from the Denial-Action masters; action code, SLA and priority from
    /// the Denial-Action masters. Each value is the text alone, multi-code cells joined with "; ",
    /// a value repeated across the cell's codes written once.
    /// </summary>
    public static DenialDerivedValues DeriveAll(
        string? rawDenialCode,
        DenialDescriptionLookup lookup,
        ICollection<string>? unresolved = null)
    {
        var description = new ValueList();
        var category = new ValueList();
        var actionCode = new ValueList();
        var sla = new ValueList();
        var priority = new ValueList();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var code in Split(rawDenialCode))
        {
            // Same codes as the normalized column: an excluded code is neither described nor
            // reported as unresolved.
            var (key, excluded) = Strip(code);
            if (excluded || key.Length == 0 || !seen.Add(key)) continue;

            var info = lookup.ResolveInfo(code);

            if (string.IsNullOrWhiteSpace(info.Description)) unresolved?.Add(key);

            description.Add(info.Description);
            category.Add(info.ActionCategory);
            actionCode.Add(info.ActionCode);
            sla.Add(info.Sla);
            priority.Add(info.Priority);
        }

        return new DenialDerivedValues(description.Joined, category.Joined, actionCode.Joined, sla.Joined, priority.Joined);
    }

    /// <summary>Distinct non-blank values in first-seen order, joined with "; ".</summary>
    private sealed class ValueList
    {
        private readonly List<string> _values = new();
        private readonly HashSet<string> _seen = new(StringComparer.OrdinalIgnoreCase);

        public void Add(string? value)
        {
            var text = value?.Trim();
            if (!string.IsNullOrEmpty(text) && _seen.Add(text)) _values.Add(text);
        }

        public string? Joined => _values.Count == 0 ? null : string.Join(DescriptionSeparator, _values);
    }
}

/// <summary>The derived denial columns for one denial cell; null where nothing was found.</summary>
public sealed record DenialDerivedValues(
    string? Description, string? ActionCategory, string? ActionCode, string? Sla, string? Priority);

/// <summary>What one master row says about a denial code. Any field may be blank.</summary>
public sealed record DenialCodeInfo(
    string? Description = null, string? ActionCategory = null, string? ActionCode = null, string? Sla = null, string? Priority = null)
{
    public static readonly DenialCodeInfo Empty = new();
}

/// <summary>
/// The denial code lookups behind the derived columns.
///
/// <para><b>Description and action category</b> come from the Denial Category Master
/// (<c>LRNMaster.dbo.DenialCategoryMaster</c>), matched on the NORMALIZED code - the master holds
/// the common codes (10, B7, OA252), so CO10, PR10 and PI10 all find "10". A code the Category
/// Master does not have falls back to the Denial-Action cascade below.</para>
///
/// <para><b>Action code, SLA and priority</b> - and the fallback description / category - come from
/// the Denial-Action cascade, in the order the requirements define it:</para>
/// <list type="number">
///   <item>The lab's own Denial-Action master (<c>dbo.DenialCodeMaster</c>) matched on the RAW code.</item>
///   <item>The Denial-Action Super Master (<c>LRNMaster.dbo.DenialMapperSuperMaster</c>), RAW code.</item>
///   <item>The lab's Denial-Action master matched on the NORMALIZED code.</item>
///   <item>The Super Master, normalized code.</item>
/// </list>
/// <para>Each field walks the cascade on its own and takes the first non-blank value, so a lab row
/// carrying an action code but no description still supplies the action code.</para>
///
/// <para>The lab's own table outranks the Super Master at both steps because a lab that has
/// customised a value means it; the raw code outranks the normalized one because it is the more
/// specific match, and falling back to the normalized code is what lets a claim carrying CO10 pick
/// up a value the master stores only under PR10.</para>
/// </summary>
public sealed class DenialDescriptionLookup
{
    // Category Master rows by their cleaned code, prefix kept ("10", "B7", "OA252"), so an OA row
    // never overwrites the plain code it would normalize to.
    private readonly Dictionary<string, DenialCodeInfo> _categoryByNormalized = new(StringComparer.OrdinalIgnoreCase);
    // Denial-Action master rows stored under an OA code, reached by the OA fallback.
    private readonly Dictionary<string, DenialCodeInfo> _labByOa = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, DenialCodeInfo> _superByOa = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, DenialCodeInfo> _labByRaw = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, DenialCodeInfo> _labByNormalized = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, DenialCodeInfo> _superByRaw = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, DenialCodeInfo> _superByNormalized = new(StringComparer.OrdinalIgnoreCase);

    public int CategoryCodeCount => _categoryByNormalized.Count;
    public int LabCodeCount => _labByRaw.Count;
    public int SuperCodeCount => _superByRaw.Count;
    public bool IsEmpty => _categoryByNormalized.Count == 0 && _labByRaw.Count == 0 && _superByRaw.Count == 0;

    /// <summary>Adds one row of the Denial Category Master: description and action category.</summary>
    public void AddCategory(string? denialCode, string? description, string? actionCategory)
    {
        var code = DenialCodeNormalizer.Clean(denialCode);
        var info = Clean(new DenialCodeInfo(description, actionCategory));
        if (code.Length == 0 || info is null) return;

        // A master row written with a CO/PR/PI group ("CO10") is filed under its common code;
        // an OA row keeps its OA ("OA252") for the OA fallback; anything else as it is.
        var key = DenialCodeNormalizer.OaForm(code) ?? DenialCodeNormalizer.Normalize(code);
        if (key.Length > 0) _categoryByNormalized.TryAdd(key, info);
    }

    /// <summary>Adds one row of the lab's own Denial-Action master.</summary>
    public void AddLab(string? denialCode, string? description) => AddLab(denialCode, new DenialCodeInfo(description));

    /// <summary>Adds one row of the lab's own Denial-Action master, with its action fields.</summary>
    public void AddLab(string? denialCode, DenialCodeInfo info) => Add(_labByRaw, _labByNormalized, _labByOa, denialCode, info);

    /// <summary>Adds one row of the Denial-Action Super Master.</summary>
    public void AddSuper(string? denialCode, string? description) => AddSuper(denialCode, new DenialCodeInfo(description));

    /// <summary>Adds one row of the Denial-Action Super Master, with its action fields.</summary>
    public void AddSuper(string? denialCode, DenialCodeInfo info) => Add(_superByRaw, _superByNormalized, _superByOa, denialCode, info);

    private static void Add(
        Dictionary<string, DenialCodeInfo> byRaw,
        Dictionary<string, DenialCodeInfo> byNormalized,
        Dictionary<string, DenialCodeInfo> byOa,
        string? denialCode,
        DenialCodeInfo info)
    {
        var code = DenialCodeNormalizer.Clean(denialCode);
        var clean = Clean(info);
        if (code.Length == 0 || clean is null) return;

        byRaw.TryAdd(code, clean);

        // An OA row is kept apart from the plain code it normalizes to (OA97 vs 97): it answers
        // only the OA fallback, so the CO/PR/PI wording of 97 is what a bare 97 finds.
        var oa = DenialCodeNormalizer.OaForm(code);
        if (oa is not null)
        {
            byOa.TryAdd(oa, clean);
            return;
        }

        // CO10, PR10 and PI10 all collapse onto "10" here. They carry the same values, so the
        // first one read wins and which one that was does not matter.
        var normalized = DenialCodeNormalizer.Normalize(code);
        if (normalized.Length > 0) byNormalized.TryAdd(normalized, clean);
    }

    /// <summary>Trims every field; null when nothing is left, so a blank row is never a match.</summary>
    private static DenialCodeInfo? Clean(DenialCodeInfo info)
    {
        static string? T(string? v) => string.IsNullOrWhiteSpace(v) ? null : v.Trim();
        var clean = new DenialCodeInfo(T(info.Description), T(info.ActionCategory), T(info.ActionCode), T(info.Sla), T(info.Priority));
        return clean == DenialCodeInfo.Empty ? null : clean;
    }

    /// <summary>The description for one raw code, or null when no master has one.</summary>
    public string? Resolve(string? rawDenialCode) => ResolveInfo(rawDenialCode).Description;

    /// <summary>Every derived value for one raw code; fields no master has are null.</summary>
    public DenialCodeInfo ResolveInfo(string? rawDenialCode)
    {
        var raw = DenialCodeNormalizer.Clean(rawDenialCode);
        if (raw.Length == 0) return DenialCodeInfo.Empty;

        var normalized = DenialCodeNormalizer.Normalize(raw);
        var oa = DenialCodeNormalizer.OaForm(raw);

        // Category Master: the normalized code (OA, CO, PR, PI, '-' and '.' removed) first; when
        // that has no row and the code carried OA, the OA form ("OA97") is tried.
        DenialCodeInfo? category = null;
        if (normalized.Length > 0) _categoryByNormalized.TryGetValue(normalized, out category);
        if (category is null && oa is not null) _categoryByNormalized.TryGetValue(oa, out category);

        // The Denial-Action cascade, most specific first, then the OA fallback.
        var cascade = new List<DenialCodeInfo>(6);
        if (_labByRaw.TryGetValue(raw, out var labRaw)) cascade.Add(labRaw);
        if (_superByRaw.TryGetValue(raw, out var superRaw)) cascade.Add(superRaw);
        if (normalized.Length > 0)
        {
            if (_labByNormalized.TryGetValue(normalized, out var labNormalized)) cascade.Add(labNormalized);
            if (_superByNormalized.TryGetValue(normalized, out var superNormalized)) cascade.Add(superNormalized);
        }
        if (oa is not null)
        {
            if (_labByOa.TryGetValue(oa, out var labOa)) cascade.Add(labOa);
            if (_superByOa.TryGetValue(oa, out var superOa)) cascade.Add(superOa);
        }

        string? First(Func<DenialCodeInfo, string?> field) => cascade.Select(field).FirstOrDefault(v => v is not null);

        return new DenialCodeInfo(
            Description: category?.Description ?? First(i => i.Description),
            ActionCategory: category?.ActionCategory ?? First(i => i.ActionCategory),
            ActionCode: First(i => i.ActionCode),
            Sla: First(i => i.Sla),
            Priority: First(i => i.Priority));
    }
}
