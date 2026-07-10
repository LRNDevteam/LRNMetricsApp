using System.Text.RegularExpressions;
using LRN.PayerPolicyMapper.Core.Steps;

namespace LRN.PayerPolicyMapper.Core;

/// <summary>
/// Step 0: immutable in-memory reference index shared by the web app and the worker.
/// Built once from a ReferenceDataSet snapshot and swapped atomically by the index provider
/// when any source table changes. All regexes are compiled here, policy names are
/// canonicalized once (Step 1A transform), and the alias table is a composite-key dictionary.
/// </summary>
public sealed class PayerPolicyIndex
{
    private PayerPolicyIndex() { }

    /// <summary>Full state names ordered longest-first (so WEST VIRGINIA wins over VIRGINIA), canonicalized.</summary>
    public IReadOnlyList<(string CanonicalName, string StateCode)> StateNamesByLength { get; private init; } = Array.Empty<(string, string)>();
    public IReadOnlySet<string> StateCodes { get; private init; } = new HashSet<string>();
    /// <summary>Lookup accepting a 2-letter code or a full state name (canonicalized, case-insensitive).</summary>
    public IReadOnlyDictionary<string, string> StateLookup { get; private init; } = new Dictionary<string, string>();

    /// <summary>Plan/network codes canonicalized, multi-word first ("POS II" before "POS") - Step 1B strip order.</summary>
    public IReadOnlyList<string> PlanCodesByLength { get; private init; } = Array.Empty<string>();

    /// <summary>Brand keyword -> state code, in MappingId order; keywords canonicalized. Null-state rows are excluded
    /// (they exist only to carry a normalized brand name; state must come from the name or review).</summary>
    public IReadOnlyList<(string CanonicalKeyword, string CompactKeyword, string StateCode)> BrandMappings { get; private init; }
        = Array.Empty<(string, string, string)>();

    /// <summary>Program rules in Priority order; the NULL-pattern Commercial fallback has Regex == null.</summary>
    public IReadOnlyList<(string ProgramType, Regex? Regex)> ProgramRules { get; private init; } = Array.Empty<(string, Regex?)>();

    /// <summary>Family rules in Priority order (lower first), regexes compiled once.</summary>
    public IReadOnlyList<(string Family, Regex Regex)> FamilyRules { get; private init; } = Array.Empty<(string, Regex)>();

    /// <summary>Step 5 alias shortcut keyed on the composite (CanonicalName, ResolvedStateCode) - never name alone.</summary>
    public IReadOnlyDictionary<(string Name, string? State), int> Aliases { get; private init; }
        = new Dictionary<(string, string?), int>();

    public IReadOnlyList<PayerPolicyRecord> PolicyRecords { get; private init; } = Array.Empty<PayerPolicyRecord>();
    /// <summary>Family-key indexed buckets for Step 6 candidate selection.</summary>
    public IReadOnlyDictionary<string, IReadOnlyList<PayerPolicyRecord>> PolicyRecordsByFamily { get; private init; }
        = new Dictionary<string, IReadOnlyList<PayerPolicyRecord>>();

    /// <summary>Policy rows whose GlobalPayerId is NULL or not castable to int (manual-review-only candidates).</summary>
    public IReadOnlyList<PayerPolicyRecord> RecordsMissingGlobalPayerId { get; private init; } = Array.Empty<PayerPolicyRecord>();

