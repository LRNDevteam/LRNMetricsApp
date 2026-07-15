namespace LRN.PayerPolicyMapper.Core.Steps;

/// <summary>
/// Step 2 - resolve the state signal, three ordered sub-steps:
///  1. state code/full name embedded in the CanonicalName (USStateCode)     -> NameEmbedded
///  2. StateBrandMapping keyword containment (EMPIRE BLUECROSS -> NY, even
///     when the submitting lab is in Utah)                                  -> BrandMapping
///  3. the lab's own state (LabStateCode / LabState)                        -> LabState
///  else null                                                               -> None
/// The source is recorded - it goes in the audit and gates the Step 8 tie rule.
/// </summary>
public static class Step2ResolveState
{
    public static void Run(MatchContext context, PayerPolicyIndex index)
    {
        var name = context.CanonicalName;

        // 2.1 embedded full state names (longest first: WEST VIRGINIA before VIRGINIA), then 2-letter codes.
        foreach (var (stateName, code) in index.StateNamesByLength)
        {
            if (stateName.Length == 0) continue;
            if (ContainsPhrase(name, stateName))
            {
                context.ResolvedStateCode = code;
                context.StateSignalSource = StateSignalSource.NameEmbedded;
                return;
            }
        }
        foreach (var word in name.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (word.Length == 2 && index.StateCodes.Contains(word))
            {
                context.ResolvedStateCode = word;
                context.StateSignalSource = StateSignalSource.NameEmbedded;
                return;
            }
        }

        // 2.2 brand -> home-state mapping. Multi-word keywords are additionally matched space-insensitively,
        // because the seed keyword may join words the raw name splits ("EMPIRE BLUECROSS" vs
        // "EMPIRE BLUE CROSS ..."). Single-word keywords get whole-word matching ONLY - a compact
        // substring test would let MEDICA fire inside MEDICARE.
        var compactName = name.Replace(" ", string.Empty);
        foreach (var (keyword, compactKeyword, code) in index.BrandMappings)
        {
            if (ContainsPhrase(name, keyword)
                || (keyword.Contains(' ') && compactName.Contains(compactKeyword, StringComparison.Ordinal)))
            {
                context.ResolvedStateCode = code;
                context.StateSignalSource = StateSignalSource.BrandMapping;
                return;
            }
        }

        // 2.3 lab-state fallback (code first, then full name).
        var labState = index.ResolveStateValue(context.LabStateCode) ?? index.ResolveStateValue(context.LabState);
        if (labState != null)
        {
            context.ResolvedStateCode = labState;
            context.StateSignalSource = StateSignalSource.LabState;
            return;
        }

        context.StateSignalSource = StateSignalSource.None;
    }

    private static bool ContainsPhrase(string text, string phrase)
    {
        var at = 0;
        while ((at = text.IndexOf(phrase, at, StringComparison.Ordinal)) >= 0)
        {
            var before = at == 0 || text[at - 1] == ' ';
            var end = at + phrase.Length;
            var after = end == text.Length || text[end] == ' ';
            if (before && after) return true;
            at = end;
        }
        return false;
    }
}
