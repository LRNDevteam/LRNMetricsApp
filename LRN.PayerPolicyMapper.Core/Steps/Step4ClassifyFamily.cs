namespace LRN.PayerPolicyMapper.Core.Steps;

/// <summary>
/// Step 4 - brand family: first PayerFamilyRule regex hit in Priority order (lower first, so
/// AETNA_BETTER_HEALTH at 10 beats AETNA at 50). A null family does NOT stop the pipeline -
/// Step 6 falls back to the full master.
/// </summary>
public static class Step4ClassifyFamily
{
    public static void Run(MatchContext context, PayerPolicyIndex index)
    {
        foreach (var (family, regex) in index.FamilyRules)
        {
            if (regex.IsMatch(context.CanonicalName))
            {
                context.CandidateFamily = family;
                return;
            }
        }
    }
}