    public static PayerPolicyIndex Build(ReferenceDataSet data)
    {
        var stateLookup = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var stateCodes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var stateNames = new List<(string CanonicalName, string StateCode)>();
        foreach (var s in data.States)
        {
            var code = s.StateCode.Trim().ToUpperInvariant();
            var canonicalName = Step1ACanonicalize.Run(s.StateName);
            stateCodes.Add(code);
            stateLookup[code] = code;
            if (canonicalName.Length > 0) stateLookup[canonicalName] = code;
            stateNames.Add((canonicalName, code));
        }
        stateNames.Sort((a, b) => b.CanonicalName.Length.CompareTo(a.CanonicalName.Length));

        var planCodes = data.PlanNetworkTypeCodes
            .Select(Step1ACanonicalize.Run)
            .Where(c => c.Length > 0)
            .Distinct()
            // multi-word first, then longest first, so "POS II" strips before "POS" and "HDHP HSA" before "HDHP"/"HSA"
            .OrderByDescending(c => c.Count(ch => ch == ' '))
            .ThenByDescending(c => c.Length)
            .ToList();

        var brandMappings = data.StateBrandMappings
            .Where(m => !string.IsNullOrWhiteSpace(m.StateCode))
            .OrderBy(m => m.MappingId)
            .Select(m =>
            {
                var canonical = Step1ACanonicalize.Run(m.BrandKeyword);
                return (canonical, canonical.Replace(" ", string.Empty), m.StateCode!.Trim().ToUpperInvariant());
            })
            .Where(m => m.Item1.Length > 0)
            .ToList();

        var programRules = data.ProgramTypeRules
            .OrderBy(r => r.Priority).ThenBy(r => r.RuleId)
            .Select(r => (r.ProgramType, string.IsNullOrWhiteSpace(r.Pattern)
                ? null
                : new Regex(r.Pattern!, RegexOptions.Compiled | RegexOptions.IgnoreCase)))
            .ToList();

        var familyRules = data.PayerFamilyRules
            .OrderBy(r => r.Priority).ThenBy(r => r.RuleId)
            // family patterns are plain alternations; wrap in word boundaries so UHC never fires inside UHCSR
            .Select(r => (r.Family, new Regex($@"\b(?:{r.Pattern})\b", RegexOptions.Compiled | RegexOptions.IgnoreCase)))
            .ToList();

        var aliases = new Dictionary<(string, string?), int>();
        foreach (var a in data.Aliases)
        {
            var key = (a.CanonicalName.Trim().ToUpperInvariant(),
                       string.IsNullOrWhiteSpace(a.ResolvedStateCode) ? null : a.ResolvedStateCode.Trim().ToUpperInvariant());
            aliases[key] = a.GlobalPayerId; // last row wins; the DB unique index makes duplicates impossible in practice
        }

        // Precompute policy record canonical forms, state codes, program types and family keys.
        var records = data.PolicyRecords;
        foreach (var r in records)
        {
            r.CanonicalRawName = Step1ACanonicalize.Run(r.PayerNameRaw);
            r.CanonicalNormalizedName = string.IsNullOrWhiteSpace(r.PayerNameNormalized) ? null : Step1ACanonicalize.Run(r.PayerNameNormalized);
            r.StateCode = ResolveState(r.PayerState, stateLookup);
            r.FamilyKey = FamilyKey(r.PayerFamily);
            r.ProgramType = !string.IsNullOrWhiteSpace(r.PlanType)
                ? r.PlanType!.Trim()
                : InferProgram(r.CanonicalRawName, programRules);
        }

        var byFamily = records
            .Where(r => r.FamilyKey != null)
            .GroupBy(r => r.FamilyKey!)
            .ToDictionary(g => g.Key, g => (IReadOnlyList<PayerPolicyRecord>)g.ToList());

        return new PayerPolicyIndex
        {
            StateNamesByLength = stateNames,
            StateCodes = stateCodes,
            StateLookup = stateLookup,
            PlanCodesByLength = planCodes,
            BrandMappings = brandMappings,
            ProgramRules = programRules,
            FamilyRules = familyRules,
            Aliases = aliases,
            PolicyRecords = records,
            PolicyRecordsByFamily = byFamily,
            RecordsMissingGlobalPayerId = records.Where(r => r.GlobalPayerId is null).ToList()
        };
    }

    /// <summary>Resolves a free-form state value (2-letter code or full name) to a 2-letter code.</summary>
    public string? ResolveStateValue(string? value) => ResolveState(value, StateLookup);

    /// <summary>Alphanumeric-only uppercase key so "AETNA_BETTER_HEALTH" and "Aetna Better Health" compare equal.</summary>
    public static string? FamilyKey(string? family)
    {
        if (string.IsNullOrWhiteSpace(family)) return null;
        var key = new string(family.Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        return key.Length == 0 ? null : key;
    }

    private static string? ResolveState(string? value, IReadOnlyDictionary<string, string> lookup)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var canonical = Step1ACanonicalize.Run(value);
        return lookup.TryGetValue(canonical, out var code) ? code : null;
    }

    private static string? InferProgram(string canonicalName, IReadOnlyList<(string ProgramType, Regex? Regex)> rules)
    {
        foreach (var (program, regex) in rules)
            if (regex is null || regex.IsMatch(canonicalName)) return program;
        return null;
    }
}
