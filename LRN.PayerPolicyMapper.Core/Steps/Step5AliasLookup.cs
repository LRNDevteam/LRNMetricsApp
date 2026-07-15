namespace LRN.PayerPolicyMapper.Core.Steps;

/// <summary>
/// Step 5 - alias shortcut. Dictionary lookup on the composite key (CanonicalName, ResolvedStateCode) -
/// never CanonicalName alone: bare "MEDICARE" maps to 1195 for an IL lab and 1186 with no state signal.
/// A hit means ConfidenceScore 100 / Decision AutoMap and the pipeline skips to Step 9.
/// </summary>
public static class Step5AliasLookup
{
    public static void Run(MatchContext context, PayerPolicyIndex index)
    {
        if (index.Aliases.TryGetValue((context.CanonicalName, context.ResolvedStateCode), out var globalPayerId))
        {
            context.AliasHit = true;
            context.AliasGlobalPayerId = globalPayerId;
        }
    }
}
